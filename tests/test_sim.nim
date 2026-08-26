## Rules tests. Everything the sim promises the server, the tests and the
## wasm viewer: seeded determinism, turn order, bid legality, challenge
## resolution, the bid cap, scoring, the exact binomial tail, the soft-play
## audit, the Liar's Poker variant, rune-safe truncation, event JSON, and
## replay re-derivation for every end reason.

import std/[json, options, sets, strutils, unicode, unittest]
import liars_dice/sim

proc fixtureConfig(seats = 4, deals = 4, seed = 0, mode = mDice, handSize = 5,
    talk = true, maxBids = 12): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.mode = mode
  result.handSize = handSize
  result.deals = deals
  result.maxBidsPerDeal = maxBids
  result.talk = talk
  ## Pinned, so these tests exercise the rules rather than the budget cap.
  result.sampled = true
  for index in 0 ..< seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc faceHeldAtLeast(sim: Sim, atLeast: int): int =
  ## A face the whole table really holds `atLeast` of, so a test can bid
  ## exactly the true count without depending on which hands the seed drew.
  result = -1
  for face in sim.config.lowFace() .. sim.config.highFace():
    if sim.actualCount(face) >= atLeast:
      return face

proc playDeal(sim: var Sim, bids = 2) =
  ## One whole deal: `bids` strictly-rising legal bids, then a challenge.
  sim.beginDeal()
  for index in 0 ..< bids:
    let seat = sim.currentTurn().seat
    sim.applyBid(seat, index + 1, sim.config.lowFace())
  sim.applyChallenge(sim.currentTurn().seat)

proc playEpisode(sim: var Sim, bids = 2) =
  while not sim.done:
    sim.playDeal(bids)

suite "determinism and budget":
  test "the seed fixes the seating, the aliases and every deal's hands":
    let a = initSim(fixtureConfig(seed = 7))
    let b = initSim(fixtureConfig(seed = 7))
    check a.order == b.order
    check a.seatAt == b.seatAt
    check a.names == b.names
    for deal in 0 ..< 4:
      check dealHands(a.config, deal) == dealHands(b.config, deal)
    ## The permutation really is a permutation.
    var covered = initHashSet[int]()
    for slot in a.order:
      covered.incl(slot)
    check covered.len == a.seats()
    for position, slot in a.order:
      check a.seatAt[slot] == position
    let c = initSim(fixtureConfig(seed = 8))
    check dealHands(c.config, 0) != dealHands(a.config, 0)

  test "sampleEpisode caps deals at the call budget and is idempotent":
    var config = fixtureConfig(deals = 500)
    config.sampled = false
    config.turnDelayMs = 10_000
    let fitted = sampleEpisode(config)
    check fitted.deals == EpisodeCallBudget div (config.maxBidsPerDeal + 1)
    check fitted.deals == 9
    check fitted.turnDelayMs == PacingBudgetMs div 9
    check fitted.sampled
    check sampleEpisode(fitted) == fitted
    var small = fixtureConfig(deals = 1)
    small.sampled = false
    check sampleEpisode(small).deals == MinDeals

suite "table":
  test "three to six seats all init, play and settle":
    for count in [3, 4, 5, 6]:
      var sim = initSim(fixtureConfig(seats = count, deals = 3, seed = count))
      check sim.totalSymbols() == count * 5
      check sim.names.len == count
      while not sim.done:
        let turn = sim.currentTurn()
        case turn.kind
        of tkDeal:
          sim.beginDeal()
        of tkAct:
          if sim.bidsThisDeal >= 2 or sim.mustChallenge():
            sim.applyChallenge(turn.seat)
          else:
            sim.applyBid(turn.seat, sim.bidQuantity + 1, sim.config.lowFace())
        of tkNone:
          discard
      check sim.reason == "complete"
      check sim.dealsPlayed == 3

  test "seat counts outside 3..6 are rejected":
    expect LiarsDiceError:
      discard initSim(fixtureConfig(seats = 2))
    expect LiarsDiceError:
      discard initSim(fixtureConfig(seats = 7))

  test "the opener of deal d is table position d mod S and the turn wraps":
    var sim = initSim(fixtureConfig(seats = 4, deals = 4, seed = 5))
    for deal in 0 ..< 3:
      sim.beginDeal()
      check sim.deal == deal
      check sim.turn == deal mod 4
      check sim.opener == sim.order[deal mod 4]
      check sim.currentTurn() == (tkAct, sim.order[deal mod 4])
      sim.applyBid(sim.order[deal mod 4], 2, 3)
      check sim.turn == (deal + 1) mod 4
      sim.applyBid(sim.order[(deal + 1) mod 4], 3, 3)
      check sim.turn == (deal + 2) mod 4
      sim.applyChallenge(sim.order[(deal + 2) mod 4])

