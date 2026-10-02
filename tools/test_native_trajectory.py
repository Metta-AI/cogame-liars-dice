"""Verify native HTTP/WebSocket trajectory evidence without provider credentials.

Arguments: compiled game binary, fresh private output directory, source commit.
"""

import json
import os
import socket
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from websockets.sync.client import connect

binary, output, revision = sys.argv[1:]
root = Path(output)
root.mkdir(mode=0o700, parents=True, exist_ok=False)
reports = []
for mode in ["accepted", "retry", "fallback", "greedy", "refusal", "sampled"]:
    folder = root / mode
    folder.mkdir(mode=0o700)
    requests = []

    class Native(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            assert self.path == "/v1/messages"
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            user = body["messages"][0]["content"]
            action = {
                "action": "challenge" if "STANDING BID: (none" not in user else "bid",
                "say": "fixture public speech",
                "notes": "PRIVATE NOTE SENTINEL",
            }
            if action["action"] == "bid":
                action.update(quantity=1, face=1)
            raw = json.dumps(action, separators=(",", ":"))
            if (
                mode == "fallback"
                or mode == "retry"
                and "previous reply was invalid" not in user
            ):
                raw = "PRIVATE INVALID RESPONSE SENTINEL"
            call_id = str(uuid.uuid4())
            response = {
                "id": call_id,
                "type": "message",
                "role": "assistant",
                "model": body["model"],
                "content": [{"type": "text", "text": raw}],
                "stop_reason": "end_turn",
                "usage": {"input_tokens": 100, "output_tokens": 20},
            }
            if mode == "refusal":
                response["stop_reason"] = "refusal"
            if mode in {"greedy", "sampled"}:
                response["sampling_evidence"] = {
                    "prompt_token_ids": [1],
                    "completion_token_ids": [2],
                    "behavior_log_probs": [-0.25] if mode == "sampled" else None,
                    "stop_reason": "eos",
                }
            response["model"] = "fixture/actual-served"
            requests.append(
                {
                    "platform_call_id": call_id,
                    "caller_request": body,
                    "caller_slot": self.headers["X-Coworld-Player-Slot"],
                    "provider_response": response,
                }
            )
            payload = json.dumps(response).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("X-Softmax-Llm-Call-Id", call_id)
            self.send_header("X-Coworld-Checkpoint-Sha256", "a" * 64)
            self.send_header("X-Coworld-Tokenizer-Sha256", "b" * 64)
            self.send_header("X-Coworld-Chat-Template-Sha256", "c" * 64)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Native)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    listener.close()
    config = {
        "seed": 17,
        "num_agents": 4,
        "llmTimeoutSeconds": 1,
        "playerConnectTimeoutSeconds": 3,
        "episodeTimeoutSeconds": 300,
        "turnDelayMs": 0,
        "tokens": [str(i) for i in range(4)],
        "players": [{"name": "fixture-" + str(i)} for i in range(4)],
        "deals": 2,
        "maxBidsPerDeal": 12,
    }
    config_path = folder / "config.json"
    config_path.write_text(json.dumps(config))
    environment = dict(os.environ)
    environment.update(
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_CONFIG_URI=config_path.as_uri(),
        COGAME_RESULTS_URI=(folder / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(folder / "replay.json").as_uri(),
        COGAME_SAVE_TRAJECTORY_URI=(folder / "trajectory.jsonl").as_uri(),
        COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{server.server_port}",
        COWORLD_LLM_MODEL="fixture/native",
        COWORLD_LLM_TEMPERATURE="1" if mode == "sampled" else "0",
        COWORLD_EPISODE_ID="fixture-" + mode,
        COWORLD_GAME_VERSION="source-fixture",
        COWORLD_SOURCE_REVISION=revision,
    )
    with (folder / "game.log").open("w") as log:
        process = subprocess.Popen(
            [binary], env=environment, stdout=log, stderr=subprocess.STDOUT
        )
        try:
            deadline = time.monotonic() + 10
            while True:
                probe = socket.socket()
                ready = probe.connect_ex(("127.0.0.1", port)) == 0
                probe.close()
                if ready:
                    break
                assert process.poll() is None, (folder / "game.log").read_text()
                assert time.monotonic() < deadline
                threading.Event().wait(0.01)
            sockets = [
                connect(
                    f"ws://127.0.0.1:{port}/player?slot={slot}&token={slot}",
                    max_queue=None,
                    ping_interval=None,
                )
                for slot in range(4)
            ]
            try:
                for seat in sockets:
                    seat.send(
                        json.dumps(
                            {"type": "prompt", "prompt": "PRIVATE OPERATOR SENTINEL"}
                        )
                    )
                assert process.wait(timeout=120) == 0, (folder / "game.log").read_text()
            finally:
                for seat in sockets:
                    seat.close()
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
            server.shutdown()
            server.server_close()
    events = [
        json.loads(line)
        for line in (folder / "trajectory.jsonl").read_text().splitlines()
    ]
    decisions = events[:-1]
    assert decisions and events[-1]["status"] == "completed"
    assert events[-1]["outcome"]["reason"] == "complete"
    calls = {record["platform_call_id"]: record for record in requests}
    for decision in decisions:
        for attempt in decision["attempts"]:
            if attempt["origin"] != "model":
                continue
            archive = calls[attempt["platform_call_id"]]
            assert decision["seat"] == archive["caller_slot"]
            assert attempt["request"] == archive["caller_request"]
            assert attempt["request"]["model"] == "fixture/native"
            assert (
                attempt["model"]
                == archive["provider_response"]["model"]
                == "fixture/actual-served"
            )
            assert attempt["decoder"] == {
                "max_tokens": archive["caller_request"]["max_tokens"],
                "temperature": 1 if mode == "sampled" else 0,
                "timeout_ms": 1000,
            }
            assert attempt["model_identity"] == "a" * 64
            assert attempt["tokenizer_identity"] == "b" * 64
            assert attempt["chat_template_sha256"] == "c" * 64
            if mode == "greedy":
                assert attempt["prompt_token_ids"] == [1]
                assert attempt["sampled_token_ids"] == [2]
                assert attempt["behavior_logprobs"] is None
            if mode == "sampled":
                assert attempt["sampled_token_ids"] == [2]
                assert attempt["behavior_logprobs"] == [-0.25]
            assert attempt["raw_response"] == archive["provider_response"]
        if decision["action_status"] == "accepted":
            selected = next(
                a
                for a in decision["attempts"]
                if a["attempt_id"] == decision["selected_attempt_id"]
            )
            assert (
                selected["accepted"]
                and selected["parsed_action"] == decision["executed_action"]
            )

        else:
            assert decision["selected_attempt_id"] is None
    assert len(calls) == sum(
        a["origin"] == "model" for d in decisions for a in d["attempts"]
    )
    for private_text in ["PRIVATE NOTE SENTINEL", "PRIVATE INVALID RESPONSE SENTINEL"]:
        assert private_text not in (folder / "replay.json").read_text()
        assert private_text not in (folder / "game.log").read_text()
    assert "PRIVATE OPERATOR SENTINEL" not in (folder / "replay.json").read_text()
    assert "PRIVATE OPERATOR SENTINEL" not in (folder / "game.log").read_text()
    assert "PRIVATE OPERATOR SENTINEL" in (folder / "trajectory.jsonl").read_text()
    assert (folder / "trajectory.jsonl").stat().st_mode & 0o777 == 0o600
    reports.append(
        {
            "mode": mode,
            "complete_episodes": 1,
            "decisions": len(decisions),
            "native_call_joins": len(requests),
            "source_revision": revision,
            "cohort": "native HTTP fixture; no platform hosted claim",
        }
    )
(root / "report.json").write_text(json.dumps(reports, indent=2) + "\n")
print(json.dumps(reports))
