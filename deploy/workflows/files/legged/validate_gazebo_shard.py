"""Run one shard of the Gazebo (ROS 2) sim2sim subset for every model under test.

  --data-dir     dataset folder (scenarios.json)
  --models-dir   folder written by assets.py fetch (models.json + one folder per model version)
  --shard i --shards n
  --subset-in / --subset-out   size of the Gazebo subset (in / out of distribution)

The Gazebo subset is chosen deterministically from the scenario set: an even spread over the
in-distribution scenarios (random and compound) and over the out-of-distribution friction,
payload and push groups. Latency scenarios are skipped: latency cannot be injected into the
vendor controller. Episodes that fall right after the start (startup failures, see
gazebo_episode.STARTUP_WINDOW_S) are retried up to --max-attempts times and reported separately;
if every attempt fails that way the episode is invalid.

Writes <out>/episodes.csv (same columns as the MuJoCo shards plus rtf / attempts) and
<out>/shard.json.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import platform
import time
from collections import defaultdict
from pathlib import Path

from gazebo_episode import run_episode

FIELDS = ["model", "version", "simulator", "scenario", "split", "group", "friction", "added_mass", "push_force",
          "latency_ms", "fell", "fall_time", "survival", "lin_vel_rmse", "yaw_rate_rmse", "distance",
          "rtf", "attempts", "startup_failures", "valid"]
SKIP_GROUPS = {"latency_ms"}


def select_subset(scenarios: list[dict], n_in: int, n_out: int) -> list[dict]:
    groups = defaultdict(list)
    for s in scenarios:
        if s["group"] not in SKIP_GROUPS:
            groups[(s["split"], s["group"])].append(s)
    picked = []
    for split, n in (("in_dist", n_in), ("out_dist", n_out)):
        keys = sorted(k for k in groups if k[0] == split)
        total = sum(len(groups[k]) for k in keys)
        for k in keys:
            share = max(1, round(n * len(groups[k]) / total)) if total else 0
            items = sorted(groups[k], key=lambda s: s["id"])
            step = max(1, len(items) // share)
            picked += items[::step][:share]
    return sorted(picked, key=lambda s: s["id"])


def stack_config(ws: str, robot_type: str, params_yaml: str) -> dict:
    """Paths of the vendor ROS 2 stack inside the Gazebo image (built under <ws>)."""
    import yaml

    share = f"{ws}/install"
    rc = f"{share}/robot_controllers/share/robot_controllers/config"
    hw = f"{share}/robot_hw/share/robot_hw/config"
    cfg = yaml.safe_load(open(params_yaml))
    scales = next(iter(cfg.values()))["ros__parameters"]["ControllerCfg"]["user_cmd_scales"]
    return {
        "robot_type": robot_type,
        "xacro": f"{share}/robot_description/share/robot_description/pointfoot/{robot_type}/xacro/robot.xacro",
        "hw_package": "robot_hw", "hw_executable": "pointfoot_node", "hw_node_name": "robot_hw_node",
        "hw_param_files": [params_yaml, f"{rc}/robot_controllers.yaml", f"{hw}/joystick.yaml", f"{hw}/robot_hw.yaml"],
        "user_cmd_scales": scales,
    }


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--data-dir", required=True)
    p.add_argument("--models-dir", required=True)
    p.add_argument("--shard", type=int, required=True)
    p.add_argument("--shards", type=int, required=True)
    p.add_argument("--subset-in", type=int, default=120)
    p.add_argument("--subset-out", type=int, default=80)
    p.add_argument("--max-attempts", type=int, default=5)
    p.add_argument("--ws", default=os.environ.get("ROS_WS", "/ws"))
    p.add_argument("--out", required=True)
    a = p.parse_args()

    doc = json.loads((Path(a.data_dir) / "scenarios.json").read_text())
    robot_type = doc.get("robot_type") or os.environ["ROBOT_TYPE"]
    subset = select_subset(doc["scenarios"], a.subset_in, a.subset_out)
    mine = [s for i, s in enumerate(subset) if i % a.shards == a.shard]
    models = json.loads((Path(a.models_dir) / "models.json").read_text())["models"]
    params_yaml = f"{a.ws}/install/robot_controllers/share/robot_controllers/config/pointfoot/{robot_type}/params.yaml"
    cfg = stack_config(a.ws, robot_type, params_yaml)

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    rows = startup_total = 0
    with open(out / "episodes.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        for m in models:
            model = {"dir": str((Path(a.models_dir) / m["dir"]).resolve()), "rl_type": m["rl_type"]}
            falls = 0
            for sc in mine:
                startups = 0
                for attempt in range(1, a.max_attempts + 1):
                    r = run_episode(sc, model, cfg, out / "logs" / f"v{m['version']}-s{sc['id']}-a{attempt}")
                    if not r.extra["startup_failure"]:
                        break
                    startups += 1
                startup_total += startups
                falls += r.fell
                w.writerow({
                    "model": m["name"], "version": m["version"], "simulator": "gazebo", "scenario": sc["id"],
                    "split": sc["split"], "group": sc["group"], "friction": sc["friction"],
                    "added_mass": sc["added_mass"], "push_force": sc["push_force"], "latency_ms": 0.0,
                    "fell": int(r.fell), "fall_time": "" if r.fall_time is None else round(r.fall_time, 3),
                    "survival": round(r.survival, 4), "lin_vel_rmse": round(r.lin_vel_rmse, 4),
                    "yaw_rate_rmse": round(r.yaw_rate_rmse, 4), "distance": round(r.distance, 3),
                    "rtf": r.extra["rtf"], "attempts": attempt, "startup_failures": startups,
                    "valid": int(r.extra["valid"]),
                })
                f.flush()
                rows += 1
                print(f"{m['name']}:{m['version']} scenario {sc['id']}: fell={r.fell} rtf={r.extra['rtf']} "
                      f"attempts={attempt} wall={r.extra['wall_s']}s", flush=True)
            print(f"{m['name']}:{m['version']} ({m['rl_type']}): {len(mine)} scenarios, {falls} falls", flush=True)
    info = {"shard": a.shard, "shards": a.shards, "scenarios": len(mine), "episodes": rows,
            "startup_failures": startup_total, "seconds": round(time.time() - t0, 1),
            "simulator": "gazebo-classic-11 + ros2-iron (vendor ros2_control stack)",
            "host": os.environ.get("HOSTNAME", platform.node())}
    (out / "shard.json").write_text(json.dumps(info, indent=2))
    print(json.dumps(info))


if __name__ == "__main__":
    main()