suite "bid legality":
  test "only a strict raise inside the ranges is accepted":
    var sim = initSim(fixtureConfig(seats = 3, deals = 3, seed = 2,
      maxBids = 3))
    expect LiarsDiceError:
      sim.applyBid(sim.order[0], 1, 1)          # no deal has opened
    sim.beginDeal()
    let opener = sim.order[0]
    expect LiarsDiceError:
      sim.applyChallenge(opener)                # nothing stands: must bid
    expect LiarsDiceError:
      sim.applyBid(sim.order[1], 1, 1)          # out of turn
    expect LiarsDiceError:
      sim.applyBid(opener, 0, 1)                # quantity below 1
    expect LiarsDiceError:
      sim.applyBid(opener, sim.totalSymbols() + 1, 1)
    expect LiarsDiceError:
      sim.applyBid(opener, 1, 0)                # face below the dice range
    expect LiarsDiceError:
      sim.applyBid(opener, 1, 7)                # face above it
    check sim.events.len == 2                   # nothing illegal was recorded
    sim.applyBid(opener, 4, 3)
    let second = sim.order[1]
    expect LiarsDiceError:
      sim.applyBid(second, 4, 3)                # the same bid
    expect LiarsDiceError:
      sim.applyBid(second, 4, 2)                # equal quantity, lower face
    expect LiarsDiceError:
      sim.applyBid(second, 3, 6)                # lower quantity
    check sim.legalBid(4, 5)
    check sim.legalBid(5, 1)
    sim.applyBid(second, 4, 5)                  # equal quantity, higher face
    sim.applyBid(sim.order[2], 5, 1)            # higher quantity, lower face
    check sim.bidsThisDeal == 3
    check sim.mustChallenge()
    check not sim.legalBid(6, 1)
    expect LiarsDiceError:
      sim.applyBid(sim.order[0], 6, 1)          # the bid cap forbids a bid
    sim.applyChallenge(sim.order[0], forced = true)
    check sim.resolution.isSome()
    check sim.resolution.get().forced
    check sim.events[^1].forced
    check sim.dealsPlayed == 1

  test "acting after the episode is over is rejected":
    var sim = initSim(fixtureConfig(seats = 3, deals = 2, seed = 4))
    sim.playEpisode()
    check sim.done
    expect LiarsDiceError:
      sim.beginDeal()
    expect LiarsDiceError:
      sim.applyBid(sim.order[0], 1, 1)
    expect LiarsDiceError:
      sim.applyChallenge(sim.order[0])

