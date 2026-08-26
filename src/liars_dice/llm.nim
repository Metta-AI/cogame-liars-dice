## Claude-backed decision making for Liar's Dice. Each seat's policy is just
## a prompt: the game server composes the seat's view (its own hand, the
## public bid history, the table talk, every previous deal in full, the
## standings and its private notes) plus that seat's prompt and asks Claude
## whether to raise or to call the bluff.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal scripted
## baseline immediately (no retries, no network waits) so offline
## certification still completes - this fallback is load-bearing. The same
## scripted bot is also a fieldable policy: a player that registers as
## scripted plays it deliberately, LLM or not.

import
  std/[json, math, os, random, strutils, unicode],
  bitworld/runtime,
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  ## The calibrated baseline. Also the no-credentials fallback and the
  ## fallback for a rejected LLM reply, so it must always be legal.
  ## These two numbers are the pick of `tools/tune_baseline.nim`, a full
  ## round-robin sweep of a 110-point (chal, safe) lattice; its table is
  ## `data/tuning/threshold_sweep.tsv` (this point ranks 8 of 110 and is
  ## paired-tied with the optimum, at the centre of the 10-point winning
  ## plateau) and CI re-runs a slice of the same sweep on every push. Do not
  ## edit them by hand: rerun the harness and take its pick.
  BayesChallenge* = 0.15
  BayesSafe* = 0.35
  ## The bluffier filler: it calls a standing bid sooner than the tuned line
  ## and pads its chosen raise by one, so it bids past what its own read
  ## supports and the champions have something to catch. A deliberate foil,
  ## not a grid pick — the sweep ranks its cell (26 of 110, unpadded), it
  ## does not choose it.
  PressureChallenge* = 0.25
  PressureSafe* = 0.35
  ## The raise enumeration never proposes more than this many candidates.
  RaiseQuantitySteps = 3

type
  Action* = enum
    aBid = "bid"
    aChallenge = "challenge"

  Decision* = object
    action*: Action
    quantity*: int
    face*: int
    say*: string
    notes*: string
    scripted*: bool   ## produced by a scripted baseline
    fallback*: bool   ## the LLM reply was rejected twice

  Thresholds* = tuple[chal, safe: float, pad: bool]
    ## One scripted baseline's parameters: challenge a standing bid below
    ## `chal`, keep a raise only above `safe`, and (pressure only) pad the
    ## chosen raise by one. Named so the tuning harness can drive a point
    ## the shipped constants do not name.

  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string          ## anthropic transport
    bedrockEndpoint: string ## bedrock transport: sidecar or public host
    bedrockModels: seq[string]  ## candidates, tried in order on denial
    bedrockModel: int           ## index into bedrockModels
    bedrockToken: string
    model: string
    maxOutputTokens: int
    timeoutSeconds: int
    disabled*: bool   ## true once credentials are known-unavailable
    rand: Rand

proc clipText(text: string, cap: int): string =
  ## Rune-safe head of a diagnostic string: a byte cut mid-UTF-8 would make
  ## anything that records it fail a strict JSON parser.
  if text.runeLen <= cap: text else: text.runeSubStr(0, cap) & "..."

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "liars-dice llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL
  ## pins a single id; without it, fall through this list — model access is
  ## a per-account Marketplace subscription, so an id that works in one
  ## account 403s in another.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  ## Haiku leads: hosted Bedrock capacity is shared account-wide and the
  ## sonnet profiles run out of daily tokens first.
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-6",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "liars-dice llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds,
    rand: initRand(config.seed xor 0x5EED)
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION",
      getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "liars-dice llm: bedrock transport, url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "liars-dice llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "liars-dice llm: no LLM credentials; using scripted fallback"

# ---- Scripted baselines -----------------------------------------------------

proc normalizeBaseline*(name: string): string =
  ## `PLAYER_SCRIPTED` set to anything but `pressure` (including the legacy
  ## `1`) means `bayes`; the caller logs the coercion.
  if name.strip().toLowerAscii() == "pressure": "pressure" else: "bayes"

