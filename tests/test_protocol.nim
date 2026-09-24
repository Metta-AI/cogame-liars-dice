## An external policy gets the acting seat's legal decision view.

import std/[json, strutils, unittest]
import liars_dice/[server, sim]

suite "player decision observation":
  test "current private state stays in its seat and legal bids match rules":
    var config = defaultGameConfig()
    config.sampled = true
    for slot in 0 ..< 4:
      config.players.add(PlayerConfig(name: "P" & $slot))
      config.tokens.add("token-" & $slot)
    var game = initSim(config)
    game.beginDeal()
    game.notes[1] = "private note of other seat"
    let observation = game.decisionObservation(0)
    check observation["hand"] == %game.hands[0]
    check observation{"hands"}.isNil
    check "private note of other seat" notin $observation
    check observation["history"].len == 0
    for bid in observation["legalBids"]:
      check game.legalBid(bid["quantity"].getInt(), bid["face"].getInt())
    let actor = game.currentTurn().seat
    game.applyBid(actor, 1, config.lowFace())
    game.applyChallenge(game.currentTurn().seat)
    game.beginDeal()
    let next = game.decisionObservation(0)
    check next["history"].len == 1
    check next["history"][0]["hands"].len == 4
    check next["hand"] == %game.hands[0]
