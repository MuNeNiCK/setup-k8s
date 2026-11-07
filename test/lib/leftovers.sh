#!/bin/sh
# Run on a VM as root after "setup-k8s.sh cleanup": print what is left of a
# Kubernetes installation (one item per line; nothing when clean).

for p in kubelet kube-apiserver kube-controller-manager kube-scheduler etcd kube-proxy kube-vip; do
    pgrep -x "$p" >/dev/null 2>&1 && echo "process:$p"
done
for b in kubeadm kubelet kubectl crio; do
    command -v "$b" >/dev/null 2>&1 && echo "binary:$(command -v "$b")"
done
if command -v dpkg-query >/dev/null 2>&1; then
    for p in kubeadm kubelet kubectl cri-tools kubernetes-cni cri-o; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q ' installed$' && echo "package:$p"
    done
    apt-mark showhold 2>/dev/null | grep -E '^(kube|cri-tools$|cri-o$)' | sed 's/^/hold:/'
fi
if command -v rpm >/dev/null 2>&1; then
    for p in kubeadm kubelet kubectl cri-tools kubernetes-cni cri-o; do
        rpm -q "$p" >/dev/null 2>&1 && echo "package:$p"
    done
fi
if command -v pacman >/dev/null 2>&1; then
    for p in kubeadm kubelet kubectl crictl cni-plugins cri-o; do
        pacman -Qq 2>/dev/null | grep -qxF "$p" && echo "package:$p"
    done
fi
if command -v apk >/dev/null 2>&1; then
    for p in kubeadm kubelet kubectl kubelet-openrc cri-tools cni-plugins cri-o; do
        apk info -e "$p" >/dev/null 2>&1 && echo "package:$p"
    done
fi
if command -v semodule >/dev/null 2>&1; then
    semodule -l 2>/dev/null | awk '{print $1}' | grep -x 'setup-k8s.*' | sed 's/^/selinux-module:/'
fi
if command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive locks 2>/dev/null | grep -o -E '\b(kubeadm|kubelet|kubectl|cri-tools|cri-o)\b' | sort -u | sed 's/^/lock:/'
fi
for f in /etc/yum.repos.d/kubernetes.repo /etc/yum.repos.d/cri-o.repo /etc/yum.repos.d/docker.repo \
         /etc/yum.repos.d/containers.repo \
         /etc/apt/sources.list.d/kubernetes.list /etc/apt/sources.list.d/cri-o.list /etc/apt/sources.list.d/docker.list \
         /etc/apt/keyrings/kubernetes.gpg /etc/apt/keyrings/cri-o.gpg /etc/apt/keyrings/docker.gpg \
         /etc/zypp/repos.d/kubernetes.repo /etc/zypp/repos.d/cri-o.repo /etc/zypp/repos.d/containers.repo \
         /etc/default/kubelet /etc/sysconfig/kubelet /etc/systemd/system/kubelet.service /etc/init.d/kubelet \
         /etc/crictl.yaml; do
    [ -e "$f" ] && echo "file:$f"
done
[ -d /etc/kubernetes ] && [ -n "$(ls -A /etc/kubernetes 2>/dev/null)" ] && echo "directory:/etc/kubernetes"
[ -d /etc/systemd/system/kubelet.service.d ] && echo "directory:/etc/systemd/system/kubelet.service.d"
if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet kubelet 2>/dev/null && echo "service:kubelet active"
    [ "$(systemctl is-enabled kubelet 2>/dev/null)" = enabled ] && echo "service:kubelet enabled"
elif command -v rc-service >/dev/null 2>&1; then
    rc-service kubelet status >/dev/null 2>&1 && echo "service:kubelet active"
fi
true