proc baselineThresholds*(name: string): Thresholds =
  if normalizeBaseline(name) == "pressure":
    (PressureChallenge, PressureSafe, true)
  else:
    (BayesChallenge, BayesSafe, false)

proc favouriteFace(sim: Sim, seat: int): int =
  ## The face this seat holds most of; ties go to the higher face.
  result = sim.config.lowFace()
  var best = -1
  for face in sim.config.lowFace() .. sim.config.highFace():
    let held = sim.ownCount(seat, face)
    if held >= best:
      best = held
      result = face

proc scriptedActionWith*(client: LlmClient, sim: Sim, seat: int,
    thresholds: Thresholds): Decision =
  ## Always legal by construction, never talks, never writes notes. The
  ## candidate enumeration is bounded by `RaiseQuantitySteps * faces`. Takes
  ## the thresholds directly so `tools/tune_baseline.nim` can play a grid
  ## point that no shipped baseline names.
  result.scripted = true
  let total = sim.totalSymbols()
  let standing = sim.bidSeat >= 0
  ## 1. A standing bid this seat judges unlikely is called immediately.
  if standing and sim.pTrue(seat, sim.bidQuantity, sim.bidFace) <
      thresholds.chal:
    result.action = aChallenge
    return
  ## 2. Rule 8: past the bid cap a challenge is the only legal move.
  if sim.mustChallenge():
    result.action = aChallenge
    return
  let best = favouriteFace(sim, seat)
  if not standing:
    ## 3. Opening: my own count plus the table's expected share.
    let unseen = (sim.seats() - 1) * sim.config.handSize
    let share = int(floor(unseen.float / sim.config.faces().float))
    result.action = aBid
    result.face = best
    result.quantity = max(1, min(sim.ownCount(seat, best) + share, total))
    return
  ## 4. Enumerate the small raise window and keep the safe ones.
  var bestQuantity = -1
  var bestFace = -1
  var bestP = -1.0
  let ceiling = min(sim.bidQuantity + RaiseQuantitySteps - 1, total)
  for quantity in sim.bidQuantity .. ceiling:
    for face in sim.config.lowFace() .. sim.config.highFace():
      if not sim.legalBid(quantity, face):
        continue
      let p = sim.pTrue(seat, quantity, face)
      if p < thresholds.safe:
        continue
      var better = p > bestP + 1e-12
      if not better and abs(p - bestP) <= 1e-12:
        ## Ties: the lower quantity, then the face I hold most of, then the
        ## seeded RNG.
        if quantity < bestQuantity:
          better = true
        elif quantity == bestQuantity:
          let mine = sim.ownCount(seat, face)
          let theirs = sim.ownCount(seat, bestFace)
          better = mine > theirs or (mine == theirs and client.rand.rand(1) == 1)
      if better:
        bestP = p
        bestQuantity = quantity
        bestFace = face
  if bestQuantity < 0:
    result.action = aChallenge
    return
  if thresholds.pad and bestQuantity + 1 <= total and
      sim.legalBid(bestQuantity + 1, bestFace):
    bestQuantity += 1
  result.action = aBid
  result.quantity = bestQuantity
  result.face = bestFace

proc scriptedAction*(client: LlmClient, sim: Sim, seat: int,
    baseline = "bayes"): Decision =
  ## The named baseline's move: `bayes` (the calibrated line, and the
  ## fallback everywhere) or `pressure` (the bluffier filler).
  client.scriptedActionWith(sim, seat, baselineThresholds(baseline))

# ---- Prompt building --------------------------------------------------------

const NumberWords = ["zero", "one", "two", "three", "four", "five", "six"]

proc numberWord(value: int): string =
  if value >= 0 and value < NumberWords.len: NumberWords[value] else: $value

proc symbolWord(sim: Sim): string =
  if sim.config.mode == mPoker: "digits" else: "dice"