suite "challenge resolution":
  test "the bidder wins on >= and loses on <":
    var sim = initSim(fixtureConfig(deals = 4, seed = 21))
    sim.beginDeal()
    let face = sim.faceHeldAtLeast(2)
    check face >= 0
    let actual = sim.actualCount(face)
    ## Exactly the true count: the bidder holds.
    let bidder = sim.currentTurn().seat
    sim.applyBid(bidder, actual, face)
    let challenger = sim.currentTurn().seat
    sim.applyChallenge(challenger)
    let first = sim.resolution.get()
    check first.actual == actual
    check first.bidderWins
    check sim.wins[bidder] == 1
    check sim.losses[challenger] == 1
    var total = 0
    for value in first.counts:
      total += value
    check total == actual
    check first.counts.len == sim.seats()
    ## One under the true count: the bidder still holds.
    sim.beginDeal()
    let face2 = sim.faceHeldAtLeast(2)
    let bidder2 = sim.currentTurn().seat
    sim.applyBid(bidder2, sim.actualCount(face2) - 1, face2)
    sim.applyChallenge(sim.currentTurn().seat)
    check sim.resolution.get().bidderWins
    ## One over: the bid was a lie and the challenger scores.
    sim.beginDeal()
    let face3 = sim.faceHeldAtLeast(0)
    let bidder3 = sim.currentTurn().seat
    sim.applyBid(bidder3, sim.actualCount(face3) + 1, face3)
    let caller3 = sim.currentTurn().seat
    sim.applyChallenge(caller3)
    check not sim.resolution.get().bidderWins
    check sim.wins[caller3] >= 1
    ## Points move exactly +1 / -1 and sum to zero across the table.
    var sum = 0
    for slot in 0 ..< sim.seats():
      sum += sim.points(slot)
      check sim.wins[slot] + sim.losses[slot] <= sim.dealsPlayed
    check sum == 0
    check sim.dealsPlayed == 3

suite "scoring":
  test "score is 0.5 + points / (2 x deals) and the table means 0.5":
    var sim = initSim(fixtureConfig(deals = 3, seed = 33))
    for slot in 0 ..< sim.seats():
      check sim.score(slot) == 0.5             # nothing played yet
    var mean = 0.0
    sim.playDeal()
    for slot in 0 ..< sim.seats():
      let expected = 0.5 + sim.points(slot).float /
        (2.0 * sim.dealsPlayed.float)
      check abs(sim.score(slot) - expected) < 1e-12
      check sim.score(slot) >= 0.0
      check sim.score(slot) <= 1.0
      mean += sim.score(slot)
    check abs(mean / sim.seats().float - 0.5) < 1e-12
    sim.playEpisode()
    check sim.done
    let results = sim.resultsJson()
    check results["reason"].getStr() == "complete"
    check results["deals"].getInt() == 3
    check results["maxDeals"].getInt() == 3
    check results["names"].len == sim.seats()
    check results["aliases"].len == sim.seats()
    check results["names"][0].getStr() == "P1"
    check results["aliases"][0].getStr() == sim.names[0]
    var pointSum = 0
    for slot in 0 ..< sim.seats():
      pointSum += results["points"][slot].getInt()
    check pointSum == 0

  test "a deadline episode with no deal played scores everyone at break even":
    var sim = initSim(fixtureConfig(deals = 5, seed = 3))
    sim.endEarly()
    check sim.done
    check sim.reason == "deadline"
    check sim.dealsPlayed == 0
    let results = sim.resultsJson()
    check results["reason"].getStr() == "deadline"
    for slot in 0 ..< sim.seats():
      check results["scores"][slot].getFloat() == 0.5
    let before = sim.events.len
    sim.endEarly()                                # idempotent
    check sim.events.len == before

suite "pTrue":
  test "the exact binomial tail matches its closed forms":
    var sim = initSim(fixtureConfig(deals = 3, seed = 12))
    sim.beginDeal()
    let unseen = (sim.seats() - 1) * sim.config.handSize
    check unseen == 15
    for slot in 0 ..< sim.seats():
      for face in 1 .. 6:
        let own = sim.ownCount(slot, face)
        check sim.pTrue(slot, own, face) == 1.0
        check sim.pTrue(slot, 0, face) == 1.0
        check sim.pTrue(slot, own + unseen + 1, face) == 0.0
        ## Monotone non-increasing in the quantity claimed.
        for quantity in 1 ..< own + unseen:
          check sim.pTrue(slot, quantity, face) >=
            sim.pTrue(slot, quantity + 1, face) - 1e-12
    ## A tabulated value: P[Binomial(15, 1/6) >= 3], for a seat holding none
    ## of the face.
    var checked = false
    for slot in 0 ..< sim.seats():
      for face in 1 .. 6:
        if sim.ownCount(slot, face) == 0:
          check abs(sim.pTrue(slot, 3, face) - 0.4677751335452294) < 1e-9
          check abs(sim.pTrue(slot, 1, face) - 0.9350945284811262) < 1e-9
          checked = true
    check checked

  test "poker mode uses ten faces":
    var sim = initSim(fixtureConfig(deals = 3, seed = 12, mode = mPoker,
      handSize = 8))
    sim.beginDeal()
    check sim.config.faces() == 10
    check sim.config.lowFace() == 0
    check sim.config.highFace() == 9
    check sim.totalSymbols() == 32
    ## Twenty-four digits are unseen by any one seat, at 1/10 apiece.
    check (sim.seats() - 1) * sim.config.handSize == 24
    var checked = false
    for slot in 0 ..< sim.seats():
      for face in 0 .. 9:
        if sim.ownCount(slot, face) == 0:
          check abs(sim.pTrue(slot, 5, face) - 0.08507488587867089) < 1e-9
          check abs(sim.pTrue(slot, 1, face) - 0.9202335569231281) < 1e-9
          checked = true
    check checked

