## The replay bytes are the whole product: everything the hosted static
## viewer ever sees. They must be STRICT UTF-8 (a byte-boundary truncation
## renders fine in a browser and fails every strict JSON parser), and they
## must re-parse through the very code path the wasm entry runs in the
## browser back into the same episode the server played.

import std/[json, unicode, unittest]
import liars_dice/[llm, sim]
import "../replay-viewer/liars_dice_replay"

proc fixture(seed: int, deals = 4): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.deals = deals
  result.talk = true
  result.sampled = true
  for index in 0 ..< 4:
    result.players.add(PlayerConfig(
      name: ["daveey/liars-dice-calibrator", "Baseline (1)",
        "daveey-1/liars-dice-needler", "Baseline (2)"][index]))
    result.tokens.add("t" & $index)

proc replayPayload(sim: Sim): string =
  ## Byte-for-byte the payload src/liars_dice/server.nim writes as the
  ## episode's replay artifact.
  var names = newJArray()
  for name in sim.names:
    names.add(%name)
  var policyNames = newJArray()
  for player in sim.config.players:
    policyNames.add(%player.name)
  var events = newJArray()
  for event in sim.events:
    events.add(event.eventToJson())
  var order = newJArray()
  for slot in sim.order:
    order.add(%slot)
  $ %*{
    "protocol": "liarsdice.replay.v1",
    "names": names,
    "policyNames": policyNames,
    "config": {
      "mode": $sim.config.mode,
      "seats": sim.seats(),
      "handSize": sim.config.handSize,
      "faces": sim.config.faces(),
      "deals": sim.config.deals,
      "talk": sim.config.talk,
      "maxBidsPerDeal": sim.config.maxBidsPerDeal,
      "seed": sim.config.seed,
      "sampled": true,
      "order": order
    },
    "events": events,
    "results": sim.resultsJson()
  }

proc playWithTalk(config: GameConfig): Sim =
  ## A whole scripted episode, but with the free text pushed in through the
  ## SAME parse path a model reply takes, so the multi-byte truncation that
  ## lands in the replay is the real one.
  let client = newLlmClient(config)
  var sim = initSim(config)
  var beat = 0
  var overlong = "🎲 "
  for index in 0 ..< 200:
    overlong.add("字")
  while not sim.done:
    let turn = sim.currentTurn()
    case turn.kind
    of tkDeal:
      sim.beginDeal()
    of tkAct:
      inc beat
      let scripted = client.scriptedAction(sim, turn.seat, "bayes")
      let say = if beat mod 3 == 0: overlong
        else: "🎲 " & sim.names[turn.seat] & " smells a bluff — 字 " & $beat
      let notes = "per-opponent read 字 " & $beat & " 🎲"
      if scripted.action == aBid:
        let reply = parseReply(sim, %*{
          "action": "bid",
          "quantity": scripted.quantity,
          "face": scripted.face,
          "say": say,
          "notes": notes
        })
        sim.applyBid(turn.seat, reply.quantity, reply.face, reply.say,
          reply.notes, scripted = true)
      else:
        let reply = parseReply(sim, %*{
          "action": "challenge",
          "say": say,
          "notes": notes
        })
        sim.applyChallenge(turn.seat, reply.say, reply.notes, scripted = true)
    of tkNone:
      discard
  result = sim

suite "replay bytes":
  test "the payload is strict UTF-8 and re-derives through the wasm path":
    var sim = playWithTalk(fixture(77))
    check sim.done
    check sim.reason == "complete"
    check sim.dealsPlayed == 4
    ## Multi-byte talk really did land in the log, cut on a rune boundary.
    var sawCut = false
    var sawTalk = false
    for event in sim.events:
      if event.say.len > 0:
        sawTalk = true
        check event.say.runeLen <= MaxSayLen
        if event.say.runeLen == MaxSayLen:
          sawCut = true
      if event.notes.len > 0:
        check event.notes.runeLen <= MaxNotesLen
    check sawTalk
    check sawCut

    let payload = sim.replayPayload()
    ## THE assertion: not one invalid byte anywhere in the artifact.
    check validateUtf8(payload) == -1
    check parseJson(payload)["protocol"].getStr() == "liarsdice.replay.v1"

    ## Re-parse with the wasm entry's own code path.
    let enrichedText = buildReplayPayload(payload)
    check validateUtf8(enrichedText) == -1
    let enriched = parseJson(enrichedText)
    check enriched["type"].getStr() == "replay"
    check enriched["protocol"].getStr() == "liarsdice.replay.v1"
    check enriched["names"].len == 4
    check enriched["policyNames"][0].getStr() ==
      "daveey/liars-dice-calibrator"
    check enriched["events"].len == sim.events.len
    check enriched["states"].len == sim.events.len + 1
    ## The last re-derived state is the live sim's, and the results survive
    ## the round trip verbatim.
    check $enriched["states"][^1] == $sim.tableStateJson()
    check $enriched["results"] == $sim.resultsJson()
    check enriched["results"]["reason"].getStr() == "complete"
    check enriched["results"]["audit"]["faced"].len == 4

  test "a deadline replay re-derives as deadline through the wasm path":
    var sim = initSim(fixture(78, deals = 6))
    sim.beginDeal()
    sim.applyBid(sim.currentTurn().seat, 2, 3, "🎲 opening 字", "note 字")
    sim.applyChallenge(sim.currentTurn().seat, "call 字 🎲", "")
    sim.endEarly()
    check sim.reason == "deadline"
    let payload = sim.replayPayload()
    check validateUtf8(payload) == -1
    let enriched = parseJson(buildReplayPayload(payload))
    check enriched["states"].len == sim.events.len + 1
    check $enriched["states"][^1] == $sim.tableStateJson()
    check enriched["states"][^1]["reason"].getStr() == "deadline"
    check enriched["results"]["reason"].getStr() == "deadline"
    check enriched["results"]["deals"].getInt() == 1

  test "doctored replay bytes are refused, not rendered":
    var sim = playWithTalk(fixture(79, deals = 2))
    let node = parseJson(sim.replayPayload())
    for event in node["events"]:
      if event["kind"].getStr() == "deal":
        let hand = event["hands"][0]
        ## 1->2, 2->3, ... 6->1: always a different face from the seeded one.
        hand.elems[0] = %((hand[0].getInt() mod 6) + 1)
        break
    expect LiarsDiceError:
      discard buildReplayPayload($node)