proc systemPrompt*(sim: Sim, seat: int): string =
  let total = sim.totalSymbols()
  let dice = sim.config.mode == mDice
  result.add("You are " & sim.names[seat] &
    ", a cog at a Liar's Dice table with " & numberWord(sim.seats() - 1) &
    " other cogs.\n\nRules:\n")
  if dice:
    result.add("- Every deal each cog is dealt " & $sim.config.handSize &
      " hidden dice, faces 1 to 6. You see only your\n  own dice. There are " &
      $total & " dice on the table in total.\n")
    result.add("- A bid is a claim about ALL the dice on the table: \"6 x 2\" " &
      "claims that at\n  least six of the " & $total & " dice show a 2. Ones " &
      "are NOT wild: a die counts only for\n  its own face.\n")
  else:
    result.add("- Every deal each cog is dealt a hidden " &
      $sim.config.handSize & "-digit serial number, digits 0 to 9.\n  You " &
      "see only your own serial. There are " & $total &
      " digits on the table in total.\n")
    result.add("- A bid is a claim about ALL the digits on the table: " &
      "\"6 x 2\" claims that at\n  least six of the " & $total &
      " digits are a 2. A digit counts only for its own\n  value.\n")
  result.add("""- On your turn you either raise the standing bid or challenge it. A raise must
  be strictly higher: a larger quantity, or the same quantity with a higher
  face. The cog who opens a deal must bid.
- A challenge reveals every hand. If the standing bid is TRUE (the real count
  is at least its quantity) the BIDDER scores +1 and the challenger -1. If it
  is FALSE the CHALLENGER scores +1 and the bidder -1. Nobody else scores. The
  deal then ends and a fresh deal is dealt.
- Your score is 0.5 + (your wins - your losses) / (2 x deals). Break even is
  0.5. Bluffing is legal and expected; the losing moves are being caught and
  challenging a bid that turns out to be true.
""")
  if sim.config.talk:
    result.add("- You may attach one short line of table talk (at most " &
      $MaxSayLen & " characters) to any\n  action. Everyone sees it. It is " &
      "cheap talk: nothing you say binds you, and\n  nothing anyone else " &
      "says binds them.\n")
  result.add("""- Your notes are private to you and are fed back to you every turn.

OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no analysis, no
explanation, no markdown fences, no text before or after the object. Your reply
must begin with the character { and end with }.""")

proc tableLine(sim: Sim): string =
  ## Every seat in turn order for this deal, opener first.
  var parts: seq[string]
  let count = sim.seats()
  let start = if sim.deal >= 0: sim.deal mod count else: 0
  for step in 0 ..< count:
    parts.add(sim.names[sim.order[(start + step) mod count]])
  parts.join(", ")

proc biddingBlock(sim: Sim): string =
  if sim.dealBids.len == 0:
    return "(none)"
  var lines: seq[string]
  for index, entry in sim.dealBids:
    lines.add($(index + 1) & ". " & sim.names[entry.seat] & " bids " &
      bidText(entry.quantity, entry.face))
  lines.join("\n")

proc talkBlock(sim: Sim): string =
  if sim.dealSays.len == 0:
    return "(none)"
  var lines: seq[string]
  for entry in sim.dealSays:
    lines.add(sim.names[entry.seat] & ": \"" & entry.text & "\"")
  lines.join("\n")

proc historyBlock(sim: Sim): string =
  ## Every previous deal in full: the challenged bid, who challenged, the
  ## real count and all revealed hands. This is the learning signal.
  var hands: seq[seq[int]]
  var lines: seq[string]
  for event in sim.events:
    case event.kind
    of evDeal:
      hands = event.hands
    of evChallenge:
      let winner = if event.bidderWins: event.other else: event.seat
      var shown: seq[string]
      for position in 0 ..< sim.seats():
        let slot = sim.order[position]
        var symbols: seq[string]
        if slot < hands.len:
          for symbol in hands[slot]:
            symbols.add($symbol)
        shown.add(sim.names[slot] & " " & symbols.join(" "))
      lines.add("Deal " & $(event.deal + 1) & " - " &
        sim.names[event.other] & " bid " &
        bidText(event.quantity, event.face) & ", " & sim.names[event.seat] &
        (if event.forced: " was forced to challenge" else: " challenged") &
        ", the real count was " & $event.actual & ": " &
        sim.names[winner] & " scored. Hands: " & shown.join(" | "))
    else:
      discard
  if lines.len == 0:
    return "(none)"
  lines.join("\n")

