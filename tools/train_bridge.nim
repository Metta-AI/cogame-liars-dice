## Persistent JSONL bridge for Metta RL and native Puffer training.
## nim c -d:release --path:src -o:liars-dice-train-bridge tools/train_bridge.nim
## liars-dice-train-bridge coworld_manifest_template.json [standard|poker|silent]

import std/[json, os]
import liars_dice/[llm, sim]

const
  OperatorPrompt = "Play to maximize your score using only your own hand and the public table."
  MaxQuantity = 32
  MaxFace = 9

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc advance(game: var Sim) =
  while not game.done:
    let turn = game.currentTurn()
    case turn.kind
    of tkDeal: game.beginDeal()
    of tkAct:
      if not game.mustChallenge():
        return
      game.applyChallenge(turn.seat, scripted = true, forced = true)
    of tkNone: doAssert game.done

proc decision(game: Sim, id: int): JsonNode =
  let seat = game.currentTurn().seat
  var hand = newJArray()
  for face in 0 .. MaxFace:
    hand.add(%game.ownCount(seat, face))
  let view = %*{
    "seat": seat, "table_position": game.seatAt[seat],
    "mode": $game.config.mode, "hand": hand,
    "deal": game.deal, "deals": game.config.deals,
    "bid": (if game.bidSeat < 0: newJNull()
      else: %*{"seat": game.bidSeat, "quantity": game.bidQuantity, "face": game.bidFace}),
    "bids_this_deal": game.bidsThisDeal,
    "wins": game.wins, "losses": game.losses
  }
  %*{
    "kind": "decision", "game": "liars-dice", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": id,
    "semantic_view": view, "inbox": [],
    "messages": [
      {"role": "system", "content": systemPrompt(game, seat)},
      {"role": "user", "content": userPrompt(game, seat, OperatorPrompt)}
    ],
    "speech_messages": [],
    "action_schema": {"type": "object", "required": ["action"]},
    "typed_question": newJNull()
  }

proc encoding(game: Sim, id: int): JsonNode =
  let seat = game.currentTurn().seat
  var values = newJArray()
  for slot in 0 ..< game.seats():
    values.add(%(if slot == seat: 1 else: 0))
  values.add(%game.seatAt[seat])
  values.add(%(if game.config.mode == mPoker: 1 else: 0))
  for value in [game.config.handSize, game.config.deals, game.deal,
      game.dealsPlayed, game.config.maxBidsPerDeal, game.bidsThisDeal,
      game.bidQuantity, game.bidFace, game.bidSeat]:
    values.add(%value)
  for face in 0 .. MaxFace:
    values.add(%game.ownCount(seat, face))
  for slot in 0 ..< game.seats():
    values.add(%game.wins[slot])
    values.add(%game.losses[slot])
  var actions = newJArray()
  for quantity in 1 .. MaxQuantity:
    for face in 0 .. MaxFace:
      if game.legalBid(quantity, face):
        actions.add(%*{"action": "bid", "quantity": quantity, "face": face})
      else:
        actions.add(newJNull())
  if game.bidSeat >= 0:
    actions.add(%*{"action": "challenge"})
  else:
    actions.add(newJNull())
  %*{"decision_id": id, "values": values, "actions": actions}

when isMainModule:
  let args = commandLineParams()
  if args.len notin 1 .. 2:
    quit("usage: liars-dice-train-bridge MANIFEST [VARIANT]", 1)
  let variant = if args.len == 2: args[1] else: "standard"
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil, "unknown variant: " & variant
  var game: Sim
  var client: LlmClient
  var id = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == 4
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["tokens"] = %*["t0", "t1", "t2", "t3"]
      runtimeConfig["seed"] = %seedOf(request["seed"].getStr())
      config.update($runtimeConfig)
      config = sampleEpisode(config)
      doAssert config.players.len == 4 and config.handSize * 4 <= MaxQuantity
      game = initSim(config)
      client = newScriptedClient(config)
      id = 0
      game.advance()
      response = game.decision(id)
    of "encode":
      doAssert not game.done
      response = game.encoding(id)
    of "teacher":
      doAssert not game.done
      let seat = game.currentTurn().seat
      let teacher = client.scriptedAction(game, seat)
      var action = %*{"action": $teacher.action}
      if teacher.action == aBid:
        action["quantity"] = %teacher.quantity
        action["face"] = %teacher.face
      response = %*{"response": $action}
    of "step":
      doAssert not game.done and request["decision_id"].getInt() == id
      let action = parseJson(request["response"].getStr())
      let seat = game.currentTurn().seat
      let parsed = game.parseReply(action)
      if parsed.action == aBid:
        doAssert game.legalBid(parsed.quantity, parsed.face)
        game.applyBid(seat, parsed.quantity, parsed.face)
      else:
        doAssert game.bidSeat >= 0
        game.applyChallenge(seat)
      game.advance()
      inc id
      var observation: JsonNode
      if game.done:
        let outcome = game.resultsJson()
        var scores = newJObject()
        for slot in 0 ..< game.seats():
          scores[$slot] = outcome["scores"][slot]
        observation = %*{"kind": "terminal", "scores": scores}
      else:
        observation = game.decision(id)
      response = %*{"kind": "accepted", "action": action,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