suite "soft-play audit":
  test "faced, challenged, net, expLoss and bluffRate track the play":
    var sim = initSim(fixtureConfig(seats = 3, deals = 3, seed = 44))
    let count = sim.seats()
    var faced = newSeq[seq[int]](count)
    var challenged = newSeq[seq[int]](count)
    var net = newSeq[seq[int]](count)
    var forgone = newSeq[seq[float]](count)
    var bids = newSeq[int](count)
    var bluffs = newSeq[int](count)
    for slot in 0 ..< count:
      faced[slot] = newSeq[int](count)
      challenged[slot] = newSeq[int](count)
      net[slot] = newSeq[int](count)
      forgone[slot] = newSeq[float](count)
    while not sim.done:
      let turn = sim.currentTurn()
      case turn.kind
      of tkDeal:
        sim.beginDeal()
      of tkAct:
        let seat = turn.seat
        let standing = sim.bidSeat
        let calls = sim.bidsThisDeal >= 2 or sim.mustChallenge()
        if standing >= 0 and standing != seat:
          inc faced[seat][standing]
          if calls:
            inc challenged[seat][standing]
          else:
            let ev = 1.0 - 2.0 * sim.pTrue(seat, sim.bidQuantity, sim.bidFace)
            if ev > 0.0:
              forgone[seat][standing] += ev
        if calls:
          let bidder = standing
          let truthful = sim.actualCount(sim.bidFace) >= sim.bidQuantity
          if truthful:
            inc net[bidder][seat]
            dec net[seat][bidder]
          else:
            inc net[seat][bidder]
            dec net[bidder][seat]
          sim.applyChallenge(seat)
        else:
          let quantity = sim.bidQuantity + 1
          let face = sim.config.lowFace()
          inc bids[seat]
          if sim.actualCount(face) < quantity:
            inc bluffs[seat]
          sim.applyBid(seat, quantity, face)
      of tkNone:
        discard
    for a in 0 ..< count:
      for b in 0 ..< count:
        check sim.faced[a][b] == faced[a][b]
        check sim.challenged[a][b] == challenged[a][b]
        check sim.netPair[a][b] == net[a][b]
        ## Antisymmetric by construction, and no seat faces itself.
        check sim.netPair[a][b] == -sim.netPair[b][a]
        check sim.faced[a][a] == 0
        check sim.challenged[a][b] <= sim.faced[a][b]
        check sim.expLoss(a, b) >= 0.0
        let expected =
          if faced[a][b] == 0: 0.0 else: forgone[a][b] / faced[a][b].float
        check abs(sim.expLoss(a, b) - expected) < 1e-12
    for slot in 0 ..< count:
      check sim.bidCount[slot] == bids[slot]
      check sim.bluffCount[slot] == bluffs[slot]
      let rate =
        if bids[slot] == 0: 0.0 else: bluffs[slot].float / bids[slot].float
      check abs(sim.bluffRate(slot) - rate) < 1e-12
    let audit = sim.resultsJson()["audit"]
    check audit["faced"].len == count
    check audit["expLoss"][0].len == count
    ## The audit is spectator- and results-side only: it is never in a frame
    ## a seat could read.
    check not sim.tableStateJson().hasKey("audit")

