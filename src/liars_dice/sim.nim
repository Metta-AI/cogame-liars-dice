## Pure game rules for Liar's Dice. No IO, no networking, no LLM — the
## server, the tests, and the wasm replay viewer all drive this same module.
##
## A `Sim` is one whole episode: the seeded table order and aliases, the
## current deal's hidden hands, the standing bid and the deal's public bid
## and talk history, every seat's tallies and private notes, the soft-play
## audit matrices, and the append-only event log. Everything random is drawn
## from the seed, so a replay re-derives the episode from the recorded deal /
## bid / challenge events alone.

import
  std/[algorithm, json, math, options, random, sequtils, strutils, unicode],
  types

export types

const
  MinSeats* = 3
  MaxSeats* = 6
  ## An episode's whole model-call allowance. A deal costs at most
  ## `maxBidsPerDeal + 1` decisions, so `deals` is capped to this at sample
  ## time and the worst-case episode is provable.
  EpisodeCallBudget* = 120
  MinDeals* = 2
  ## Total spectator-pacing sleep an episode may spend, in milliseconds.
  PacingBudgetMs* = 60_000
  MaxSayLen* = 140
  MaxNotesLen* = 400
  DiceFaces* = 6
  PokerFaces* = 10
  CogNames* = [
    "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
    "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
  ]

type
  TurnKind* = enum
    tkDeal = "deal"   ## the next deal needs opening (beginDeal)
    tkAct = "act"     ## the seat on turn must bid or challenge
    tkNone = "none"   ## the episode is over

  Turn* = tuple[kind: TurnKind, seat: int]
    ## `seat` is the acting seat's SLOT (config index), not its table
    ## position, so a caller can index prompts and tokens by it directly.

  Phase* = enum
    phBidding = "bidding"
    phReveal = "reveal"     ## a challenge has resolved; every hand is open
    phBetween = "between"   ## before the first deal
    phDone = "done"

  Bid* = object
    seat*: int        ## slot
    quantity*: int
    face*: int

  Say* = object
    seat*: int        ## slot
    text*: string

  Resolution* = object
    challenger*: int  ## slot
    bidder*: int      ## slot
    quantity*: int
    face*: int
    actual*: int
    counts*: seq[int] ## per-slot count of `face`
    bidderWins*: bool
    forced*: bool

  Sim* = object
    config*: GameConfig
    names*: seq[string]        ## anonymous table aliases, by slot
    order*: seq[int]           ## table position -> slot
    seatAt*: seq[int]          ## slot -> table position
    logFact*: seq[float]       ## ln(i!) for i in 0 .. (S-1)*handSize
    hands*: seq[seq[int]]      ## the current deal's hands, by slot
    deal*: int                 ## current deal, 0-based; -1 before the first
    phase*: Phase
    turn*: int                 ## table position on turn
    opener*: int               ## slot that opened the current deal
    bidQuantity*: int
    bidFace*: int
    bidSeat*: int              ## slot of the standing bid; -1 = none
    bidsThisDeal*: int
    dealBids*: seq[Bid]
    dealSays*: seq[Say]
    resolution*: Option[Resolution]
    wins*: seq[int]
    losses*: seq[int]
    bidCount*: seq[int]
    challengeCount*: seq[int]
    bluffCount*: seq[int]      ## bids that were false when made
    notes*: seq[string]
    faced*: seq[seq[int]]      ## faced[a][b]: a on turn with b's bid standing
    challenged*: seq[seq[int]] ## of those, how many a challenged
    netPair*: seq[seq[int]]    ## points a took from b
    forgoneEv*: seq[seq[float]] ## summed max(0, 1 - 2p) over waved-through bids
    dealsPlayed*: int
    done*: bool
    reason*: string            ## "complete" | "deadline"
    forcedReason*: string      ## replay: the recorded ending, pre-seeded
    events*: seq[GameEvent]

# ---- Text helpers -----------------------------------------------------------

proc collapseSpace(text: string): string =
  ## Newlines and control characters become single spaces; runs collapse.
  var pending = false
  for rune in text.runes:
    let value = int32(rune)
    if value <= 0x20'i32 or value == 0x7F'i32:
      pending = result.len > 0
    else:
      if pending:
        result.add(' ')
        pending = false
      result.add(rune)

