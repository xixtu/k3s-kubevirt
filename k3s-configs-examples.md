# Configurations et Exemples - K3s Cluster

Ce document contient tous les fichiers de configuration YAML, scripts et exemples pratiques pour déployer et gérer le cluster.

---

## Table des matières

1. [Configuration système Rocky Linux](#configuration-système-rocky-linux)
2. [Configuration K3s](#configuration-k3s)
3. [MetalLB Configuration](#metallb-configuration)
4. [Longhorn Configuration](#longhorn-configuration)
5. [KubeVirt - Exemples VMs](#kubevirt---exemples-vms)
6. [Ingress & SSL](#ingress--ssl)
7. [Monitoring Stack](#monitoring-stack)
8. [Network Policies](#network-policies)
9. [Backup Velero](#backup-velero)
10. [Exemples Workloads](#exemples-workloads)

---

## Configuration système Rocky Linux

### Script d'initialisation nœud

```bash
#!/bin/bash
# init-k3s-node.sh - Script d'initialisation pour Rocky Linux 9

set -e

NODE_IP=$1
NODE_NAME=$2

if [ -z "$NODE_IP" ] || [ -z "$NODE_NAME" ]; then
    echo "Usage: $0 <node_ip> <node_name>"
    echo "Example: $0 192.168.1.11 k3s-node-1"
    exit 1
fi

echo "===== Initialisation nœud K3s: $NODE_NAME ($NODE_IP) ====="

# 1. Mise à jour système
echo "[1/8] Mise à jour système..."
dnf update -y

# 2. Installation packages requis
echo "[2/8] Installation packages..."
dnf install -y \
    iscsi-initiator-utils \
    nfs-utils \
    curl \
    wget \
    vim \
    git \
    htop \
    net-tools

# 3. Configuration hostname
echo "[3/8] Configuration hostname..."
hostnamectl set-hostname "${NODE_NAME}.local"

# 4. Configuration firewalld
echo "[4/8] Configuration firewall..."
systemctl enable --now firewalld

# Ports K3s
firewall-cmd --permanent --add-port=6443/tcp    # K3s API
firewall-cmd --permanent --add-port=10250/tcp   # Kubelet
firewall-cmd --permanent --add-port=2379-2380/tcp # etcd

# Ports CNI Flannel
firewall-cmd --permanent --add-port=8472/udp    # VXLAN

# Ports Longhorn
firewall-cmd --permanent --add-port=9500-9504/tcp

# Ports services (HTTP/HTTPS)
firewall-cmd --permanent --add-port=80/tcp
firewall-cmd --permanent --add-port=443/tcp

# Reload firewall
firewall-cmd --reload

echo "Firewall rules:"
firewall-cmd --list-all

# 5. SELinux - vérifier mode Enforcing
echo "[5/8] Vérification SELinux..."
if [ "$(getenforce)" != "Enforcing" ]; then
    echo "WARNING: SELinux n'est pas en mode Enforcing!"
    echo "Activer avec: setenforce 1"
fi

# 6. Modules kernel pour KVM
echo "[6/8] Configuration modules kernel..."
modprobe kvm kvm_intel vhost_net vhost_vsock

cat > /etc/modules-load.d/k3s-kubevirt.conf <<EOF
kvm
kvm_intel
vhost_net
vhost_vsock
EOF

# Vérifier support virtualisation
if ! grep -E 'vmx|svm' /proc/cpuinfo > /dev/null; then
    echo "WARNING: CPU ne supporte pas la virtualisation matérielle!"
else
    echo "✓ Virtualisation matérielle supportée"
fi

# 7. iSCSI pour Longhorn
echo "[7/8] Configuration iSCSI..."
systemctl enable --now iscsid
echo "InitiatorName=$(iscsi-iname)" > /etc/iscsi/initiatorname.iscsi
systemctl restart iscsid

# 8. Désactiver swap (K8s requirement)
echo "[8/8] Désactivation swap..."
swapoff -a
sed -i '/swap/d' /etc/fstab

echo ""
echo "===== Initialisation terminée ====="
echo ""
echo "Prochaines étapes:"
echo "1. Installer K3s (voir README.md)"
echo "2. Configurer Longhorn disks (/dev/sdb, /dev/sdc)"
echo ""
echo "Informations nœud:"
echo "  Hostname: $(hostname)"
echo "  IP: $NODE_IP"
echo "  OS: $(cat /etc/redhat-release)"
echo "  Kernel: $(uname -r)"
echo "  Virtualisation: $(lscpu | grep Virtualization || echo 'Non détecté')"
echo ""
```

### Fichier /etc/hosts pour tous les nœuds

```bash
# /etc/hosts
127.0.0.1   localhost localhost.localdomain
::1         localhost localhost.localdomain

# Cluster K3s nodes
192.168.1.11    k3s-node-1.local k3s-node-1
192.168.1.12    k3s-node-2.local k3s-node-2
192.168.1.13    k3s-node-3.local k3s-node-3

# VIP MetalLB (optionnel)
192.168.1.100   cluster.local cluster
```

### Sysctl tuning pour Kubernetes

```bash
# /etc/sysctl.d/99-k3s-kubernetes.conf

# IP Forwarding (requis pour K8s)
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1

# Augmenter limites réseau
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 5000

# File descriptors
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192

# Appliquer:
# sysctl --system
```

---

## Configuration K3s

### Installation K3s - Node 1 (Control Plane)

```bash
#!/bin/bash
# install-k3s-master.sh - Premier nœud control plane

curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --write-kubeconfig-mode=644 \
  --disable=traefik \
  --disable=servicelb \
  --flannel-backend=vxlan \
  --node-name=k3s-node-1 \
  --node-ip=192.168.1.11 \
  --tls-san=192.168.1.11 \
  --tls-san=cluster.local

# Attendre que K3s soit prêt
echo "Attente démarrage K3s..."
sleep 30

# Vérifier installation
kubectl get nodes

# Sauvegarder le token pour les autres nœuds
cat /var/lib/rancher/k3s/server/node-token > ~/k3s-token.txt
echo "Token sauvegardé dans ~/k3s-token.txt"
```

### Installation K3s - Nodes 2 & 3 (Join cluster)

```bash
#!/bin/bash
# install-k3s-node.sh - Rejoindre le cluster

NODE_IP=$1      # Ex: 192.168.1.12
NODE_NAME=$2    # Ex: k3s-node-2
K3S_TOKEN=$3    # Token depuis node-1

if [ -z "$NODE_IP" ] || [ -z "$NODE_NAME" ] || [ -z "$K3S_TOKEN" ]; then
    echo "Usage: $0 <node_ip> <node_name> <k3s_token>"
    exit 1
fi

curl -sfL https://get.k3s.io | K3S_TOKEN="${K3S_TOKEN}" sh -s - server \
  --server https://192.168.1.11:6443 \
  --write-kubeconfig-mode=644 \
  --disable=traefik \
  --disable=servicelb \
  --flannel-backend=vxlan \
  --node-name="${NODE_NAME}" \
  --node-ip="${NODE_IP}"

echo "Nœud ${NODE_NAME} a rejoint le cluster"
```

### Configuration kubectl locale

```bash
# Copier kubeconfig depuis un nœud
mkdir -p ~/.kube
scp root@192.168.1.11:/etc/rancher/k3s/k3s.yaml ~/.kube/config

# Éditer pour remplacer 127.0.0.1 par l'IP du nœud
sed -i 's/127.0.0.1/192.168.1.11/g' ~/.kube/config

# Tester
kubectl get nodes
kubectl cluster-info
```

---

## MetalLB Configuration

### Installation MetalLB

```bash
# Installer MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml

# Attendre que les pods soient Ready
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=90s
```

### Configuration IP Pool

```yaml
# metallb-config.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: production-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.1.100-192.168.1.150  # Pool de 51 IPs
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: production-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - production-pool
```

```bash
# Appliquer la configuration
kubectl apply -f metallb-config.yaml

# Vérifier
kubectl get ipaddresspools -n metallb-system
kubectl get l2advertisements -n metallb-system
```

### Test MetalLB avec Nginx

```yaml
# test-metallb-nginx.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-test
  namespace: default
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx-test
  template:
    metadata:
      labels:
        app: nginx-test
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-test-lb
  namespace: default
spec:
  type: LoadBalancer
  selector:
    app: nginx-test
  ports:
  - port: 80
    targetPort: 80
```

```bash
# Déployer
kubectl apply -f test-metallb-nginx.yaml

# Vérifier l'IP externe assignée
kubectl get svc nginx-test-lb
# EXTERNAL-IP devrait afficher une IP du pool (ex: 192.168.1.100)

# Tester l'accès
curl http://192.168.1.100
# Devrait afficher la page par défaut Nginx
```

---

## Longhorn Configuration

### Installation Longhorn

```bash
# Installer Longhorn via kubectl
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.6.0/deploy/longhorn.yaml

# Attendre que tous les pods soient Running
kubectl get pods -n longhorn-system -w
```

### Configuration Longhorn Settings

```yaml
# longhorn-settings.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: longhorn-default-setting
  namespace: longhorn-system
data:
  default-replica-count: "2"
  guaranteed-engine-manager-cpu: "5"
  guaranteed-replica-manager-cpu: "5"
  storage-minimal-available-percentage: "15"
  backup-target: ""  # Configurer S3/NFS pour backups
  backup-target-credential-secret: ""
  create-default-disk-labeled-nodes: "true"
  default-data-path: "/var/lib/longhorn"
  default-data-locality: "disabled"
  replica-soft-anti-affinity: "true"
  replica-auto-balance: "best-effort"
  storage-over-provisioning-percentage: "200"
  storage-reserved-percentage-for-default-disk: "25"
  upgrade-checker: "true"
  taint-toleration: ""
  system-managed-pods-image-pull-policy: "if-not-present"
```

```bash
# Appliquer settings
kubectl apply -f longhorn-settings.yaml
```

### Storage Class par défaut

```yaml
# longhorn-storageclass.yaml
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: longhorn
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "2"
  staleReplicaTimeout: "2880"  # 48 heures
  fromBackup: ""
  fsType: "ext4"
  dataLocality: "disabled"
```

```bash
# Appliquer
kubectl apply -f longhorn-storageclass.yaml

# Vérifier
kubectl get storageclass
# longhorn devrait avoir (default) à côté
```

### Configurer les disques Longhorn

```yaml
# longhorn-disk-config.yaml
# À appliquer après avoir identifié les nœuds

# Exemple pour k3s-node-1
apiVersion: longhorn.io/v1beta1
kind: Node
metadata:
  name: k3s-node-1
  namespace: longhorn-system
spec:
  disks:
    disk-sdb:
      allowScheduling: true
      evictionRequested: false
      path: /var/lib/longhorn-sdb
      storageReserved: 107374182400  # 100 GB réservés
      tags: ["fast", "ssd"]
    disk-sdc:
      allowScheduling: true
      evictionRequested: false
      path: /var/lib/longhorn-sdc
      storageReserved: 107374182400  # 100 GB réservés
      tags: ["fast", "ssd"]
```

**Note** : Avant d'appliquer, créer les points de montage sur chaque nœud :

```bash
# Sur chaque nœud (k3s-node-1, 2, 3)

# Formater les disques
mkfs.ext4 /dev/sdb
mkfs.ext4 /dev/sdc

# Créer les points de montage
mkdir -p /var/lib/longhorn-sdb
mkdir -p /var/lib/longhorn-sdc

# Monter les disques
mount /dev/sdb /var/lib/longhorn-sdb
mount /dev/sdc /var/lib/longhorn-sdc

# Ajouter au /etc/fstab pour montage automatique
echo "/dev/sdb /var/lib/longhorn-sdb ext4 defaults 0 0" >> /etc/fstab
echo "/dev/sdc /var/lib/longhorn-sdc ext4 defaults 0 0" >> /etc/fstab

# Vérifier
df -h | grep longhorn
```

### Exposer Longhorn UI via Ingress

```yaml
# longhorn-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: longhorn-ingress
  namespace: longhorn-system
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    traefik.ingress.kubernetes.io/router.middlewares: default-redirect-https@kubernetescrd
spec:
  ingressClassName: traefik
  tls:
  - hosts:
    - longhorn.mydomain.com
    secretName: longhorn-tls
  rules:
  - host: longhorn.mydomain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: longhorn-frontend
            port:
              number: 80
```

---

## KubeVirt - Exemples VMs

### Installation KubeVirt et CDI

```bash
# Version KubeVirt
export KUBEVIRT_VERSION=$(curl -s https://api.github.com/repos/kubevirt/kubevirt/releases/latest | grep tag_name | cut -d '"' -f 4)

# Installer operator
kubectl create -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml

# Installer KubeVirt CR
kubectl create -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml

# CDI version
export CDI_VERSION=$(curl -s https://github.com/kubevirt/containerized-data-importer/releases/latest | grep -o "v[0-9]\.[0-9]*\.[0-9]*")

# Installer CDI
kubectl create -f https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml
kubectl create -f https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-cr.yaml

# Installer virtctl CLI
wget https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64
chmod +x virtctl-${KUBEVIRT_VERSION}-linux-amd64
mv virtctl-${KUBEVIRT_VERSION}-linux-amd64 /usr/local/bin/virtctl

# Vérifier
kubectl get kubevirt -n kubevirt
kubectl get cdi -n cdi
```

### VM Linux (Ubuntu)

```yaml
# vm-ubuntu.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ubuntu-vm-disk
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 50Gi
  storageClassName: longhorn
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ubuntu-vm
  namespace: default
  labels:
    app: ubuntu-vm
spec:
  running: true
  template:
    metadata:
      labels:
        kubevirt.io/vm: ubuntu-vm
    spec:
      domain:
        cpu:
          cores: 2
        devices:
          disks:
          - name: disk0
            disk:
              bus: virtio
          - name: cloudinit
            disk:
              bus: virtio
          interfaces:
          - name: default
            masquerade: {}
        machine:
          type: q35
        resources:
          requests:
            memory: 4Gi
      networks:
      - name: default
        pod: {}
      volumes:
      - name: disk0
        persistentVolumeClaim:
          claimName: ubuntu-vm-disk
      - name: cloudinit
        cloudInitNoCloud:
          userData: |
            #cloud-config
            hostname: ubuntu-vm
            users:
              - name: ubuntu
                sudo: ALL=(ALL) NOPASSWD:ALL
                groups: users, admin
                home: /home/ubuntu
                shell: /bin/bash
                ssh_authorized_keys:
                  - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAB... # Votre clé SSH publique
            ssh_pwauth: true
            disable_root: false
            chpasswd:
              list: |
                ubuntu:ubuntu
              expire: False
            package_update: true
            packages:
              - qemu-guest-agent
              - nginx
```

```bash
# Créer la VM
kubectl apply -f vm-ubuntu.yaml

# Attendre que la VM soit Running
kubectl get vmi

# Se connecter via console
virtctl console ubuntu-vm

# Ou via SSH (obtenir l'IP)
kubectl get vmi ubuntu-vm -o jsonpath='{.status.interfaces[0].ipAddress}'
ssh ubuntu@<IP>
```

### VM Windows Server 2022

```yaml
# vm-windows.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: windows-vm-disk
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Gi
  storageClassName: longhorn
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: windows-vm
  namespace: default
  labels:
    app: windows-vm
spec:
  running: false  # Démarrer manuellement après import ISO
  template:
    metadata:
      labels:
        kubevirt.io/vm: windows-vm
    spec:
      domain:
        cpu:
          cores: 4
        devices:
          disks:
          - name: disk0
            disk:
              bus: sata
          - name: cdrom-iso
            cdrom:
              bus: sata
          interfaces:
          - name: default
            masquerade: {}
        machine:
          type: q35
        resources:
          requests:
            memory: 16Gi
      networks:
      - name: default
        pod: {}
      volumes:
      - name: disk0
        persistentVolumeClaim:
          claimName: windows-vm-disk
      - name: cdrom-iso
        persistentVolumeClaim:
          claimName: windows-iso-pvc  # À créer avec CDI
```

**Importer ISO Windows via CDI** :

```yaml
# windows-iso-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: windows-iso-pvc
  namespace: default
  annotations:
    cdi.kubevirt.io/storage.import.endpoint: "https://software-download.microsoft.com/download/..."  # URL ISO
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: longhorn
```

```bash
# Créer le PVC ISO
kubectl apply -f windows-iso-pvc.yaml

# Attendre la fin de l'import
kubectl get pvc windows-iso-pvc -w

# Créer la VM Windows
kubectl apply -f vm-windows.yaml

# Démarrer la VM
virtctl start windows-vm

# Accéder via VNC (depuis un nœud du cluster)
virtctl vnc windows-vm

# Ou exposer via Ingress/Service pour RDP après installation
```

### Exposer VM Windows via RDP

```yaml
# windows-rdp-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: windows-vm-rdp
  namespace: default
spec:
  type: LoadBalancer
  selector:
    kubevirt.io/vm: windows-vm
  ports:
  - name: rdp
    port: 3389
    targetPort: 3389
    protocol: TCP
```

```bash
kubectl apply -f windows-rdp-service.yaml

# Obtenir l'IP LoadBalancer
kubectl get svc windows-vm-rdp
# Se connecter via RDP client: <EXTERNAL-IP>:3389
```

---

## Ingress & SSL

### Installation Traefik

```bash
# Installer Traefik via Helm
helm repo add traefik https://traefik.github.io/charts
helm repo update

helm install traefik traefik/traefik \
  --namespace kube-system \
  --set service.type=LoadBalancer \
  --set ports.web.exposedPort=80 \
  --set ports.websecure.exposedPort=443 \
  --set additionalArguments="{--log.level=INFO}"

# Vérifier
kubectl get svc -n kube-system traefik
# Une IP LoadBalancer devrait être assignée
```

### Installation cert-manager

```bash
# Installer cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# Vérifier installation
kubectl get pods -n cert-manager
```

### ClusterIssuer Let's Encrypt

```yaml
# letsencrypt-issuers.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: admin@mydomain.com
    privateKeySecretRef:
      name: letsencrypt-staging-key
    solvers:
    - http01:
        ingress:
          class: traefik
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@mydomain.com
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - http01:
        ingress:
          class: traefik
```

```bash
kubectl apply -f letsencrypt-issuers.yaml

# Vérifier
kubectl get clusterissuer
```

### Middleware Redirect HTTPS

```yaml
# redirect-https-middleware.yaml
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: redirect-https
  namespace: default
spec:
  redirectScheme:
    scheme: https
    permanent: true
```

### Exemple Ingress avec SSL

```yaml
# example-app-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: example-app
  namespace: default
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    traefik.ingress.kubernetes.io/router.middlewares: default-redirect-https@kubernetescrd
spec:
  ingressClassName: traefik
  tls:
  - hosts:
    - app.mydomain.com
    - www.app.mydomain.com
    secretName: app-mydomain-tls
  rules:
  - host: app.mydomain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: example-app-service
            port:
              number: 80
  - host: www.app.mydomain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: example-app-service
            port:
              number: 80
```

---

## Monitoring Stack

### Installation kube-prometheus-stack

```bash
# Ajouter repo Helm
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Installer stack complète
helm install kube-prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set prometheus.prometheusSpec.retention=15d \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=50Gi \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=longhorn \
  --set grafana.persistence.enabled=true \
  --set grafana.persistence.size=10Gi \
  --set grafana.persistence.storageClassName=longhorn \
  --set alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.resources.requests.storage=10Gi \
  --set alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.storageClassName=longhorn

# Vérifier
kubectl get pods -n monitoring
```

### Exposer Grafana via Ingress

```yaml
# grafana-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: monitoring
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    traefik.ingress.kubernetes.io/router.middlewares: default-redirect-https@kubernetescrd
spec:
  ingressClassName: traefik
  tls:
  - hosts:
    - grafana.mydomain.com
    secretName: grafana-tls
  rules:
  - host: grafana.mydomain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: kube-prometheus-grafana
            port:
              number: 80
```

### ServiceMonitor pour Longhorn

```yaml
# longhorn-servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: longhorn-prometheus-servicemonitor
  namespace: longhorn-system
  labels:
    app: longhorn
spec:
  selector:
    matchLabels:
      app: longhorn-manager
  namespaceSelector:
    matchNames:
    - longhorn-system
  endpoints:
  - port: manager
```

### Alertes personnalisées

```yaml
# custom-alerts.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cluster-alerts
  namespace: monitoring
  labels:
    prometheus: kube-prometheus
spec:
  groups:
  - name: cluster
    interval: 30s
    rules:
    - alert: NodeDown
      expr: up{job="node-exporter"} == 0
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "Node {{ $labels.instance }} is down"
        description: "Node {{ $labels.instance }} has been down for more than 5 minutes."
    
    - alert: HighCPUUsage
      expr: 100 - (avg by (instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
      for: 10m
      labels:
        severity: warning
      annotations:
        summary: "High CPU usage on {{ $labels.instance }}"
        description: "CPU usage is above 80% for more than 10 minutes."
    
    - alert: HighMemoryUsage
      expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 85
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "High memory usage on {{ $labels.instance }}"
        description: "Memory usage is above 85%."
    
    - alert: DiskSpaceLow
      expr: (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100 < 15
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "Low disk space on {{ $labels.instance }}"
        description: "Disk space is below 15% on root filesystem."
    
    - alert: LonghornVolumeNotHealthy
      expr: longhorn_volume_robustness != 0
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "Longhorn volume {{ $labels.volume }} is not healthy"
        description: "Volume {{ $labels.volume }} has degraded replicas."
```

```bash
kubectl apply -f custom-alerts.yaml
```

---

## Network Policies

### Deny all par défaut

```yaml
# default-deny-all.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
```

### Allow DNS

```yaml
# allow-dns.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: kube-system
    ports:
    - protocol: UDP
      port: 53
```

### Allow Ingress vers application web

```yaml
# allow-web-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-web-ingress
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: webapp
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: kube-system
    - podSelector:
        matchLabels:
          app.kubernetes.io/name: traefik
    ports:
    - protocol: TCP
      port: 80
```

---

## Backup Velero

### Installation Velero avec MinIO

**Déployer MinIO (stockage S3-compatible local)** :

```yaml
# minio-deployment.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 500Gi
  storageClassName: longhorn
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
      - name: minio
        image: minio/minio:latest
        args:
        - server
        - /data
        - --console-address
        - ":9001"
        env:
        - name: MINIO_ROOT_USER
          value: "minio"
        - name: MINIO_ROOT_PASSWORD
          value: "minio123"  # Changer en production !
        ports:
        - containerPort: 9000
        - containerPort: 9001
        volumeMounts:
        - name: data
          mountPath: /data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: minio-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: default
spec:
  type: ClusterIP
  selector:
    app: minio
  ports:
  - name: api
    port: 9000
    targetPort: 9000
  - name: console
    port: 9001
    targetPort: 9001
```

```bash
kubectl apply -f minio-deployment.yaml

# Créer le bucket pour Velero (port-forward vers MinIO console)
kubectl port-forward svc/minio 9001:9001
# Ouvrir http://localhost:9001
# Créer un bucket nommé "k3s-backups"
```

**Installer Velero** :

```bash
# Créer credentials file
cat > credentials-velero <<EOF
[default]
aws_access_key_id = minio
aws_secret_access_key = minio123
EOF

# Installer Velero
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.8.0 \
  --bucket k3s-backups \
  --secret-file ./credentials-velero \
  --use-volume-snapshots=true \
  --backup-location-config region=minio,s3ForcePathStyle="true",s3Url=http://minio.default.svc:9000

# Vérifier
velero version
kubectl get pods -n velero
```

### Schedules de backup

```yaml
# velero-schedules.yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: daily-backup
  namespace: velero
spec:
  schedule: "0 3 * * *"  # 3h du matin chaque jour
  template:
    includedNamespaces:
    - '*'
    excludedNamespaces:
    - kube-system
    - velero
    ttl: 720h  # 30 jours
---
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: weekly-full-backup
  namespace: velero
spec:
  schedule: "0 2 * * 0"  # 2h du matin chaque dimanche
  template:
    includedNamespaces:
    - '*'
    snapshotVolumes: true
    ttl: 2160h  # 90 jours
```

```bash
kubectl apply -f velero-schedules.yaml

# Vérifier les schedules
velero schedule get

# Créer un backup manuel
velero backup create manual-backup-$(date +%Y%m%d-%H%M)

# Lister les backups
velero backup get

# Restore depuis backup
velero restore create --from-backup daily-backup-20260208
```

---

## Exemples Workloads

### Application web stateless (Nginx)

```yaml
# nginx-webapp.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-webapp
  namespace: default
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx-webapp
  template:
    metadata:
      labels:
        app: nginx-webapp
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 200m
            memory: 256Mi
        volumeMounts:
        - name: html
          mountPath: /usr/share/nginx/html
      volumes:
      - name: html
        configMap:
          name: nginx-html
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-html
  namespace: default
data:
  index.html: |
    <!DOCTYPE html>
    <html>
    <head><title>K3s Cluster</title></head>
    <body>
      <h1>Bienvenue sur le cluster K3s!</h1>
      <p>Hébergé sur Dell Precision T5600</p>
    </body>
    </html>
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-webapp-service
  namespace: default
spec:
  selector:
    app: nginx-webapp
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx-webapp-ingress
  namespace: default
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    traefik.ingress.kubernetes.io/router.middlewares: default-redirect-https@kubernetescrd
spec:
  ingressClassName: traefik
  tls:
  - hosts:
    - www.mydomain.com
    secretName: webapp-tls
  rules:
  - host: www.mydomain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nginx-webapp-service
            port:
              number: 80
```

### Base de données PostgreSQL stateful

```yaml
# postgresql-statefulset.yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: default
spec:
  selector:
    app: postgres
  ports:
  - port: 5432
    targetPort: 5432
  clusterIP: None  # Headless service
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: default
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:15-alpine
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_DB
          value: "mydb"
        - name: POSTGRES_USER
          value: "admin"
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgres-secret
              key: password
        volumeMounts:
        - name: postgres-data
          mountPath: /var/lib/postgresql/data
        resources:
          requests:
            cpu: 500m
            memory: 1Gi
          limits:
            cpu: 1000m
            memory: 2Gi
  volumeClaimTemplates:
  - metadata:
      name: postgres-data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      storageClassName: longhorn
      resources:
        requests:
          storage: 50Gi
---
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secret
  namespace: default
type: Opaque
data:
  password: cG9zdGdyZXNwYXNz  # Base64 de "postgrespass" - Changer!
```

---

## Scripts utilitaires

### Script de monitoring rapide

```bash
#!/bin/bash
# cluster-status.sh - Statut rapide du cluster

echo "===== CLUSTER K3S STATUS ====="
echo ""

echo "--- Nodes ---"
kubectl get nodes -o wide
echo ""

echo "--- Control Plane Pods ---"
kubectl get pods -n kube-system -o wide | grep -E "kube-|etcd"
echo ""

echo "--- Longhorn Status ---"
kubectl get pods -n longhorn-system | grep -E "manager|driver|ui"
echo ""

echo "--- Storage Classes ---"
kubectl get sc
echo ""

echo "--- PVCs ---"
kubectl get pvc -A
echo ""

echo "--- Services LoadBalancer ---"
kubectl get svc -A | grep LoadBalancer
echo ""

echo "--- Top Nodes ---"
kubectl top nodes
echo ""

echo "--- Top Pods (Top 10 CPU) ---"
kubectl top pods -A --sort-by=cpu | head -n 11
echo ""

echo "--- Recent Events (Errors/Warnings) ---"
kubectl get events -A --sort-by='.lastTimestamp' | grep -E "Warning|Error" | tail -n 10
```

---

**Fin du fichier de configuration. Tous les exemples YAML et scripts sont prêts à l'emploi ! 🚀**
