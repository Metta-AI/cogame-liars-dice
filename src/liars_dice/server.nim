## Liar's Dice game server: implements the Coworld game contract.
##
## Endpoints:
##   GET /healthz                    - liveness
##   GET /client/global              - spectator page
##   GET /client/player              - player page (view-only; policies are prompts)
##   GET /client/replay              - replay page (replay mode)
##   GET /client/renderer.js         - shared stage renderer
##   GET /client/chrome.css          - shared chrome stylesheet
##   GET /client/assets/<name>       - sprites and fonts
##   WS  /player?slot=N&token=T      - player protocol (prompt delivery)
##   WS  /global                     - spectator snapshots
##   WS  /replay                     - replay payload (replay mode)
##
## Player protocol (liarsdice.player.v1), all JSON text frames:
##   game -> player: {"type":"welcome","slot":N,"name":...}
##                   {"type":"state",...} after every event (redacted to the
##                   seat's own tallies: hands, bids and talk are not for the
##                   container, and every decision is server-side)
##                   {"type":"final","scores":[...],"points":[...]}
##   player -> game: {"type":"prompt","prompt":"...","scripted":bool,
##                    "baseline":"bayes|pressure"}
##                   (max 4000 chars; scripted:true plays the named baseline
##                   for that seat instead of the LLM)

import
  std/[json, locks, os, sets, strutils, tables, times, unicode],
  bitworld/runtime,
  curly,
  mummy,
  mummy/routers,
  llm,
  sim

const
  MaxPromptLen = 4000
  ReplayVersion = 1

type
  GameState = object
    config: GameConfig
    sim: Sim
    prompts: seq[string]
    scripted: seq[bool]
    baselines: seq[string]
    external: seq[bool]
    registered: seq[bool]
    awaitingSeat: int
    awaitingEvent: int
    pendingAction: Decision
    hasPendingAction: bool
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    started: bool
    finished: bool

var
  stateLock: Lock
  state: GameState
  gameServer: Server
  runtimeConfigGlobal: RuntimeConfig
  replayPayloadGlobal: string

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc dataDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "data", appDir / ".." / "data", "data"]:
    if dirExists(candidate):
      return candidate
  "data"

proc policyNamesJson(gs: GameState): JsonNode =
  ## Seats play under anonymous table names; the policy names ride alongside
  ## for the SPECTATOR views only, which render them in place of the aliases.
  result = newJArray()
  for player in gs.config.players:
    result.add(%player.name)

proc snapshotJson(gs: GameState): JsonNode =
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  var connected = newJArray()
  for slot in 0 ..< gs.config.tokens.len:
    connected.add(%gs.playerSockets.hasKey(slot))
  result = gs.sim.tableStateJson()
  result["type"] = %"state"
  result["game"] = %"liars-dice"
  result["policyNames"] = gs.policyNamesJson()
  result["events"] = events
  result["started"] = %gs.started
  result["done"] = %gs.sim.done
  result["connected"] = connected

proc playerStateJson(gs: GameState, slot: int): JsonNode =
  ## Liar's Dice is a hidden-information game and every decision is made
  ## server-side, so a player container sees only its own seat's tallies and
  ## the deal counter. Handing it hands, bids or talk would let a wrapper
  ## policy meta-game and would lose nothing by being withheld.
  %*{
    "type": "state",
    "slot": slot,
    "name": gs.sim.names[slot],
    "seat": {
      "score": gs.sim.score(slot),
      "points": gs.sim.points(slot),
      "wins": gs.sim.wins[slot],
      "losses": gs.sim.losses[slot],
      "bids": gs.sim.bidCount[slot],
      "challenges": gs.sim.challengeCount[slot]
    },
    "deal": gs.sim.deal,
    "deals": gs.config.deals,
    "dealsPlayed": gs.sim.dealsPlayed,
    "started": gs.started,
    "done": gs.sim.done,
    "reason": gs.sim.reason
  }

