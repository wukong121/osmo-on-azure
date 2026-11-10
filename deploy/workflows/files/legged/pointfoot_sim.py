"""Headless, deterministic MuJoCo rollout of a point-foot biped locomotion policy.

Re-implements a common sim2sim deployment loop for blind velocity-tracking policies exported
from rsl_rl (policy.onnx + encoder.onnx + params.yaml), without the vendor SDK, inter-process
messaging or a joystick:

  physics 1 kHz -> PD (Kp*(q*-q) - Kd*dq) every physics step
  controller 500 Hz -> torque-limit-aware action clipping -> joint position targets
  policy 50 Hz (decimation 10) -> encoder(obs history) + obs + velocity command -> actions

Observation (30): base angular velocity, projected gravity, joint positions (relative to the
default pose), joint velocities, last actions, gait clock (sin, cos), gait parameters (4).
Encoder: 10-step observation history -> base linear velocity estimate (3).
Policies trained in Isaac Lab order joints by type (abad L/R, hip L/R, knee L/R); policies from
Isaac Gym order them per leg, like the robot. `rl_type` selects the mapping.

Scenario perturbations: ground friction, added base mass, a horizontal push, observation
latency, and a piecewise-constant velocity command sequence.
"""

from __future__ import annotations

import collections
import math
from dataclasses import dataclass, field

import mujoco
import numpy as np
import onnxruntime as ort
import yaml
from scipy.spatial.transform import Rotation as R

LAB_ORDER = [0, 3, 1, 4, 2, 5]  # robot order (L abad, hip, knee, R abad, hip, knee) -> Isaac Lab order

PHYSICS_HZ = 1000
FALL_HEIGHT = 0.45   # base height [m] below which the robot is considered fallen
FALL_TILT = 1.0      # base tilt [rad] above which the robot is considered fallen
SETTLE_S = 1.0       # ignore tracking error right after reset
CMD_SETTLE_S = 0.5   # ... after each command change
PUSH_SETTLE_S = 1.5  # ... after a push starts
SMOOTH_S = 0.5       # moving-average window for base velocity (one gait cycle at 2 Hz)


def _to_lab(a: np.ndarray) -> np.ndarray:
    return a[LAB_ORDER]


def _from_lab(a: np.ndarray) -> np.ndarray:
    out = np.empty_like(a)
    out[LAB_ORDER] = a
    return out


def _session(path: str):
    so = ort.SessionOptions()
    so.intra_op_num_threads = 1
    so.inter_op_num_threads = 1
    so.log_severity_level = 3
    s = ort.InferenceSession(path, sess_options=so, providers=["CPUExecutionProvider"])
    return s, s.get_inputs()[0].name


