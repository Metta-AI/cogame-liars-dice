"""Complete real socket games across training and held-out rule wording, without model calls."""

import asyncio
import hashlib
import json
import os
import socket
import sys
from pathlib import Path

import websockets


async def play(binary, folder, configuration, revision):
    folder.mkdir(mode=0o700)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    config = configuration | {"tokens": [str(seat) for seat in range(4)]}
    (folder / "config.json").write_text(json.dumps(config))
    environment = dict(os.environ)
    for key in (
        "COWORLD_LLM_ENDPOINT",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_API_KEY_URI",
        "AWS_BEARER_TOKEN_BEDROCK",
    ):
        environment.pop(key, None)
    environment.update(
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_CONFIG_URI=(folder / "config.json").as_uri(),
        COGAME_RESULTS_URI=(folder / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(folder / "replay.json").as_uri(),
        COGAME_SAVE_TRAJECTORY_URI=(folder / "trajectory.jsonl").as_uri(),
        COWORLD_EPISODE_ID=folder.name,
        COWORLD_GAME_VERSION="prompt-fuzzing-system",
        COWORLD_SOURCE_REVISION=revision,
    )
    observations = []
    systems = {}
    identities = []
    with (folder / "game.log").open("w") as log:
        process = await asyncio.create_subprocess_exec(
            binary, env=environment, stdout=log, stderr=log
        )
        players = []
        try:
            async with asyncio.timeout(20):
                while "serving on" not in (folder / "game.log").read_text():
                    assert process.returncode is None, (folder / "game.log").read_text()
                    await asyncio.sleep(0.02)

            async def player(seat):
                async with websockets.connect(
                    f"ws://127.0.0.1:{port}/player?slot={seat}&token={seat}"
                ) as connection:
                    await connection.send(
                        json.dumps({"type": "register", "control": "external"})
                    )
                    async for raw in connection:
                        frame = json.loads(raw)
                        if frame["type"] == "final":
                            return
                        if frame["type"] != "observation":
                            continue
                        observation = frame["observation"]
                        messages = observation["input"]
                        identity = observation["prompt_template"]
                        assert identity["bank"] == "liars-dice-rules-v1"
                        assert identity["selection"] == config["promptVariant"]
                        assert identity["seed"] == config["promptSeed"]
                        for role in ("system", "user"):
                            assert (
                                identity[role + "_sha256"].lower()
                                == hashlib.sha256(messages[role].encode()).hexdigest()
                            )
                        assert (
                            systems.setdefault(seat, messages["system"])
                            == messages["system"]
                        )
                        assert (
                            observation["slot"] == seat and "hands" not in observation
                        )
                        assert all(
                            f"PRIVATE-SEAT-{other}" not in messages["user"]
                            for other in range(4)
                            if other != seat
                        )
                        identities.append(identity)
                        observations.append(
                            {
                                **observation,
                                "input": {"user": messages["user"]},
                                "prompt_template": None,
                            }
                        )
                        action = {
                            "action": "challenge"
                            if observation["canChallenge"]
                            and len(observation["bids"]) >= 2
                            else "bid",
                            "say": "public prompt check" if observation["talk"] else "",
                            "notes": f"PRIVATE-SEAT-{seat}",
                        }
                        if action["action"] == "bid":
                            action.update(observation["legalBids"][0])
                        await connection.send(
                            json.dumps(
                                {
                                    "type": "action",
                                    "event": frame["event"],
                                    "action": action,
                                }
                            )
                        )

            players = [asyncio.create_task(player(seat)) for seat in range(4)]
            async with asyncio.timeout(120):
                await asyncio.gather(*players)
                assert await process.wait() == 0, (folder / "game.log").read_text()
        finally:
            for task in players:
                task.cancel()
            await asyncio.gather(*players, return_exceptions=True)
            if process.returncode is None:
                process.terminate()
                await process.wait()
    events = [
        json.loads(line)
        for line in (folder / "trajectory.jsonl").read_text().splitlines()
    ]
    assert events[-1]["status"] == "completed"
    assert len(events) == len(observations) + 1
    for event, expected in zip(events[:-1], identities, strict=True):
        assert event["observation"]["prompt_template"] == expected
    result = json.loads((folder / "results.json").read_text())
    assert result["reason"] == "complete"
    assert len({identity["variant"] for identity in identities}) == 1
    return observations, result, systems, identities[0]["variant"]


async def main():
    binary, destination, revision = sys.argv[1:]
    root = Path(destination).resolve()
    root.mkdir(mode=0o700, parents=True, exist_ok=False)
    manifest = json.loads(
        (
            Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"
        ).read_text()
    )
    templates = ["canonical", "heldout-briefing", "heldout-reference"]
    reports = []
    for variant in manifest["variants"]:
        for seed in (17,):
            canonical = None
            direct = []
            for selection in templates:
                prompt_seed = 0
                name = f"{variant['id']}-{seed}-{selection}-{prompt_seed}"
                run = await play(
                    binary,
                    root / name,
                    variant["game_config"]
                    | {
                        "seed": seed,
                        "promptVariant": selection,
                        "promptSeed": prompt_seed,
                    },
                    revision,
                )
                if selection == "canonical":
                    canonical = run
                else:
                    assert run[:2] == canonical[:2], (
                        "Wording changed state, private visibility, or results"
                    )
                assert run[3] == selection
                direct.append(run)
                reports.append(
                    {"game": name, "decisions": len(run[0]), "selected": run[3]}
                )
            for seat in range(4):
                assert len({run[2][seat] for run in direct}) == len(templates)
    (root / "report.json").write_text(json.dumps(reports, indent=2) + "\n")
    print(
        json.dumps(
            {
                "completed_games": len(reports),
                "templates": len(templates),
                "output": str(root),
            }
        )
    )


asyncio.run(main())
