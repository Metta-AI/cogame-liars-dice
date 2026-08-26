## The scripted baselines must play whole episodes without ever proposing an
## illegal action — they are both the no-credentials fallback (offline
## certification) and fieldable policies, so this is the completion path. The
## calibrated one must also actually beat the loose one, or the "calibrated"
## label means nothing. And the LLM reply parser must be tolerant of the
## shapes a model really emits without ever letting an illegal move through.

import std/[json, monotimes, os, times, unicode, unittest]
import liars_dice/[llm, sim]

## Every test in this file is about the SCRIPTED path. Clear the credential
## environment up front so no test can accidentally reach the network.
delEnv("ANTHROPIC_API_KEY")
delEnv("ANTHROPIC_API_KEY_URI")
delEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")
delEnv("AWS_BEARER_TOKEN_BEDROCK")

proc fixture(seats = 4, deals = 3, seed = 0, mode = mDice, handSize = 5,
    talk = true): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.mode = mode
  result.handSize = handSize
  result.deals = deals
  result.talk = talk
  result.sampled = true
  for index in 0 ..< seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

type Trace = object
  actions: int
  bids: int
  challenges: int

proc playBaselines(config: GameConfig, baselines: seq[string]): (Sim, Trace) =
  ## Drives a whole episode from the scripted baselines alone, asserting that
  ## every action they emit is accepted by the sim FIRST TIME: applyBid or
  ## applyChallenge raising anywhere fails the test.
  let client = newLlmClient(config)
  var sim = initSim(config)
  var trace = Trace()
  while not sim.done:
    let turn = sim.currentTurn()
    case turn.kind
    of tkDeal:
      sim.beginDeal()
    of tkAct:
      let standing = sim.bidSeat >= 0
      let before = sim.bidQuantity
      let decision = client.scriptedAction(sim, turn.seat,
        baselines[turn.seat])
      ## Bounded orders: exactly one action, never talk, never notes.
      inc trace.actions
      check decision.scripted
      check decision.say.len == 0
      check decision.notes.len == 0
      if decision.action == aBid:
        inc trace.bids
        check sim.legalBid(decision.quantity, decision.face)
        check decision.face >= sim.config.lowFace()
        check decision.face <= sim.config.highFace()
        check decision.quantity >= 1
        check decision.quantity <= sim.totalSymbols()
        if standing:
          ## The raise window is q0 .. q0 + 2, plus at most pressure's pad.
          check decision.quantity >= before
          check decision.quantity <= before + 3
        sim.applyBid(turn.seat, decision.quantity, decision.face,
          decision.say, decision.notes, decision.scripted)
      else:
        inc trace.challenges
        check standing
        sim.applyChallenge(turn.seat, decision.say, decision.notes,
          decision.scripted)
      check sim.bidsThisDeal <= sim.config.maxBidsPerDeal
    of tkNone:
      discard
  result = (sim, trace)

suite "scripted baselines":
  test "both baselines play legal episodes across seeds, modes, talk, seats":
    let started = getMonoTime()
    for baseline in ["bayes", "pressure"]:
      for seed in [1, 7, 42, 1234]:
        for mode in [mDice, mPoker]:
          for talk in [true, false]:
            for seats in [3, 4, 6]:
              let config = fixture(seats = seats, deals = 3, seed = seed,
                mode = mode, handSize = (if mode == mPoker: 8 else: 5),
                talk = talk)
              var names: seq[string]
              for index in 0 ..< seats:
                names.add(baseline)
              let (sim, trace) = playBaselines(config, names)
              check sim.done
              check sim.reason == "complete"
              check sim.dealsPlayed == 3
              ## One challenge closes each deal, and nothing else can.
              check trace.challenges == 3
              check trace.actions == trace.bids + trace.challenges
              let results = sim.resultsJson()
              for slot in 0 ..< seats:
                check results["scores"][slot].getFloat() >= 0.0
                check results["scores"][slot].getFloat() <= 1.0
              var sum = 0
              for slot in 0 ..< seats:
                sum += results["points"][slot].getInt()
              check sum == 0
    let elapsed = (getMonoTime() - started).inMilliseconds
    echo "baseline sweep: ", elapsed, " ms"
    check elapsed < 240_000

  test "an unknown PLAYER_SCRIPTED name coerces to bayes":
    check normalizeBaseline("pressure") == "pressure"
    check normalizeBaseline("PRESSURE") == "pressure"
    check normalizeBaseline("bayes") == "bayes"
    check normalizeBaseline("1") == "bayes"
    check normalizeBaseline("") == "bayes"
    check normalizeBaseline("nonsense") == "bayes"
    let config = fixture(seed = 5)
    let client = newLlmClient(config)
    var sim = initSim(config)
    sim.beginDeal()
    let seat = sim.currentTurn().seat
    let coerced = client.scriptedAction(sim, seat, "nonsense")
    let bayes = client.scriptedAction(sim, seat, "bayes")
    check coerced.action == bayes.action
    check coerced.quantity == bayes.quantity
    check coerced.face == bayes.face

  test "calibration: two bayes seats beat two pressure seats":
    var bayesTotal = 0.0
    var pressureTotal = 0.0
    var samples = 0
    for seed in [1, 7, 42, 1234]:
      let config = fixture(seats = 4, deals = 30, seed = seed)
      let (sim, _) = playBaselines(config,
        @["bayes", "pressure", "bayes", "pressure"])
      check sim.dealsPlayed == 30
      for slot in 0 ..< 4:
        let score = sim.score(slot)
        check score >= 0.0
        check score <= 1.0
        if slot mod 2 == 0: bayesTotal += score else: pressureTotal += score
      samples += 2
    let bayesMean = bayesTotal / samples.float
    let pressureMean = pressureTotal / samples.float
    echo "bayes mean ", bayesMean, " vs pressure mean ", pressureMean
    check bayesMean > 0.5
    check pressureMean < 0.5

