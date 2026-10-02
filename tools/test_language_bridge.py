"""Play the ordinary language parser, retaining private notes between turns."""

import json
import subprocess
import sys
from pathlib import Path

binary = Path(sys.argv[1]).resolve()
manifest = Path(__file__).resolve().parent.parent / "coworld_manifest_template.json"
variants = [entry["id"] for entry in json.loads(manifest.read_text())["variants"]]
for variant in variants:
    process = subprocess.Popen(
        [str(binary), str(manifest), variant, "--language"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    )

    def request(value):
        process.stdin.write(json.dumps(value) + "\n")
        process.stdin.flush()
        line = process.stdout.readline()
        assert line, process.poll()
        return json.loads(line)

    try:
        observation = request(
            {"kind": "reset", "seed": "language-" + variant, "players": 4}
        )
        notes = {}
        decisions = 0
        while observation["kind"] == "decision":
            seat = observation["seat"]
            if seat in notes:
                assert notes[seat] in observation["messages"][1]["content"]
            action = json.loads(request({"kind": "teacher"})["response"])
            action["notes"] = "PRIVATE LANGUAGE NOTE " + str(seat)
            notes[seat] = action["notes"]
            result = request(
                {
                    "kind": "step",
                    "decision_id": observation["decision_id"],
                    "response": "```json\n" + json.dumps(action) + "\n```",
                }
            )
            assert result["kind"] == "accepted" and result["action"] == action
            observation = result["observation"]
            decisions += 1
            assert decisions < 10000
        assert observation["kind"] == "terminal"
        assert set(observation["scores"]) == {"0", "1", "2", "3"}
        print(variant, "language", decisions, "decisions")
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0
