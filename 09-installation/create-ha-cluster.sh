#!/bin/bash
set -e

# Проверка root-прав
if [ "$EUID" -ne 0 ]; then
  echo "Запустите: sudo $0"
  exit 1
fi

# === КОНФИГУРАЦИЯ ===
REAL_USER="${SUDO_USER:-$USER}"
SSH_KEY=$(cat "/home/$REAL_USER/.ssh/id_rsa.pub")
SSH_KEY_PATH="/home/$REAL_USER/.ssh/id_rsa.pub"
BRIDGE="br0"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VM_DIR="/var/lib/libvirt/images"
BASE_IMG="$VM_DIR/debian-13-generic-amd64-daily.qcow2"
VM_TPL="$VM_DIR/k8s-base-template.qcow2"
DISK_SIZE="10G"
MASTER_TPL="$SCRIPT_DIR/k8s-master-user-data.tpl"
WORKER_TPL="$SCRIPT_DIR/k8s-worker-user-data.tpl"

# Сетевая конфигурация
GATEWAY="192.168.100.1"
VIP_ADDRESS="192.168.100.160"

# === ПРОВЕРКИ ===
if [ ! -f "$SSH_KEY_PATH" ]; then
  echo "❌ SSH-ключ не найден: $SSH_KEY"
  exit 1
fi

# Создаём шаблон, если его нет
if [ ! -f "$VM_TPL" ]; then
  echo "=== Создание шаблона $VM_TPL ==="
  qemu-img create -f qcow2 -b "$BASE_IMG" -F qcow2 "$VM_TPL" "$DISK_SIZE"
  echo "✅ Шаблон создан"
  echo ""
fi

if [ ! -f "$MASTER_TPL" ]; then
  echo "❌ Шаблон $MASTER_TPL не найден"
  exit 1
fi

if [ ! -f "$WORKER_TPL" ]; then
  echo "❌ Шаблон $WORKER_TPL не найден"
  exit 1
fi

mkdir -p "$VM_DIR"

# Массив ВМ: "имя:роль:RAM:vCPU:IP:keepalived_state:keepalived_priority"
VMS=(
  "k8s-ha-master-1:master:4096:2:192.168.100.161:BACKUP:100"
  "k8s-ha-master-2:master:4096:2:192.168.100.162:BACKUP:90"
  "k8s-ha-master-3:master:4096:2:192.168.100.163:BACKUP:80"
  "k8s-ha-worker-1:worker:2048:2:192.168.100.164"
  "k8s-ha-worker-2:worker:2048:2:192.168.100.165"
  "k8s-ha-worker-3:worker:2048:2:192.168.100.166"
  "k8s-ha-worker-4:worker:2048:2:192.168.100.167"
)

for entry in "${VMS[@]}"; do
  IFS=':' read -r NAME ROLE RAM VCPU STATIC_IP KEEPALIVED_STATE KEEPALIVED_PRIORITY <<< "$entry"
  VM_DISK="$VM_DIR/${NAME}.qcow2"
  USER_DATA="$VM_DIR/${NAME}-user-data"
  META_DATA="$VM_DIR/${NAME}-meta-data"
  
  echo "=== Создание ВМ: $NAME ($ROLE) IP=$STATIC_IP ==="
  
  # Создаём диск
  qemu-img create -f qcow2 -b "$VM_TPL" -F qcow2 "$VM_DISK"
  
  # Экспортируем переменные для envsubst
  export HOSTNAME="$NAME"
  export SSH_KEY
  export STATIC_IP
  export GATEWAY
  export NODE_IP="$STATIC_IP"
  export VIP_ADDRESS
  export INTERFACE_NAME="enp1s0"
  export MASTER1_IP="192.168.100.161"
  export MASTER2_IP="192.168.100.162"
  export MASTER3_IP="192.168.100.163"
  
  if [ "$ROLE" = "master" ]; then
    export KEEPALIVED_STATE
    export KEEPALIVED_PRIORITY
    envsubst < "$MASTER_TPL" > "$USER_DATA"
  else
    envsubst < "$WORKER_TPL" > "$USER_DATA"
  fi
  
  echo "instance-id: ${NAME}" > "$META_DATA"

  # Создаём network-config
  NETWORK_CONFIG="$VM_DIR/${NAME}-network-config"
  cat > "$NETWORK_CONFIG" << EOF
version: 2
renderer: networkd
ethernets:
  enp1s0:
    dhcp4: false
    addresses:
      - ${STATIC_IP}/24
    gateway4: ${GATEWAY}
    nameservers:
      addresses: [8.8.8.8, 1.1.1.1]
EOF

  # Создаём ВМ
  virt-install \
    --name "$NAME" \
    --memory "$RAM" \
    --vcpus "$VCPU" \
    --disk path="$VM_DISK",format=qcow2 \
    --import \
    --os-variant debian11 \
    --network bridge="$BRIDGE",model=virtio \
    --cloud-init user-data="$USER_DATA",meta-data="$META_DATA",network-config="$NETWORK_CONFIG" \
    --graphics spice \
    --video virtio \
    --noautoconsole
  
  echo "✅ ВМ $NAME создана с IP $STATIC_IP"
  echo "   Диск: $VM_DISK"
  echo ""
done

echo "=== Все ВМ созданы! ==="
echo "Ожидайте 3-5 минут, пока cloud-init завершит установку..."
