"""Run one shard of a sim2sim scenario set for every model under test (pure simulation).

  --data-dir   dataset folder: scenarios.json + robot/xml/robot.xml + robot/meshes/
  --models-dir folder written by assets.py fetch: models.json + one folder per model version
  --shard i --shards n   scenarios with id % n == i (round-robin keeps shards balanced)

Writes <out>/episodes.csv (one row per model x scenario) and <out>/shard.json.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import platform
import time
from pathlib import Path

import mujoco

from pointfoot_sim import Policy, PointfootSim, rollout

FIELDS = ["model", "version", "scenario", "split", "group", "friction", "added_mass", "push_force", "latency_ms",
          "fell", "fall_time", "survival", "lin_vel_rmse", "yaw_rate_rmse", "distance"]


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--data-dir", required=True)
    p.add_argument("--models-dir", required=True)
    p.add_argument("--shard", type=int, required=True)
    p.add_argument("--shards", type=int, required=True)
    p.add_argument("--out", required=True)
    a = p.parse_args()

    data = Path(a.data_dir)
    doc = json.loads((data / "scenarios.json").read_text())
    scenarios = [s for s in doc["scenarios"] if s["id"] % a.shards == a.shard]
    models = json.loads((Path(a.models_dir) / "models.json").read_text())["models"]
    xml = data / doc.get("robot_model", "robot/xml/robot.xml")
    sim = PointfootSim(str(xml))

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    rows = 0
    with open(out / "episodes.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        for m in models:
            pol = Policy(str(Path(a.models_dir) / m["dir"]), m["rl_type"])
            falls = 0
            for sc in scenarios:
                r = rollout(sim, pol, sc)
                falls += r.fell
                w.writerow({
                    "model": m["name"], "version": m["version"], "scenario": sc["id"], "split": sc["split"],
                    "group": sc["group"], "friction": sc["friction"], "added_mass": sc["added_mass"],
                    "push_force": sc["push_force"], "latency_ms": sc["latency_ms"],
                    "fell": int(r.fell), "fall_time": "" if r.fall_time is None else round(r.fall_time, 3),
                    "survival": round(r.survival, 4), "lin_vel_rmse": round(r.lin_vel_rmse, 4),
                    "yaw_rate_rmse": round(r.yaw_rate_rmse, 4), "distance": round(r.distance, 3),
                })
                rows += 1
            print(f"{m['name']}:{m['version']} ({m['rl_type']}): {len(scenarios)} scenarios, {falls} falls", flush=True)
    info = {
        "shard": a.shard, "shards": a.shards, "scenarios": len(scenarios), "episodes": rows,
        "seconds": round(time.time() - t0, 1), "simulator": f"mujoco-{mujoco.__version__}",
        "host": os.environ.get("HOSTNAME", platform.node()),
    }
    (out / "shard.json").write_text(json.dumps(info, indent=2))
    print(json.dumps(info))


if __name__ == "__main__":
    main()
