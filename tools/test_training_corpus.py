"""Check full private evidence, source pins, and exact selected teacher labels."""

import json
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
manifest = json.loads((root / "manifest.json").read_text())
assert manifest["format"] == "coworld-private-teacher-corpus-v1"
assert len(manifest["runs"]) >= 10
for path in [root, *root.rglob("*")]:
    assert stat.S_IMODE(path.stat().st_mode) == (0o700 if path.is_dir() else 0o600)
labels = {}
split_episodes = []
for split in ["train", "validation"]:
    rows = [
        json.loads(line)
        for line in (root / (split + ".jsonl")).read_text().splitlines()
    ]
    assert len(rows) == manifest[split + "_examples"] > 0
    split_episodes.append({row["episode_id"] for row in rows})
    for row in rows:
        key = (row["episode_id"], str(row["decision_id"]))
        assert key not in labels
        labels[key] = row
assert not split_episodes[0] & split_episodes[1]
for run in manifest["runs"]:
    events = [
        json.loads(line) for line in (root / run["trajectory"]).read_text().splitlines()
    ]
    assert events[-1]["event_type"] == "episode" and events[-1]["status"] == "completed"
    assert events[-1]["source_revision"] == manifest["source_revision"]
    assert set(events[-1]["participant_outcomes"]) == {"0", "1", "2", "3"}
    label_count = 0
    actual_labels = []
    for decision in events[:-1]:
        assert decision["visibility"] == "private"
        assert decision["source_revision"] == manifest["source_revision"]
        if decision["action_status"] == "fallback":
            assert (
                decision["selected_attempt_id"] is None and decision["fallback_origin"]
            )
            continue
        selected = next(
            a
            for a in decision["attempts"]
            if a["attempt_id"] == decision["selected_attempt_id"]
        )
        assert (
            selected["origin"] == "teacher"
            and selected["policy"] == manifest["selection"]["policy"]
        )
        assert (
            selected["accepted"]
            and selected["parsed_action"] == decision["executed_action"]
        )
        assert (
            selected["model"] is None
            and selected["request"] is None
            and selected["platform_call_id"] is None
        )
        row = labels.pop((decision["episode_id"], str(decision["decision_index"])))
        assert row["prompt"] == selected["prompt"]
        assert (
            json.loads(row["completion"][0]["content"]) == decision["executed_action"]
        )
        actual_labels.append(
            {
                "decision_index": decision["decision_index"],
                "decision_id": decision["decision_id"],
            }
        )
        label_count += 1
    assert label_count == run["labels"] and actual_labels == run["label_ids"]
assert not labels
print(manifest["variant"], len(manifest["runs"]), "complete private episodes passed")