proc cutRunes(text: string, cap: int): string =
  ## Over the cap the string is cut at a RUNE boundary with the cut marked,
  ## never at a byte boundary: a byte cut mid-UTF-8 makes the replay fail a
  ## strict JSON parser even though a browser renders it.
  result = text.strip()
  if result.runeLen <= cap:
    return
  result = result.runeSubStr(0, cap - 1) & "…"

proc cleanSay*(text: string): string =
  cutRunes(collapseSpace(text), MaxSayLen)

proc cleanNotes*(text: string): string =
  cutRunes(text, MaxNotesLen)

# ---- Setup ------------------------------------------------------------------

proc tableNames*(players: seq[PlayerConfig], seed: int): seq[string] =
  ## Policy display names never reach the table: every seat plays under an
  ## anonymous cog name, drawn deterministically from the seed so replays
  ## and the live table agree.
  var rng = initRand(int64(seed) * 6779 + 31)
  var pool = @CogNames
  rng.shuffle(pool)
  for index in 0 ..< players.len:
    if index < pool.len:
      result.add(pool[index])
    else:
      result.add("Cog " & $(index + 1))

proc faces*(config: GameConfig): int =
  ## The symbol space, derived from the mode and never configured alone.
  if config.mode == mPoker: PokerFaces else: DiceFaces

proc lowFace*(config: GameConfig): int =
  if config.mode == mPoker: 0 else: 1

proc highFace*(config: GameConfig): int =
  config.lowFace() + config.faces() - 1

proc seats*(sim: Sim): int =
  sim.config.players.len

proc totalSymbols*(sim: Sim): int =
  sim.config.players.len * sim.config.handSize

proc callsPerDeal*(config: GameConfig): int =
  config.maxBidsPerDeal + 1

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Fits the deal count into one episode's call budget. Idempotent: a
  ## config that already carries the cap (a replay being re-read) is
  ## untouched.
  result = config
  if result.sampled:
    return
  result.deals = max(
    min(config.deals, EpisodeCallBudget div max(config.callsPerDeal(), 1)),
    MinDeals)
  result.turnDelayMs =
    min(config.turnDelayMs, PacingBudgetMs div max(result.deals, 1))
  result.sampled = true

proc blankEvent(kind: EventKind): GameEvent =
  GameEvent(kind: kind, deal: -1, seat: -1, other: -1, opener: -1,
    quantity: 0, face: -1, actual: -1)

proc addEvent(sim: var Sim, event: GameEvent) =
  sim.events.add(event)

proc initSim*(config: GameConfig): Sim =
  let count = config.players.len
  if count < MinSeats or count > MaxSeats:
    raise newException(LiarsDiceError,
      "liars-dice seats " & $MinSeats & ".." & $MaxSeats & ", got " & $count)
  if config.deals < MinDeals:
    raise newException(LiarsDiceError,
      "deals must be at least " & $MinDeals)
  if config.handSize < 1:
    raise newException(LiarsDiceError, "handSize must be at least 1")
  if config.maxBidsPerDeal < 1:
    raise newException(LiarsDiceError, "maxBidsPerDeal must be at least 1")
  result = Sim(config: config, names: tableNames(config.players, config.seed))
  ## The seating permutation is the randomised-seating half of the soft-play
  ## audit: a pair of policies never sits in the same relation twice.
  var rng = initRand(int64(config.seed) * 4111 + 97)
  result.order = toSeq(0 ..< count)
  rng.shuffle(result.order)
  result.seatAt = newSeq[int](count)
  for position, slot in result.order:
    result.seatAt[slot] = position
  let unseen = (count - 1) * config.handSize
  result.logFact = newSeq[float](unseen + 1)
  for i in 1 .. unseen:
    result.logFact[i] = result.logFact[i - 1] + ln(i.float)
  result.deal = -1
  result.phase = phBetween
  result.turn = 0
  result.opener = -1
  result.bidSeat = -1
  result.bidFace = -1
  result.wins = newSeq[int](count)
  result.losses = newSeq[int](count)
  result.bidCount = newSeq[int](count)
  result.challengeCount = newSeq[int](count)
  result.bluffCount = newSeq[int](count)
  result.notes = newSeq[string](count)
  for _ in 0 ..< count:
    result.faced.add(newSeq[int](count))
    result.challenged.add(newSeq[int](count))
    result.netPair.add(newSeq[int](count))
    result.forgoneEv.add(newSeq[float](count))
  result.addEvent(blankEvent(evStart))

