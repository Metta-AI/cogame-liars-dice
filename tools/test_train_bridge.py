"""Exercise every certified variant through the Metta decision protocol."""

import json
import sys
from pathlib import Path

from metta_training.decision_environment import DecisionEncoding
from metta_training.game import Terminal
from metta_training.session import GameBridge


BRIDGE = Path(sys.argv[1]).resolve()
MANIFEST = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"

for variant in ("standard", "poker", "silent"):
    with GameBridge([str(BRIDGE), str(MANIFEST), variant]) as bridge:
        for seed in ("test-1", "test-2"):
            observation = bridge.reset(seed, 4)
            decisions = 0
            while not isinstance(observation, Terminal):
                encoding = DecisionEncoding.model_validate_json(bridge.request({"kind": "encode"}))
                assert len(encoding.values) == 33
                assert len(encoding.actions) == 321
                action = json.loads(bridge.teacher())
                assert encoding.action_for(encoding.indices_for(action)) == action
                observation = bridge.step(observation.decision_id, json.dumps(action)).observation
                decisions += 1
            assert 1 <= decisions <= 8 * 13
            assert sum(observation.scores.values()) == 2.0
            print(variant, seed, decisions, observation.scores)