class Policy:
    """Policy + encoder with the deployment-side observation pipeline."""

    def __init__(self, model_dir: str, rl_type: str):
        cfg = yaml.safe_load(open(f"{model_dir}/params.yaml"))["PointfootCfg"]
        if rl_type not in ("isaacgym", "isaaclab"):
            raise ValueError(f"unsupported rl_type {rl_type}")
        self.rl_type = rl_type
        self.pol, self.pol_in = _session(f"{model_dir}/policy.onnx")
        self.enc, self.enc_in = _session(f"{model_dir}/encoder.onnx")
        self.joint_names = cfg["joint_names"]
        self.default_q = np.array([cfg["init_state"]["default_joint_angle"][n] for n in self.joint_names])
        c = cfg["control"]
        self.kp, self.kd = float(c["stiffness"]), float(c["damping"])
        self.action_scale, self.decimation, self.tau_lim = c["action_scale_pos"], c["decimation"], c["user_torque_limit"]
        n = cfg["normalization"]
        self.obs_scales = n["obs_scales"]
        self.clip_obs, self.clip_act = n["clip_scales"]["clip_observations"], n["clip_scales"]["clip_actions"]
        s = cfg["size"]
        self.n_obs, self.hist_len = s["observations_size"], s["obs_history_length"]
        self.loop_hz = cfg["loop_frequency"]
        self.policy_dt = self.decimation / self.loop_hz
        self.reset()

    def reset(self) -> None:
        self.hist = None
        self.gait_index = 0.0
        self.actions = np.zeros(len(self.joint_names))
        self.last_actions = np.zeros(len(self.joint_names))

    def step(self, quat_xyzw, gyro, q, dq, cmd) -> None:
        """50 Hz: observation -> encoder -> policy. cmd = [vx, vy, wz] in m/s, rad/s."""
        grav = R.from_quat(quat_xyzw).inv().apply([0.0, 0.0, -1.0])
        gait = np.array([2.0, 0.5, 0.5, 0.1])  # frequency, phase offset, contact duration, swing height
        self.gait_index += self.policy_dt * gait[0]
        if self.gait_index > 1.0:
            self.gait_index = 0.0
        clock = [math.sin(2 * math.pi * self.gait_index), math.cos(2 * math.pi * self.gait_index)]
        jp, jv, la = (q - self.default_q) * self.obs_scales["dof_pos"], dq, self.last_actions
        if self.rl_type == "isaaclab":
            jp, jv, la = _to_lab(jp), _to_lab(jv), _to_lab(la)
        obs = np.concatenate([gyro * self.obs_scales["ang_vel"], grav, jp, jv * self.obs_scales["dof_vel"], la, clock, gait])
        if self.hist is None:
            self.hist = np.tile(obs, self.hist_len)
        self.hist = np.concatenate([self.hist[self.n_obs:], obs])
        obs = np.clip(obs, -self.clip_obs, self.clip_obs)
        enc = self.enc.run(None, {self.enc_in: self.hist.astype(np.float32)})[0].ravel()
        x = np.concatenate([enc, obs, cmd]).astype(np.float32)
        a = np.clip(self.pol.run(None, {self.pol_in: x})[0].ravel(), -self.clip_act, self.clip_act)
        self.actions = _from_lab(a) if self.rl_type == "isaaclab" else a

    def targets(self, q, dq) -> np.ndarray:
        """500 Hz: clip actions so the PD torque stays within the limit, return joint targets."""
        lo = (q - self.default_q + (self.kd * dq - self.tau_lim) / self.kp) / self.action_scale
        hi = (q - self.default_q + (self.kd * dq + self.tau_lim) / self.kp) / self.action_scale
        self.actions = np.clip(self.actions, lo, hi)
        self.last_actions = self.actions.copy()
        return self.actions * self.action_scale + self.default_q


class PointfootSim:
    def __init__(self, xml_path: str):
        self.m = mujoco.MjModel.from_xml_path(xml_path)
        if round(1.0 / self.m.opt.timestep) != PHYSICS_HZ:
            raise ValueError(f"expected a {PHYSICS_HZ} Hz model, got timestep {self.m.opt.timestep}")
        self.d = mujoco.MjData(self.m)
        self.nj = self.m.nu
        self.base = mujoco.mj_name2id(self.m, mujoco.mjtObj.mjOBJ_BODY, "base_Link")
        self.base_geom = mujoco.mj_name2id(self.m, mujoco.mjtObj.mjOBJ_GEOM, "base_collision")
        adr = lambda n: self.m.sensor_adr[mujoco.mj_name2id(self.m, mujoco.mjtObj.mjOBJ_SENSOR, n)]
        self.s_quat, self.s_gyro = adr("quat"), adr("gyro")
        self.nominal_mass = float(self.m.body_mass[self.base])
        self.nominal_friction = self.m.geom_friction.copy()

    def configure(self, friction: float | None, added_mass: float) -> None:
        self.m.geom_friction[:] = self.nominal_friction
        if friction is not None:
            self.m.geom_friction[:, 0] = friction  # MuJoCo uses the max of a contact pair: set all geoms
        self.m.body_mass[self.base] = self.nominal_mass + added_mass

    def reset(self) -> None:
        mujoco.mj_resetData(self.m, self.d)
        mujoco.mj_forward(self.m, self.d)

    def sense(self):
        d = self.d
        w, x, y, z = d.sensordata[self.s_quat:self.s_quat + 4]
        return (np.array([x, y, z, w]), d.sensordata[self.s_gyro:self.s_gyro + 3].copy(),
                d.qpos[7:7 + self.nj].copy(), d.qvel[6:6 + self.nj].copy())

    def step(self, q_des, kp, kd, n) -> None:
        for _ in range(n):
            self.d.ctrl[:] = kp * (q_des - self.d.qpos[7:7 + self.nj]) - kd * self.d.qvel[6:6 + self.nj]
            mujoco.mj_step(self.m, self.d)

    def base_contact(self) -> bool:
        for i in range(self.d.ncon):
            c = self.d.contact[i]
            if c.geom1 == self.base_geom or c.geom2 == self.base_geom:
                return True
        return False


