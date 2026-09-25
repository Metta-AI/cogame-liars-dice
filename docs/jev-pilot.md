# Jev pilot, 2026-09-23

The September 23 pilot used game-side Jev calls. That version remains historical evidence. The corrected player sets `PLAYER_JEV=1`, receives its own private hand, public history, and legal bid list, and sends a bid or challenge through the normal action interface. The game validates the move and owns replay and results. Existing prompt and scripted policies still run.

The corrected player uses its own Bedrock sidecar, Metta capture proxy, OpenRouter key, or TypeSafe key. These credentials belong to the player container, not the game.

## Local evidence

The old game-side `tools/jev_eval.nim` ran three deals per seed with Jev in seat 0 and three scripted bayes opponents. These scores do not validate the corrected policy protocol.

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

For a local player-side smoke, build the image, then run `SMOKE_JEV_SLOT=0 TYPESAFE_API_KEY=... tools/ci/docker_smoke.sh <image>`. Keep the default roster for a non-Jev control on the same image.
