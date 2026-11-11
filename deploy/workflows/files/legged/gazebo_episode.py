"""Run one sim2sim scenario in Gazebo Classic with a ROS 2 (ros2_control) deployment stack.

Brings up a fresh stack per episode, so every scenario starts from the same state:

  1. robot description: xacro -> URDF, then per scenario: foot friction (mu1/mu2), added base
     mass, and a p3d plugin that publishes the base ground truth on /base_truth
  2. gzserver (headless, started paused) with the gazebo_ros init, factory and force system
     plugins (the last one provides /apply_link_wrench); robot_state_publisher; spawn the robot
  3. the vendor hardware node (ros2_control + RL controller, connects to the Gazebo hardware
     plugin through the vendor SDK); the node starts the controller after ~6 s (use_gazebo)
  4. unpause physics when the controller's stand phase ends (it ran against paused physics):
     episode time 0. A point foot cannot stand still, so the policy takes over immediately,
     like a reset in the vendor's MuJoCo simulator.
  5. after a WARMUP_S warm-up with a zero command (stepping in place), the driver publishes
     /cmd_vel from the scenario's command schedule, applies the push,
     records base state at 50 Hz (simulation time) and stops at the end or on a fall

The command is sent the way the vendor controller expects it: /cmd_vel is clipped to +-1 and
multiplied by user_cmd_scales (params.yaml), so the driver divides by those scales.
Gazebo runs in real time and the controller loop is wall-clock driven, so the real-time
factor is recorded; episodes below MIN_RTF are flagged invalid.
A fall within STARTUP_WINDOW_S of the start is a startup failure (the first steps from a
standstill in Gazebo are sensitive to the timing between the wall-clock controller and the
physics; such falls happen ~0.31 s after the start whatever the scenario); the shard runner
retries it and reports it separately. Later falls, including during the warm-up, are real falls. Observation latency cannot be injected into the vendor
controller; it is ignored here.
"""

from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import numpy as np

from episode_metrics import WARMUP_S, EpisodeResult, command_at, is_fallen, score, yaw_from_quat_xyzw

MIN_RTF = 0.9
# The first steps after unpausing are sensitive to the timing between the wall-clock controller
# and the physics: a fall within this window after the start is a startup failure (retried); a
# later fall, even during the warm-up, is a real fall.
STARTUP_WINDOW_S = 0.5
CONTROLLER_TIMEOUT_S = 40.0
SAMPLE_DT = 0.02

WORLD = """<?xml version="1.0" ?>
<sdf version="1.6">
  <world name="default">
    <physics type="ode">
      <max_step_size>0.002</max_step_size>
      <real_time_update_rate>500</real_time_update_rate>
    </physics>
    <include><uri>model://ground_plane</uri></include>
    <include><uri>model://sun</uri></include>
  </world>
</sdf>
"""

# Fast DDS over UDP only: pods have a small /dev/shm, and the shared-memory transport fails there.
FASTDDS_PROFILE = """<?xml version="1.0" encoding="UTF-8"?>
<profiles xmlns="http://www.eprosima.com/XMLSchemas/fastRTPS_Profiles">
  <transport_descriptors>
    <transport_descriptor><transport_id>udp</transport_id><type>UDPv4</type></transport_descriptor>
  </transport_descriptors>
  <participant profile_name="udp_only" is_default_profile="true">
    <rtps><userTransports><transport_id>udp</transport_id></userTransports>
      <useBuiltinTransports>false</useBuiltinTransports></rtps>
  </participant>
</profiles>
"""

P3D = """
  <gazebo>
    <plugin name="base_truth" filename="libgazebo_ros_p3d.so">
      <ros><remapping>odom:=base_truth</remapping></ros>
      <body_name>base_Link</body_name>
      <frame_name>world</frame_name>
      <update_rate>100</update_rate>
      <gaussian_noise>0.0</gaussian_noise>
    </plugin>
  </gazebo>
"""