proc standingsBlock(sim: Sim): string =
  var order: seq[int]
  for slot in 0 ..< sim.seats():
    order.add(slot)
  ## Highest points first; a stable insertion sort keeps ties in slot order.
  for i in 1 ..< order.len:
    var j = i
    while j > 0 and sim.points(order[j]) > sim.points(order[j - 1]):
      swap(order[j], order[j - 1])
      dec j
  var parts: seq[string]
  for slot in order:
    let value = sim.points(slot)
    parts.add(sim.names[slot] & " " & (if value > 0: "+" & $value else: $value) &
      " (" & $sim.wins[slot] & "W " & $sim.losses[slot] & "L)")
  parts.join(", ")

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules;\nalways reply in the requested format):\n" & prompt & "\n\n"

proc userPrompt*(sim: Sim, seat: int, prompt: string): string =
  let unseen = (sim.seats() - 1) * sim.config.handSize
  let symbols = sim.symbolWord()
  result.add("DEAL " & $(sim.deal + 1) & " OF " & $sim.config.deals &
    ". You are " & sim.names[seat] & ", position " &
    $(sim.seatAt[seat] + 1) & " of " & $sim.seats() & " in turn order.\n\n")
  result.add("TABLE (turn order this deal, opener first): " & sim.tableLine() &
    "\n\n")
  result.add("YOUR HAND: " & sim.handText(seat) & "\n\n")
  result.add(symbols.toUpperAscii() & " ON THE TABLE: " &
    $sim.totalSymbols() & " (yours: " & $sim.config.handSize &
    ", unseen to you: " & $unseen & ")\n\n")
  if sim.bidSeat >= 0:
    result.add("STANDING BID: " & bidText(sim.bidQuantity, sim.bidFace) &
      ", bid by " & sim.names[sim.bidSeat] & "\n\n")
  else:
    result.add("STANDING BID: (none - you open this deal and must bid)\n\n")
  result.add("BIDDING THIS DEAL:\n" & sim.biddingBlock() & "\n\n")
  if sim.config.talk:
    result.add("TABLE TALK THIS DEAL:\n" & sim.talkBlock() & "\n\n")
  result.add("PREVIOUS DEALS:\n" & sim.historyBlock() & "\n\n")
  result.add("STANDINGS: " & sim.standingsBlock() & "\n\n")
  result.add("YOUR NOTES:\n" &
    (if sim.notes[seat].len > 0: sim.notes[seat] else: "(none)") & "\n\n")
  result.add(operatorBlock(prompt))
  let sayHint =
    if sim.config.talk: ",\"say\":\"...\"" else: ""
  result.add("Reply with ONLY {\"action\":\"bid\",\"quantity\":" &
    $(sim.bidQuantity + 1) & ",\"face\":" & $sim.config.lowFace() & sayHint &
    ",\"notes\":\"...\"}\nor {\"action\":\"challenge\"" & sayHint &
    ",\"notes\":\"...\"} - " &
    (if sim.bidSeat >= 0:
       "a bid must strictly raise\n" & bidText(sim.bidQuantity, sim.bidFace)
     else:
       "you open this deal, so a challenge is illegal") &
    (if sim.config.talk: "; say at most " & $MaxSayLen & " characters" else: "") &
    "; notes at most " & $MaxNotesLen & " characters.")

# ---- Anthropic / Bedrock transport ------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    ## Quote the head of the reply so a hosted log shows WHAT the model sent
    ## instead of JSON (prose, a refusal, a cut-off analysis...).
    let head = clipText(text.strip(), 160)
    raise newException(LiarsDiceError, "no JSON object in response: " &
      head.replace("\n", " "))
  parseJson(text[start .. stop])

