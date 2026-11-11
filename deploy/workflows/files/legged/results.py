"""Central results store for hybrid (multi-pool) sim2sim runs, in the AzureML data lake.

A validation run can be split across OSMO pools (Azure, other clouds, on-prem): each pool runs
a range of shards and publishes their outputs; a final gate collects everything in Azure.

  publish  --run-id ID --pool NAME --src DIR...   upload each shard folder (episodes.csv,
           shard.json) to <datastore>/sim2sim-runs/<run-id>/<pool>/<shard folder name>/
  collect  --run-id ID --out DIR                  download all shard folders of a run

The data lake is private (private endpoints; from external clusters through the storage gateway)
and accessed with the OSMO managed identity (Workload Identity / federation), never with keys.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from aml_common import ml_client
from data_assets import container_client

PREFIX = "sim2sim-runs"


def _container(datastore: str):
    client = ml_client()
    return container_client(client, datastore)


def publish(a: argparse.Namespace) -> None:
    cc = _container(a.datastore)
    n = 0
    for src in a.src:
        src = Path(src)
        info_file = src / "shard.json"
        if not info_file.exists():
            print(f"skip {src}: no shard.json")
            continue
        info = json.loads(info_file.read_text())
        sim = "gazebo" if str(info.get("simulator", "")).startswith("gazebo") else "mujoco"
        dest = f"{PREFIX}/{a.run_id}/{a.pool}/{sim}-{info['shard']:03d}"
        for f in sorted(src.iterdir()):
            if f.is_file():
                cc.upload_blob(f"{dest}/{f.name}", f.read_bytes(), overwrite=True)
                n += 1
        print(f"published {src} -> {cc.container_name}/{dest}")
    print(f"{n} files published for run {a.run_id} from pool {a.pool}")


def collect(a: argparse.Namespace) -> None:
    cc = _container(a.datastore)
    prefix = f"{PREFIX}/{a.run_id}/"
    out = Path(a.out)
    pools, n = set(), 0
    for blob in cc.list_blobs(name_starts_with=prefix, include=["metadata"]):
        if (blob.metadata or {}).get("hdi_isfolder") == "true":
            continue
        rel = blob.name[len(prefix):]
        pools.add(rel.split("/")[0])
        target = out / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(cc.download_blob(blob.name).readall())
        n += 1
    if not n:
        raise SystemExit(f"no results for run {a.run_id} under {cc.container_name}/{prefix}")
    shards = len(list(out.rglob("shard.json")))
    print(f"collected {n} files, {shards} shards from pools {sorted(pools)}")
    (out / "run.json").write_text(json.dumps({"run_id": a.run_id, "pools": sorted(pools), "shards": shards}))


def main() -> None:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("publish")
    s.add_argument("--run-id", required=True)
    s.add_argument("--pool", required=True)
    s.add_argument("--src", nargs="+", required=True)
    s.set_defaults(func=publish)
    s = sub.add_parser("collect")
    s.add_argument("--run-id", required=True)
    s.add_argument("--out", required=True)
    s.set_defaults(func=collect)
    for s in sub.choices.values():
        s.add_argument("--datastore", default=os.environ.get("AML_DATASTORE", "robotics_data"))
    a = p.parse_args()
    a.func(a)


if __name__ == "__main__":
    main()