def make_urdf(xacro_file: str, friction: float | None, added_mass: float) -> str:
    urdf = subprocess.run(["xacro", xacro_file, "use_gazebo:=true", "use_support:=false"],
                          check=True, capture_output=True, text=True).stdout
    if friction is not None:
        # every <gazebo reference="..._Link"> block of a foot/knee link (the contact links)
        def fix(m):
            block = m.group(0)
            block = re.sub(r"<mu1>[^<]*</mu1>", f"<mu1>{friction}</mu1>", block)
            block = re.sub(r"<mu2>[^<]*</mu2>", f"<mu2>{friction}</mu2>", block)
            return block
        urdf, n = re.subn(r'<gazebo reference="(foot|knee|contact)_[LR]_Link">.*?</gazebo>', fix, urdf, flags=re.S)
        if n == 0:
            raise RuntimeError("no foot friction blocks found in the robot description")
    if added_mass:
        m = re.search(r'(<link name="base_Link">.*?<mass value=")([0-9.eE+-]+)(")', urdf, flags=re.S)
        if not m:
            raise RuntimeError("base_Link mass not found")
        urdf = urdf[:m.start(2)] + f"{float(m.group(2)) + added_mass:.4f}" + urdf[m.end(2):]
    return urdf.replace("</robot>", P3D + "</robot>")


class Stack:
    """Processes of one episode, each in its own process group."""

    def __init__(self, workdir: Path):
        self.workdir = workdir
        self.procs: list[subprocess.Popen] = []

    def start(self, name, cmd, env=None):
        log = open(self.workdir / f"{name}.log", "w")
        p = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, env=env, start_new_session=True)
        self.procs.append(p)
        return p

    def stop(self):
        for p in reversed(self.procs):
            try:
                os.killpg(p.pid, signal.SIGINT)
            except ProcessLookupError:
                pass
        deadline = time.time() + 5
        for p in self.procs:
            try:
                p.wait(timeout=max(0.1, deadline - time.time()))
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        # gzserver sometimes leaves children behind
        subprocess.run(["pkill", "-9", "-f", "gzserver"], check=False)


