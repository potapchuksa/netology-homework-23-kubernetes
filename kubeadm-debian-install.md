🏗️ Элементы кластера (Глоссарий для старта)

1. **containerd** — это «движок». Сам по себе Kubernetes не умеет запускать контейнеры, ему нужен помощник. `containerd` — это современный стандартный движок, который скачивает образы и запускает их.
2. **kubeadm** — это «прораб». Инструмент командной строки, который автоматически генерирует сертификаты, создает конфигурационные файлы и запускает основные компоненты кластера. Он делает всю грязную работу по инициализации.
3. **kubelet** — это «бригадир на месте». Агент, который устанавливается на **каждую** машину (ноду) в кластере. Он слушает приказы от главного сервера и следит, чтобы нужные контейнеры были запущены и работали.
4. **kubectl** — это «пульт управления». Клиентская утилита, которую вы будете использовать на своем локальном компьютере, чтобы отдавать команды кластеру (например, `kubectl get nodes`).
5. **CNI (Container Network Interface), например Calico** — это «система коммуникаций». По умолчанию поды (контейнеры в K8s) не видят друг друга. Плагин CNI выдает им IP-адреса и настраивает маршрутизацию между ними.

# Пошаговая инструкция (для Debian/Ubuntu)
Мы разделим процесс на две части: настройка Виртуальной Машины (ВМ) и настройка Вашего Локального компьютера.

> ⚠️ Важно: Замените `<ВНЕШНИЙ_IP>` в командах ниже на реальный белый IP-адрес вашей виртуальной машины (например, `123.45.67.89`).

## ЭТАП 1: Подготовка ВМ (Выполняем на виртуальной машине)

### 1. Отключаем Swap

Kubernetes требует точного контроля над памятью. Swap (файл подкачки на диске) эту логику ломает, поэтому его отключают.

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

### 2. Настраиваем сетевые модули ядра

Разрешаем ядру пересылать сетевые пакеты между интерфейсами (это нужно, чтобы поды могли общаться с внешним миром).

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

## ЭТАП 2: Установка движка и компонентов (На ВМ)

### 3. Устанавливаем containerd

```bash
sudo apt-get update
sudo apt-get install -y containerd

# Создаем конфигурацию по умолчанию и включаем поддержку systemd (важно для стабильности)
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd
```

### 4. Устанавливаем kubelet, kubeadm, kubectl

Добавляем официальный репозиторий Kubernetes (используем стабильную ветку 1.30).

```bash
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl # Запрещаем автообновление, чтобы кластер не сломался сам по себе
```

## ЭТАП 3: Инициализация кластера (На ВМ)

### 5. Запускаем "прораба" (kubeadm)

Здесь мы решаем задачу ДЗ по сертификатам. Флаг `--apiserver-cert-extra-sans` добавляет ваш внешний IP в список доверенных адресов сертификата API-сервера.

```bash
sudo kubeadm init \
  --apiserver-advertise-address=$(hostname -I | awk '{print $1}') \
  --apiserver-cert-extra-sans=<ВНЕШНИЙ_IP> \
  --pod-network-cidr=192.168.0.0/16
```

*(Замените `<ВНЕШНИЙ_IP>` на реальный IP, например `--apiserver-cert-extra-sans=123.45.67.89`)*

> 📌 ВНИМАНИЕ: В конце вывода этой команды будет блок `Your Kubernetes control-plane has initialized successfully!`. Там будут команды для обычного пользователя. Скопируйте их и выполните (обычно это `mkdir -p $HOME/.kube` и `cp ...`). Это даст вашему текущему пользователю права на управление кластером.

### 6. Устанавливаем сетевой плагин (Calico)

Без этого шага нода будет в статусе `NotReady`.

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
```

Подождите 1-2 минуты и проверьте статус ноды:

```bash
kubectl get nodes
```

*Должно быть: `STATUS: Ready`.*

---

## ЭТАП 4: Установка Dashboard (На ВМ)

### 7. Разворачиваем Dashboard

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml
```

### 8. Создаем учетную запись администратора для входа

Создайте файл `dashboard-admin.yaml` (например, через `vim dashboard-admin.yaml`) и вставьте туда:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
```

Примените его:

```bash
kubectl apply -f dashboard-admin.yaml
```

### 9. Получаем токен для входа

Эта команда сгенерирует длинную строку. Скопируйте её целиком — это ваш пароль для Dashboard.

```bash
kubectl -n kubernetes-dashboard create token admin-user
```

## ЭТАП 5: Настройка локального компьютера (Ваша рабочая машина)

Теперь мы свяжем ваш локальный `kubectl` с удаленным кластером, как требует задание.

### 10. Устанавливаем kubectl локально

Если у вас Windows, скачайте `.exe` с официального сайта, если macOS — `brew install kubectl`.

✅ Правильный и современный способ установки kubectl (для Debian/Ubuntu):

Используйте официальный репозиторий Kubernetes.

```bash
# 1. Обновляем пакеты и устанавливаем необходимые утилиты
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

# 2. Скачиваем официальный GPG-ключ репозитория Kubernetes
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# 3. Добавляем репозиторий (можете заменить v1.36 на актуальную версию)
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

# 4. Устанавливаем kubectl
sudo apt-get update
sudo apt-get install -y kubectl

# 5. Проверяем версию
kubectl version --client
```

> (Примечание: версия v1.36 в ссылке актуальна на середину 2026 года, вы можете проверить последнюю стабильную ветку на [kubernetes.io](https://kubernetes.io/releases/)).

### 11. Копируем конфигурацию

Вернитесь на ВМ и выведите конфиг:

```bash
cat ~/.kube/config
```

Скопируйте весь вывод (от `apiVersion:` до конца).

На локальной машине создайте или откройте файл `~/.kube/config` (на Windows это `C:\Users\ВашеИмя\.kube\config`) и вставьте туда скопированный текст.

### 12. Проверяем подключение

На локальной машине выполните:

```bash
kubectl get nodes
```

*Если вы видите вашу ноду в статусе `Ready` — поздравляю, вы успешно подключились!*

### 13. Делаем проброс порта для ДЗ

На локальной машине выполните:

```bash
kubectl port-forward -n kubernetes-dashboard service/kubernetes-dashboard 10443:443 --address 0.0.0.0
```

### 14. Финал

Откройте браузер на локальной машине и перейдите по адресу:

👉 `https://localhost:10443`

*(Игнорируйте предупреждение браузера о "небезопасном соединении" — это нормально для самоподписанных сертификатов).*

Вставьте скопированный ранее токен и войдите.

Сделайте скриншоты:

1. Вывода kubectl get nodes -o wide в терминале.
2. Открытой страницы Dashboard с видимым интерфейсом.

---
