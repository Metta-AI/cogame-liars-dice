# Metta post-training data

The native simulator and published `bayes` policy export supervised examples
for all three certified variants:

```sh
nimby sync nimby.lock
for variant in standard poker silent; do
  nim r -d:release --path:src tools/export_posttrain.nim \
    "/tmp/liars-dice-$variant" 10 1 "$variant"
done
```

Each run reads its manifest variant config, adds the per-seat tokens supplied
by the hosted platform, and plays complete seeded matches. The exporter skips
challenges the game forces at its bid cap, since those have no player decision.
Examples contain the hosted system and user prompts, the acting seat's own
hand and public table, and a `bayes` action accepted by the game's reply
parser. Parsed actions drive the simulator. Entire matches stay in one split.
The manifest records source revision, variant, scores, wins, and row counts.
Existing output directories are never overwritten.

Train an output with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/liars-dice-standard \
  --output /tmp/liars-dice-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

Ten complete matches yielded 262 training and 67 validation examples for
standard, 254 and 57 for poker, and 262 and 67 for silent. All 969 examples
fit a 4,096-token context with the Qwen2.5-0.5B-Instruct tokenizer (maximum:
1,523 tokens). One CPU optimizer step per dataset with a local tiny model
verifies the Metta post-training path. These examples distill the scripted
teacher; they do not establish stronger league play.

# Numeric reinforcement learning

Compile the persistent decision bridge and pass its manifest and variant to
Metta's `recipes.external.coworld.train` (native PufferLib) or
`recipes.external.coworld_metta_rl.train` (Metta RL):

```sh
nim c -d:release --path:src -o:/tmp/liars-dice-train-bridge tools/train_bridge.nim
python tools/test_train_bridge.py /tmp/liars-dice-train-bridge
```

The three certified variants have four seats, 33 numeric observation values,
and 321 fixed action slots. The first 320 slots encode quantity 1–32 and face
0–9; slot 320 challenges a standing bid. Illegal choices are masked. The
bridge advances forced challenges without asking a policy and uses the
published Bayesian baseline for opponents and teacher labels. Numeric values
contain the acting seat's hand counts and public state. Text messages reuse
the hosted prompts, which also include public history and previously revealed
hands. Complete episodes produce native scores; a truncated episode is never
scored as complete.
