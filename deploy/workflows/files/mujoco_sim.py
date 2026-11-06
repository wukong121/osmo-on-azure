"""Headless MuJoCo smoke simulation: double pendulum + falling boxes (CPU, no rendering)."""
import csv, os, sys, time
import mujoco

XML = """
<mujoco model="osmo-mujoco-smoke">
  <option timestep="0.002" gravity="0 0 -9.81"/>
  <worldbody>
    <geom name="floor" type="plane" size="5 5 0.1"/>
    <body name="link1" pos="0 0 2">
      <joint name="hinge1" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 0.5 0 0" size="0.04" mass="1"/>
      <body name="link2" pos="0.5 0 0">
        <joint name="hinge2" type="hinge" axis="0 1 0"/>
        <geom type="capsule" fromto="0 0 0 0.5 0 0" size="0.04" mass="1"/>
      </body>
    </body>
    <body name="box1" pos="1.5 0 1"><freejoint/><geom type="box" size="0.1 0.1 0.1" mass="0.5"/></body>
    <body name="box2" pos="1.6 0 1.5"><freejoint/><geom type="box" size="0.1 0.1 0.1" mass="0.5"/></body>
  </worldbody>
</mujoco>
"""

out_dir = sys.argv[1] if len(sys.argv) > 1 else "."
sim_seconds = float(os.environ.get("SIM_SECONDS", "10"))
os.makedirs(out_dir, exist_ok=True)

model = mujoco.MjModel.from_xml_string(XML)
data = mujoco.MjData(model)
data.qpos[0] = 1.0  # initial pendulum angle
steps = int(sim_seconds / model.opt.timestep)

rows = []
start = time.perf_counter()
for i in range(steps):
    mujoco.mj_step(model, data)
    if i % 50 == 0:
        rows.append([round(data.time, 3), data.qpos[0], data.qpos[1], data.body("box1").xpos[2]])
wall = time.perf_counter() - start

box_z = data.body("box1").xpos[2]
print(f"MuJoCo {mujoco.__version__}: {steps} steps ({data.time:.1f} s simulated) "
      f"in {wall:.2f} s wall, {steps / wall:,.0f} steps/s")
print(f"box1 final height: {box_z:.3f} m (resting on the floor at ~0.1 m)")
assert 0.05 < box_z < 0.15, "box1 did not come to rest on the floor"

with open(os.path.join(out_dir, "trajectory.csv"), "w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(["time", "hinge1", "hinge2", "box1_z"])
    writer.writerows(rows)
with open(os.path.join(out_dir, "summary.txt"), "w") as f:
    f.write(f"mujoco={mujoco.__version__} steps={steps} wall_s={wall:.3f} "
            f"steps_per_s={steps / wall:.0f} box1_z={box_z:.4f}\n")
print(f"Wrote {len(rows)} trajectory rows to {out_dir}")