def run_episode(sc: dict, model: dict, cfg: dict, workdir: Path) -> EpisodeResult:
    import rclpy
    from geometry_msgs.msg import Twist, Wrench
    from gazebo_msgs.srv import ApplyLinkWrench
    from nav_msgs.msg import Odometry
    from std_srvs.srv import Empty
    from builtin_interfaces.msg import Duration, Time

    workdir.mkdir(parents=True, exist_ok=True)
    (workdir / "world.world").write_text(WORLD)
    (workdir / "fastdds.xml").write_text(FASTDDS_PROFILE)
    # Keep ROS 2 traffic inside the pod: shards on the same network must not discover each
    # other's nodes (or one shard's /cmd_vel would reach another shard's controller).
    os.environ["ROS_AUTOMATIC_DISCOVERY_RANGE"] = "LOCALHOST"
    os.environ.pop("ROS_LOCALHOST_ONLY", None)
    os.environ["FASTRTPS_DEFAULT_PROFILES_FILE"] = str(workdir / "fastdds.xml")
    urdf = make_urdf(cfg["xacro"], sc.get("friction"), sc.get("added_mass", 0.0))
    (workdir / "robot.urdf").write_text(urdf)
    env = dict(os.environ, ROBOT_TYPE=cfg["robot_type"], RL_TYPE=model["rl_type"])
    scales = cfg["user_cmd_scales"]
    stack = Stack(workdir)
    t_wall0 = time.time()
    try:
        stack.start("gzserver", ["gzserver", "-u", "-s", "libgazebo_ros_init.so", "-s", "libgazebo_ros_factory.so",
                                 "-s", "libgazebo_ros_force_system.so",
                                 str(workdir / "world.world")], env)
        stack.start("rsp", ["ros2", "run", "robot_state_publisher", "robot_state_publisher", "--ros-args",
                            "-p", f"robot_description:={urdf}"], env)
        spawn = subprocess.run(["ros2", "run", "gazebo_ros", "spawn_entity.py", "-topic", "robot_description",
                                "-entity", "robot", "-x", "0", "-y", "0", "-z", str(cfg.get("spawn_z", 0.812)),
                                "-timeout", "60"], env=env, capture_output=True, text=True, timeout=90)
        if spawn.returncode != 0:
            raise RuntimeError(f"spawn failed: {spawn.stdout[-500:]} {spawn.stderr[-500:]}")
        hw_cmd = ["ros2", "run", cfg["hw_package"], cfg["hw_executable"], "127.0.0.1", "--ros-args",
                  "-r", f"__node:={cfg['hw_node_name']}", "-p", "use_gazebo:=true",
                  "-p", f"robot_controllers_policy_file:={model['dir']}/policy.onnx",
                  "-p", f"robot_controllers_encoder_file:={model['dir']}/encoder.onnx"]
        for pf in cfg["hw_param_files"]:
            hw_cmd += ["--params-file", pf]
        stack.start("hw", hw_cmd, env)
        hw_log = workdir / "hw.log"
        deadline = time.time() + CONTROLLER_TIMEOUT_S
        while time.time() < deadline:
            if hw_log.exists() and re.search(r"Controller '\w+' started", hw_log.read_text(errors="ignore")):
                break
            time.sleep(0.02)
        else:
            raise RuntimeError("controller did not start: " + hw_log.read_text(errors="ignore")[-1000:])
        # The controller's stand phase (stand_duration, 1 s) runs against paused physics; unpause
        # right as it ends, so the policy spends as few steps as possible on a frozen state.
        t_started = time.time()

        rclpy.init()
        node = rclpy.create_node("sim2sim_driver")
        cmd_pub = node.create_publisher(Twist, "/cmd_vel", 10)
        state = {}

        def on_odom(msg):
            state["t"] = msg.header.stamp.sec + msg.header.stamp.nanosec * 1e-9
            state["stamp"] = msg.header.stamp
            p, q, v = msg.pose.pose.position, msg.pose.pose.orientation, msg.twist.twist
            state["pos"] = (p.x, p.y, p.z)
            state["quat"] = (q.x, q.y, q.z, q.w)
            state["lin"] = (v.linear.x, v.linear.y, v.linear.z)
            state["wz"] = v.angular.z

        node.create_subscription(Odometry, "/base_truth", on_odom, 50)
        unpause = node.create_client(Empty, "/unpause_physics")
        wrench = node.create_client(ApplyLinkWrench, "/apply_link_wrench")
        for c in (unpause, wrench):
            if not c.wait_for_service(timeout_sec=20):
                raise RuntimeError(f"service {c.srv_name} not available")

        def send_cmd(cmd):
            tw = Twist()
            tw.linear.x = float(np.clip(cmd[0] / scales["lin_vel_x"], -1, 1))
            tw.linear.y = float(np.clip(cmd[1] / scales["lin_vel_y"], -1, 1))
            tw.angular.z = float(np.clip(cmd[2] / scales["ang_vel_yaw"], -1, 1))
            cmd_pub.publish(tw)

        send_cmd(command_at(sc["commands"], 0.0))
        rclpy.spin_once(node, timeout_sec=0.05)
        time.sleep(max(0.0, t_started + cfg.get("unpause_after_start_s", 1.0) - time.time()))
        unpause.call_async(Empty.Request())
        # Soft start ("elastic band"): an upward force on the base that steps down during the
        # warm-up, so the robot lands softly while the policy picks up its gait.
        for force, dur in cfg.get("support_profile", []):
            req = ApplyLinkWrench.Request()
            req.link_name = "robot::base_Link"
            req.reference_frame = "world"
            req.wrench = Wrench()
            req.wrench.force.z = float(force)
            req.duration = Duration(sec=int(dur), nanosec=int((dur % 1) * 1e9))
            req.start_time = Time(sec=0, nanosec=0)
            wrench.call_async(req)
        while "t" not in state:
            rclpy.spin_once(node, timeout_sec=0.1)
        t0, wall0 = state["t"], time.time()
        start_xy = None
        push = sc.get("push")
        push_sent = False
        push_future, push_peak = None, 0.0
        t_log, v_log, wz_log, c_log = [], [], [], []
        fell, t_fall, fall_state = False, None, None
        next_sample = 0.0
        last_cmd_pub = -1.0
        while True:
            rclpy.spin_once(node, timeout_sec=0.01)
            t = state["t"] - t0 - WARMUP_S  # scenario time; negative during the warm-up
            if t >= sc["duration"]:
                break
            if not fell and is_fallen(state["pos"][2], state["quat"]):
                fell, t_fall = True, max(0.0, t)
                fall_state = {"pos": state["pos"], "quat": state["quat"], "t": t}
                break
            cmd = command_at(sc["commands"], t) if t >= 0 else np.zeros(3)
            if t - last_cmd_pub >= 1.0 / 30:
                send_cmd(cmd)
                last_cmd_pub = t
            if push and not push_sent and t >= push["t"]:
                req = ApplyLinkWrench.Request()
                req.link_name = "robot::base_Link"
                req.reference_frame = "world"
                w = Wrench()
                w.force.x, w.force.y = float(push.get("fx", 0.0)), float(push.get("fy", 0.0))
                req.wrench = w
                req.duration = Duration(sec=0, nanosec=int(push.get("dur", 0.1) * 1e9))
                # start_time must be the current simulation time: the force system computes the
                # end as start_time + duration and drops tasks that already ended (a zero
                # start_time means the push is silently discarded)
                req.start_time = state["stamp"]
                push_future = wrench.call_async(req)
                push_sent = True
            if push_sent and t < push["t"] + 0.5:
                push_peak = max(push_peak, float(np.hypot(state["lin"][0], state["lin"][1])))
            if t >= 0 and start_xy is None:
                start_xy = np.array(state["pos"][:2])
            if t >= 0 and t >= next_sample:
                yaw = yaw_from_quat_xyzw(state["quat"])
                c, s = np.cos(yaw), np.sin(yaw)
                vx, vy = state["lin"][0], state["lin"][1]
                t_log.append(t)
                v_log.append((c * vx + s * vy, -s * vx + c * vy))
                wz_log.append(state["wz"])
                c_log.append(cmd)
                next_sample += SAMPLE_DT
        push_ok = None
        if push_future is not None:
            rclpy.spin_until_future_complete(node, push_future, timeout_sec=2.0)
            r = push_future.result()
            push_ok = bool(r and r.success)
        sim_elapsed = state["t"] - t0
        rtf = sim_elapsed / max(1e-6, time.time() - wall0)
        distance = 0.0 if start_xy is None else float(np.linalg.norm(np.array(state["pos"][:2]) - start_xy))
        node.destroy_node()
        rclpy.shutdown()
    finally:
        stack.stop()
    res = score(sc, t_log, v_log, wz_log, c_log, SAMPLE_DT, fell, t_fall, distance)
    startup_failure = bool(fell and fall_state and fall_state["t"] < -WARMUP_S + STARTUP_WINDOW_S)
    res.extra = {"rtf": round(rtf, 3), "valid": rtf >= MIN_RTF and not startup_failure,
                 "startup_failure": startup_failure, "wall_s": round(time.time() - t_wall0, 1),
                 "fall_t": None if fall_state is None else round(fall_state["t"], 3),
                 "push_ok": push_ok, "push_peak_speed": round(push_peak, 3) if push else None}
    return res


if __name__ == "__main__":
    # Manual test: gazebo_episode.py <scenario.json> <model_dir> <rl_type> <stack_config.json>
    sc = json.loads(Path(sys.argv[1]).read_text())
    cfg = json.loads(Path(sys.argv[4]).read_text())
    r = run_episode(sc, {"dir": sys.argv[2], "rl_type": sys.argv[3]}, cfg, Path(tempfile.mkdtemp(prefix="ep-")))
    print(json.dumps(r.__dict__, default=str))
