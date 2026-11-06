"""Sim2sim validation: run an Isaac Lab Cartpole policy (ONNX) in MuJoCo.

For each initial state in scenarios.json the policy controls the MuJoCo cartpole for one
episode (5 s, 60 Hz control, 120 Hz physics, same as Isaac-Cartpole). An episode succeeds when
the cart stays within +-3 m (the Isaac Lab termination bound) and the pole is upright at the end
(mean |angle| over the last second below --angle-tol). The gate passes when the success rate is
at least --threshold.

Writes report.json and episodes.csv to --out. With AML_WORKSPACE set it also logs an MLflow run
and tags the model version given by --model-json. Exits 1 when the gate fails.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
from pathlib import Path

import mujoco
import numpy as np
import onnxruntime as ort

ACTION_SCALE = 100.0  # mdp.JointEffortActionCfg(scale=100.0)
EFFORT_LIMIT = 400.0
DECIMATION = 2
CART_BOUND = 3.0


def wrap(angle: float) -> float:
    return (angle + math.pi) % (2 * math.pi) - math.pi


def run_episode(model, data, policy, scenario: dict, steps: int, angle_tol: float) -> dict:
    mujoco.mj_resetData(model, data)
    data.qpos[:] = [scenario["cart_pos"], scenario["pole_angle"]]
    data.qvel[:] = [scenario["cart_vel"], scenario["pole_vel"]]
    mujoco.mj_forward(model, data)
    in_name = policy.get_inputs()[0].name
    dt = model.opt.timestep * DECIMATION
    reward, tail, out_of_bounds, step = 0.0, [], False, 0
    for step in range(steps):
        x, theta = data.qpos
        v, omega = data.qvel
        # Isaac-Cartpole policy observation: joint_pos_rel (cart, pole) + joint_vel_rel (cart, pole)
        obs = np.array([[x, theta, v, omega]], dtype=np.float32)
        action = float(np.asarray(policy.run(None, {in_name: obs})[0]).reshape(-1)[0])
        data.ctrl[0] = np.clip(action * ACTION_SCALE, -EFFORT_LIMIT, EFFORT_LIMIT)
        for _ in range(DECIMATION):
            mujoco.mj_step(model, data)
        x, theta = data.qpos
        v, omega = data.qvel
        out_of_bounds = abs(x) > CART_BOUND
        # Isaac-Cartpole reward terms, weighted by step dt
        reward += dt * (1.0 - 2.0 * out_of_bounds - theta**2 - 0.01 * abs(v) - 0.005 * abs(omega))
        if step >= steps - int(round(1.0 / dt)):
            tail.append(abs(wrap(theta)))
        if out_of_bounds:
            break
    final_angle = float(np.mean(tail)) if tail else math.pi
    success = (not out_of_bounds) and final_angle < angle_tol
    return {
        "id": scenario["id"],
        "success": int(success),
        "steps": step + 1,
        "out_of_bounds": int(out_of_bounds),
        "final_abs_pole_angle": round(final_angle, 4),
        "final_cart_pos": round(float(data.qpos[0]), 4),
        "reward": round(reward, 4),
    }


def log_to_azureml(args, report: dict, out: Path) -> None:
    from aml_common import ml_client, setup_mlflow, workflow_tags

    client = ml_client()
    mlflow = setup_mlflow(client, args.experiment)
    model_info = json.loads(Path(args.model_json).read_text()) if args.model_json else {}
    data_info = json.loads((Path(args.data_dir) / "data_asset.json").read_text()) if (Path(args.data_dir) / "data_asset.json").exists() else {}
    tags = {**workflow_tags(), "stage": "sim2sim-validation", "simulator": f"mujoco-{mujoco.__version__}"}
    if model_info:
        tags.update({"model_name": model_info["name"], "model_version": str(model_info["version"])})
        if model_info.get("run_id"):
            tags["mlflow.parentRunId"] = model_info["run_id"]
    if data_info:
        tags["data_asset"] = f"{data_info['name']}:{data_info['version']}"
    with mlflow.start_run(run_name="sim2sim-mujoco", tags=tags) as run:
        mlflow.log_params({"episodes": report["episodes"], "threshold": args.threshold, "angle_tol": args.angle_tol})
        mlflow.log_metrics({k: report[k] for k in ("success_rate", "mean_reward", "mean_final_abs_pole_angle", "out_of_bounds_rate")})
        mlflow.log_artifacts(str(out), artifact_path="validation")
        report["mlflow_run_id"] = run.info.run_id

    if model_info:
        model = client.models.get(model_info["name"], version=str(model_info["version"]))
        model.tags = {
            **(model.tags or {}),
            "sim2sim_validation": "passed" if report["passed"] else "failed",
            "sim2sim_success_rate": f"{report['success_rate']:.3f}",
            "sim2sim_simulator": tags["simulator"],
            "sim2sim_run_id": report["mlflow_run_id"],
        }
        client.models.create_or_update(model)
        print(f"tagged model {model.name}:{model.version} sim2sim_validation={model.tags['sim2sim_validation']}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", required=True, help="policy.onnx exported from Isaac Lab")
    parser.add_argument("--data-dir", required=True, help="folder with cartpole.xml and scenarios.json")
    parser.add_argument("--out", required=True)
    parser.add_argument("--threshold", type=float, default=0.9)
    parser.add_argument("--angle-tol", type=float, default=0.2)
    parser.add_argument("--model-json", default="")
    parser.add_argument("--experiment", default="cartpole-rl")
    args = parser.parse_args()

    data_dir, out = Path(args.data_dir), Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    spec = json.loads((data_dir / "scenarios.json").read_text())
    model = mujoco.MjModel.from_xml_path(str(data_dir / "cartpole.xml"))
    data = mujoco.MjData(model)
    policy = ort.InferenceSession(args.policy, providers=["CPUExecutionProvider"])
    steps = int(round(spec.get("episode_seconds", 5.0) / (model.opt.timestep * DECIMATION)))

    episodes = [run_episode(model, data, policy, s, steps, args.angle_tol) for s in spec["scenarios"]]
    with open(out / "episodes.csv", "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(episodes[0]))
        writer.writeheader()
        writer.writerows(episodes)

    n = len(episodes)
    report = {
        "episodes": n,
        "success_rate": sum(e["success"] for e in episodes) / n,
        "out_of_bounds_rate": sum(e["out_of_bounds"] for e in episodes) / n,
        "mean_reward": float(np.mean([e["reward"] for e in episodes])),
        "mean_final_abs_pole_angle": float(np.mean([e["final_abs_pole_angle"] for e in episodes])),
        "threshold": args.threshold,
    }
    report["passed"] = report["success_rate"] >= args.threshold
    if os.environ.get("AML_WORKSPACE"):
        log_to_azureml(args, report, out)
    (out / "report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    if not report["passed"]:
        raise SystemExit(f"sim2sim gate failed: success rate {report['success_rate']:.2%} < {args.threshold:.0%}")
    print("sim2sim gate passed")


if __name__ == "__main__":
    main()
