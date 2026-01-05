#!/bin/bash
# Kubernetes install script for Ubuntu 24.04 (Noble)

set -eE

#####################################
# error handling
#####################################
function err_report() {
  echo "Error on line $(caller)" >&2
  exec >&3 2>&3 3>&-
  cat "$LOG_FILE"
  cleanup_tmp
}
trap err_report ERR

function cleanup_tmp() {
  rm -rf "$TMP_DIR"
}
trap cleanup_tmp EXIT

#####################################
# help
#####################################
function show_help(){
  echo "USAGE:"
  echo "$0 -c   (control plane)"
  echo "$0      (worker)"
  echo "$0 -s   (single-node)"
  echo "$0 -v   (verbose)"
}

#####################################
# distro check (Ubuntu 24.04 only)
#####################################
function check_linux_distribution(){
  echo "Checking Linux distribution"
  source /etc/os-release
  if [[ "$VERSION_ID" != "24.04" ]]; then
    echo "ERROR: This script supports ONLY Ubuntu 24.04"
    exit 1
  fi
}

#####################################
# disable swap
#####################################
function disable_swap(){
  echo "Disabling swap"
  swapoff -a || true
  sed -i '/\sswap\s/ s/^/#/' /etc/fstab
}

#####################################
# base packages
#####################################
function install_packages(){
  echo "Installing base packages"
  apt-get update
  apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    jq
}

#####################################
# kernel + sysctl
#####################################
function configure_system(){
  echo "Configuring kernel and sysctl"
  cat <<EOF >/etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

  cat <<EOF >/etc/sysctl.d/99-kubernetes.conf
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF

  modprobe overlay
  modprobe br_netfilter
  sysctl --system
}

#####################################
# install containerd (Ubuntu repo = v2.x)
#####################################
function install_containerd(){
  echo "Installing containerd"
  apt-get update
  apt-get install -y containerd
}

#####################################
# configure containerd (CRI + systemd cgroups)
#####################################
function configure_containerd(){
  echo "Configuring containerd"
  mkdir -p /etc/containerd

  containerd config default >/etc/containerd/config.toml

  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' \
    /etc/containerd/config.toml

  # Ensure CRI is NOT disabled
  sed -i '/disabled_plugins/d' /etc/containerd/config.toml

  # Force containerd to use this config
  mkdir -p /etc/systemd/system/containerd.service.d
  cat <<EOF >/etc/systemd/system/containerd.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/bin/containerd --config /etc/containerd/config.toml
EOF

  systemctl daemon-reexec
  systemctl daemon-reload
  systemctl restart containerd
}

#####################################
# crictl config
#####################################
function configure_crictl(){
  echo "Configuring crictl"
  cat <<EOF >/etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
EOF
}

#####################################
# Kubernetes packages (stable, explicit)
#####################################
function install_kubernetes_packages(){
  echo "Installing Kubernetes packages"

  mkdir -p /etc/apt/keyrings
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key |
    gpg --dearmor -o /etc/apt/keyrings/kubernetes.gpg

  cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /
EOF

  apt-get update
  apt-get install -y kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl
}

#####################################
# kubelet config
#####################################
function configure_kubelet(){
  echo "Configuring kubelet"
  cat <<EOF >/etc/default/kubelet
KUBELET_EXTRA_ARGS="--container-runtime-endpoint=unix:///run/containerd/containerd.sock"
EOF
}

#####################################
# start services
#####################################
function start_services(){
  systemctl enable containerd
  systemctl restart containerd
  systemctl enable kubelet
  systemctl restart kubelet
}

#####################################
# kubeadm init
#####################################
function kubeadm_init(){
  echo "Initializing control plane"
  kubeadm init \
    --cri-socket=unix:///run/containerd/containerd.sock \
    --pod-network-cidr=192.168.0.0/16
}

#####################################
# kubeconfig
#####################################
function configure_kubeconfig(){
  mkdir -p $HOME/.kube
  cp /etc/kubernetes/admin.conf $HOME/.kube/config
  chown $(id -u):$(id -g) $HOME/.kube/config
}

#####################################
# install calico
#####################################
function install_cni(){
  echo "Installing Calico CNI"
  kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml
}

#####################################
# MAIN
#####################################
TMP_DIR=$(mktemp -d)
LOG_FILE=$TMP_DIR/install.log

CONTROL_NODE=false
SINGLE_NODE=false
VERBOSE=false

while getopts "h?cvs" opt; do
  case "$opt" in
    h|\?) show_help; exit 0 ;;
    c) CONTROL_NODE=true ;;
    s) SINGLE_NODE=true; CONTROL_NODE=true ;;
    v) VERBOSE=true ;;
  esac
done

check_linux_distribution
disable_swap
install_packages
configure_system
install_containerd
configure_containerd
configure_crictl
install_kubernetes_packages
configure_kubelet
start_services

if [[ "$CONTROL_NODE" == "true" ]]; then
  kubeadm_init
  configure_kubeconfig
  install_cni

  if [[ "$SINGLE_NODE" == "true" ]]; then
    kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- || true
  fi

  echo "Cluster initialized successfully"
  kubeadm token create --print-join-command --ttl 0
else
  echo "Worker node ready. Use join command from control plane."
fi
