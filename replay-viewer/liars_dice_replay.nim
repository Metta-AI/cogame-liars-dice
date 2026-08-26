## Liar's Dice static replay viewer, wasm side.
##
## JS hands the raw replay bytes to ld_load_replay; this module parses them
## with the SAME sim code the game server runs, re-derives the per-event table
## states, and exposes the enriched payload (identical shape to the game's
## /replay websocket message) for the shared renderer.js to draw.

import
  std/json,
  liars_dice/sim

var
  payload: string
  lastError: string

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc buildReplayPayload*(raw: string): string =
  ## The whole wasm entry point's work in one pure proc, so tests can drive
  ## the exact code path the browser runs: parse the recorded replay bytes
  ## with the SAME sim the game server ran, re-derive one table state per
  ## event prefix, and emit the enriched payload renderer.js reads.
  let replay = parseJson(raw)
  let configNode = replay["config"]
  var config = defaultGameConfig()
  config.mode = parseMode(configNode{"mode"}.getStr("dice"))
  config.handSize = configNode{"handSize"}.getInt(5)
  config.deals = configNode{"deals"}.getInt(8)
  config.talk = configNode{"talk"}.getBool(true)
  config.maxBidsPerDeal = configNode{"maxBidsPerDeal"}.getInt(12)
  config.seed = configNode{"seed"}.getInt(0)
  ## The replay carries the episode's fitted cap; never re-fit it.
  config.sampled = true
  for name in replay["names"]:
    config.players.add(PlayerConfig(name: name.getStr()))
  var events: seq[GameEvent]
  for node in replay["events"]:
    events.add(eventFromJson(node))
  var states = newJArray()
  for frame in replayMatch(config, events):
    states.add(frame.tableStateJson())
  $ %*{
    "type": "replay",
    "protocol": replay{"protocol"}.getStr("liarsdice.replay.v1"),
    "names": replay["names"],
    "policyNames": replay{"policyNames"},
    "config": replay["config"],
    "events": replay["events"],
    "results": replay{"results"},
    "states": states
  }

proc ldLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "ld_load_replay", cdecl.} =
  try:
    lastError = ""
    payload = buildReplayPayload(bytesFromPointer(data, int(length)))
    return 1
  except CatchableError as error:
    lastError = error.msg
    return 0

proc ldPayloadPointer(): ptr uint8 {.exportc: "ld_payload_ptr", cdecl.} =
  if payload.len == 0:
    nil
  else:
    cast[ptr uint8](payload[0].addr)

proc ldPayloadLength(): cint {.exportc: "ld_payload_len", cdecl.} =
  cint(payload.len)

proc ldErrorPointer(): ptr uint8 {.exportc: "ld_error_ptr", cdecl.} =
  if lastError.len == 0:
    nil
  else:
    cast[ptr uint8](lastError[0].addr)

proc ldErrorLength(): cint {.exportc: "ld_error_len", cdecl.} =
  cint(lastError.len)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  ## Nim's generated main would run module-global destructors on return,
  ## freeing `payload` and friends while JS keeps calling into the module.
  ## Exiting with a live runtime skips the destructor epilogue so globals stay
  ## valid for the life of the page.
  emscriptenExitWithLiveRuntime()