# ---- Queries ----------------------------------------------------------------

proc dealHands*(config: GameConfig, deal: int): seq[seq[int]] =
  ## Every seat's hand for deal `deal`, drawn from the seed alone so a
  ## replay re-derives it and a doctored `deal` event cannot render.
  var rng = initRand(int64(config.seed) * 9176 + int64(deal) * 1013 + 7)
  let low = config.lowFace()
  let high = config.highFace()
  for _ in 0 ..< config.players.len:
    var hand: seq[int]
    for _ in 0 ..< config.handSize:
      hand.add(rng.rand(low .. high))
    hand.sort()
    result.add(hand)

proc currentTurn*(sim: Sim): Turn =
  ## What the episode needs next: a deal to open, or the acting seat's move.
  if sim.done:
    return (tkNone, -1)
  case sim.phase
  of phBetween, phReveal: (tkDeal, -1)
  of phBidding: (tkAct, sim.order[sim.turn])
  of phDone: (tkNone, -1)

proc actingSeat*(sim: Sim): int =
  ## The slot on turn, or -1 when nobody is.
  if sim.phase == phBidding and not sim.done: sim.order[sim.turn] else: -1

proc mustChallenge*(sim: Sim): bool =
  ## Rule 8: at the bid cap the acting seat may not bid.
  sim.bidSeat >= 0 and sim.bidsThisDeal >= sim.config.maxBidsPerDeal

proc legalBid*(sim: Sim, quantity, face: int): bool =
  if quantity < 1 or quantity > sim.totalSymbols():
    return false
  if face < sim.config.lowFace() or face > sim.config.highFace():
    return false
  if sim.mustChallenge():
    return false
  if sim.bidSeat < 0:
    return true
  quantity > sim.bidQuantity or
    (quantity == sim.bidQuantity and face > sim.bidFace)

proc ownCount*(sim: Sim, seat, face: int): int =
  if seat < 0 or seat >= sim.hands.len:
    return 0
  for symbol in sim.hands[seat]:
    if symbol == face:
      inc result

proc actualCount*(sim: Sim, face: int): int =
  for hand in sim.hands:
    for symbol in hand:
      if symbol == face:
        inc result

proc pTrue*(sim: Sim, seat, quantity, face: int): float =
  ## P[the bid (quantity, face) is true] from `seat`'s own hand alone: the
  ## exact upper tail of Binomial(unseen, 1/faces), summed in float64 through
  ## the precomputed log-factorial table so C(U, i) never overflows. Shared
  ## by the audit, the scripted baselines and the tests so the three cannot
  ## drift apart.
  let unseen = (sim.seats() - 1) * sim.config.handSize
  let need = max(0, quantity - sim.ownCount(seat, face))
  if need == 0:
    return 1.0
  if need > unseen:
    return 0.0
  let p1 = 1.0 / sim.config.faces().float
  let logP = ln(p1)
  let logQ = ln(1.0 - p1)
  var total = 0.0
  for i in need .. unseen:
    total += exp(sim.logFact[unseen] - sim.logFact[i] -
      sim.logFact[unseen - i] + i.float * logP + (unseen - i).float * logQ)
  min(1.0, max(0.0, total))

proc points*(sim: Sim, slot: int): int =
  sim.wins[slot] - sim.losses[slot]

proc score*(sim: Sim, slot: int): float =
  ## 0.5 is break even, 1.0 is winning every deal, 0.0 is losing every one.
  if sim.dealsPlayed == 0: 0.5
  else: 0.5 + sim.points(slot).float / (2.0 * sim.dealsPlayed.float)

proc bluffRate*(sim: Sim, slot: int): float =
  if sim.bidCount[slot] == 0: 0.0
  else: sim.bluffCount[slot].float / sim.bidCount[slot].float

