# Gazebo Classic 11 + ROS 2 Iron image with a vendor point-foot deployment stack, for the
# Gazebo sim2sim shards of deploy/workflows/legged-validate.yaml.
#
# The four source repositories are build arguments (the vendor's open-source robot description,
# low-level SDK, Gazebo hardware plugin and ros2_control RL controller). Built inside the cluster
# by deploy/workflows/build-image.yaml and pushed to the private ACR.
FROM osrf/ros:iron-desktop-full

ARG ROBOT_DESCRIPTION_REPO
ARG SDK_REPO
ARG GAZEBO_REPO
ARG CONTROLLER_REPO
ARG ONNXRUNTIME_VERSION=1.10.0

ENV DEBIAN_FRONTEND=noninteractive ROS_WS=/ws

# ROS 2 Iron is end-of-life: the base image already points apt at the frozen Iron snapshot.
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      ros-iron-gazebo-ros-pkgs ros-iron-gazebo-ros2-control ros-iron-urdf ros-iron-kdl-parser \
      ros-iron-hardware-interface ros-iron-controller-manager ros-iron-controller-interface \
      ros-iron-controller-manager-msgs ros-iron-control-msgs ros-iron-control-toolbox \
      ros-iron-ros2-control ros-iron-ros2-controllers ros-iron-xacro ros-iron-robot-state-publisher \
      libeigen3-dev libboost-all-dev liburdfdom-dev wget git python3-colcon-common-extensions \
      python3-yaml python3-numpy \
    && rm -rf /var/lib/apt/lists/*

# The vendor controller links against the ONNX Runtime C++ library
RUN wget -q https://github.com/microsoft/onnxruntime/releases/download/v${ONNXRUNTIME_VERSION}/onnxruntime-linux-x64-${ONNXRUNTIME_VERSION}.tgz \
    && tar xf onnxruntime-linux-x64-${ONNXRUNTIME_VERSION}.tgz \
    && cp -a onnxruntime-linux-x64-${ONNXRUNTIME_VERSION}/include/* /usr/include \
    && cp -a onnxruntime-linux-x64-${ONNXRUNTIME_VERSION}/lib/* /usr/lib \
    && rm -rf onnxruntime-linux-x64-*

RUN mkdir -p ${ROS_WS}/src && cd ${ROS_WS}/src \
    && git clone --depth 1 "${ROBOT_DESCRIPTION_REPO}" robot-description \
    && git clone --depth 1 "${SDK_REPO}" sdk \
    && git clone --depth 1 "${GAZEBO_REPO}" gazebo \
    && git clone --depth 1 "${CONTROLLER_REPO}" controller \
    && for d in robot-description sdk gazebo controller; do echo "$d $(git -C $d rev-parse HEAD)"; done > ${ROS_WS}/sources.txt \
    && rm -rf */.git \
    && cd ${ROS_WS} && . /opt/ros/iron/setup.sh \
    && colcon build --cmake-args -DCMAKE_BUILD_TYPE=Release \
    && rm -rf build log

RUN printf '%s\n' '. /opt/ros/iron/setup.sh' ". ${ROS_WS}/install/setup.sh" '. /usr/share/gazebo/setup.sh' > /etc/profile.d/ros.sh
