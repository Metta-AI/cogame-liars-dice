## Liar's Dice player: a policy is just a prompt.
##
## Connects to the game, delivers its prompt (from PLAYER_PROMPT, or a default
## Liar's Dice strategy), then idles until the final frame. All of the actual
## decision making happens inside the game server, which sends this seat's
## prompt to Claude whenever the seat is on turn.
##
## PLAYER_SCRIPTED=bayes|pressure registers the seat as one of the built-in
## scripted baselines instead: the server plays it deterministically, no LLM.
## Any other value (including the legacy `1`) means `bayes`.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <liars-dice-image> --name my-liars-dice \
##     --run /bin/liars-dice-player --secret-env PLAYER_PROMPT="<strategy>"

import
  std/[json, options, os, strutils],
  liars_dice/jev_policy,
  whisky

const DefaultPrompt = """
Count the dice you can see before you speak. Your own hand plus the table's
expected share (one sixth of the dice you cannot see, per face) is your honest
estimate of any face's count; treat any bid more than two above that estimate as
probably a lie. Challenge when you judge the standing bid is under 40% likely to
be true, and never challenge a bid you would happily have made yourself. When
you raise, prefer the smallest legal raise on a face you actually hold - it
costs the least credibility and leaves you room later. Use table talk to build a
picture you can cash in: claim a face you do NOT hold early in the episode, then
bid honestly on it later. Keep in your notes, per opponent, how often their bids
turned out false and whether their talk matched their hands.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  let requested = getEnv("PLAYER_SCRIPTED").strip()
  let scripted = requested.len > 0
  let jev = getEnv("PLAYER_JEV") == "1"
  ## The server owns the coercion (and logs it); the player reports what it
  ## was asked for.
  let baseline = if requested.toLowerAscii() == "pressure": "pressure"
    else: "bayes"

  proc promptFrame(): string =
    if jev:
      $ %*{"type": "register", "control": "external"}
    else:
      $ %*{"type": "prompt", "prompt": prompt,
        "scripted": scripted, "baseline": baseline}

  echo "liars-dice player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "liars-dice player: prompt delivered (", prompt.len, " chars",
    (if scripted: ", scripted " & baseline else: ""), ")"

  ## whisky RAISES on a close frame or a truncated read (only a timeout
  ## returns none), and the game's quit(0) can outrun the flushed final
  ## frame — so a dead socket must exit 0, not crash the container.
  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        echo "liars-dice player: connection closed, exiting"
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      try:
        let payload = parseJson(message.data)
        case payload{"type"}.getStr()
        of "welcome":
          echo "liars-dice player: seated at slot ",
            payload{"slot"}.getInt(), " as ", payload{"name"}.getStr()
          ## Re-deliver the prompt after the welcome, in case the first send
          ## raced the server's slot registration.
          socket.send(promptFrame())
        of "final":
          echo "liars-dice player: final scores ", payload{"scores"}
          break
        of "observation":
          if jev:
            socket.send($ %*{"type": "action", "event": payload["event"],
              "action": chooseAction(payload["observation"], prompt)})
        else:
          discard
      except CatchableError as error:
        echo "liars-dice player: ignoring bad frame: ", error.msg
  except CatchableError as error:
    echo "liars-dice player: socket closed (", error.msg, "), exiting"
  try:
    socket.close()
  except CatchableError:
    discard