proc expLoss*(sim: Sim, a, b: int): float =
  ## Expected value `a` forwent by not challenging `b`, averaged over the
  ## facings. The soft-play signal: high against one opponent and low
  ## elsewhere is the asymmetry the audit reads.
  if sim.faced[a][b] == 0: 0.0
  else: sim.forgoneEv[a][b] / sim.faced[a][b].float

proc handText*(sim: Sim, seat: int): string =
  if seat < 0 or seat >= sim.hands.len:
    return ""
  sim.hands[seat].mapIt($it).join(" ")

proc bidText*(quantity, face: int): string =
  $quantity & " x " & $face

# ---- Play -------------------------------------------------------------------

proc settle(sim: var Sim, reason: string) =
  sim.done = true
  ## A wall-clock ending is not derivable from the rules, so a replay
  ## pre-seeds the recorded reason and settles with that.
  sim.reason = if sim.forcedReason.len > 0: sim.forcedReason else: reason
  sim.phase = phDone
  var event = blankEvent(evEnd)
  event.deal = sim.dealsPlayed
  event.text = sim.reason
  sim.addEvent(event)

proc beginDeal*(sim: var Sim) =
  ## Opens the next deal: draws every seat a fresh hidden hand from the seed
  ## and puts the opener (table position `deal mod S`) on turn.
  if sim.done:
    raise newException(LiarsDiceError, "the episode is over")
  if sim.phase == phBidding:
    raise newException(LiarsDiceError, "a deal is already in progress")
  let count = sim.seats()
  sim.deal = sim.dealsPlayed
  sim.hands = dealHands(sim.config, sim.deal)
  sim.turn = sim.deal mod count
  sim.opener = sim.order[sim.turn]
  sim.bidSeat = -1
  sim.bidQuantity = 0
  sim.bidFace = -1
  sim.bidsThisDeal = 0
  sim.dealBids = @[]
  sim.dealSays = @[]
  sim.resolution = none(Resolution)
  sim.phase = phBidding
  var event = blankEvent(evDeal)
  event.deal = sim.deal
  event.opener = sim.opener
  event.hands = sim.hands
  sim.addEvent(event)

proc requireTurn(sim: Sim, seat: int) =
  if sim.done:
    raise newException(LiarsDiceError, "the episode is over")
  if sim.phase != phBidding:
    raise newException(LiarsDiceError, "no seat is on turn")
  if seat != sim.order[sim.turn]:
    raise newException(LiarsDiceError,
      "it is " & sim.names[sim.order[sim.turn]] & "'s turn, not seat " & $seat)

proc recordFacing(sim: var Sim, seat: int, challenged: bool) =
  ## Soft-play audit: `seat` was on turn with the standing bidder's bid up.
  if sim.bidSeat < 0 or sim.bidSeat == seat:
    return
  let other = sim.bidSeat
  inc sim.faced[seat][other]
  if challenged:
    inc sim.challenged[seat][other]
  else:
    ## Waving a bid through forgoes EV `1 - 2p` when that is positive.
    let ev = 1.0 - 2.0 * sim.pTrue(seat, sim.bidQuantity, sim.bidFace)
    if ev > 0.0:
      sim.forgoneEv[seat][other] += ev

proc applyBid*(sim: var Sim, seat, quantity, face: int, say = "",
    notes = "", scripted = false, fallback = false) =
  ## The seat on turn raises. Raises LiarsDiceError on anything illegal; the
  ## server catches it and substitutes the scripted baseline's move.
  sim.requireTurn(seat)
  if sim.mustChallenge():
    raise newException(LiarsDiceError,
      "the bid cap is reached; this seat must challenge")
  if not sim.legalBid(quantity, face):
    raise newException(LiarsDiceError,
      "illegal bid " & bidText(quantity, face) &
      (if sim.bidSeat >= 0: " against " & bidText(sim.bidQuantity, sim.bidFace)
       else: " (opening bid)"))
  sim.recordFacing(seat, challenged = false)
  if sim.actualCount(face) < quantity:
    inc sim.bluffCount[seat]
  inc sim.bidCount[seat]
  sim.bidQuantity = quantity
  sim.bidFace = face
  sim.bidSeat = seat
  inc sim.bidsThisDeal
  sim.dealBids.add(Bid(seat: seat, quantity: quantity, face: face))
  let spoken = if sim.config.talk: cleanSay(say) else: ""
  if spoken.len > 0:
    sim.dealSays.add(Say(seat: seat, text: spoken))
  let written = cleanNotes(notes)
  if written.len > 0:
    sim.notes[seat] = written
  sim.turn = (sim.turn + 1) mod sim.seats()
  var event = blankEvent(evBid)
  event.deal = sim.deal
  event.seat = seat
  event.quantity = quantity
  event.face = face
  event.scripted = scripted
  event.fallback = fallback
  event.say = spoken
  event.notes = sim.notes[seat]
  sim.addEvent(event)