suite "liar's poker":
  test "digits 0..9, eight-digit serials, and bids on digit 0 are legal":
    var seenLeadingZero = false
    for seed in 0 .. 30:
      var sim = initSim(fixtureConfig(deals = 3, seed = seed, mode = mPoker,
        handSize = 8))
      sim.beginDeal()
      for slot in 0 ..< sim.seats():
        check sim.hands[slot].len == 8
        for digit in sim.hands[slot]:
          check digit >= 0
          check digit <= 9
        if sim.hands[slot][0] == 0:
          seenLeadingZero = true
      if seed == 0:
        let opener = sim.currentTurn().seat
        check sim.legalBid(1, 0)
        sim.applyBid(opener, 1, 0)
        check sim.bidFace == 0
        check sim.events[^1].face == 0
        ## A digit is spoken as a digit, never as a letter.
        check bidText(1, 0) == "1 x 0"
        expect LiarsDiceError:
          sim.applyBid(sim.currentTurn().seat, 1, 10)
        expect LiarsDiceError:
          sim.applyBid(sim.currentTurn().seat, 1, -1)
    check seenLeadingZero

suite "talk and notes":
  test "say and notes are cut on RUNE boundaries, never on bytes":
    var longSay = ""
    for index in 0 ..< 300:
      longSay.add("é")
    var longNotes = ""
    for index in 0 ..< 700:
      longNotes.add("字")
    check longSay.runeLen == 300
    check cleanSay(longSay).runeLen == MaxSayLen
    check cleanSay(longSay).endsWith("…")
    check validateUtf8(cleanSay(longSay)) == -1
    check cleanNotes(longNotes).runeLen == MaxNotesLen
    check validateUtf8(cleanNotes(longNotes)) == -1
    ## Newlines and control characters collapse to single spaces.
    check cleanSay("  a\n\nb\tc  ") == "a b c"
    var sim = initSim(fixtureConfig(deals = 3, seed = 6))
    sim.beginDeal()
    sim.applyBid(sim.currentTurn().seat, 3, 4, longSay, longNotes)
    check sim.events[^1].say.runeLen == MaxSayLen
    check sim.events[^1].notes.runeLen == MaxNotesLen
    check validateUtf8($sim.events[^1].eventToJson()) == -1
    check sim.dealSays.len == 1

  test "with talk off a say never reaches the event or the frame":
    var sim = initSim(fixtureConfig(deals = 3, seed = 6, talk = false))
    sim.beginDeal()
    sim.applyBid(sim.currentTurn().seat, 3, 4, "loaded with fours", "mine")
    check sim.events[^1].say == ""
    check sim.dealSays.len == 0
    check sim.events[^1].notes == "mine"
    check sim.tableStateJson()["seats"][0]["say"].getStr() == ""
    sim.applyChallenge(sim.currentTurn().seat, "nice try")
    check sim.events[^1].say == ""

suite "event json":
  test "every kind round-trips, including multi-byte talk":
    var sim = initSim(fixtureConfig(deals = 2, seed = 15))
    sim.beginDeal()
    sim.applyBid(sim.currentTurn().seat, 3, 2, "sixes are cheap 🎲",
      "watch the 字 seat", scripted = true, fallback = true)
    sim.applyChallenge(sim.currentTurn().seat, "liar 🃏", "called it")
    sim.playDeal()
    check sim.done
    for event in sim.events:
      check eventFromJson(event.eventToJson()) == event
      check validateUtf8($event.eventToJson()) == -1
    let start = sim.events[0].eventToJson()
    check start["kind"].getStr() == "start"
    check not start.hasKey("deal")
    let deal = sim.events[1].eventToJson()
    check deal["kind"].getStr() == "deal"
    check deal["hands"].len == sim.seats()
    check deal["opener"].getInt() == sim.order[0]
    let bid = sim.events[2].eventToJson()
    check bid["kind"].getStr() == "bid"
    check bid["quantity"].getInt() == 3
    check bid["face"].getInt() == 2
    check bid["scripted"].getBool()
    check bid["fallback"].getBool()
    check not bid.hasKey("counts")
    let challenge = sim.events[3].eventToJson()
    check challenge["kind"].getStr() == "challenge"
    check challenge["counts"].len == sim.seats()
    check challenge.hasKey("bidderWins")
    check challenge["other"].getInt() == sim.events[2].seat
    check sim.events[^1].kind == evEnd
    check sim.events[^1].text == "complete"