proc decisionObservation*(sim: Sim, slot: int): JsonNode =
  ## One seat's normal decision view. Current hands and private notes of
  ## other seats never enter this frame; prior revealed hands are public.
  var names = newJArray()
  var standings = newJArray()
  for index, name in sim.names:
    names.add(%name)
    standings.add(%*{"name": name, "score": sim.score(index),
      "points": sim.points(index)})
  var bids = newJArray()
  for bid in sim.dealBids:
    bids.add(%*{"seat": bid.seat, "quantity": bid.quantity,
      "face": bid.face})
  var talk = newJArray()
  for entry in sim.dealSays:
    talk.add(%*{"seat": entry.seat, "say": entry.text})
  var history = newJArray()
  var dealtHands: seq[seq[int]]
  for event in sim.events:
    case event.kind
    of evDeal:
      dealtHands = event.hands
    of evChallenge:
      history.add(%*{"deal": event.deal, "challenger": event.seat,
        "bidder": event.other, "quantity": event.quantity,
        "face": event.face, "actual": event.actual,
        "hands": dealtHands, "bidderWins": event.bidderWins})
    else:
      discard
  var legalBids = newJArray()
  for quantity in 1 .. sim.totalSymbols():
    for face in sim.config.lowFace() .. sim.config.highFace():
      if sim.legalBid(quantity, face):
        legalBids.add(%*{"quantity": quantity, "face": face})
  %*{"slot": slot, "name": sim.names[slot], "names": names,
    "mode": $sim.config.mode, "talk": sim.config.talk,
    "deal": sim.deal, "deals": sim.config.deals,
    "hand": sim.hands[slot], "handSize": sim.config.handSize,
    "faces": sim.config.faces(), "lowFace": sim.config.lowFace(),
    "totalSymbols": sim.totalSymbols(), "order": sim.order,
    "standingBid": (if sim.bidSeat < 0: newJNull() else:
      %*{"seat": sim.bidSeat, "quantity": sim.bidQuantity,
        "face": sim.bidFace}),
    "bids": bids, "talkHistory": talk, "history": history,
    "standings": standings, "notes": sim.notes[slot],
    "legalBids": legalBids, "canChallenge": sim.bidSeat >= 0}

proc broadcastLocked(gs: GameState) =
  ## Callers hold stateLock. Spectators get the whole table; players get the
  ## redacted per-seat state.
  let payload = $gs.snapshotJson()
  for socket in gs.globalSockets:
    socket.send(payload)
  for slot, socket in gs.playerSockets:
    socket.send($gs.playerStateJson(slot))

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  ## Writes a Coworld artifact, honoring the platform's PUT/POST method hint.
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError,
        "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc replayConfigJson(gs: GameState): JsonNode =
  var order = newJArray()
  for slot in gs.sim.order:
    order.add(%slot)
  %*{
    "mode": $gs.config.mode,
    "seats": gs.config.players.len,
    "handSize": gs.config.handSize,
    "faces": gs.config.faces(),
    "deals": gs.config.deals,
    "talk": gs.config.talk,
    "maxBidsPerDeal": gs.config.maxBidsPerDeal,
    "seed": gs.config.seed,
    "sampled": true,
    "order": order
  }

proc replayPayload(gs: GameState, results: JsonNode): string =
  var names = newJArray()
  for name in gs.sim.names:
    names.add(%name)
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  $ %*{
    "protocol": "liarsdice.replay.v" & $ReplayVersion,
    "names": names,
    "policyNames": gs.policyNamesJson(),
    "config": gs.replayConfigJson(),
    "events": events,
    "results": results
  }

proc statesFromEvents(config: GameConfig, events: seq[GameEvent]): JsonNode =
  ## One table-state object per event prefix, for scrubbing replays.
  result = newJArray()
  for frame in replayMatch(config, events):
    result.add(frame.tableStateJson())

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    results = state.sim.resultsJson()
    replayData = state.replayPayload(results)

    ## Send final frames to players BEFORE writing artifacts: the hosted
    ## worker tears player pods down as soon as results.json exists, and
    ## writing first would race player log collection.
    ## Results carry POLICY names for the platform, but the final frame goes
    ## to the player sockets — hand them the table aliases instead.
    var aliasNames = newJArray()
    for name in state.sim.names:
      aliasNames.add(%name)
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "points": results["points"],
      "wins": results["wins"],
      "losses": results["losses"],
      "names": aliasNames,
      "deals": results["deals"],
      "reason": results["reason"]
    }
    for slot, socket in state.playerSockets:
      final["slot"] = %slot
      socket.send($final)
    state.broadcastLocked()

  sleep(500)
  echo "liars-dice: writing results and replay"
  writeArtifact(
    runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD"
  )
  writeArtifact(
    runtimeConfig.replayUri, replayData, "application/octet-stream",
    "COGAME_SAVE_REPLAY_METHOD"
  )
  sleep(500)
  echo "liars-dice: episode complete, shutting down"
  quit(0)