proc applyChallenge*(sim: var Sim, seat: int, say = "", notes = "",
    scripted = false, fallback = false, forced = false) =
  ## The seat on turn calls the standing bid. Every hand is revealed and the
  ## deal ends: +1 to whoever was right, -1 to whoever was wrong.
  sim.requireTurn(seat)
  if sim.bidSeat < 0:
    raise newException(LiarsDiceError,
      "there is no standing bid to challenge; this seat must bid")
  let bidder = sim.bidSeat
  let quantity = sim.bidQuantity
  let face = sim.bidFace
  var counts = newSeq[int](sim.seats())
  for slot in 0 ..< sim.seats():
    counts[slot] = sim.ownCount(slot, face)
  let actual = sim.actualCount(face)
  let bidderWins = actual >= quantity
  sim.recordFacing(seat, challenged = true)
  inc sim.challengeCount[seat]
  if bidderWins:
    inc sim.wins[bidder]
    inc sim.losses[seat]
    inc sim.netPair[bidder][seat]
    dec sim.netPair[seat][bidder]
  else:
    inc sim.wins[seat]
    inc sim.losses[bidder]
    inc sim.netPair[seat][bidder]
    dec sim.netPair[bidder][seat]
  let spoken = if sim.config.talk: cleanSay(say) else: ""
  if spoken.len > 0:
    sim.dealSays.add(Say(seat: seat, text: spoken))
  let written = cleanNotes(notes)
  if written.len > 0:
    sim.notes[seat] = written
  sim.resolution = some(Resolution(challenger: seat, bidder: bidder,
    quantity: quantity, face: face, actual: actual, counts: counts,
    bidderWins: bidderWins, forced: forced))
  inc sim.dealsPlayed
  sim.phase = phReveal
  var event = blankEvent(evChallenge)
  event.deal = sim.deal
  event.seat = seat
  event.other = bidder
  event.quantity = quantity
  event.face = face
  event.actual = actual
  event.counts = counts
  event.bidderWins = bidderWins
  event.forced = forced
  event.scripted = scripted
  event.fallback = fallback
  event.say = spoken
  event.notes = sim.notes[seat]
  sim.addEvent(event)
  if sim.dealsPlayed >= sim.config.deals:
    sim.settle("complete")

proc endEarly*(sim: var Sim) =
  ## Stop now. The hosted platform kills an episode that outlives its
  ## timeout and keeps NOTHING, so a short honest episode always beats a
  ## long one that never lands. Scores use the deals actually played.
  if sim.done:
    return
  sim.settle("deadline")

# ---- Results ----------------------------------------------------------------

proc auditJson*(sim: Sim): JsonNode =
  var facedNode = newJArray()
  var challengedNode = newJArray()
  var netNode = newJArray()
  var lossNode = newJArray()
  for a in 0 ..< sim.seats():
    var facedRow = newJArray()
    var challengedRow = newJArray()
    var netRow = newJArray()
    var lossRow = newJArray()
    for b in 0 ..< sim.seats():
      facedRow.add(%sim.faced[a][b])
      challengedRow.add(%sim.challenged[a][b])
      netRow.add(%sim.netPair[a][b])
      lossRow.add(%sim.expLoss(a, b))
    facedNode.add(facedRow)
    challengedNode.add(challengedRow)
    netNode.add(netRow)
    lossNode.add(lossRow)
  %*{
    "faced": facedNode,
    "challenged": challengedNode,
    "net": netNode,
    "expLoss": lossNode
  }