suite "the LLM path":
  test "decide falls back to scripted with no credentials and no retry":
    let config = fixture(seed = 3)
    let client = newLlmClient(config)
    ## No credentials anywhere: the client latches disabled at construction,
    ## so the very first attempt is the scripted move — no network, no retry.
    check client.disabled
    var sim = initSim(config)
    sim.beginDeal()
    let seat = sim.currentTurn().seat
    let started = getMonoTime()
    let decision = client.decide(sim, seat, "bluff every deal",
      scripted = false)
    let elapsed = (getMonoTime() - started).inMilliseconds
    check elapsed < 1000
    check decision.scripted
    check not decision.fallback
    ## And it is legal, so the episode always advances.
    if decision.action == aBid:
      check sim.legalBid(decision.quantity, decision.face)
      sim.applyBid(seat, decision.quantity, decision.face)
    else:
      check sim.bidSeat >= 0
      sim.applyChallenge(seat)
    check sim.events[^1].kind in {evBid, evChallenge}

  test "replies parse tolerantly and illegal ones are still rejected":
    let config = fixture(seed = 8)
    var sim = initSim(config)
    sim.beginDeal()
    let seat = sim.currentTurn().seat
    for word in ["bid", "BID", "Bid", " raise "]:
      let reply = parseReply(sim, %*{"action": word, "quantity": 3,
        "face": 2})
      check reply.action == aBid
      check reply.quantity == 3
      check reply.face == 2
    for word in ["challenge", "Challenge", "CALL", "liar", "doubt"]:
      check parseReply(sim, %*{"action": word}).action == aChallenge
    ## Numbers as numeric strings.
    let stringy = parseReply(sim, %*{"action": "bid", "quantity": "4",
      "face": " 6 "})
    check stringy.quantity == 4
    check stringy.face == 6
    ## Missing or unknown action, and a bid with no numbers, are rejected.
    expect LiarsDiceError:
      discard parseReply(sim, %*{"quantity": 3, "face": 2})
    expect LiarsDiceError:
      discard parseReply(sim, %*{"action": "ponder"})
    expect LiarsDiceError:
      discard parseReply(sim, %*{"action": "bid", "face": 2})
    expect LiarsDiceError:
      discard parseReply(sim, %*{"action": "bid", "quantity": "many",
        "face": 2})
    ## Oversized free text is TRUNCATED on rune boundaries, not rejected.
    var longSay = ""
    for index in 0 ..< 400:
      longSay.add("é")
    var longNotes = ""
    for index in 0 ..< 900:
      longNotes.add("字")
    let padded = parseReply(sim, %*{"action": "challenge", "say": longSay,
      "notes": longNotes})
    check padded.say.runeLen == MaxSayLen
    check padded.notes.runeLen == MaxNotesLen
    check validateUtf8(padded.say) == -1
    check validateUtf8(padded.notes) == -1
    ## An opening bid stands, and then only a strict raise survives the probe
    ## the decide() path applies before it accepts a reply.
    sim.applyBid(seat, 5, 3)
    let next = sim.currentTurn().seat
    for bad in [(5, 3), (5, 2), (4, 6), (0, 3), (21, 3), (6, 9)]:
      let reply = parseReply(sim, %*{"action": "bid", "quantity": bad[0],
        "face": bad[1]})
      var probe = sim
      expect LiarsDiceError:
        probe.applyBid(next, reply.quantity, reply.face)
    let good = parseReply(sim, %*{"action": "bid", "quantity": 5, "face": 4})
    var probe = sim
    probe.applyBid(next, good.quantity, good.face)
    check probe.bidQuantity == 5
    check probe.bidFace == 4
    ## A challenge with no standing bid is rejected the same way.
    var fresh = initSim(config)
    fresh.beginDeal()
    let opener = fresh.currentTurn().seat
    let call = parseReply(fresh, %*{"action": "call"})
    check call.action == aChallenge
    var freshProbe = fresh
    expect LiarsDiceError:
      freshProbe.applyChallenge(opener)

  test "talk off strips a say out of the parsed reply":
    let config = fixture(seed = 9, talk = false)
    var sim = initSim(config)
    sim.beginDeal()
    let reply = parseReply(sim, %*{"action": "bid", "quantity": 2, "face": 4,
      "say": "twos are cheap", "notes": "keep"})
    check reply.say == ""
    check reply.notes == "keep"
