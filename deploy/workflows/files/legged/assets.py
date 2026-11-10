"""Data lake, model registry and dataset plumbing for the point-foot sim2sim workflows.

  seed     Upload the robot model (MJCF + meshes) and a generated scenario set to the data lake
           and register the AzureML data asset <name>:<version>.
  import   Register exported policies (policy.onnx + encoder.onnx + params.yaml per rl_type) as
           versions of one AzureML model. The files are logged as MLflow run artifacts, so each
           version points back to its import run (and later validation runs nest under it).
  fetch    Resolve the models under test and download them, plus the data asset:
             --models name:version  candidate, plus the current champion (tag stage=production)
             --models name:all      every registered version (re-validation)
           Writes <out>/models/models.json and <out>/data/... (with data_asset.json).

All Azure access uses the pod's Workload Identity (DefaultAzureCredential).
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import tempfile
from pathlib import Path

from azure.ai.ml.constants import AssetTypes
from azure.ai.ml.entities import Data, Model

import scenarios as scen
from aml_common import ml_client, setup_mlflow, workflow_tags
from data_assets import container_client, download as download_data_asset


def seed(a: argparse.Namespace) -> None:
    client = ml_client()
    robot = Path(a.robot_dir)
    prefix = f"{a.prefix.strip('/')}/{a.version}"
    doc = scen.document(a.profile, a.seed)
    doc["robot_model"] = "robot/xml/robot.xml"
    doc["robot_type"] = a.robot_type
    files = {"scenarios.json": json.dumps(doc, indent=1).encode()}
    for sub in ("xml", "meshes"):
        for f in sorted((robot / sub).iterdir()):
            files[f"robot/{sub}/{f.name}"] = f.read_bytes()
    cc = container_client(client, a.datastore)
    for name, payload in files.items():
        cc.upload_blob(f"{prefix}/{name}", payload, overwrite=True)
    print(f"uploaded {len(files)} files to {cc.container_name}/{prefix}/")
    counts = {}
    for s in doc["scenarios"]:
        counts[f"{s['split']}/{s['group']}"] = counts.get(f"{s['split']}/{s['group']}", 0) + 1
    asset = client.data.create_or_update(Data(
        name=a.name,
        version=a.version,
        type=AssetTypes.URI_FOLDER,
        path=f"azureml://datastores/{a.datastore}/paths/{prefix}/",
        description=f"Point-foot biped sim2sim scenario set ({a.profile}): {doc['count']} scenarios "
                    "(velocity commands x friction x payload x push x latency) + robot MJCF",
        tags={"robot": a.robot_type, "profile": a.profile, "scenarios": str(doc["count"]), "seed": str(a.seed),
              **{f"n_{k.replace('/', '_')}": str(v) for k, v in sorted(counts.items())}},
    ))
    print(f"registered data asset {asset.name}:{asset.version} -> {asset.path}  {counts}")


def import_policies(a: argparse.Namespace) -> None:
    client = ml_client()
    mlflow = setup_mlflow(client, a.experiment)
    root = Path(a.policy_root)
    for rl_type in a.rl_type:
        src = root / "policy" / rl_type
        tags = {**workflow_tags(), "stage": "import", "source": "pretrained", "rl_type": rl_type,
                "robot": a.robot_type, "source_repo": a.source_repo, "source_commit": a.source_commit}
        with mlflow.start_run(run_name=f"import-{a.robot_type}-{rl_type}", tags=tags) as run:
            with tempfile.TemporaryDirectory() as tmp:
                d = Path(tmp) / "model"
                d.mkdir()
                for f in ("policy.onnx", "encoder.onnx"):
                    shutil.copy2(src / f, d / f)
                shutil.copy2(root / "params.yaml", d / "params.yaml")
                (d / "policy.json").write_text(json.dumps({"rl_type": rl_type, "robot": a.robot_type, "interface": "pointfoot-rsl-rl-encoder"}))
                mlflow.log_params({"rl_type": rl_type, "robot": a.robot_type})
                mlflow.log_artifacts(str(d), artifact_path="model")
            run_id = run.info.run_id
        model = client.models.create_or_update(Model(
            name=a.model_name,
            path=f"azureml://jobs/{run_id}/outputs/artifacts/paths/model/",
            type=AssetTypes.CUSTOM_MODEL,
            description=f"Pretrained {a.robot_type} blind locomotion policy trained with {rl_type} (ONNX policy + encoder)",
            tags={k: v for k, v in tags.items() if k != "stage"} | {"format": "onnx", "sim2sim_validation": "pending"},
        ))
        print(f"registered {model.name}:{model.version} ({rl_type}, run {run_id})")


def fetch(a: argparse.Namespace) -> None:
    import mlflow

    client = ml_client()
    setup_mlflow(client, a.experiment)
    name, _, version = a.models.partition(":")
    versions = {m.version: m for m in client.models.list(name=name)}
    if not versions:
        raise SystemExit(f"no versions of model {name}")
    prod = [v for v, m in versions.items() if (m.tags or {}).get("stage") == "production"]
    selected: list[tuple[str, str]] = []
    if version in ("all", "*"):
        selected = [(v, "champion" if v in prod else "registered") for v in sorted(versions, key=int)]
    else:
        if version not in versions:
            raise SystemExit(f"model {name}:{version} not found (have {sorted(versions, key=int)})")
        selected.append((version, "candidate"))
        selected += [(v, "champion") for v in prod if v != version]

    out = Path(a.out)
    mdir = out / "models"
    mdir.mkdir(parents=True, exist_ok=True)
    entries = []
    for v, role in selected:
        m = client.models.get(name, version=v)
        run_id = m.path.split("/jobs/")[1].split("/")[0] if "/jobs/" in m.path else (m.job_name or "")
        local = Path(mlflow.artifacts.download_artifacts(run_id=run_id, artifact_path="model", dst_path=str(mdir / f"v{v}")))
        meta = json.loads((local / "policy.json").read_text())
        entries.append({"name": name, "version": v, "role": role, "rl_type": meta["rl_type"], "run_id": run_id,
                        "dir": str(local.relative_to(mdir))})
        print(f"{name}:{v} role={role} rl_type={meta['rl_type']} -> {local}")
    (mdir / "models.json").write_text(json.dumps({"models": entries}, indent=2))
    download_data_asset(argparse.Namespace(asset=a.dataset, out=str(out / "data")))


def main() -> None:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("seed")
    s.add_argument("--robot-dir", required=True, help="folder with xml/robot.xml and meshes/")
    s.add_argument("--robot-type", required=True)
    s.add_argument("--profile", default="v1")
    s.add_argument("--seed", type=int, default=2026)
    s.add_argument("--version", default="1")
    s.add_argument("--name", default="pointfoot-sim2sim-scenarios")
    s.add_argument("--prefix", default="legged/pointfoot/sim2sim")
    s.add_argument("--datastore", default=os.environ.get("AML_DATASTORE", "robotics_data"))
    s.set_defaults(func=seed)
    s = sub.add_parser("import")
    s.add_argument("--policy-root", required=True, help="folder with params.yaml and policy/<rl_type>/{policy,encoder}.onnx")
    s.add_argument("--rl-type", action="append", required=True)
    s.add_argument("--robot-type", required=True)
    s.add_argument("--model-name", default="pointfoot-policy")
    s.add_argument("--experiment", default="pointfoot-sim2sim")
    s.add_argument("--source-repo", default="")
    s.add_argument("--source-commit", default="")
    s.set_defaults(func=import_policies)
    s = sub.add_parser("fetch")
    s.add_argument("--models", required=True, help="name:version (candidate + champion) or name:all")
    s.add_argument("--dataset", required=True, help="data asset name or name:version")
    s.add_argument("--experiment", default="pointfoot-sim2sim")
    s.add_argument("--out", required=True)
    s.set_defaults(func=fetch)
    a = p.parse_args()
    a.func(a)


if __name__ == "__main__":
    main()
