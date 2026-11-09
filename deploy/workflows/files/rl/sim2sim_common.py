"""Simulator-independent parts of the Cartpole sim2sim validation.

Each simulator (validate_mujoco.py, validate_gazebo.py) only implements reset + one control
step; scenario loading, the ONNX policy, episode scoring and the report live here. The
validators have no Azure dependencies: gate.py records the reports in AzureML and applies the
pass/fail gate.

Episode = 5 s at 60 Hz control (120 Hz physics), same as Isaac-Cartpole. Success = the cart
stays within +-3 m (the Isaac Lab termination bound) and the pole is upright at the end (mean
|angle| over the last second below ANGLE_TOL).
"""

from __future__ import annotations

import csv
import json
import math
from pathlib import Path
from typing import Callable

import numpy as np
import onnxruntime as ort

ACTION_SCALE = 100.0  # mdp.JointEffortActionCfg(scale=100.0)
EFFORT_LIMIT = 400.0
DECIMATION = 2
PHYSICS_DT = 1.0 / 120.0
CONTROL_DT = PHYSICS_DT * DECIMATION
CART_BOUND = 3.0
ANGLE_TOL = 0.2

State = tuple[float, float, float, float]  # cart_pos, pole_angle, cart_vel, pole_vel


class Policy:
    """ONNX policy exported by Isaac Lab: obs [1, 4] -> actions [1, 1]."""

    def __init__(self, path: str):
        self.session = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
        self.input = self.session.get_inputs()[0].name

    def force(self, state: State) -> float:
        obs = np.asarray([state], dtype=np.float32)
        action = float(np.asarray(self.session.run(None, {self.input: obs})[0]).reshape(-1)[0])
        return float(np.clip(action * ACTION_SCALE, -EFFORT_LIMIT, EFFORT_LIMIT))


def load_scenarios(data_dir: str) -> tuple[list[dict], int]:
    spec = json.loads((Path(data_dir) / "scenarios.json").read_text())
    steps = int(round(spec.get("episode_seconds", 5.0) / CONTROL_DT))
    return spec["scenarios"], steps


def wrap(angle: float) -> float:
    return (angle + math.pi) % (2 * math.pi) - math.pi


def run_episode(reset: Callable[[dict], State], step: Callable[[float], State], policy: Policy,
                scenario: dict, steps: int) -> dict:
    """reset(scenario) -> state; step(force) advances one control step and returns the new state."""
    state = reset(scenario)
    reward, tail, out_of_bounds, n = 0.0, [], False, 0
    tail_len = int(round(1.0 / CONTROL_DT))
    for n in range(1, steps + 1):
        state = step(policy.force(state))
        x, theta, v, omega = state
        out_of_bounds = abs(x) > CART_BOUND
        # Isaac-Cartpole reward terms, weighted by the control step
        reward += CONTROL_DT * (1.0 - 2.0 * out_of_bounds - theta**2 - 0.01 * abs(v) - 0.005 * abs(omega))
        if n > steps - tail_len:
            tail.append(abs(wrap(theta)))
        if out_of_bounds:
            break
    final_angle = float(np.mean(tail)) if tail else math.pi
    return {
        "id": scenario["id"],
        "success": int((not out_of_bounds) and final_angle < ANGLE_TOL),
        "steps": n,
        "out_of_bounds": int(out_of_bounds),
        "final_abs_pole_angle": round(final_angle, 4),
        "final_cart_pos": round(float(state[0]), 4),
        "reward": round(reward, 4),
    }


def write_report(out_dir: str, simulator: str, episodes: list[dict]) -> dict:
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    with open(out / "episodes.csv", "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(episodes[0]))
        writer.writeheader()
        writer.writerows(episodes)
    n = len(episodes)
    report = {
        "simulator": simulator,
        "episodes": n,
        "success_rate": sum(e["success"] for e in episodes) / n,
        "out_of_bounds_rate": sum(e["out_of_bounds"] for e in episodes) / n,
        "mean_reward": float(np.mean([e["reward"] for e in episodes])),
        "mean_final_abs_pole_angle": float(np.mean([e["final_abs_pole_angle"] for e in episodes])),
        "angle_tol": ANGLE_TOL,
    }
    (out / "report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    return report
