"""Sim2sim scenario sets for point-foot biped locomotion policies (deterministic, seeded).

Every scenario is a 20 s episode with four 5 s velocity-command segments inside the operator
command range (vx +-0.75 m/s, vy +-0.5 m/s, wz +-0.25 rad/s), plus physical perturbations:

  friction     ground/foot sliding friction            in distribution: 0.4 - 1.2
  added_mass   payload on the base [kg]                in distribution: -1 - 2
  push         0.1 s horizontal push on the base [N]   in distribution: 0 - 100 (~10 N*s)
  latency_ms   observation latency [ms]                in distribution: 0 - 10

The in-distribution ranges follow typical training-time domain randomization for this robot
class. Profiles:

  v1  600 in-distribution scenarios (all factors sampled inside the ranges) + 400
      out-of-distribution scenarios, 100 per factor: one factor is pushed outside its range,
      the others stay nominal, so failures can be attributed to that factor.
  v2  v1 + 200 "compound" scenarios: several factors near the edge of their range at the same
      time (e.g. a slippery floor, a payload, a push and some latency), as seen in field incidents.
      Compound scenarios are in distribution, so they count towards the gate.
"""

from __future__ import annotations

import argparse
import json

import numpy as np

DURATION = 20.0
SEGMENT = 5.0
CMD_RANGE = {"vx": 0.75, "vy": 0.5, "wz": 0.25}
IN_DIST = {"friction": (0.4, 1.2), "added_mass": (-1.0, 2.0), "push": (0.0, 100.0), "latency_ms": (0.0, 10.0)}
OUT_DIST = {"friction": (0.15, 0.4), "added_mass": (2.0, 6.0), "push": (100.0, 300.0), "latency_ms": (20.0, 60.0)}
NOMINAL = {"friction": 0.8, "added_mass": 0.0, "push": 0.0, "latency_ms": 0.0}


def _commands(rng: np.random.Generator) -> list[list[float]]:
    segs = []
    for i in range(int(DURATION / SEGMENT)):
        kind = rng.choice(["stand", "forward", "lateral", "turn", "mixed"], p=[0.15, 0.3, 0.2, 0.15, 0.2])
        vx = vy = wz = 0.0
        if kind in ("forward", "mixed"):
            vx = rng.uniform(-1, 1) * CMD_RANGE["vx"]
        if kind in ("lateral", "mixed"):
            vy = rng.uniform(-1, 1) * CMD_RANGE["vy"]
        if kind in ("turn", "mixed"):
            wz = rng.uniform(-1, 1) * CMD_RANGE["wz"]
        segs.append([i * SEGMENT, round(vx, 3), round(vy, 3), round(wz, 3)])
    return segs


def _push(rng: np.random.Generator, force: float) -> dict | None:
    if force <= 0:
        return None
    ang = rng.uniform(0, 2 * np.pi)
    return {"t": round(float(rng.uniform(3.0, DURATION - 3.0)), 3),
            "fx": round(float(force * np.cos(ang)), 1), "fy": round(float(force * np.sin(ang)), 1), "dur": 0.1}


def _scenario(sid: int, split: str, factor: str, values: dict, rng: np.random.Generator) -> dict:
    return {
        "id": sid,
        "split": split,            # in_dist | out_dist
        "group": factor,           # which factor is stressed (in_dist: "all" or "compound")
        "duration": DURATION,
        "commands": _commands(rng),
        "friction": round(float(values["friction"]), 3),
        "added_mass": round(float(values["added_mass"]), 3),
        "push_force": round(float(values["push"]), 1),
        "push": _push(rng, values["push"]),
        "latency_ms": round(float(values["latency_ms"]), 1),
    }


def make(profile: str, seed: int) -> list[dict]:
    rng = np.random.default_rng(seed)
    out: list[dict] = []
    for _ in range(600):
        vals = {k: rng.uniform(*r) for k, r in IN_DIST.items()}
        out.append(_scenario(len(out), "in_dist", "all", vals, rng))
    for factor, rng_range in OUT_DIST.items():
        for _ in range(100):
            vals = dict(NOMINAL)
            vals[factor] = rng.uniform(*rng_range)
            out.append(_scenario(len(out), "out_dist", factor, vals, rng))
    if profile == "v2":
        crng = np.random.default_rng(seed + 1)  # keep v1 scenarios identical
        for _ in range(200):
            vals = {
                "friction": crng.uniform(0.4, 0.55),
                "added_mass": crng.uniform(1.0, 2.0),
                "push": crng.uniform(60.0, 100.0),
                "latency_ms": crng.uniform(5.0, 10.0),
            }
            out.append(_scenario(len(out), "in_dist", "compound", vals, crng))
    elif profile != "v1":
        raise ValueError(f"unknown profile {profile}")
    return out


def document(profile: str, seed: int) -> dict:
    scenarios = make(profile, seed)
    return {
        "profile": profile,
        "seed": seed,
        "in_distribution": IN_DIST,
        "out_of_distribution": OUT_DIST,
        "command_range": CMD_RANGE,
        "count": len(scenarios),
        "scenarios": scenarios,
    }


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--profile", default="v1")
    p.add_argument("--seed", type=int, default=2026)
    p.add_argument("--out", required=True)
    a = p.parse_args()
    doc = document(a.profile, a.seed)
    with open(a.out, "w") as f:
        json.dump(doc, f, indent=1)
    print(f"wrote {doc['count']} scenarios ({a.profile}) to {a.out}")
