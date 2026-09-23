## Paired local Liar's Dice episodes: Jev seat 0 versus scripted bayes.
import std/[json, os, strutils]
import liars_dice/[llm, sim]

proc run(seed: int, jev: bool): JsonNode =
  var config = defaultGameConfig()
  config.seed = seed
  config.deals = 3
  config.handSize = 5
  config.talk = true
  config.sampled = true
  for seat in 0 ..< 4:
    config.players.add(PlayerConfig(name: "P" & $seat))
    config.tokens.add("token-" & $seat)
  var sim = initSim(config)
  let client = newLlmClient(config)
  var jevTurns = 0
  while not sim.done:
    let turn = sim.currentTurn()
    case turn.kind
    of tkDeal:
      sim.beginDeal()
    of tkAct:
      let decision =
        if jev and turn.seat == 0:
          if jevTurns >= 60:
            raise newException(ValueError, "Jev evaluation exceeded 60 turns")
          inc jevTurns
          client.decide(sim, turn.seat,
            "Maximize your own wins using your hand and the public bids.", false)
        else:
          client.scriptedAction(sim, turn.seat)
      if decision.action == aBid:
        sim.applyBid(turn.seat, decision.quantity, decision.face,
          decision.say, decision.notes, decision.scripted)
      else:
        sim.applyChallenge(turn.seat, decision.say, decision.notes,
          decision.scripted)
    of tkNone:
      break
  result = %*{"scores": sim.resultsJson()["scores"], "jev_turns": jevTurns}

let seed = parseInt(paramStr(1))
echo "jev_result " & $run(seed, true)
echo "baseline_result " & $run(seed, false)
