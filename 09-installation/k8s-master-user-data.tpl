#cloud-config
hostname: ${HOSTNAME}

package_update: true
package_upgrade: true

packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - gnupg
  - containerd
  - qemu-guest-agent
  - keepalived
  - haproxy

write_files:
  - path: /etc/modules-load.d/k8s.conf
    content: |
      overlay
      br_netfilter

  - path: /etc/sysctl.d/k8s.conf
    content: |
      net.bridge.bridge-nf-call-iptables  = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.ip_forward                 = 1

  - path: /etc/containerd/config.toml
    content: |
      version = 2
      [plugins."io.containerd.grpc.v1.cri".containerd]
        snapshotter = "overlayfs"
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            SystemdCgroup = true

  - path: /etc/keepalived/keepalived.conf
    content: |
      vrrp_script check_apiserver {
        script "/usr/bin/curl -k --silent https://localhost:6443/healthz > /dev/null"
        interval 3
        weight -2
        fall 10
        rise 2
      }

      vrrp_instance VI_1 {
          state ${KEEPALIVED_STATE}
          interface ${INTERFACE_NAME}
          virtual_router_id 51
          priority ${KEEPALIVED_PRIORITY}
          authentication {
              auth_type PASS
              auth_pass secret
          }
          virtual_ipaddress {
              ${VIP_ADDRESS}
          }
          track_script {
              check_apiserver
          }
      }

  - path: /etc/haproxy/haproxy.cfg
    content: |
      global
          log /dev/log local0
          log /dev/log local1 notice
          chroot /var/lib/haproxy
          stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
          stats timeout 30s
          user haproxy
          group haproxy
          daemon

      defaults
          log global
          mode tcp
          option tcplog
          option dontlognull
          timeout connect 5000
          timeout client 50000
          timeout server 50000

      frontend kubernetes-apiserver
          bind *:8443
          mode tcp
          option tcplog
          default_backend kubernetes-apiserver

      backend kubernetes-apiserver
          mode tcp
          option tcp-check
          balance roundrobin
          server k8s-master-1 ${MASTER1_IP}:6443 check
          server k8s-master-2 ${MASTER2_IP}:6443 check
          server k8s-master-3 ${MASTER3_IP}:6443 check

  - path: /etc/default/kubelet
    content: |
      KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}

runcmd:
  - modprobe overlay
  - modprobe br_netfilter
  - sysctl --system
  - swapoff -a
  - sed -i '/swap/d' /etc/fstab
  - systemctl daemon-reload
  - systemctl enable --now containerd
  - systemctl enable --now keepalived
  - systemctl enable --now haproxy
  
  # Установка Kubernetes с обходом строгой проверки GPG в Debian 13
  - curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  - echo 'deb [trusted=yes] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
  - apt-get update
  - apt-get install -y kubelet kubeadm kubectl
  - apt-mark hold kubelet kubeadm kubectl

users:
  - name: sergey
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: users, sudo
    shell: /bin/bash
    lock_passwd: false
    passwd: 12345678
    ssh_authorized_keys:
      - ${SSH_KEY}
