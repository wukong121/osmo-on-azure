"""Robotics data lake <-> AzureML data assets.

  seed     Upload the validation dataset (robot models for each simulator + initial-state scenarios) to the data lake
           (ADLS Gen2, private endpoint) and register it as an AzureML data asset.
  download Resolve a data asset (name[:version], default: latest) to its data lake folder and
           download it.

The data lake is reached through Workload Identity (Storage Blob Data Contributor), never with
account keys. The data asset records which data each validation run used (lineage).
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
from pathlib import Path

import numpy as np
from azure.ai.ml.constants import AssetTypes
from azure.ai.ml.entities import Data
from azure.storage.blob import ContainerClient

from aml_common import credential, ml_client


def container_client(client, datastore_name: str) -> ContainerClient:
    ds = client.datastores.get(datastore_name)
    account_url = f"https://{ds.account_name}.blob.{ds.endpoint}"
    return ContainerClient(account_url, ds.filesystem, credential=credential())


def make_scenarios(count: int, seed: int) -> list[dict]:
    """Initial states drawn from the Isaac-Cartpole reset distribution (cartpole_manager_env_cfg.py)."""
    rng = np.random.default_rng(seed)
    quarter_pi = 0.25 * math.pi
    return [
        {
            "id": i,
            "cart_pos": float(rng.uniform(-1.0, 1.0)),
            "cart_vel": float(rng.uniform(-0.5, 0.5)),
            "pole_angle": float(rng.uniform(-quarter_pi, quarter_pi)),
            "pole_vel": float(rng.uniform(-quarter_pi, quarter_pi)),
        }
        for i in range(count)
    ]


def seed(args: argparse.Namespace) -> None:
    client = ml_client()
    prefix = f"{args.prefix.strip('/')}/{args.version}"
    files = {Path(f).name: Path(f).read_bytes() for f in args.file}
    files.update({
        "scenarios.json": json.dumps(
            {"seed": args.seed, "episode_seconds": 5.0, "scenarios": make_scenarios(args.count, args.seed)},
            indent=2,
        ).encode(),
    })
    cc = container_client(client, args.datastore)
    for name, payload in files.items():
        cc.upload_blob(f"{prefix}/{name}", payload, overwrite=True)
        print(f"uploaded {cc.container_name}/{prefix}/{name} ({len(payload)} bytes)")

    asset = Data(
        name=args.name,
        version=args.version,
        type=AssetTypes.URI_FOLDER,
        path=f"azureml://datastores/{args.datastore}/paths/{prefix}/",
        description="Cartpole sim2sim validation set: " + ", ".join(sorted(files)) + " (initial-state scenarios + robot models)",
        tags={"robot": "cartpole", "scenarios": str(args.count), "source": "simulated-customer-data"},
    )
    asset = client.data.create_or_update(asset)
    print(f"registered data asset {asset.name}:{asset.version} -> {asset.path}")


def download(args: argparse.Namespace) -> None:
    client = ml_client()
    name, _, version = args.asset.partition(":")
    asset = client.data.get(name, version=version) if version else client.data.get(name, label="latest")
    m = re.search(r"datastores/([^/]+)/paths/(.+)$", asset.path)
    if not m:
        raise SystemExit(f"unsupported data asset path: {asset.path}")
    datastore, prefix = m.group(1), m.group(2).rstrip("/") + "/"
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    cc = container_client(client, datastore)
    for blob in cc.list_blobs(name_starts_with=prefix):
        target = out / blob.name[len(prefix):]
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(cc.download_blob(blob.name).readall())
        print(f"downloaded {blob.name} -> {target}")
    (out / "data_asset.json").write_text(json.dumps({"name": asset.name, "version": asset.version, "path": asset.path}))


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("seed")
    p.add_argument("--file", action="append", required=True, help="robot model file to include (repeatable)")
    p.add_argument("--datastore", default=os.environ.get("AML_DATASTORE", "robotics_data"))
    p.add_argument("--prefix", default="cartpole/sim2sim")
    p.add_argument("--name", default="cartpole-sim2sim-scenarios")
    p.add_argument("--version", default="1")
    p.add_argument("--count", type=int, default=100)
    p.add_argument("--seed", type=int, default=2026)
    p.set_defaults(func=seed)
    p = sub.add_parser("download")
    p.add_argument("--asset", required=True, help="name or name:version")
    p.add_argument("--out", required=True)
    p.set_defaults(func=download)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
