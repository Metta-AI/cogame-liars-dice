## Complete private language teacher episodes with authoritative outcomes.
import std/[json, os, osproc, strutils, posix]
import bitworld/decision_trajectory
import liars_dice/[llm, sim, training]

const OperatorPrompt = "Choose legal actions to maximize your score using only your own hand and public history."
const Variants = ["standard", "poker", "silent"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT MATCHES [FIRST_SEED] [VARIANT]", 1)
  let output = args[0]
  let matches = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: Variants[0]
  doAssert matches >= 10 and firstSeed >= 1
  doAssert variant in Variants
  doAssert not dirExists(output) and not fileExists(output)
  doAssert execProcess("git status --porcelain").strip().len == 0, "commit source before exporting"
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  discard umask(posix.Mode(0o077))
  createDir(output)
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant: variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var trainRows, validationRows: seq[string]
  var runs = newJArray()
  for seed in firstSeed ..< firstSeed + matches:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = newJArray()
    for seat in 0 ..< variantConfig["players"].len:
      runtimeConfig["tokens"].add(%("t" & $seat))
    runtimeConfig["seed"] = %seed
    runtimeConfig["turnDelayMs"] = %0
    config.update($runtimeConfig)
    config = sampleEpisode(config)
    var sim = initSim(config)
    let episode = "liars-dice-" & variant & "-" & $seed
    let trajectory = newDecisionTrajectory(episode, episode, "liars-dice",
      sourceRevision, sourceRevision)
    let client = newScriptedClient(config)
    while not sim.done:
      let turn = sim.currentTurn()
      if turn.kind == tkDeal:
        sim.beginDeal()
        continue
      doAssert turn.kind == tkAct
      let before = sim
      let seat = turn.seat
      if sim.mustChallenge():
        let forced = Decision(action: aChallenge, scripted: true, fallback: true,
          policy: "engine-bid-cap")
        sim.applyChallenge(seat, scripted = true, forced = true)
        trajectory.recordAppliedDecision(before, sim, seat, forced, OperatorPrompt,
          false, "engine-bid-cap")
        continue
      var teacher = client.scriptedAction(sim, seat, "bayes")
      teacher.policy = "scripted-bayes"
      let completion = sim.decisionAction(teacher)
      let parsed = parseReply(sim, extractJsonObject($completion))
      doAssert parsed.action == teacher.action
      if parsed.action == aBid:
        sim.applyBid(seat, parsed.quantity, parsed.face, parsed.say, parsed.notes, scripted = true)
      else:
        sim.applyChallenge(seat, parsed.say, parsed.notes, scripted = true)
      trajectory.recordAppliedDecision(before, sim, seat, teacher, OperatorPrompt, true)
    doAssert sim.done and sim.reason == "complete"
    trajectory.finishTrajectory(sim)
    let events = trajectory.eventsJsonl()
    let destination = output / "episodes" / (episode & ".jsonl")
    trajectory.writeEventsToUri("file://" & absolutePath(destination))
    var rows: seq[string]
    for line in events.splitLines():
      if line.len == 0: continue
      let event = parseJson(line)
      if event["event_type"].getStr() != "decision" or event["action_status"].getStr() != "accepted": continue
      let selected = event["selected_attempt_id"].getStr()
      for attempt in event["attempts"]:
        if attempt["attempt_id"].getStr() == selected and attempt["policy"].getStr() == "scripted-bayes":
          doAssert attempt["parsed_action"] == event["executed_action"]
          rows.add($(%*{"episode_id": episode, "seed": episode,
            "decision_id": event["decision_id"], "seat": event["seat"],
            "prompt": attempt["prompt"],
            "completion": [{"role": "assistant", "content": attempt["response"]}],
            "game": "liars-dice", "action_schema_revision": "liars-dice-action-v1"}))
    doAssert rows.len > 0
    if seed mod 5 == 0: validationRows.add(rows)
    else: trainRows.add(rows)
    runs.add(%*{"episode_id": episode, "seed": seed, "labels": rows.len,
      "trajectory": "episodes/" & episode & ".jsonl", "outcome": sim.resultsJson()})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 2, "format": "coworld-private-teacher-corpus-v1",
    "game": "liars-dice", "variant": variant, "source_revision": sourceRevision,
    "selection": {"policy": "scripted-bayes", "seats": "all"},
    "operator_prompt": OperatorPrompt, "train_examples": trainRows.len,
    "validation_examples": validationRows.len, "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
