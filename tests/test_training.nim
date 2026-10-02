## Teacher and prompt cannot observe opponents' hidden hands.
import std/[algorithm, json, sequtils, strutils]
import bitworld/decision_trajectory
import liars_dice/[llm, sim, training]

when isMainModule:
  let manifest = parseFile("coworld_manifest_template.json")
  var labels = 0
  for entry in manifest["variants"]:
    for seed in 1 .. 3:
      var config = defaultGameConfig()
      let raw = copy(entry["game_config"])
      raw["tokens"] = newJArray()
      for seat in 0 ..< raw["players"].len: raw["tokens"].add(%("t" & $seat))
      raw["seed"] = %seed
      config.update($raw)
      config = sampleEpisode(config)
      var sim = initSim(config)
      let trajectory = newDecisionTrajectory("test", "test", "test", "test", "test")
      while not sim.done:
        let turn = sim.currentTurn()
        if turn.kind == tkDeal:
          sim.beginDeal()
          continue
        if sim.mustChallenge():
          sim.applyChallenge(turn.seat, scripted = true, forced = true)
          continue
        let seat = turn.seat
        let privatePrompt = userPrompt(sim, seat, "maximize score")
        var teacher = newScriptedClient(config).scriptedAction(sim, seat, "bayes")
        teacher.policy = "scripted-bayes"
        for permutation in 0 ..< 6:
          var hidden = sim
          hidden.hands = newSeq[seq[int]](sim.hands.len)
          for other, hand in sim.hands:
            for symbol in hand:
              hidden.hands[other].add(if other == seat: symbol else:
                sim.config.lowFace() + (symbol - sim.config.lowFace() + permutation + 1) mod sim.config.faces())
          doAssert userPrompt(hidden, seat, "maximize score") == privatePrompt
          doAssert systemPrompt(hidden, seat) == systemPrompt(sim, seat)
          let candidate = newScriptedClient(config).scriptedAction(hidden, seat, "bayes")
          doAssert hidden.decisionAction(candidate) == sim.decisionAction(teacher)
        let before = sim
        let parsed = parseReply(sim, extractJsonObject($sim.decisionAction(teacher)))
        if parsed.action == aBid:
          sim.applyBid(seat, parsed.quantity, parsed.face, parsed.say, parsed.notes, scripted = true)
        else: sim.applyChallenge(seat, parsed.say, parsed.notes, scripted = true)
        trajectory.recordAppliedDecision(before, sim, seat, teacher, "maximize score", true)
        inc labels
      trajectory.finishTrajectory(sim)
      for line in trajectory.eventsJsonl().splitLines():
        if line.len == 0: continue
        let event = parseJson(line)
        if event["event_type"].getStr() == "decision":
          doAssert event["attempts"][0]["parsed_action"] == event["executed_action"]
      echo entry["id"].getStr(), " seed=", seed, " complete"
  doAssert labels > 0
  echo "hidden-state invariant labels=", labels
