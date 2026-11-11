"""Sim2sim gate for point-foot locomotion policies: merge shards, score, record, promote.

Inputs: models.json from the fetch task (models under test, their roles and MLflow run IDs),
data_asset.json, and the output folders of every validation shard (episodes.csv + shard.json)
from one or more simulators (MuJoCo shards, Gazebo shards).

Per model version and simulator it computes, on the in-distribution scenarios (the gate set):
  fall_rate          share of episodes in which the robot fell
  lin_vel_rmse       velocity-tracking RMSE [m/s] over the episodes without a fall
  yaw_rate_rmse      yaw-rate tracking RMSE [rad/s] (reported, not gated)
and fall rates per stress factor (friction, payload, push, latency, compound), in and out of
distribution, for diagnosis. Out-of-distribution scenarios are reported but never gated.
Invalid episodes (Gazebo: real-time factor too low, or no clean start after retries) are
excluded and counted.

A model passes when it passes in every simulator. It logs one MLflow run per model version and
simulator (child of the run that holds the model files), tags the model versions, and then,
depending on --mode:
  promote     the "candidate" must pass the gate and must not be worse than the current
              "champion" (stage=production) in any simulator; if so it becomes
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
NUMERIC = ("friction", "added_mass", "push_force", "latency_ms", "survival", "lin_vel_rmse", "yaw_rate_rmse", "distance")


def load_rows(shard_dirs: list[str]) -> tuple[list[dict], dict[str, int]]:
    """All episode rows, and the number of scenarios per simulator (from shard.json)."""
    rows, scenarios = [], defaultdict(int)
    for d in shard_dirs:
        info = json.loads((Path(d) / "shard.json").read_text())
        sim = "gazebo" if str(info.get("simulator", "")).startswith("gazebo") else "mujoco"
        scenarios[sim] += info["scenarios"]
        with open(Path(d) / "episodes.csv") as f:
            for r in csv.DictReader(f):
                for k in NUMERIC:
                    r[k] = float(r[k]) if r[k] != "" else float("nan")
                r["fell"] = int(r["fell"])
                r["simulator"] = r.get("simulator") or sim
                r["valid"] = int(r.get("valid", 1) or 1)
                rows.append(r)
    return rows, dict(scenarios)


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


def _fmt(x, pct=False):
    if x is None or (isinstance(x, float) and math.isnan(x)):
        return "-"
    return f"{x:.1%}" if pct else f"{x:.3f}"


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
    sims = sorted(n_scen)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)

    # results[model key][simulator] = summary
    results: dict[str, dict] = {}
    for m in models:
        key = f"{m['name']}:{m['version']}"
        results[key] = {"model": m, "sims": {}}
        for sim in sims:
            mrows = [r for r in rows if r["model"] == m["name"] and r["version"] == str(m["version"]) and r["simulator"] == sim]
            if len(mrows) != n_scen[sim]:
                raise SystemExit(f"{key} {sim}: {len(mrows)} episodes, expected {n_scen[sim]} (missing shard?)")
            valid = [r for r in mrows if r["valid"]]
            s = summarize(valid)
            s["invalid_episodes"] = len(mrows) - len(valid)
            inv = defaultdict(int)
            for r in mrows:
                if not r["valid"]:
                    inv[f"{r['split']}/{r['group']}"] += 1
            s["invalid_by_group"] = dict(inv)
            s["startup_failures"] = sum(int(r.get("startup_failures") or 0) for r in mrows)
            s["passed"] = s["fall_rate"] <= a.max_fall_rate and s["lin_vel_rmse"] <= a.max_lin_vel_rmse
            results[key]["sims"][sim] = s
            with open(out / f"episodes-{m['name']}-v{m['version']}-{sim}.csv", "w", newline="") as f:
                w = csv.DictWriter(f, fieldnames=list(mrows[0]))
                w.writeheader()
                w.writerows(mrows)
        results[key]["passed"] = all(s["passed"] for s in results[key]["sims"].values())

    # Console report (shows up in the OSMO task log)
    print(f"\nsim2sim on {data_ref}: scenarios per model {n_scen}; gate (every simulator) = in-distribution "
          f"fall rate <= {a.max_fall_rate:.0%} and velocity RMSE <= {a.max_lin_vel_rmse} m/s")
    print(f"{'model':22s} {'role':10s} {'simulator':9s} {'fall':>7s} {'v_rmse':>7s} {'yaw_rmse':>8s} {'ood_fall':>8s} {'invalid':>7s}  gate")
    for k, res in results.items():
        for sim, s in res["sims"].items():
            print(f"{k:22s} {res['model'].get('role', ''):10s} {sim:9s} {_fmt(s['fall_rate'], True):>7s} "
                  f"{_fmt(s['lin_vel_rmse']):>7s} {_fmt(s['yaw_rate_rmse']):>8s} {_fmt(s['ood_fall_rate'], True):>8s} "
                  f"{s['invalid_episodes']:7d}  {'PASS' if s['passed'] else 'FAIL'}")
    cols = [(k, sim) for k, res in results.items() for sim in res["sims"]]
    groups = sorted({g for res in results.values() for s in res["sims"].values() for g in s["by_group"]})
    print("\nfall rate by scenario group:")
    print(f"{'group':22s}" + "".join(f"{k + ' ' + sim:>30s}" for k, sim in cols))
    for g in groups:
        print(f"{g:22s}" + "".join(f"{_fmt(results[k]['sims'][sim]['by_group'].get(g, {}).get('fall_rate'), True):>30s}" for k, sim in cols))

    if any(s["invalid_episodes"] for res in results.values() for s in res["sims"].values()):
        print("\ninvalid episodes by scenario group (excluded from the statistics):")
        for k, res in results.items():
            for sim, s in res["sims"].items():
                if s["invalid_episodes"]:
                    print(f"  {k} {sim}: {s['invalid_by_group']}")

    # Decision: the candidate must pass on every simulator and not be worse than the champion on any
    decision = {"mode": a.mode, "data_asset": data_ref, "simulators": sims}
    exit_msg = None
    if a.mode == "promote":
        cand = next((r for r in results.values() if r["model"].get("role") == "candidate"), None)
        champ = next((r for r in results.values() if r["model"].get("role") == "champion"), None)
        if cand is None:
            raise SystemExit("promote mode needs a model with role=candidate")
        ckey = f"{cand['model']['name']}:{cand['model']['version']}"
        hkey = f"{champ['model']['name']}:{champ['model']['version']}" if champ else None
        worse = [sim for sim in sims if champ and (
            cand["sims"][sim]["fall_rate"] > champ["sims"][sim]["fall_rate"] + a.champion_margin_fall
            or cand["sims"][sim]["lin_vel_rmse"] > champ["sims"][sim]["lin_vel_rmse"] + a.champion_margin_rmse)]
        if not cand["passed"]:
            decision["promotion"] = "rejected-gate"
            failed = [sim for sim in sims if not cand["sims"][sim]["passed"]]
            exit_msg = f"sim2sim gate failed for {ckey} in {', '.join(failed)}"
        elif worse:
            decision["promotion"] = "rejected-champion"
            decision["worse_in"] = worse
        else:
            decision["promotion"] = "promoted"
        decision.update(candidate=ckey, champion=hkey)
    else:
        prod = [r for r in results.values() if r["model"].get("role") == "champion"]
        if prod and not prod[0]["passed"]:
            exit_msg = f"production model {prod[0]['model']['name']}:{prod[0]['model']['version']} no longer passes the gate on {data_ref}"
    print(f"\ndecision: {json.dumps(decision)}")

    fig_path = out / "fall_rate_by_factor.png"
    try:
        figure({f"{k} {sim}": s for k, res in results.items() for sim, s in res["sims"].items()}, fig_path)
    except Exception as e:  # the figure is a nice-to-have
        print(f"figure skipped: {e}")

    if not a.offline:
        client = ml_client()
        mlflow = setup_mlflow(client, a.experiment)
        for k, res in results.items():
            m = res["model"]
            for sim, s in res["sims"].items():
                tags = {**workflow_tags(), "stage": "sim2sim-validation", "simulator": sim, "model_name": m["name"],
                        "model_version": str(m["version"]), "data_asset": data_ref, "role": m.get("role", "")}
                if m.get("run_id"):
                    tags["mlflow.parentRunId"] = m["run_id"]
                with mlflow.start_run(run_name=f"sim2sim-{m['name']}-v{m['version']}-{sim}", tags=tags) as run:
                    mlflow.log_params({"scenarios": n_scen[sim], "max_fall_rate": a.max_fall_rate,
                                       "max_lin_vel_rmse": a.max_lin_vel_rmse, "mode": a.mode, "rl_type": m.get("rl_type")})
                    metrics = {x: s[x] for x in ("fall_rate", "lin_vel_rmse", "yaw_rate_rmse", "mean_survival", "ood_fall_rate")}
                    metrics.update(invalid_episodes=s["invalid_episodes"], startup_failures=s["startup_failures"],
                                   gate_passed=int(s["passed"]))
                    metrics.update({f"fall_rate.{g.replace('/', '.')}": v["fall_rate"] for g, v in s["by_group"].items()})
                    mlflow.log_metrics({x: v for x, v in metrics.items() if not (isinstance(v, float) and math.isnan(v))})
                    mlflow.log_dict({x: s[x] for x in ("by_group", "by_bin")}, "breakdown.json")
                    mlflow.log_artifact(str(out / f"episodes-{m['name']}-v{m['version']}-{sim}.csv"))
                    if fig_path.exists():
                        mlflow.log_artifact(str(fig_path))
                    s["mlflow_run_id"] = run.info.run_id

            model = client.models.get(m["name"], version=str(m["version"]))
            t = dict(model.tags or {})
            t.update({
                "sim2sim_validation": "passed" if res["passed"] else "failed",
                "sim2sim_data_asset": data_ref,
                "sim2sim_simulators": ",".join(sims),
                # worst case over the simulators
                "sim2sim_fall_rate": f"{max(s['fall_rate'] for s in res['sims'].values()):.3f}",
                "sim2sim_lin_vel_rmse": f"{max(s['lin_vel_rmse'] for s in res['sims'].values()):.3f}",
                "sim2sim_ood_fall_rate": f"{max(s['ood_fall_rate'] for s in res['sims'].values()):.3f}",
            })
            for sim, s in res["sims"].items():
                t[f"sim2sim_{sim}_fall_rate"] = f"{s['fall_rate']:.3f}"
                t[f"sim2sim_{sim}_lin_vel_rmse"] = f"{s['lin_vel_rmse']:.3f}"
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
