"""Sim2sim gate for point-foot locomotion policies: merge shards, score, record, promote.

Inputs: models.json from the fetch task (models under test, their roles and MLflow run IDs),
data_asset.json, and the output folders of every validation shard (episodes.csv + shard.json).

Per model version it computes, on the in-distribution scenarios (the gate set):
  fall_rate          share of episodes in which the robot fell
  lin_vel_rmse       velocity-tracking RMSE [m/s] over the episodes without a fall
  yaw_rate_rmse      yaw-rate tracking RMSE [rad/s] (reported, not gated)
and fall rates per stress factor (friction, payload, push, latency, compound), in and out of
distribution, for diagnosis. Out-of-distribution scenarios are reported but never gated.

It logs one MLflow run per model version (child of the run that holds the model files), tags
the model versions, and then, depending on --mode:
  promote     the "candidate" must pass the gate and must not be worse than the current
              "champion" (stage=production) on the same scenarios; if so it becomes
              stage=production and the champion stage=archived. Exit 1 if the candidate fails
              the gate.
  revalidate  re-score every listed version on (new) data; no promotion. Exit 1 if the current
              production version no longer passes the gate.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
from collections import defaultdict
from pathlib import Path

from aml_common import ml_client, setup_mlflow, workflow_tags

BINS = {
    "friction": [0.15, 0.3, 0.4, 0.6, 0.8, 1.2],
    "added_mass": [-1.0, 0.0, 2.0, 4.0, 6.0],
    "push_force": [0.0, 50.0, 100.0, 200.0, 300.0],
    "latency_ms": [0.0, 5.0, 10.0, 20.0, 40.0, 60.0],
}


def _mean(xs):
    xs = [x for x in xs if not math.isnan(x)]
    return sum(xs) / len(xs) if xs else float("nan")


def _bin(name, v):
    """(index, label) of the bin that holds v, e.g. (1, "0.3~0.4")."""
    edges = BINS[name]
    for i, (lo, hi) in enumerate(zip(edges, edges[1:])):
        if lo < v <= hi or (i == 0 and v == lo):  # (lo, hi]; the first bin also holds its lower edge
            return i, f"{lo:g}~{hi:g}"
    return len(edges), "other"


def summarize(rows: list[dict]) -> dict:
    ind = [r for r in rows if r["split"] == "in_dist"]
    ood = [r for r in rows if r["split"] == "out_dist"]
    ok = [r for r in ind if not r["fell"]]
    s = {
        "episodes": len(rows),
        "in_dist_episodes": len(ind),
        "fall_rate": sum(r["fell"] for r in ind) / max(1, len(ind)),
        "lin_vel_rmse": _mean([r["lin_vel_rmse"] for r in ok]),
        "yaw_rate_rmse": _mean([r["yaw_rate_rmse"] for r in ok]),
        "mean_survival": _mean([r["survival"] for r in ind]),
        "ood_fall_rate": sum(r["fell"] for r in ood) / max(1, len(ood)),
    }
    groups = defaultdict(list)
    for r in rows:
        groups[(r["split"], r["group"])].append(r)
    s["by_group"] = {f"{sp}/{g}": {"episodes": len(v), "fall_rate": sum(r["fell"] for r in v) / len(v)}
                     for (sp, g), v in sorted(groups.items())}
    bins = defaultdict(list)
    for r in rows:
        factor = r["group"] if r["split"] == "out_dist" else None
        for name in BINS:
            # in-distribution rows count for every factor; out-of-distribution rows only for the stressed one
            if factor is None or BINS_KEY.get(factor) == name:
                bins[(name, *_bin(name, r[name]))].append(r)
    s["by_bin"] = [{"factor": n, "bin": b, "episodes": len(v), "fall_rate": sum(r["fell"] for r in v) / len(v)}
                   for (n, _, b), v in sorted(bins.items())]
    return s


BINS_KEY = {"friction": "friction", "added_mass": "added_mass", "push": "push_force", "latency_ms": "latency_ms"}


def load_rows(shard_dirs: list[str]) -> tuple[list[dict], int]:
    rows, scenarios = [], 0
    for d in shard_dirs:
        info = json.loads((Path(d) / "shard.json").read_text())
        scenarios += info["scenarios"]
        with open(Path(d) / "episodes.csv") as f:
            for r in csv.DictReader(f):
                for k in ("friction", "added_mass", "push_force", "latency_ms", "survival", "lin_vel_rmse", "yaw_rate_rmse", "distance"):
                    r[k] = float(r[k])
                r["fell"] = int(r["fell"])
                rows.append(r)
    return rows, scenarios


def figure(summaries: dict, path: Path) -> None:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    factors = list(BINS)
    fig, axes = plt.subplots(1, len(factors), figsize=(4 * len(factors), 3.4), sharey=True)
    width = 0.8 / max(1, len(summaries))
    for i, (key, s) in enumerate(summaries.items()):
        for ax, f in zip(axes, factors):
            items = [b for b in s["by_bin"] if b["factor"] == f]
            xs = [j + i * width for j in range(len(items))]
            ax.bar(xs, [100 * b["fall_rate"] for b in items], width=width, label=key)
            ax.set_xticks([j + 0.4 - width / 2 for j in range(len(items))], [b["bin"] for b in items], rotation=30, fontsize=8)
            ax.set_title(f)
    axes[0].set_ylabel("fall rate [%]")
    axes[-1].legend(fontsize=8)
    fig.suptitle("Fall rate by stress factor (in + out of distribution)")
    fig.tight_layout()
    fig.savefig(path, dpi=120)
    plt.close(fig)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--models-json", required=True)
    p.add_argument("--data-asset-json", required=True)
    p.add_argument("--shard-dir", action="append", required=True)
    p.add_argument("--mode", choices=["promote", "revalidate"], default="promote")
    p.add_argument("--max-fall-rate", type=float, default=0.05)
    p.add_argument("--max-lin-vel-rmse", type=float, default=0.3)
    p.add_argument("--champion-margin-fall", type=float, default=0.01)
    p.add_argument("--champion-margin-rmse", type=float, default=0.02)
    p.add_argument("--experiment", default="pointfoot-sim2sim")
    p.add_argument("--out", required=True)
    p.add_argument("--offline", action="store_true", help="score only, no AzureML (local testing)")
    a = p.parse_args()

    models = json.loads(Path(a.models_json).read_text())["models"]
    data = json.loads(Path(a.data_asset_json).read_text())
    data_ref = f"{data['name']}:{data['version']}"
    rows, n_scen = load_rows(a.shard_dir)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)

    results = {}
    for m in models:
        key = f"{m['name']}:{m['version']}"
        mrows = [r for r in rows if r["model"] == m["name"] and r["version"] == str(m["version"])]
        if len(mrows) != n_scen:
            raise SystemExit(f"{key}: {len(mrows)} episodes, expected {n_scen} (missing shard?)")
        s = summarize(mrows)
        s["passed"] = s["fall_rate"] <= a.max_fall_rate and s["lin_vel_rmse"] <= a.max_lin_vel_rmse
        s.update({"model": m, "key": key})
        results[key] = s
        with open(out / f"episodes-{m['name']}-v{m['version']}.csv", "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(mrows[0]))
            w.writeheader()
            w.writerows(mrows)

    # Console report (shows up in the OSMO task log)
    print(f"\nsim2sim on {data_ref}: {n_scen} scenarios per model; gate = in-distribution fall rate <= "
          f"{a.max_fall_rate:.0%} and velocity RMSE <= {a.max_lin_vel_rmse} m/s")
    print(f"{'model':28s} {'role':10s} {'fall':>7s} {'v_rmse':>7s} {'yaw_rmse':>8s} {'ood_fall':>8s}  gate")
    for k, s in results.items():
        print(f"{k:28s} {s['model'].get('role', ''):10s} {s['fall_rate']:7.1%} {s['lin_vel_rmse']:7.3f} "
              f"{s['yaw_rate_rmse']:8.3f} {s['ood_fall_rate']:8.1%}  {'PASS' if s['passed'] else 'FAIL'}")
    groups = sorted({g for s in results.values() for g in s["by_group"]})
    print("\nfall rate by scenario group:")
    print(f"{'group':22s}" + "".join(f"{k:>24s}" for k in results))
    for g in groups:
        print(f"{g:22s}" + "".join(f"{s['by_group'].get(g, {}).get('fall_rate', float('nan')):24.1%}" for s in results.values()))

    # Decision
    decision = {"mode": a.mode, "data_asset": data_ref}
    exit_msg = None
    if a.mode == "promote":
        cand = next((s for s in results.values() if s["model"].get("role") == "candidate"), None)
        champ = next((s for s in results.values() if s["model"].get("role") == "champion"), None)
        if cand is None:
            raise SystemExit("promote mode needs a model with role=candidate")
        if not cand["passed"]:
            decision["promotion"] = "rejected-gate"
            exit_msg = f"sim2sim gate failed for {cand['key']}"
        elif champ and (cand["fall_rate"] > champ["fall_rate"] + a.champion_margin_fall
                        or cand["lin_vel_rmse"] > champ["lin_vel_rmse"] + a.champion_margin_rmse):
            decision["promotion"] = "rejected-champion"
        else:
            decision["promotion"] = "promoted"
        decision.update(candidate=cand["key"], champion=champ["key"] if champ else None)
    else:
        prod = [s for s in results.values() if s["model"].get("role") == "champion"]
        if prod and not prod[0]["passed"]:
            exit_msg = f"production model {prod[0]['key']} no longer passes the gate on {data_ref}"
    print(f"\ndecision: {json.dumps(decision)}")

    fig_path = out / "fall_rate_by_factor.png"
    try:
        figure(results, fig_path)
    except Exception as e:  # the figure is a nice-to-have
        print(f"figure skipped: {e}")

    if not a.offline:
        client = ml_client()
        mlflow = setup_mlflow(client, a.experiment)
        for k, s in results.items():
            m = s["model"]
            tags = {**workflow_tags(), "stage": "sim2sim-validation", "simulator": "mujoco", "model_name": m["name"],
                    "model_version": str(m["version"]), "data_asset": data_ref, "role": m.get("role", "")}
            if m.get("run_id"):
                tags["mlflow.parentRunId"] = m["run_id"]
            with mlflow.start_run(run_name=f"sim2sim-{m['name']}-v{m['version']}", tags=tags) as run:
                mlflow.log_params({"scenarios": n_scen, "max_fall_rate": a.max_fall_rate,
                                   "max_lin_vel_rmse": a.max_lin_vel_rmse, "mode": a.mode, "rl_type": m.get("rl_type")})
                mlflow.log_metrics({x: s[x] for x in ("fall_rate", "lin_vel_rmse", "yaw_rate_rmse", "mean_survival", "ood_fall_rate")
                                    if not math.isnan(s[x])})
                mlflow.log_metrics({f"fall_rate.{g.replace('/', '.')}": v["fall_rate"] for g, v in s["by_group"].items()})
                mlflow.log_metric("gate_passed", int(s["passed"]))
                mlflow.log_dict({x: s[x] for x in ("by_group", "by_bin")}, "breakdown.json")
                mlflow.log_artifact(str(out / f"episodes-{m['name']}-v{m['version']}.csv"))
                if fig_path.exists():
                    mlflow.log_artifact(str(fig_path))
                s["mlflow_run_id"] = run.info.run_id

            model = client.models.get(m["name"], version=str(m["version"]))
            t = dict(model.tags or {})
            t.update({
                "sim2sim_validation": "passed" if s["passed"] else "failed",
                "sim2sim_data_asset": data_ref,
                "sim2sim_fall_rate": f"{s['fall_rate']:.3f}",
                "sim2sim_lin_vel_rmse": f"{s['lin_vel_rmse']:.3f}",
                "sim2sim_ood_fall_rate": f"{s['ood_fall_rate']:.3f}",
            })
            if a.mode == "promote" and decision.get("promotion") == "promoted":
                if k == decision["candidate"]:
                    t["stage"] = "production"
                elif k == decision.get("champion"):
                    t["stage"] = "archived"
            if a.mode == "promote" and k == decision.get("candidate") and decision["promotion"] != "promoted":
                t["stage"] = decision["promotion"]
            model.tags = t
            client.models.create_or_update(model)
            print(f"tagged {k}: sim2sim_validation={t['sim2sim_validation']} stage={t.get('stage', '-')}")

    (out / "gate.json").write_text(json.dumps({"decision": decision, "results": results}, indent=2, default=str))
    if exit_msg:
        raise SystemExit(exit_msg)


if __name__ == "__main__":
    main()
