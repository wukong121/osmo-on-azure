"""Sim2sim gate: record the validation reports in AzureML and decide pass/fail.

Inputs: model.json from the register task, data_asset.json from the fetch-data task, and one
report directory per simulator (report.json + episodes.csv from validate_mujoco.py /
validate_gazebo.py).

For each simulator it logs an MLflow child run of the training run (metrics + episodes.csv),
then tags the model version:
  sim2sim_validation      passed | failed   (passed only if every simulator meets the threshold)
  sim2sim_<sim>           success rate per simulator, e.g. sim2sim_mujoco=1.000
  sim2sim_data_asset      the validation dataset version that was used
Exits 1 when the gate fails, so the OSMO workflow shows the failure.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from aml_common import ml_client, setup_mlflow, workflow_tags


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-json", required=True)
    parser.add_argument("--data-asset-json", required=True)
    parser.add_argument("--report", action="append", required=True, metavar="NAME=DIR",
                        help="simulator report directory, e.g. mujoco=/osmo/data/input/2")
    parser.add_argument("--threshold", type=float, default=0.9)
    parser.add_argument("--experiment", default="cartpole-rl")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    model_info = json.loads(Path(args.model_json).read_text())
    data_info = json.loads(Path(args.data_asset_json).read_text())
    data_ref = f"{data_info['name']}:{data_info['version']}"

    client = ml_client()
    mlflow = setup_mlflow(client, args.experiment)
    results = {}
    for item in args.report:
        name, _, report_dir = item.partition("=")
        report = json.loads((Path(report_dir) / "report.json").read_text())
        report["passed"] = report["success_rate"] >= args.threshold
        tags = {
            **workflow_tags(),
            "stage": "sim2sim-validation",
            "simulator": report["simulator"],
            "model_name": model_info["name"],
            "model_version": str(model_info["version"]),
            "data_asset": data_ref,
            "mlflow.parentRunId": model_info["run_id"],
        }
        with mlflow.start_run(run_name=f"sim2sim-{name}", tags=tags) as run:
            mlflow.log_params({"episodes": report["episodes"], "threshold": args.threshold, "angle_tol": report["angle_tol"]})
            mlflow.log_metrics({k: report[k] for k in ("success_rate", "mean_reward", "mean_final_abs_pole_angle", "out_of_bounds_rate")})
            mlflow.log_artifacts(report_dir, artifact_path=f"sim2sim-{name}")
            report["mlflow_run_id"] = run.info.run_id
        results[name] = report
        print(f"{name:8s} {report['simulator']:24s} success {report['success_rate']:.1%} -> {'PASS' if report['passed'] else 'FAIL'}")

    passed = all(r["passed"] for r in results.values())
    model = client.models.get(model_info["name"], version=str(model_info["version"]))
    model.tags = {
        **(model.tags or {}),
        "sim2sim_validation": "passed" if passed else "failed",
        "sim2sim_threshold": f"{args.threshold:.2f}",
        "sim2sim_data_asset": data_ref,
        **{f"sim2sim_{name}": f"{r['success_rate']:.3f}" for name, r in results.items()},
    }
    client.models.create_or_update(model)
    print(f"tagged model {model.name}:{model.version} sim2sim_validation={model.tags['sim2sim_validation']}")

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "gate.json").write_text(json.dumps({"passed": passed, "threshold": args.threshold, "model": model_info, "data_asset": data_ref, "results": results}, indent=2))
    if not passed:
        failed = ", ".join(f"{n} {r['success_rate']:.0%}" for n, r in results.items() if not r["passed"])
        raise SystemExit(f"sim2sim gate failed (threshold {args.threshold:.0%}): {failed}")
    print("sim2sim gate passed")


if __name__ == "__main__":
    main()
