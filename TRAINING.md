# Training

The authoritative game records private native Messages requests, responses,
all retries, actual served model and platform call identifiers when
`COGAME_SAVE_TRAJECTORY_URI` is set. Supply `COWORLD_EPISODE_ID`,
`COWORLD_GAME_VERSION`, and `COWORLD_SOURCE_REVISION`; absent pins fail before play.
Recording finishes before results trigger player teardown.

Each accepted proposal is compared with the independently recorded engine event.
The corpus retains every seat, consumed fallback, forced action, and complete
participant outcome. Missing credentials, external timeouts, deadlines, and
engine-forced actions are fallback evidence, never teacher labels.
Public replay and live spectator events exclude private memory. Stored replay
readers retain their existing format; archived files are not rewritten.

Native calls default to explicit `COWORLD_LLM_TEMPERATURE=1`.
Use `0` for greedy evaluation. Nonfinite or out-of-range settings fail at client
construction. Checkpoint routes carry actual model, tokenizer, template identity,
and draw-time tokens/log probabilities when the serving engine provides them.
Greedy or absent probabilities remain absent and cannot qualify for policy-gradient
training. A loopback HTTP fixture does not establish Kubernetes deployment parity.

## Language and numeric bridges

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/liars-dice-bridge tools/train_bridge.nim
python3 tools/test_language_bridge.py /tmp/liars-dice-bridge
python3 tools/test_train_bridge.py /tmp/liars-dice-bridge
```

Run the bridge with `coworld_manifest_template.json VARIANT --language` for the
ordinary hosted prompt, JSON extraction, reply parser, private notes, and action
execution. The `bayes` teacher uses the same acting-player view.
The default fixed numeric action catalog is a separate research interface; its
restricted actions omit free-text memory and do not establish language-policy parity.
Hidden-hand permutation tests compare the teacher and prompts across every variant.

## Complete private teacher corpus

Commit source before export. Use a fresh destination outside this checkout.

```sh
nim c -d:release --path:src -o:/tmp/liars-dice-export tools/export_posttrain.nim
for variant in standard poker silent; do
  /tmp/liars-dice-export "/tmp/liars-dice-${variant}" 10 1 "$variant"
done
```

`episodes/` contains complete private decision/episode JSONL, with engine-applied
labels and terminal outcomes. `train.jsonl` and `validation.jsonl` project accepted
`scripted-bayes` decisions; the manifest names that target policy. Opponent and
fallback turns remain in the underlying episodes. Seed families stay within a split.
Files are created under umask 077, episode writes are exclusive, and existing
outputs are refused. Private corpora are excluded from Docker and Git.

Use the current [Metta post-training workflow](https://github.com/Metta-AI/metta/tree/main/packages/metta-posttrain):
qualify the complete episodes with `coworld training qualify --policy scripted-bayes`,
then use the SLIME workflow for training, artifact verification, and checkpoint
reload. Runtime, training, and evaluation must use the same manifest variant,
operator prompt, model tokenizer/template, and output/context budgets. Serving a
learner through the sidecar requires a platform-owned authenticated route;
players cannot choose arbitrary checkpoint URLs. Production rollout remains separate
from local teacher/native protocol tests.
