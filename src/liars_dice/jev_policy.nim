## Jev chooses a legal bid or challenge from one private seat observation.

import std/[json, os, strutils]
import curly

proc chooseAction*(observation: JsonNode, guidance: string): JsonNode =
  var criteria = newJObject()
  var perFace = newSeq[int](observation["faces"].getInt())
  for bid in observation["legalBids"]:
    let face = bid["face"].getInt()
    let faceIndex = face - observation["lowFace"].getInt()
    if perFace[faceIndex] >= 3:
      continue
    perFace[faceIndex].inc
    var held = 0
    for symbol in observation["hand"]:
      if symbol.getInt() == face:
        held.inc
    let quantity = bid["quantity"].getInt()
    criteria["bid_" & $quantity & "_" & $face] = %(
      "Bid " & $quantity & " of face " & $face & "; you hold " & $held &
      " of this face.")
  if observation["canChallenge"].getBool():
    criteria["challenge"] = %"Challenge the standing bid as a bluff."

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  let routerKey = getEnv("OPENROUTER_API_KEY").strip()
  let directKey = getEnv("TYPESAFE_API_KEY").strip()
  var endpoint: string
  var model: string
  var key: string
  if sidecar.len > 0:
    endpoint = sidecar
    model = "typesafe/jev-1.13"
  elif capture.len > 0:
    endpoint = capture
    model = "typesafe/jev-1.13"
    key = getEnv("METTA_CAPTURE_KEY").strip()
  elif routerKey.len > 0:
    endpoint = "https://openrouter.ai/api"
    model = "typesafe/jev-1.13"
    key = routerKey
  else:
    endpoint = getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
    model = getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
    key = directKey
  if endpoint.len == 0 or (sidecar.len == 0 and key.len == 0):
    raise newException(ValueError, "Jev player has no model transport")

  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  let body = %*{
    "model": model,
    "state": "You are playing Liar's Dice. Choose a move that maximizes " &
      "your chance of winning this deal. Your own hand, public bids, talk, " &
      "and revealed history are in this observation:\n" & $observation &
      "\nStrategy guidance: " & guidance,
    "questions": {"decision": {
      "type": "choice",
      "instructions": "Choose one legal bid or challenge.",
      "criteria": criteria
    }}
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, 30)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let payload = parseJson(response.body)
  let answer = payload["answers"]["decision"]
  let probabilities = answer["probabilities"]
  if answer["type"].getStr() != "choice" or
      probabilities.len != criteria.len:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  var selected = ""
  for choice, probability in probabilities.pairs:
    if not criteria.hasKey(choice):
      raise newException(ValueError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      selected = choice
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")
  if selected == "challenge":
    result = %*{"action": "challenge", "say": "", "notes": ""}
  else:
    let parts = selected.split('_')
    result = %*{"action": "bid", "quantity": parseInt(parts[1]),
      "face": parseInt(parts[2]), "say": "", "notes": ""}
  echo "Liar's Dice Jev player: choice ", selected,
    " model ", payload{"model"}.getStr(),
    " input_tokens ", payload["usage"]{"input_tokens"}.getInt(),
    " output_tokens ", payload["usage"]{"output_tokens"}.getInt()