const PlayBudgetFraction* = 0.6
  ## Share of the platform's episode timeout spent playing. The rest covers
  ## container start, player connects, and writing the artifacts — the part
  ## that must never be the thing that runs out of time.

proc decisionText(sim: Sim, seat: int, decision: Decision): string =
  case decision.action
  of aBid:
    sim.names[seat] & " bids " & bidText(decision.quantity, decision.face)
  of aChallenge:
    sim.names[seat] & " challenges"

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let gameStart = epochTime()
    let connectDeadline = gameStart + config.playerConnectTimeoutSeconds

    while epochTime() < connectDeadline:
      var allConnected = false
      withLock stateLock:
        allConnected = state.playerSockets.len >= config.tokens.len
      if allConnected:
        break
      sleep(200)

    let registerDeadline = epochTime() + 3.0
    while epochTime() < registerDeadline:
      var allRegistered = true
      withLock stateLock:
        for slot in 0 ..< config.tokens.len:
          if state.playerSockets.hasKey(slot) and not state.registered[slot]:
            allRegistered = false
      if allRegistered:
        break
      sleep(20)

    withLock stateLock:
      state.started = true
      echo "liars-dice: starting with ", state.playerSockets.len, "/",
        config.tokens.len, " players connected"
      state.broadcastLocked()

    let client = newLlmClient(config)

    ## The platform kills the episode at its timeout and keeps nothing. Play
    ## inside a fraction of it so results and the replay are written with
    ## room to spare. The hosted dispatcher hands the timeout only to its own
    ## worker sidecar, NOT to the game container, so when the env is silent
    ## assume the configured platform default rather than playing open-ended.
    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    var timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: 0.0
      else: 0.0
    if timeoutSeconds <= 0.0:
      timeoutSeconds = config.episodeTimeoutSeconds.float
    let playDeadline =
      if timeoutSeconds > 0.0: gameStart + timeoutSeconds * PlayBudgetFraction
      else: 0.0
    ## A decision costs at most two model calls; never START one that could
    ## still be in flight when the play clock runs out.
    let callGuard = 2.0 * config.llmTimeoutSeconds.float + 5.0
    if playDeadline > 0.0:
      echo "liars-dice: episode timeout ", timeoutSeconds.int, "s (",
        (if hostedTimeout.len > 0: "from env" else: "assumed"),
        "); playing until ", (timeoutSeconds * PlayBudgetFraction).int,
        "s, last model call by ",
        (timeoutSeconds * PlayBudgetFraction - callGuard).int, "s"

    while true:
      var simCopy: Sim
      var turn: Turn
      var seatPrompt: string
      var seatScripted: bool
      var seatBaseline: string
      var seatExternal: bool
      withLock stateLock:
        if state.sim.done:
          break
        turn = state.sim.currentTurn()
        let now = epochTime()
        let pastDeadline = playDeadline > 0.0 and now > playDeadline
        if turn.kind == tkNone:
          break
        if turn.kind == tkDeal:
          if pastDeadline:
            ## The platform keeps nothing at all from an episode that outruns
            ## its timeout, so give up deals rather than the whole result:
            ## stop here, between deals.
            echo "liars-dice: episode deadline reached after ",
              state.sim.dealsPlayed, "/", config.deals,
              " deals; ending early"
            state.sim.endEarly()
            state.broadcastLocked()
            break
          state.sim.beginDeal()
          echo "liars-dice: deal ", state.sim.deal + 1, " of ", config.deals,
            ", opener ", state.sim.names[state.sim.opener], " at ",
            (now - gameStart).int, "s"
          state.broadcastLocked()
          continue
        ## Rule 8: at the bid cap the sim forces a challenge on the acting
        ## seat's behalf — no model call, and the deal is bounded.
        if state.sim.mustChallenge():
          let seat = turn.seat
          state.sim.applyChallenge(seat, scripted = true, forced = true)
          echo "liars-dice: ", state.sim.names[seat],
            " forced to challenge at the bid cap"
          state.broadcastLocked()
          continue
        simCopy = state.sim
        seatPrompt = state.prompts[turn.seat]
        seatBaseline = state.baselines[turn.seat]
        ## Past the guard every remaining decision is taken by the baseline
        ## (instant) so the deal completes and the hands are revealed. The
        ## note is explicit about WHICH baseline finishes a deal the play
        ## clock interrupted: "remaining decisions of that deal are `bayes`
        ## (instant) so the deal completes" (design.md:408) — the deal is
        ## being finished for the clock's sake, not played, so it is finished
        ## on the calibrated line rather than on whatever pressure the seat
        ## registered.
        let deadlineForced =
          playDeadline > 0.0 and now + callGuard > playDeadline
        if deadlineForced and not state.scripted[turn.seat]:
          seatBaseline = "bayes"
        seatScripted = state.scripted[turn.seat] or deadlineForced
        seatExternal = state.external[turn.seat] and not deadlineForced and
          state.playerSockets.hasKey(turn.seat)
        if seatExternal:
          state.awaitingSeat = turn.seat
          state.awaitingEvent = state.sim.events.len
          state.hasPendingAction = false
          state.playerSockets[turn.seat].send($ %*{
            "type": "observation", "event": state.awaitingEvent,
            "observation": state.sim.decisionObservation(turn.seat)})

      ## The slow part (Claude) runs outside the lock on a snapshot; only
      ## this thread mutates the sim, so the snapshot cannot go stale.
      var decision: Decision
      if seatExternal:
        let actionDeadline = epochTime() + config.llmTimeoutSeconds.float
        while epochTime() < actionDeadline:
          var ready = false
          withLock stateLock:
            ready = state.hasPendingAction
          if ready:
            break
          sleep(20)
        withLock stateLock:
          state.awaitingSeat = -1
          if state.hasPendingAction:
            decision = state.pendingAction
          else:
            decision = client.scriptedAction(simCopy, turn.seat, "bayes")
            decision.fallback = true
      else:
        decision = client.decide(simCopy, turn.seat, seatPrompt,
          scripted = seatScripted, baseline = seatBaseline)

      var challenged = false
      withLock stateLock:
        echo "liars-dice: deal ", state.sim.deal + 1, " ",
          decisionText(state.sim, turn.seat, decision), " at ",
          (epochTime() - gameStart).int, "s"
        try:
          if decision.action == aBid:
            state.sim.applyBid(turn.seat, decision.quantity, decision.face,
              decision.say, decision.notes, decision.scripted,
              decision.fallback)
          else:
            state.sim.applyChallenge(turn.seat, decision.say, decision.notes,
              decision.scripted, decision.fallback)
            challenged = true
        except LiarsDiceError as error:
          echo "liars-dice: reply rejected (", error.msg,
            "); using the bayes fallback"
          let fallback = client.scriptedAction(state.sim, turn.seat, "bayes")
          if fallback.action == aBid:
            state.sim.applyBid(turn.seat, fallback.quantity, fallback.face,
              "", "", scripted = true, fallback = true)
          else:
            state.sim.applyChallenge(turn.seat, "", "", scripted = true,
              fallback = true)
            challenged = true
        state.broadcastLocked()

      ## Pace between deals: after the challenge that closes one.
      if config.turnDelayMs > 0 and challenged:
        sleep(config.turnDelayMs)

    ## Let the verdict land before the final frame.
    if config.turnDelayMs > 0:
      sleep(config.turnDelayMs)
    finishEpisode(runtimeConfig)

