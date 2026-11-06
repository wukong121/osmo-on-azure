"""Record an Isaac Lab RSL-RL training run in AzureML and register the policy.

rsl_rl only writes TensorBoard events, so this step replays them into an MLflow run in the
AzureML workspace (metrics with steps, key hyperparameters, config files), uploads the
checkpoint and the exported ONNX policy as run artifacts, and registers them as a model
version that points back to the run (lineage: model -> run -> OSMO workflow).

Usage: register_model.py <train output dir> <out dir> [--model-name ...] [--experiment ...]
Writes <out dir>/model.json with the registered name/version and the MLflow run ID.
"""

from __future__ import annotations

import argparse
import json
import shutil
import tempfile
from pathlib import Path

import yaml
from azure.ai.ml.constants import AssetTypes
from azure.ai.ml.entities import Model
from mlflow.entities import Metric
from tensorboard.backend.event_processing.event_accumulator import EventAccumulator

from aml_common import ml_client, setup_mlflow, workflow_tags

# Hyperparameters worth showing in the run overview (dotted paths in params/agent.yaml)
AGENT_PARAMS = [
    "seed",
    "max_iterations",
    "num_steps_per_env",
    "algorithm.learning_rate",
    "algorithm.gamma",
    "algorithm.lam",
    "algorithm.clip_param",
    "algorithm.entropy_coef",
    "algorithm.num_learning_epochs",
    "algorithm.num_mini_batches",
    "actor.hidden_dims",
    "actor.activation",
]


def find_run_dir(train_dir: Path) -> Path:
    runs = sorted({p.parent for p in train_dir.rglob("model_*.pt")})
    if not runs:
        raise SystemExit(f"no rsl_rl checkpoint under {train_dir}")
    return runs[-1]


def lookup(cfg: dict, dotted: str):
    for key in dotted.split("."):
        if not isinstance(cfg, dict) or key not in cfg:
            return None
        cfg = cfg[key]
    return cfg


class _ConfigLoader(yaml.SafeLoader):
    """SafeLoader that reads python-tagged nodes (e.g. !!python/tuple in Isaac Lab dumps) as plain data."""


def _python_tag(loader: yaml.SafeLoader, _suffix: str, node: yaml.Node):
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node, deep=True)
    if isinstance(node, yaml.MappingNode):
        return loader.construct_mapping(node, deep=True)
    return loader.construct_scalar(node)


_ConfigLoader.add_multi_constructor("tag:yaml.org,2002:python/", _python_tag)


def load_yaml(path: Path) -> dict:
    if not path.exists():
        return {}
    return yaml.load(path.read_text(), Loader=_ConfigLoader) or {}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("train_dir")
    parser.add_argument("out_dir")
    parser.add_argument("--model-name", default="cartpole-policy")
    parser.add_argument("--experiment", default="cartpole-rl")
    parser.add_argument("--task", default="Isaac-Cartpole")
    args = parser.parse_args()

    run_dir = find_run_dir(Path(args.train_dir))
    checkpoint = sorted(run_dir.glob("model_*.pt"), key=lambda p: int(p.stem.split("_")[1]))[-1]
    onnx = run_dir / "exported" / "policy.onnx"
    if not onnx.exists():
        raise SystemExit(f"{onnx} not found; the train task must export the policy")
    agent_cfg = load_yaml(run_dir / "params" / "agent.yaml")
    env_cfg = load_yaml(run_dir / "params" / "env.yaml")
    print(f"run dir: {run_dir}\ncheckpoint: {checkpoint.name}")

    client = ml_client()
    mlflow = setup_mlflow(client, args.experiment)
    tags = {**workflow_tags(), "stage": "training", "task": args.task, "rl_library": "rsl_rl", "simulator": "isaaclab-3.0-newton"}

    with mlflow.start_run(run_name=f"train-{run_dir.name}", tags=tags) as run:
        params = {"task": args.task, "checkpoint": checkpoint.name}
        params.update({k: str(v) for k in AGENT_PARAMS if (v := lookup(agent_cfg, k)) is not None})
        if (n := lookup(env_cfg, "scene.num_envs")) is not None:
            params["num_envs"] = n
        mlflow.log_params(params)

        # Replay TensorBoard scalars as MLflow metrics (with steps), in batches
        acc = EventAccumulator(str(run_dir), size_guidance={"scalars": 0})
        acc.Reload()
        metrics = [
            Metric(key=tag.replace(" ", "_"), value=float(e.value), timestamp=int(e.wall_time * 1000), step=int(e.step))
            for tag in acc.Tags().get("scalars", [])
            for e in acc.Scalars(tag)
        ]
        tracking = mlflow.tracking.MlflowClient()
        for i in range(0, len(metrics), 1000):
            tracking.log_batch(run.info.run_id, metrics=metrics[i : i + 1000])
        print(f"logged {len(metrics)} metric points from {len(acc.Tags().get('scalars', []))} TensorBoard tags")

        # Model folder: ONNX policy (deployment format) + checkpoint + configs
        with tempfile.TemporaryDirectory() as tmp:
            model_dir = Path(tmp) / "model"
            model_dir.mkdir()
            # torch.onnx may store weights in a side file (policy.onnx.data); keep it next to the graph
            for f in onnx.parent.glob("policy.onnx*"):
                shutil.copy2(f, model_dir / f.name)
            shutil.copy2(checkpoint, model_dir / checkpoint.name)
            for cfg in (run_dir / "params").glob("*.yaml"):
                shutil.copy2(cfg, model_dir / cfg.name)
            mlflow.log_artifacts(str(model_dir), artifact_path="model")
        run_id = run.info.run_id

    model = client.models.create_or_update(
        Model(
            name=args.model_name,
            path=f"azureml://jobs/{run_id}/outputs/artifacts/paths/model/",
            type=AssetTypes.CUSTOM_MODEL,
            description=f"{args.task} policy trained with Isaac Lab 3.0 (RSL-RL PPO) on OSMO",
            tags={**{k: v for k, v in tags.items() if k != "stage"}, "format": "onnx", "sim2sim_validation": "pending"},
            properties={"mlflow_run_id": run_id, "checkpoint": checkpoint.name},
        )
    )
    print(f"registered model {model.name}:{model.version} (run {run_id})")

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / "model.json").write_text(json.dumps({"name": model.name, "version": model.version, "run_id": run_id}, indent=2))


if __name__ == "__main__":
    main()