proc resultsJson*(sim: Sim): JsonNode =
  var names = newJArray()
  var aliases = newJArray()
  var orderNode = newJArray()
  var scores = newJArray()
  var pointsNode = newJArray()
  var winsNode = newJArray()
  var lossesNode = newJArray()
  var bidsNode = newJArray()
  var challengesNode = newJArray()
  var bluffNode = newJArray()
  for slot in 0 ..< sim.seats():
    ## Results are platform-facing: the league attributes scores by POLICY
    ## name. The aliases ride alongside so an auditor can line the two up.
    names.add(%sim.config.players[slot].name)
    aliases.add(%sim.names[slot])
    scores.add(%sim.score(slot))
    pointsNode.add(%sim.points(slot))
    winsNode.add(%sim.wins[slot])
    lossesNode.add(%sim.losses[slot])
    bidsNode.add(%sim.bidCount[slot])
    challengesNode.add(%sim.challengeCount[slot])
    bluffNode.add(%sim.bluffRate(slot))
  for slot in sim.order:
    orderNode.add(%slot)
  %*{
    "names": names,
    "aliases": aliases,
    "order": orderNode,
    "scores": scores,
    "points": pointsNode,
    "wins": winsNode,
    "losses": lossesNode,
    "bids": bidsNode,
    "challenges": challengesNode,
    "bluffRate": bluffNode,
    "audit": sim.auditJson(),
    "deals": sim.dealsPlayed,
    "maxDeals": sim.config.deals,
    "mode": $sim.config.mode,
    "talk": sim.config.talk,
    "reason": (if sim.done: sim.reason else: "")
  }

# ---- Viewer state -----------------------------------------------------------

proc lastSay(sim: Sim, slot: int): string =
  for entry in sim.dealSays:
    if entry.seat == slot:
      result = entry.text

proc tableStateJson*(sim: Sim): JsonNode =
  ## The exact frame the viewer reads. Spectator-side only: it carries every
  ## hand and never goes to a player socket.
  let revealed = sim.resolution.isSome()
  let acting = sim.actingSeat()
  var seatsNode = newJArray()
  for slot in 0 ..< sim.seats():
    var hand = newJArray()
    if slot < sim.hands.len:
      for symbol in sim.hands[slot]:
        hand.add(%symbol)
    seatsNode.add(%*{
      "slot": slot,
      "seat": sim.seatAt[slot],
      "name": sim.names[slot],
      "points": sim.points(slot),
      "score": sim.score(slot),
      "wins": sim.wins[slot],
      "losses": sim.losses[slot],
      "hand": hand,
      "revealed": revealed,
      "acting": acting == slot,
      "say": sim.lastSay(slot),
      "notes": sim.notes[slot]
    })
  var orderNode = newJArray()
  for slot in sim.order:
    orderNode.add(%slot)
  var bidsNode = newJArray()
  for entry in sim.dealBids:
    bidsNode.add(%*{
      "seat": entry.seat,
      "quantity": entry.quantity,
      "face": entry.face
    })
  var bidNode = newJNull()
  if sim.bidSeat >= 0:
    bidNode = %*{
      "seat": sim.bidSeat,
      "quantity": sim.bidQuantity,
      "face": sim.bidFace
    }
  var resolutionNode = newJNull()
  if sim.resolution.isSome():
    let res = sim.resolution.get()
    var counts = newJArray()
    for value in res.counts:
      counts.add(%value)
    resolutionNode = %*{
      "challenger": res.challenger,
      "bidder": res.bidder,
      "quantity": res.quantity,
      "face": res.face,
      "actual": res.actual,
      "counts": counts,
      "bidderWins": res.bidderWins,
      "forced": res.forced
    }
  %*{
    "seats": seatsNode,
    "order": orderNode,
    "mode": $sim.config.mode,
    "faces": sim.config.faces(),
    "lowFace": sim.config.lowFace(),
    "handSize": sim.config.handSize,
    "totalSymbols": sim.totalSymbols(),
    "talk": sim.config.talk,
    "deal": sim.deal,
    "deals": sim.config.deals,
    "dealsPlayed": sim.dealsPlayed,
    "opener": sim.opener,
    "turn": sim.turn,
    "bid": bidNode,
    "bids": bidsNode,
    "resolution": resolutionNode,
    "phase": $sim.phase,
    "gameDone": sim.done,
    "reason": sim.reason
  }

