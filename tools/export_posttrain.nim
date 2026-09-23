## Export complete native Liar's Dice matches as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT MATCHES [FIRST_SEED] [standard|poker|silent]

import std/[json, os, osproc, strutils]
import liars_dice/[sim, llm]

const OperatorPrompt = "Play to maximize your score using only your own hand and the public table."
const Variants = ["standard", "poker", "silent"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT MATCHES [FIRST_SEED] [standard|poker|silent]", 1)
  let output = args[0]
  let matches = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: "standard"
  if matches < 10 or firstSeed < 1:
    quit("at least ten matches and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + matches:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = newJArray()
    for seat in 0 ..< variantConfig["players"].len:
      runtimeConfig["tokens"].add(%("t" & $seat))
    config.update($runtimeConfig)
    config.seed = seed
    config = sampleEpisode(config)
    var sim = initSim(config)
    let client = newLlmClient(config)
    var rows: seq[string]
    while not sim.done:
      let turn = sim.currentTurn()
      case turn.kind
      of tkDeal:
        sim.beginDeal()
      of tkAct:
        if sim.mustChallenge():
          sim.applyChallenge(turn.seat, scripted = true, forced = true)
          continue
        let teacher = client.scriptedAction(sim, turn.seat)
        var completion = %*{"action": $teacher.action, "say": "", "notes": ""}
        if teacher.action == aBid:
          completion["quantity"] = %teacher.quantity
          completion["face"] = %teacher.face
        let parsed = sim.parseReply(completion)
        doAssert parsed.action == teacher.action
        if teacher.action == aBid:
          doAssert parsed.quantity == teacher.quantity
          doAssert parsed.face == teacher.face
        rows.add($(%*{
          "episode_id": "liars-dice-" & variant & "-" & $seed,
          "seed": "liars-dice-" & variant & "-" & $seed,
          "decision_id": rows.len,
          "prompt": [
            {"role": "system", "content": systemPrompt(sim, turn.seat)},
            {"role": "user", "content": userPrompt(sim, turn.seat, OperatorPrompt)}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "liars-dice",
          "action_schema_revision": "liars-dice-action-v1"
        }))
        if parsed.action == aBid:
          sim.applyBid(turn.seat, parsed.quantity, parsed.face, scripted = true)
        else:
          sim.applyChallenge(turn.seat, scripted = true)
      of tkNone:
        doAssert sim.done
    doAssert rows.len > 0 and sim.reason == "complete"
    let outcome = sim.resultsJson()
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "wins": outcome["wins"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "liars-dice",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-bayes",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
