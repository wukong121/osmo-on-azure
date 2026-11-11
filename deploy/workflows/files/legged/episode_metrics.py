"""Simulator-independent episode scoring for point-foot locomotion sim2sim (MuJoCo, Gazebo).

Every episode starts with a WARMUP_S warm-up: the policy is in control with a zero command
(stepping in place, like an operator starting the policy before driving). Scenario time 0 is the
end of the warm-up; commands and pushes are scheduled in scenario time. A fall during the
warm-up counts as a fall at t=0.

Both simulators log, at the 50 Hz policy rate: time, base velocity in the heading frame
(vx, vy), yaw rate and the active velocity command. score() turns that into the episode
result, so every simulator is judged by the same rules:

  fall              base height < FALL_HEIGHT or tilt > FALL_TILT (or base contact, if the
                    simulator reports it)
  lin_vel_rmse      0.5 s moving average of the base xy velocity vs the command [m/s]
  yaw_rate_rmse     same for the yaw rate [rad/s]
  excluded windows  first SETTLE_S after reset, CMD_SETTLE_S after each command change,
                    PUSH_SETTLE_S after a push, and the last 0.5 s before a fall
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np

WARMUP_S = 2.0       # zero-command warm-up (stepping in place) before scenario time 0
FALL_HEIGHT = 0.45   # base height [m] below which the robot is considered fallen
FALL_TILT = 1.0      # base tilt [rad] above which the robot is considered fallen
SETTLE_S = 1.0
CMD_SETTLE_S = 0.5
PUSH_SETTLE_S = 1.5
SMOOTH_S = 0.5       # one gait cycle at 2 Hz


@dataclass
class EpisodeResult:
    fell: bool
    fall_time: float | None
    survival: float          # fraction of the episode before a fall (1.0 if no fall)
    lin_vel_rmse: float      # m/s
    yaw_rate_rmse: float     # rad/s
    distance: float          # m, base xy displacement
    extra: dict = field(default_factory=dict)


def command_at(commands, t) -> np.ndarray:
    """Piecewise-constant command [vx, vy, wz] at time t from [[t0, vx, vy, wz], ...]."""
    cmd = [0.0, 0.0, 0.0]
    for seg in sorted(commands):
        if seg[0] <= t:
            cmd = seg[1:4]
    return np.asarray(cmd, dtype=float)


def tilt_from_quat_xyzw(q) -> float:
    """Angle between the base z axis and the world z axis [rad]."""
    x, y, z, w = q
    # z component of the base z axis in world coordinates
    zz = 1.0 - 2.0 * (x * x + y * y)
    return math.acos(max(-1.0, min(1.0, zz)))


def yaw_from_quat_xyzw(q) -> float:
    x, y, z, w = q
    return math.atan2(2.0 * (w * z + x * y), 1.0 - 2.0 * (y * y + z * z))


def is_fallen(height: float, quat_xyzw, base_contact: bool = False) -> bool:
    return height < FALL_HEIGHT or tilt_from_quat_xyzw(quat_xyzw) > FALL_TILT or base_contact


def score(sc: dict, t, v_heading, wz, cmd, sample_dt: float, fell: bool, t_fall: float | None,
          distance: float) -> EpisodeResult:
    """Score one episode from 50 Hz samples (arrays of equal length)."""
    t = np.asarray(t, dtype=float)
    v = np.asarray(v_heading, dtype=float).reshape(-1, 2)
    wz = np.asarray(wz, dtype=float)
    cmd = np.asarray(cmd, dtype=float).reshape(-1, 3)
    push = sc.get("push")
    change_times = [c[0] for c in sc["commands"]]
    win = max(1, int(round(SMOOTH_S / sample_dt)))
    kernel = np.ones(win) / win
    if len(t) >= win:
        sv = np.stack([np.convolve(v[:, i], kernel, mode="valid") for i in range(2)], axis=1)
        swz = np.convolve(wz, kernel, mode="valid")
        st = t[win - 1:]
        scmd = cmd[win - 1:]
        mask = st >= SETTLE_S
        for tc in change_times:
            mask &= ~((st >= tc) & (st < tc + CMD_SETTLE_S))
        if push:
            mask &= ~((st >= push["t"]) & (st < push["t"] + PUSH_SETTLE_S))
        if fell:
            mask &= st < t_fall - 0.5
    else:
        mask = np.zeros(0, dtype=bool)
    if mask.any():
        lin = float(np.sqrt(np.mean(np.sum((sv[mask] - scmd[mask, :2]) ** 2, axis=1))))
        yaw_rmse = float(np.sqrt(np.mean((swz[mask] - scmd[mask, 2]) ** 2)))
    else:
        lin, yaw_rmse = float("nan"), float("nan")
    return EpisodeResult(
        fell=fell,
        fall_time=t_fall,
        survival=(t_fall / sc["duration"]) if fell else 1.0,
        lin_vel_rmse=lin,
        yaw_rate_rmse=yaw_rmse,
        distance=distance,
    )
