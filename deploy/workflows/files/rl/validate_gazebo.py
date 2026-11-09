"""Sim2sim validation in Gazebo (gz-sim 8, DART): run the Isaac Lab Cartpole ONNX policy.

Gazebo is driven in-process through the gz.sim8 Python bindings (TestFixture), so every control
step is synchronous: the pre-update callback applies the joint force, the server runs
DECIMATION physics iterations, and the post-update callback reads the joint state. No ROS 2 or
gz-transport round trips are involved.

Reset: Gazebo applies joint position/velocity resets during the next physics update, so each
episode starts with one zero-force reset iteration; the state after it is the initial state.

Usage: validate_gazebo.py --policy policy.onnx --data-dir <dir with cartpole.sdf, scenarios.json> --out <dir>
"""

from __future__ import annotations

import argparse
from pathlib import Path

from gz.sim8 import Joint, Model, TestFixture, World, world_entity

from sim2sim_common import DECIMATION, Policy, load_scenarios, run_episode, write_report


class GazeboCartpole:
    def __init__(self, sdf_path: str):
        self.fixture = TestFixture(sdf_path)
        self.joints: dict[str, Joint] = {}
        self.force = 0.0
        self.pending_reset: dict | None = None
        self.state = (0.0, 0.0, 0.0, 0.0)
        self.fixture.on_pre_update(self._pre_update)
        self.fixture.on_post_update(self._post_update)
        self.fixture.finalize()
        self.server = self.fixture.server()

    def _pre_update(self, info, ecm):
        if not self.joints:
            model = Model(World(world_entity(ecm)).model_by_name(ecm, "cartpole"))
            for name in ("slider_to_cart", "cart_to_pole"):
                joint = Joint(model.joint_by_name(ecm, name))
                joint.enable_position_check(ecm, True)
                joint.enable_velocity_check(ecm, True)
                self.joints[name] = joint
        if self.pending_reset is not None:
            s = self.pending_reset
            self.joints["slider_to_cart"].reset_position(ecm, [s["cart_pos"]])
            self.joints["slider_to_cart"].reset_velocity(ecm, [s["cart_vel"]])
            self.joints["cart_to_pole"].reset_position(ecm, [s["pole_angle"]])
            self.joints["cart_to_pole"].reset_velocity(ecm, [s["pole_vel"]])
            self.pending_reset = None
        else:
            # JointForceCmd is cleared after every physics update, so apply it on each iteration
            self.joints["slider_to_cart"].set_force(ecm, [self.force])

    def _post_update(self, info, ecm):
        slider, pole = self.joints["slider_to_cart"], self.joints["cart_to_pole"]
        x, theta = slider.position(ecm), pole.position(ecm)
        v, omega = slider.velocity(ecm), pole.velocity(ecm)
        if x and theta and v and omega:
            self.state = (x[0], theta[0], v[0], omega[0])

    def reset(self, scenario: dict):
        self.pending_reset = scenario
        self.force = 0.0
        self.server.run(True, 1, False)
        # Guard against a silently broken setup (e.g. missing physics plugin): the joints must
        # actually be at the requested initial state after the reset iteration.
        x, theta = self.state[0], self.state[1]
        if abs(x - scenario["cart_pos"]) > 0.05 or abs(theta - scenario["pole_angle"]) > 0.05:
            raise SystemExit(f"Gazebo reset failed for scenario {scenario['id']}: state {self.state}")
        return self.state

    def step(self, force: float):
        self.force = force
        self.server.run(True, DECIMATION, False)
        return self.state


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", required=True)
    parser.add_argument("--data-dir", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    sim = GazeboCartpole(str(Path(args.data_dir) / "cartpole.sdf"))
    sim.server.run(True, 1, False)  # first update creates the joint state components
    policy = Policy(args.policy)
    scenarios, steps = load_scenarios(args.data_dir)
    episodes = [run_episode(sim.reset, sim.step, policy, s, steps) for s in scenarios]
    write_report(args.out, "gazebo-gz-sim-8-dart", episodes)


if __name__ == "__main__":
    main()
