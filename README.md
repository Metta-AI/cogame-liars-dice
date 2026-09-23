# Liar's Dice

A **bluffing coworld with cheap talk and a soft-play audit** for the Softmax
Coworld platform, on the [cogame-babel](https://github.com/Metta-AI/cogame-babel)
parley technology stack. Four cogs sit at a table. Every deal each is dealt
**five hidden dice** (faces 1–6) and the table holds **twenty dice** in all.
A bid is a claim about *all* of them: `6 × 2` claims that at least six of the
twenty dice show a 2. On your turn you either **raise** — strictly: a larger
quantity, or the same quantity on a higher face — or **challenge**. Ones are
**not** wild. A challenge opens every hand: if the standing bid was true the
**bidder** scores +1 and the challenger −1; if it was a lie the **challenger**
scores +1 and the bidder −1. Nobody else scores, the deal ends, and a fresh
deal is dealt. Eight independent deals settle the episode.

One line of **cheap talk** (≤ 140 characters) can ride on any action.
Everyone sees it the instant the action applies, nothing said is binding, and
the rules never reference it — it exists so a policy can build a picture it
can cash in later, and so a spectator can watch it try.

**The game is LLM-driven and a policy is just a prompt.** On each turn the
game server sends the acting seat's policy prompt plus its own hand, the
public bid history of the deal, the table talk, **every previous deal in full**
(the challenged bid, who challenged, the real count, and all revealed hands),
the standings and the seat's private notes to Claude, which answers with a bid
or a challenge, a line of talk and new notes. Player containers exist only to
deliver their prompt over the websocket. This is a strictly **sequential** turn
game: one model call per turn, for the acting seat only. Two built-in
**scripted baselines** — `bayes` (calibrated) and `pressure` (bluffier) — play
any seat that registers as scripted, and every seat when no LLM credentials are
available, so episodes (and offline certification) always complete.

Seats play under **anonymous cog names** (Sprocket, Gizmo, …) in a seeded
random seating order: policy display names never reach a prompt, so nobody can
meta-game "that seat is the champion", and no pair of policies sits in the same
relation twice. The spectator and replay viewers map the aliases back to policy
names; `results.names` carries policy names and `results.aliases` the aliases,
so an auditor can line the two up.

**Scoring.** `points = wins − losses` and
`score = 0.5 + points / (2 × deals played)`, so **0.5 is break even**, 1.0 is
winning every deal and 0.0 is losing every one. `sum(points) == 0` over any
completed set of deals: the game is zero-sum in points and the table's mean
score is always 0.5. The episode ends `complete` after `deals` deals (default
8) or `deadline` when the episode clock stops play at a deal boundary; no other
`results.reason` is ever written.

**Variants.** `standard` (dice, talk on), `poker` — the OpenSpiel
*liars_poker* variant, bidding on the digits of four hidden eight-digit serial
numbers instead of dice faces — and `silent` (no table talk).

**Soft-play audit.** The server records, from full information and never shown
to any seat in-game: who faced whom, who challenged whom, the net points
between every ordered pair, the **expected value each seat forwent by waving a
beatable bid through** (`expLoss`), and every seat's bluff rate. A seat that
repeatedly lets one specific opponent's clearly beatable bids stand shows a
high `expLoss` against that opponent and a low one elsewhere; that asymmetry is
the audit's read. It ships in `results.audit` and in the replay.

## Layout

- `src/liars_dice.nim` — entrypoint (Coworld runtime contract, live vs replay
  mode)
- `src/liars_dice/types.nim` — config, event and error types
- `src/liars_dice/sim.nim` — pure rules, no IO: seating, deals, bid legality,
  challenge resolution, the bid cap, scoring, the exact binomial tail
  (`pTrue`), the soft-play audit, rune-safe truncation and replay derivation;
  shared by the server, the tests and the wasm viewer
- `src/liars_dice/llm.nim` — Claude client, the prompts, tolerant reply
  parsing, and the two scripted baselines
- `src/liars_dice/server.nim` — mummy HTTP/WS server (player, global, replay)
- `src/liars_dice_player.nim` — the prompt-delivery player (`PLAYER_PROMPT` /
  `PLAYER_SCRIPTED=bayes|pressure`)
- `client/` — shared canvas renderer + global/player/replay pages (the
  cogame-babel broadcast chrome around the Liar's Dice stage)
- `replay-viewer/` — static wasm replay viewer (`index.html?replay=<url>`)
- `tools/build_replay_viewer.sh` — the `coworld build` replay-viewer hook
- `tools/tune_baseline.nim` — the threshold sweep that picks the `bayes`
  baseline's two numbers (see *Tuning the scripted baseline*)
- `tools/jev_eval.nim` — paired local Jev versus bayes episodes; see
  [Jev pilot](docs/jev-pilot.md) for the measured results and setup
- `tools/ci/` — the CI harness: `docker_smoke.sh` (one real episode in raw
  docker), `viewer_smoke.mjs` (the bundle opened in headless chromium) and
  `policies.json` (the policy set a release uploads)
- `data/tuning/threshold_sweep.tsv` — the committed output of that sweep
- `data/` — cog sprites and art, borrowed from
  [coworld-ctf](https://github.com/Metta-AI/coworld-ctf) (MIT)

## Local loop

```bash
export PATH="$HOME/.nimby/nim/bin:$PATH"
nimby --global sync nimby.lock                 # fetch pinned packages
# Generate nim.cfg from your nimby package tree (not committed - the
# paths are machine-specific):
rm -f nim.cfg
for pkg in ~/.nimby/pkgs/*; do
  if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg;
  else echo "--path:\"$pkg\"" >> nim.cfg; fi
done
echo '--path:"src"' >> nim.cfg

nim r --path:src tests/test_sim.nim               # rules
nim r --path:src tests/test_bot.nim               # scripted baselines
nim r --path:src tests/test_replay.nim            # strict-UTF-8 replay bytes
nim c -d:release -o:bin/liars-dice src/liars_dice.nim
nim c -d:release -o:bin/liars-dice-player src/liars_dice_player.nim
nim c --hints:off -d:emscripten \
  replay-viewer/liars_dice_replay.nim             # wasm viewer
./tools/ci/docker_smoke.sh coworld-liars-dice:ci  # one containerised episode
```

Every test runs twice in CI, debug and `-d:release`. `docker_smoke.sh` runs
with **no** `ANTHROPIC_API_KEY`, which is deliberate: the game must complete on
its scripted baselines with no credentials at all.

Coworld packaging happens in GitHub Actions
(`.github/workflows/coworld-release.yml`), which runs
`coworld build` → `certify` → `upload-policy` (every entry in
`tools/ci/policies.json`) → `upload-coworld` → `coworld secret put liars-dice
anthropic_api_key`, in that order.

## Tuning the scripted baseline

The `bayes` baseline has exactly two parameters — `chal` (challenge a standing
bid this seat reads as less than `chal` likely) and `safe` (keep a raise only
if it is at least `safe` likely). They are **searched, not chosen**:
`tools/tune_baseline.nim` runs a full round robin over a 110-point lattice
(`chal` 0.05–0.55, `safe` 0.25–0.70, step 0.05). Every point plays every other
point head to head — two seats each at a four-seat table, both seatings, 24
seeds × 30 deals × both modes, 586 080 episodes — and a point's score is the
mean `sim.score` over every seat it held, so 0.5 is break even against the
whole searched surface. A second column scores each point against the shipped
`pressure` filler, which is a deliberate foil and never a candidate.

```bash
nim r -d:release --path:src tools/tune_baseline.nim           # full sweep -> data/tuning/threshold_sweep.tsv
nim r -d:release --path:src tools/tune_baseline.nim --check   # the CI slice
```

The surface is a plateau rather than a peak — `pTrue` takes discrete values, so
a threshold only matters when it crosses one — and ten of the 110 points are
within 2 s.e. (paired by seed) of the argmax. The shipped
`BayesChallenge = 0.15`, `BayesSafe = 0.35` is the centre of that plateau:
rank **8 of 110**, paired gap **0.00011** against the argmax `0.10/0.30` with a
2 s.e. band of 0.00034, and a full 0.05 step from the cliffs on either side
(`safe` 0.45 and `chal` 0.25 both lose ~0.007). The committed table is
`data/tuning/threshold_sweep.tsv`, header and all.

CI re-runs the same sweep on every push (job `test`, step *Sweep the scripted
baseline's thresholds*) over a reduced-but-real slice — the same 110 points,
8 seeds, dice only, ~20 s — and **fails** unless the shipped point is the
optimum or paired-tied with it. If you change either constant by hand, that
step is what catches you; rerun the harness and take its pick instead.

For the record, the pre-sweep values (`chal 0.40`, `safe 0.55`) rank **80 of
110** at 0.49236, below break even against the lattice; the sweep is what
replaced them.

## Fielding a policy

A policy is just a prompt on the published player runnable:

```bash
uv run coworld upload-policy <liars-dice image> --name my-liars-dice \
  --run /bin/liars-dice-player \
  --secret-env PLAYER_PROMPT="Your Liar's Dice strategy here."
```

Or field a scripted baseline: the same image with
`--secret-env PLAYER_SCRIPTED=bayes` (or `pressure`). Any other value means
`bayes`, and the server logs the coercion.
