"""Verify the separate fixed numeric action catalog through complete games."""

import json
import subprocess
import sys
from pathlib import Path

binary = Path(sys.argv[1]).resolve()
manifest = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"
for variant in ("standard", "poker", "silent"):
    process = subprocess.Popen(
        [str(binary), str(manifest), variant],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    )

    def request(payload):
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()
        return json.loads(process.stdout.readline())

    try:
        for seed in ("test-1", "test-2"):
            observation = request({"kind": "reset", "seed": seed, "players": 4})
            decisions = 0
            while observation["kind"] == "decision":
                encoding = request({"kind": "encode"})
                assert len(encoding["values"]) == 33 and len(encoding["actions"]) == 321
                action = json.loads(request({"kind": "teacher"})["response"])
                assert action in encoding["actions"]
                result = request(
                    {
                        "kind": "step",
                        "decision_id": observation["decision_id"],
                        "response": json.dumps(action),
                    }
                )
                assert result["kind"] == "accepted" and result["action"] == action
                observation = result["observation"]
                decisions += 1
            assert 1 <= decisions <= 8 * 13 and sum(observation["scores"].values()) == 2
            print(variant, seed, decisions, "numeric decisions")
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0