@dataclass
class EpisodeResult:
    fell: bool
    fall_time: float | None
    survival: float          # fraction of the episode before a fall (1.0 if no fall)
    lin_vel_rmse: float      # m/s, smoothed base xy velocity (heading frame) vs command
    yaw_rate_rmse: float     # rad/s
    distance: float          # m, base xy displacement
    extra: dict = field(default_factory=dict)


def _command_at(commands, t):
    cmd = [0.0, 0.0, 0.0]
    for seg in commands:
        if seg[0] <= t:
            cmd = seg[1:4]
    return np.asarray(cmd, dtype=float)


def rollout(sim: PointfootSim, pol: Policy, sc: dict, on_step=None, stop_on_fall: bool = True) -> EpisodeResult:
    """Run one scenario:
      duration [s]; commands [[t, vx, vy, wz], ...]; friction; added_mass [kg];
      push {t, fx, fy, dur} [s, N]; latency_ms (observation delay, 2 ms resolution).
    Starts under policy control right after reset (a point foot cannot stand still).
    on_step(t, fell) is called after every controller step (e.g. to render frames);
    stop_on_fall=False keeps simulating after a fall (metrics still cover the time before it).
    """
    sim.configure(sc.get("friction"), sc.get("added_mass", 0.0))
    sim.reset()
    pol.reset()
    phys_per_ctrl = PHYSICS_HZ // pol.loop_hz
    n_ctrl = int(round(sc["duration"] * pol.loop_hz))
    delay = int(round(sc.get("latency_ms", 0.0) * pol.loop_hz / 1000.0))
    obs_buf = collections.deque(maxlen=delay + 1)
    push = sc.get("push")
    commands = sorted(sc["commands"])
    change_times = [c[0] for c in commands]

    t_log, v_log, wz_log, cmd_log = [], [], [], []
    start_xy = sim.d.qpos[0:2].copy()
    fell, t_fall = False, None
    for k in range(n_ctrl):
        t = k / pol.loop_hz
        state = sim.sense()
        obs_buf.append(state)
        if k % pol.decimation == 0:
            cmd = _command_at(commands, t)
            pol.step(*obs_buf[0], cmd)
            yaw = R.from_quat(state[0]).as_euler("zyx")[0]
            c, s = math.cos(yaw), math.sin(yaw)
            vx, vy = sim.d.qvel[0], sim.d.qvel[1]
            t_log.append(t)
            v_log.append((c * vx + s * vy, -s * vx + c * vy))
            wz_log.append(sim.d.qvel[5])
            cmd_log.append(cmd)
        q_des = pol.targets(state[2], state[3])
        if push and push["t"] <= t < push["t"] + push.get("dur", 0.1):
            sim.d.xfrc_applied[sim.base, 0:3] = [push.get("fx", 0.0), push.get("fy", 0.0), 0.0]
        else:
            sim.d.xfrc_applied[sim.base, :] = 0.0
        sim.step(q_des, pol.kp, pol.kd, phys_per_ctrl)
        tilt = math.acos(max(-1.0, min(1.0, -R.from_quat(sim.sense()[0]).inv().apply([0, 0, -1.0])[2])))
        if not fell and (sim.d.qpos[2] < FALL_HEIGHT or tilt > FALL_TILT or sim.base_contact()):
            fell, t_fall = True, t
        if on_step is not None:
            on_step(t, fell)
        if fell and stop_on_fall:
            break

    t_arr = np.array(t_log)
    v = np.array(v_log)
    wz = np.array(wz_log)
    cmd = np.array(cmd_log)
    win = max(1, int(round(SMOOTH_S / pol.policy_dt)))
    kernel = np.ones(win) / win
    if len(t_arr) >= win:
        sv = np.stack([np.convolve(v[:, i], kernel, mode="valid") for i in range(2)], axis=1)
        swz = np.convolve(wz, kernel, mode="valid")
        st = t_arr[win - 1:]
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
        distance=float(np.linalg.norm(sim.d.qpos[0:2] - start_xy)),
    )