suite "replay":
  test "re-deriving frames from the event log reproduces the episode":
    var sim = initSim(fixtureConfig(deals = 4, seed = 19))
    var step = 7
    while not sim.done:
      let turn = sim.currentTurn()
      case turn.kind
      of tkDeal:
        sim.beginDeal()
      of tkAct:
        step = (step * 1103515245 + 12345) mod 2147483648
        if sim.mustChallenge() or (sim.bidSeat >= 0 and step mod 3 == 0):
          sim.applyChallenge(turn.seat, "call 🎲", "note " & $step,
            scripted = step mod 2 == 0)
        else:
          sim.applyBid(turn.seat, sim.bidQuantity + 1,
            sim.config.lowFace() + step mod 6, "say " & $step, "",
            scripted = step mod 2 == 1)
      of tkNone:
        discard
    var events: seq[GameEvent]
    for event in sim.events:
      events.add(eventFromJson(event.eventToJson()))
    let frames = replayMatch(sim.config, events)
    check frames.len == events.len + 1
    check frames[^1].done
    check frames[^1].reason == sim.reason
    check frames[^1].wins == sim.wins
    check frames[^1].losses == sim.losses
    check frames[^1].notes == sim.notes
    check frames[^1].faced == sim.faced
    check frames[^1].netPair == sim.netPair
    check $frames[^1].tableStateJson() == $sim.tableStateJson()
    check $frames[^1].resultsJson() == $sim.resultsJson()
    check frames[0].deal == -1
    check frames[0].events.len == 0
    check frames[1].events.len == 1

  test "a deal event that contradicts the seed is rejected":
    var sim = initSim(fixtureConfig(deals = 3, seed = 23))
    sim.playDeal()
    var events: seq[GameEvent]
    for event in sim.events:
      events.add(eventFromJson(event.eventToJson()))
    ## Doctor one symbol of one hand: the replay must refuse to render it.
    for index in 0 ..< events.len:
      if events[index].kind == evDeal:
        ## 1->2, 2->3, ... 6->1: always a different face from the seeded one.
        events[index].hands[0][0] =
          (events[index].hands[0][0] mod 6) + 1
        break
    expect LiarsDiceError:
      discard replayMatch(sim.config, events)
    ## And a log replayed against a different seed is rejected too.
    var other = sim.config
    other.seed = sim.config.seed + 1
    expect LiarsDiceError:
      discard replayMatch(other, sim.events)

  test "a deadline ending re-derives as deadline in all three phases":
    ## (a) between deals.
    var between = initSim(fixtureConfig(deals = 6, seed = 31))
    between.playDeal()
    between.playDeal()
    between.endEarly()
    ## (b) mid-deal, after a bid.
    var midDeal = initSim(fixtureConfig(deals = 6, seed = 32))
    midDeal.playDeal()
    midDeal.beginDeal()
    midDeal.applyBid(midDeal.currentTurn().seat, 2, 5)
    midDeal.endEarly()
    ## (c) before deal 1 ever opened.
    var never = initSim(fixtureConfig(deals = 6, seed = 33))
    never.endEarly()
    for sim in [between, midDeal, never]:
      check sim.reason == "deadline"
      var events: seq[GameEvent]
      for event in sim.events:
        events.add(eventFromJson(event.eventToJson()))
      let frames = replayMatch(sim.config, events)
      check frames.len == events.len + 1
      check frames[^1].done
      check frames[^1].reason == "deadline"
      check frames[^1].dealsPlayed == sim.dealsPlayed
      check $frames[^1].tableStateJson() == $sim.tableStateJson()
      check frames[^1].resultsJson()["reason"].getStr() == "deadline"
    check between.dealsPlayed == 2
    check midDeal.dealsPlayed == 1
    check never.dealsPlayed == 0