proc completeText(client: LlmClient, system, user: string): string =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  var url: string
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    url = AnthropicUrl
  let response = client.curl.post(url, headers, $body, client.timeoutSeconds)
  if response.code == 401 or response.code == 403:
    let detail = clipText(response.body, 400)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(LiarsDiceError,
        "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(LiarsDiceError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = clipText(response.body, 300)
    discard client.tryNextBedrockModel("throttled")
    raise newException(LiarsDiceError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(LiarsDiceError, "anthropic error " & $response.code &
      ": " & clipText(response.body, 300))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LiarsDiceError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LiarsDiceError, "reply cut off at max_tokens before " &
      "any JSON: " & clipText(result, 160).replace("\n", " "))

# ---- Reply parsing ----------------------------------------------------------

proc parseAction(payload: JsonNode): Action =
  let node = payload{"action"}
  if node.isNil or node.kind != JString:
    raise newException(LiarsDiceError, "no action in the reply")
  let text = node.getStr().strip().toLowerAscii()
  case text
  of "bid", "raise":
    result = aBid
  of "challenge", "call", "liar", "doubt":
    result = aChallenge
  else:
    raise newException(LiarsDiceError, "unknown action: " & text)

proc parseNumber(payload: JsonNode, key: string): int =
  let node = payload{key}
  if node.isNil:
    raise newException(LiarsDiceError, "a bid needs a " & key)
  case node.kind
  of JInt:
    result = node.getInt()
  of JFloat:
    result = int(node.getFloat())
  of JString:
    try:
      result = parseInt(node.getStr().strip())
    except ValueError:
      raise newException(LiarsDiceError,
        key & " must be a number: " & node.getStr())
  else:
    raise newException(LiarsDiceError, key & " must be a number")

proc parseReply*(sim: Sim, payload: JsonNode): Decision =
  ## Tolerant: action synonyms, numbers as ints or numeric strings, and
  ## oversized free text truncated on rune boundaries rather than rejected.
  result.action = parseAction(payload)
  result.say = cleanSay(payload{"say"}.getStr())
  result.notes = cleanNotes(payload{"notes"}.getStr())
  if result.action == aBid:
    result.quantity = parseNumber(payload, "quantity")
    result.face = parseNumber(payload, "face")
  if not sim.config.talk:
    result.say = ""

# ---- The one call per turn --------------------------------------------------

proc decide*(client: LlmClient, sim: Sim, seat: int, prompt: string,
    scripted: bool, baseline = "bayes"): Decision =
  ## One decision for one seat — this is a strictly sequential turn game, so
  ## exactly one call goes out per turn. Never raises: any failure falls back
  ## to the scripted baseline so the episode always advances.
  if scripted or client.disabled:
    return client.scriptedAction(sim, seat, baseline)
  let system = systemPrompt(sim, seat)
  var reason = ""
  for attempt in 0 .. 1:
    var user = sim.userPrompt(seat, prompt)
    if attempt > 0:
      user.add("\n\nYour previous reply was invalid: " & reason &
        ". Respond with ONLY the requested JSON object; " &
        (if sim.bidSeat >= 0:
           "a bid must strictly raise " &
             bidText(sim.bidQuantity, sim.bidFace) &
             ", or answer {\"action\":\"challenge\"}."
         else:
           "you open this deal, so you must bid."))
    try:
      let payload = extractJsonObject(client.completeText(system, user))
      let decision = parseReply(sim, payload)
      ## Reject illegal replies against a PROBE copy of the sim so the retry
      ## carries the reason and the real sim is never touched.
      var probe = sim
      if decision.action == aBid:
        probe.applyBid(seat, decision.quantity, decision.face, decision.say,
          decision.notes)
      else:
        probe.applyChallenge(seat, decision.say, decision.notes)
      return decision
    except CatchableError as error:
      reason = error.msg
      echo "liars-dice llm: seat ", seat, " attempt ", attempt, " failed: ",
        error.msg
      if client.disabled:
        break
  echo "liars-dice llm: seat ", seat, " falling back to the bayes baseline"
  result = client.scriptedAction(sim, seat, "bayes")
  result.fallback = true