var gameThread: Thread[RuntimeConfig]

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc htmlHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name, "text/html; charset=utf-8")
  handler

proc assetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".png"): "image/png"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, dataDir() / name, contentType)

proc rendererHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(
      request, clientDir() / "renderer.js",
      "application/javascript; charset=utf-8"
    )

proc chromeCssHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(
      request, clientDir() / "chrome.css",
      "text/css; charset=utf-8"
    )

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
    if not authorized:
      request.respond(401)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      echo "liars-dice: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.tokens.len, ")"
      websocket.send($ %*{
        "type": "welcome",
        "protocol": "liarsdice.player.v2",
        "slot": slot,
        "name": state.sim.names[slot],
        "deals": state.config.deals,
        "mode": $state.config.mode,
        "talk": state.config.talk,
        "handSize": state.config.handSize,
        "faces": state.config.faces()
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      websocket.send($state.snapshotJson())

proc replayUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    if replayPayloadGlobal.len > 0:
      websocket.send(replayPayloadGlobal)

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering them
      ## itself; the platform's certifier pings /global to check the game is
      ## alive, so an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() == "register":
          if payload["control"].getStr() != "external":
            raise newException(LiarsDiceError, "unknown player control")
          withLock stateLock:
            state.external[slot] = true
            state.registered[slot] = true
          return
        if payload{"type"}.getStr() == "action":
          withLock stateLock:
            if state.external[slot] and state.awaitingSeat == slot and
                state.awaitingEvent == payload["event"].getInt():
              let decision = parseReply(state.sim, payload["action"])
              var probe = state.sim
              if decision.action == aBid:
                probe.applyBid(slot, decision.quantity, decision.face,
                  decision.say, decision.notes)
              else:
                probe.applyChallenge(slot, decision.say, decision.notes)
              state.pendingAction = decision
              state.hasPendingAction = true
          return
        if payload{"type"}.getStr() == "prompt":
          var prompt = payload{"prompt"}.getStr()
          if prompt.runeLen > MaxPromptLen:
            ## Rune boundary, never a byte boundary: a half-encoded prompt
            ## would ride into the model call and the log.
            prompt = prompt.runeSubStr(0, MaxPromptLen)
          let scripted = payload{"scripted"}.getBool(false)
          let asked = payload{"baseline"}.getStr("bayes")
          let baseline = normalizeBaseline(asked)
          if asked.len > 0 and asked != baseline:
            echo "liars-dice: slot ", slot, " asked for baseline '", asked,
              "'; coerced to '", baseline, "'"
          withLock stateLock:
            state.prompts[slot] = prompt
            state.scripted[slot] = scripted
            state.baselines[slot] = baseline
            state.external[slot] = false
            state.registered[slot] = true
          echo "liars-dice: slot ", slot, " delivered a prompt (",
            prompt.len, " chars",
            (if scripted: ", scripted " & baseline else: ""), ")"
      except CatchableError as error:
        echo "liars-dice: ignoring bad player frame: ", error.msg
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
        state.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  result.get("/healthz", healthzHandler)
  result.get("/client/global", htmlHandler("global.html"))
  result.get("/client/player", htmlHandler("player.html"))
  result.get("/client/replay", htmlHandler("replay.html"))
  result.get("/client/renderer.js", rendererHandler)
  result.get("/client/chrome.css", chromeCssHandler)
  result.get("/client/assets/@name", assetHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/replay", replayUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc configFromReplay*(payload: JsonNode): GameConfig =
  result = defaultGameConfig()
  let config = payload["config"]
  result.mode = parseMode(config{"mode"}.getStr("dice"))
  result.handSize = config{"handSize"}.getInt(5)
  result.deals = config{"deals"}.getInt(8)
  result.talk = config{"talk"}.getBool(true)
  result.maxBidsPerDeal = config{"maxBidsPerDeal"}.getInt(12)
  result.seed = config{"seed"}.getInt(0)
  ## The replay carries the episode's fitted cap; never re-fit it. The
  ## seating and the aliases are re-derived from the seed.
  result.sampled = true
  for name in payload["names"]:
    result.players.add(PlayerConfig(name: name.getStr()))

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  ## Replay mode: parse the recorded replay, precompute the scrub states, and
  ## serve the viewer until the platform tears the container down.
  let payload = parseJson(runtimeConfig.replay)
  let config = configFromReplay(payload)
  var events: seq[GameEvent]
  for node in payload["events"]:
    events.add(eventFromJson(node))
  var enriched = %*{
    "type": "replay",
    "protocol": payload{"protocol"}.getStr("liarsdice.replay.v1"),
    "names": payload["names"],
    "policyNames": payload{"policyNames"},
    "config": payload["config"],
    "events": payload["events"],
    "results": payload{"results"},
    "states": statesFromEvents(config, events)
  }
  replayPayloadGlobal = $enriched

  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler)
  echo "liars-dice: replay mode on ", runtimeConfig.host, ":",
    runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.players.len:
    raise newException(LiarsDiceError, "tokens and players must align")
  state.config = config
  state.sim = initSim(config)
  state.prompts = newSeq[string](config.players.len)
  state.scripted = newSeq[bool](config.players.len)
  state.baselines = newSeq[string](config.players.len)
  state.external = newSeq[bool](config.players.len)
  state.registered = newSeq[bool](config.players.len)
  state.awaitingSeat = -1
  for slot in 0 ..< config.players.len:
    state.baselines[slot] = "bayes"
  runtimeConfigGlobal = runtimeConfig

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  echo "liars-dice: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
