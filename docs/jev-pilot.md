# Jev pilot, 2026-09-23

Set `LIARS_DICE_JEV=1` on the game server to use `typesafe/jev-1.13` for prompt-driven seats. The server calls System One for a choice among legal bids and challenge. It supplies the acting seat's private hand, public history, and exact bid probabilities. Scripted `bayes` and `pressure` seats continue to use their local policies. Jev currently selects actions only; it does not produce table talk or persistent notes.

Transport preference is the Coworld Bedrock sidecar (`AWS_ENDPOINT_URL_BEDROCK_RUNTIME` and `X-Coworld-Player-Slot`), then the Metta capture proxy (`METTA_CAPTURE_URL` and `METTA_CAPTURE_KEY`), then OpenRouter (`OPENROUTER_API_KEY`). The capture proxy writes request and response pairs under the trajectory ID `liars-dice-jev-<seed>`.

## Local evidence

`tools/jev_eval.nim` ran three deals per seed with Jev in seat 0 and three scripted bayes opponents. The baseline reran seat 0 as bayes with the same seed and opponents.

| Seed | Jev score | Bayes score |
| --- | ---: | ---: |
| 0 | 0.500 | 0.333 |
| 1 | 0.333 | 0.667 |
| 2 | 0.500 | 0.667 |

The three-seed mean is 0.444 for Jev and 0.556 for bayes. Ten Jev calls cost $0.00082505 in total, with 306.5 ms mean and 425 ms maximum client-observed latency. This sample is too small to establish a gameplay difference.

An additional seed-3 local run through the Metta capture proxy recorded four matched System One request/response pairs, all HTTP 200. A sidecar stub completed seed 4 and received four requests, each with player slot 0 and no bearer key.

The `linux/amd64` Docker image passed a four-player episode using the manifest certification roster. Two seats called Jev and two used scripted baselines. The game and all four player containers exited zero; `results.reason` was `complete`; the replay parsed as JSON. Nine Jev decisions were logged, with no fallback.

## Hosted production canary

Version `liars-dice:0.1.1` passed local and hosted Coworld certification. A private production Experience Request (`xreq_0c5a409d-7a88-48d1-a62d-fe56108657f8`) used relh-owned `relh-liars-dice-jev-20260923:v1` in slot 0 against pressure, bayesfloor, and bayesline policies. It used a $0.05 combined player LLM cap and no ladder submission. The episode completed with scores 0.5625, 0.5, 0.375, and 0.5625; Kubernetes execution cost was $0.00948, separate from player model spend.

The game log records nine slot-0 Jev judgments through the hosted System One sidecar, no failed attempts, and no scripted fallback. Jev provider cost was $0.000892458, with 260 ms mean and 364 ms maximum client-observed latency. One episode verifies hosted operation, not a competitive advantage.

To reproduce the paired pilot, compile and run `tools/jev_eval.nim` with Nim and `OPENROUTER_API_KEY` set. To exercise the container path, build the Dockerfile and run `LIARS_DICE_JEV=1 OPENROUTER_API_KEY=... tools/ci/docker_smoke.sh <image>`.
