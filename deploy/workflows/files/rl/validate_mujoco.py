"""Sim2sim validation in MuJoCo: run the Isaac Lab Cartpole ONNX policy on every scenario.

Usage: validate_mujoco.py --policy policy.onnx --data-dir <dir with cartpole.xml, scenarios.json> --out <dir>
Writes report.json and episodes.csv; the pass/fail decision is made by gate.py.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import mujoco

from sim2sim_common import DECIMATION, Policy, load_scenarios, run_episode, write_report


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", required=True)
    parser.add_argument("--data-dir", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    model = mujoco.MjModel.from_xml_path(str(Path(args.data_dir) / "cartpole.xml"))
    data = mujoco.MjData(model)

    def state():
        return (float(data.qpos[0]), float(data.qpos[1]), float(data.qvel[0]), float(data.qvel[1]))

    def reset(s: dict):
        mujoco.mj_resetData(model, data)
        data.qpos[:] = [s["cart_pos"], s["pole_angle"]]
        data.qvel[:] = [s["cart_vel"], s["pole_vel"]]
        mujoco.mj_forward(model, data)
        return state()

    def step(force: float):
        data.ctrl[0] = force
        for _ in range(DECIMATION):
            mujoco.mj_step(model, data)
        return state()

    policy = Policy(args.policy)
    scenarios, steps = load_scenarios(args.data_dir)
    episodes = [run_episode(reset, step, policy, s, steps) for s in scenarios]
    write_report(args.out, f"mujoco-{mujoco.__version__}", episodes)


if __name__ == "__main__":
    main()