# ---- Replay -----------------------------------------------------------------

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[Sim] =
  ## Re-derives the state timeline from a recorded event log: `initSim` from
  ## the seed reproduces the seating, the aliases and every deal's hands, and
  ## the bid / challenge events are re-applied through the same rules the
  ## server ran. frames[i] = state after events[0..<i].
  var sim = initSim(config)
  ## initSim already logged the start event; the recorded log's first event
  ## is that same start.
  sim.events = @[]
  ## A wall-clock ending is not derivable from the rules, so the recorded
  ## reason is pre-seeded before replaying and the settle uses it.
  for event in events:
    if event.kind == evEnd and event.text.len > 0:
      sim.forcedReason = event.text
  result.add(sim)
  for event in events:
    case event.kind
    of evStart:
      sim.events.add(event)
    of evDeal:
      sim.beginDeal()
      let logged = sim.events[^1]
      if event.deal != logged.deal or event.opener != logged.opener or
          (event.hands.len > 0 and event.hands != logged.hands):
        raise newException(LiarsDiceError,
          "deal " & $event.deal & " does not match the seeded deal")
    of evBid:
      sim.applyBid(event.seat, event.quantity, event.face, event.say,
        event.notes, event.scripted, event.fallback)
    of evChallenge:
      sim.applyChallenge(event.seat, event.say, event.notes, event.scripted,
        event.fallback, event.forced)
    of evEnd:
      if not sim.done:
        sim.settle(event.text)
    result.add(sim)

# ---- Event JSON -------------------------------------------------------------

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{"kind": $event.kind}
  if event.deal >= 0:
    result["deal"] = %event.deal
  case event.kind
  of evStart:
    discard
  of evDeal:
    result["opener"] = %event.opener
    var hands = newJArray()
    for hand in event.hands:
      var row = newJArray()
      for symbol in hand:
        row.add(%symbol)
      hands.add(row)
    result["hands"] = hands
  of evBid:
    result["seat"] = %event.seat
    result["quantity"] = %event.quantity
    result["face"] = %event.face
    result["scripted"] = %event.scripted
    result["fallback"] = %event.fallback
  of evChallenge:
    result["seat"] = %event.seat
    result["other"] = %event.other
    result["quantity"] = %event.quantity
    result["face"] = %event.face
    result["actual"] = %event.actual
    var counts = newJArray()
    for value in event.counts:
      counts.add(%value)
    result["counts"] = counts
    result["bidderWins"] = %event.bidderWins
    result["forced"] = %event.forced
    result["scripted"] = %event.scripted
    result["fallback"] = %event.fallback
  of evEnd:
    discard
  if event.say.len > 0:
    result["say"] = %event.say
  if event.notes.len > 0:
    result["notes"] = %event.notes
  if event.text.len > 0:
    result["text"] = %event.text

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    deal: node{"deal"}.getInt(-1),
    seat: node{"seat"}.getInt(-1),
    other: node{"other"}.getInt(-1),
    opener: node{"opener"}.getInt(-1),
    quantity: node{"quantity"}.getInt(0),
    face: node{"face"}.getInt(-1),
    actual: node{"actual"}.getInt(-1),
    bidderWins: node{"bidderWins"}.getBool(false),
    forced: node{"forced"}.getBool(false),
    scripted: node{"scripted"}.getBool(false),
    fallback: node{"fallback"}.getBool(false),
    say: node{"say"}.getStr(""),
    notes: node{"notes"}.getStr(""),
    text: node{"text"}.getStr("")
  )
  if node.hasKey("counts"):
    for value in node["counts"]:
      result.counts.add(value.getInt())
  if node.hasKey("hands"):
    for hand in node["hands"]:
      var row: seq[int]
      for symbol in hand:
        row.add(symbol.getInt())
      result.hands.add(row)
