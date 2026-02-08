# 🚀 Cluster K3s + KubeVirt + Longhorn - Documentation Complète

## Vue d'ensemble du projet

Déploiement d'un cluster Kubernetes haute disponibilité sur **3 serveurs Dell Precision T5600** avec :
- **Rocky Linux 9** comme OS
- **K3s** comme distribution Kubernetes légère
- **KubeVirt** pour héberger des VMs (Windows + Linux)
- **Longhorn** pour le stockage distribué
- **Monitoring** complet avec Prometheus + Grafana
- **100% gratuit et open-source**

---

## 📚 Documentation

| Document | Description |
|----------|-------------|
| **[Architecture Principale](k3s-cluster-architecture.md)** | Schémas d'infrastructure, logique, réseau, déploiement, stockage |
| **[Sécurité & Backup](k3s-security-backup-troubleshooting.md)** | Sécurité multi-couches, DR, SSL, HA, troubleshooting |
| **[Configurations & Exemples](k3s-configs-examples.md)** | YAML, scripts, playbooks Ansible (à venir) |

---

## 🎯 Objectifs du cluster

### Cas d'usage
- ✅ **Hébergement web** : Sites internet en production
- ✅ **Virtualisation** : VMs Windows et Linux via KubeVirt
- ✅ **Lab/Dev** : Environnement de test et développement
- ✅ **CI/CD** : Pipeline de déploiement automatisé (futur)
- ✅ **Monitoring** : Observabilité complète de l'infrastructure

### Contraintes
- 💰 **Budget zéro** : Aucune licence payante
- 🔋 **Optimisation ressources** : Maximiser l'utilisation du matériel
- 🛡️ **Résilience** : Haute disponibilité avec 3 nœuds
- 📈 **Évolutivité** : Possibilité d'ajouter des nœuds facilement

---

## 🖥️ Infrastructure matérielle

### Serveurs (x3)

| Composant | Spécification |
|-----------|---------------|
| **Modèle** | Dell Precision T5600 |
| **CPU** | 2x Intel Xeon E5-2667 (6 cores @ 2.9GHz) = 12 cores, 24 threads |
| **RAM** | 128 GB DDR3 ECC |
| **Stockage OS** | 1x SSD 500 GB (`/dev/sda`) |
| **Stockage Data** | 2x SSD 1 TB (`/dev/sdb`, `/dev/sdc`) pour Longhorn |
| **Réseau** | 1 Gbps Ethernet |
| **Extension** | 2 baies 3.5" disponibles pour HDD (futur) |

### Capacités totales cluster

```
CPU Total      : 36 cores / 72 threads
RAM Total      : 384 GB
Stockage OS    : 1.5 TB (3x 500GB)
Stockage Data  : 6 TB brut → ~3 TB utilisable (replica 2)
```

---

## 🏗️ Architecture logicielle

### Stack principale

```
┌─────────────────────────────────────────┐
│          Rocky Linux 9.x LTS            │
├─────────────────────────────────────────┤
│   K3s v1.30+ (HA - 3 control planes)    │
│   ├── etcd embedded (distributed)       │
│   ├── Flannel CNI (VXLAN)               │
│   └── CoreDNS                            │
├─────────────────────────────────────────┤
│   Longhorn v1.6+ (Stockage distribué)   │
│   ├── Replica: 2                         │
│   ├── Capacity: ~3TB utilisable          │
│   └── CSI Driver                         │
├─────────────────────────────────────────┤
│   KubeVirt v1.2+ (Virtualisation)       │
│   ├── VMs Windows                        │
│   ├── VMs Linux                          │
│   └── CDI (Data Importer)                │
├─────────────────────────────────────────┤
│   Réseau & Load Balancing               │
│   ├── MetalLB (Bare-metal LB)           │
│   ├── Multus CNI (Multi-NIC VMs)        │
│   └── Traefik/Nginx Ingress             │
├─────────────────────────────────────────┤
│   Monitoring & Observabilité            │
│   ├── Prometheus                         │
│   ├── Grafana                            │
│   ├── AlertManager                       │
│   └── Node Exporter                      │
├─────────────────────────────────────────┤
│   Sécurité & Backup                     │
│   ├── cert-manager (SSL/TLS)            │
│   ├── Velero (Backup K8s)               │
│   ├── SELinux (Enforcing)               │
│   └── Network Policies                  │
└─────────────────────────────────────────┘
```

### Réseau

| Réseau | CIDR/Range | Usage |
|--------|------------|-------|
| **LAN Physique** | 192.168.1.0/24 | Nœuds K3s |
| **Pod Network** | 10.42.0.0/16 | Conteneurs Kubernetes |
| **Service Network** | 10.43.0.0/16 | ClusterIP services |
| **VM Network** | 192.168.10.0/24 | VMs KubeVirt |
| **MetalLB Pool** | 192.168.1.100-150 | IPs LoadBalancer |

---

## 🚀 Quick Start

### Prérequis

- [ ] 3 serveurs Dell T5600 opérationnels
- [ ] Réseau configuré (192.168.1.0/24 avec IPs statiques)
- [ ] Accès Internet depuis les serveurs
- [ ] ISO Rocky Linux 9 téléchargé
- [ ] Clés SSH générées

### Installation étape par étape

#### Phase 1 : Installation OS (4-6h)

```bash
# 1. Installer Rocky Linux 9 Minimal sur les 3 serveurs
#    - Partitionnement manuel :
#      - /dev/sda : OS (XFS)
#      - /dev/sdb, /dev/sdc : Non montés (pour Longhorn)

# 2. Configuration réseau (sur chaque nœud)
nmcli con mod ens192 ipv4.addresses 192.168.1.11/24
nmcli con mod ens192 ipv4.gateway 192.168.1.1
nmcli con mod ens192 ipv4.dns "8.8.8.8 8.8.4.4"
nmcli con mod ens192 ipv4.method manual
nmcli con up ens192

# 3. Mise à jour système
dnf update -y
dnf install -y iscsi-initiator-utils nfs-utils curl wget vim

# 4. Configuration hostname
hostnamectl set-hostname k3s-node-1.local  # k3s-node-2, k3s-node-3

# 5. Configuration firewalld
firewall-cmd --permanent --add-port=6443/tcp  # K3s API
firewall-cmd --permanent --add-port=10250/tcp # Kubelet
firewall-cmd --permanent --add-port=2379-2380/tcp # etcd
firewall-cmd --permanent --add-port=8472/udp  # Flannel VXLAN
firewall-cmd --permanent --add-port=9500-9504/tcp # Longhorn
firewall-cmd --reload

# 6. SELinux - rester en Enforcing
getenforce  # Vérifier = Enforcing

# 7. Modules kernel
modprobe kvm kvm_intel vhost_net vhost_vsock
echo "kvm" >> /etc/modules-load.d/kvm.conf
echo "kvm_intel" >> /etc/modules-load.d/kvm.conf
echo "vhost_net" >> /etc/modules-load.d/vhost.conf
```

#### Phase 2 : Déploiement K3s (2-3h)

```bash
# Sur k3s-node-1 (premier control plane)
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --write-kubeconfig-mode=644 \
  --disable=traefik \
  --disable=servicelb \
  --flannel-backend=vxlan

# Récupérer le token
cat /var/lib/rancher/k3s/server/node-token

# Sur k3s-node-2 et k3s-node-3 (rejoindre le cluster)
export K3S_TOKEN="<token-from-node-1>"
curl -sfL https://get.k3s.io | sh -s - server \
  --server https://192.168.1.11:6443 \
  --write-kubeconfig-mode=644 \
  --disable=traefik \
  --disable=servicelb \
  --flannel-backend=vxlan

# Vérifier le cluster (depuis n'importe quel nœud)
kubectl get nodes
# Devrait afficher 3 nœuds en "Ready"

# Configurer kubectl localement (optionnel)
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
# Ou copier vers ~/.kube/config
```

#### Phase 3 : Longhorn (2-3h)

```bash
# Installer Longhorn via kubectl
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.6.0/deploy/longhorn.yaml

# Attendre que tous les pods soient Running
kubectl get pods -n longhorn-system -w

# Exposer l'UI Longhorn (dev uniquement - pour prod utiliser Ingress)
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80

# Accéder à http://localhost:8080
# Configuration :
# - Nombre de replicas : 2
# - Disks : /dev/sdb et /dev/sdc sur chaque nœud
```

#### Phase 4 : KubeVirt (3-4h)

```bash
# Variables version
export KUBEVIRT_VERSION=$(curl -s https://api.github.com/repos/kubevirt/kubevirt/releases/latest | grep tag_name | cut -d '"' -f 4)

# Installer KubeVirt operator
kubectl create -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml

# Installer KubeVirt CR
kubectl create -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml

# Installer CDI (Containerized Data Importer)
export CDI_VERSION=$(curl -s https://github.com/kubevirt/containerized-data-importer/releases/latest | grep -o "v[0-9]\.[0-9]*\.[0-9]*")
kubectl create -f https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml
kubectl create -f https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-cr.yaml

# Installer virtctl (CLI KubeVirt)
wget https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64
chmod +x virtctl-${KUBEVIRT_VERSION}-linux-amd64
mv virtctl-${KUBEVIRT_VERSION}-linux-amd64 /usr/local/bin/virtctl

# Vérifier installation
kubectl get pods -n kubevirt
kubectl get kubevirt -n kubevirt
```

#### Phase 5 : MetalLB + Ingress (2-3h)

```bash
# Installer MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml

# Configurer IP pool (voir k3s-configs-examples.md pour le YAML)
kubectl apply -f metallb-config.yaml

# Installer Traefik (alternative : Nginx)
helm repo add traefik https://traefik.github.io/charts
helm repo update
helm install traefik traefik/traefik -n kube-system

# Installer cert-manager pour SSL
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
```

#### Phase 6 : Monitoring (2-3h)

```bash
# Installer kube-prometheus-stack via Helm
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install kube-prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  --set prometheus.prometheusSpec.retention=15d \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=50Gi

# Accéder à Grafana
kubectl port-forward -n monitoring svc/kube-prometheus-grafana 3000:80
# User: admin
# Password: prom-operator (changer ensuite)

# Importer dashboards Longhorn et KubeVirt (IDs Grafana.com)
```

#### Phase 7 : Backup Velero (1-2h)

```bash
# Installer Velero CLI
wget https://github.com/vmware-tanzu/velero/releases/download/v1.12.0/velero-v1.12.0-linux-amd64.tar.gz
tar -xvf velero-v1.12.0-linux-amd64.tar.gz
mv velero-v1.12.0-linux-amd64/velero /usr/local/bin/

# Installer Velero (avec backend S3 MinIO local ou externe)
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.8.0 \
  --bucket k3s-backups \
  --secret-file ./credentials-velero \
  --use-volume-snapshots=true \
  --backup-location-config region=minio,s3ForcePathStyle="true",s3Url=http://minio.default.svc:9000

# Créer backup schedule
velero schedule create daily-backup --schedule="0 3 * * *"
```

---

## 📊 Schémas d'architecture

### Infrastructure physique

Voir [Architecture Principale - Schéma Infrastructure](k3s-cluster-architecture.md#schéma-dinfrastructure-physique)

### Architecture logique

Voir [Architecture Principale - Schéma Logique](k3s-cluster-architecture.md#schéma-logique-des-composants)

### Réseau

Voir [Architecture Principale - Architecture Réseau](k3s-cluster-architecture.md#architecture-réseau)

### Stockage Longhorn

Voir [Architecture Principale - Stockage Longhorn](k3s-cluster-architecture.md#stockage-longhorn)

### Sécurité

Voir [Sécurité & Backup - Architecture Sécurité](k3s-security-backup-troubleshooting.md#architecture-de-sécurité)

### Backup & DR

Voir [Sécurité & Backup - Flux Backup](k3s-security-backup-troubleshooting.md#flux-de-backup-et-disaster-recovery)

---

## 🎯 Métriques et dimensionnement

### Répartition RAM par nœud (128 GB)

| Composant | Allocation | Pourcentage |
|-----------|------------|-------------|
| OS Rocky Linux | 2 GB | 1.6% |
| K3s control plane | 1.5 GB | 1.2% |
| Longhorn | 4 GB | 3.1% |
| KubeVirt | 2 GB | 1.6% |
| Monitoring (Prometheus/Grafana) | 4 GB | 3.1% |
| System reserve | 2 GB | 1.6% |
| **Total système** | **15.5 GB** | **12%** |
| **Disponible pour workloads** | **~112 GB** | **88%** |

### Capacité workloads estimée (par nœud)

- **VMs moyennes** (8 GB RAM chacune) : ~14 VMs
- **VMs Windows** (16 GB RAM) : ~7 VMs
- **Conteneurs légers** : ~50-100 pods
- **Mix réaliste** : 5-10 VMs + 30-50 conteneurs

### Stockage disponible

```
Capacité brute totale      : 6 TB (6 disques × 1 TB)
Réplication (replica 2)    : ÷ 2
Overhead Longhorn (~10%)   : - 10%
════════════════════════════════════════
Capacité utilisable finale : ~2.7 TB
```

---

## 🛡️ Sécurité

### Couches de sécurité

1. **Périmètre** : Firewall physique (ports 80, 443 uniquement)
2. **Nœud** : SELinux Enforcing + Firewalld
3. **Kubernetes** : RBAC + Network Policies + Pod Security Standards
4. **Données** : etcd encryption + TLS partout
5. **Monitoring** : Audit logs + Alertes

### Checklist sécurité

- [x] SELinux en mode Enforcing
- [x] Firewalld configuré (zones trusted + public)
- [x] RBAC least privilege
- [x] Network Policies (deny by default)
- [x] Pod Security Standards (restricted)
- [x] Secrets encryption at rest (etcd)
- [x] TLS/SSL via cert-manager + Let's Encrypt
- [x] Audit logging activé

---

## 💾 Backup et Disaster Recovery

### Stratégie de backup

| Type | Fréquence | Rétention | Tool | RTO | RPO |
|------|-----------|-----------|------|-----|-----|
| **etcd snapshot** | 12h | 5 snapshots | K3s auto | 2-4h | 12h |
| **Longhorn snapshot** | 6h | 7 jours | Longhorn auto | 5-10min | 6h |
| **Velero backup** | Quotidien (3h) | 30 jours | Velero | 15-30min | 24h |
| **Velero backup** | Hebdo (dimanche) | 90 jours | Velero | 15-30min | 7j |

### Scénarios de récupération

Voir [Sécurité & Backup - DR Scenarios](k3s-security-backup-troubleshooting.md#flux-de-backup-et-disaster-recovery)

---

## 📈 Monitoring et alertes

### Dashboards Grafana

1. **Cluster Overview** : Santé globale du cluster
2. **Node Metrics** : CPU, RAM, Disk, Network par nœud
3. **Longhorn** : Volumes, replicas, I/O performance
4. **KubeVirt** : VMs running, resources, migrations
5. **Ingress** : Traffic HTTP/HTTPS, latency, errors

### Alertes critiques

- CPU > 80% pendant 10 minutes
- RAM > 85% pendant 5 minutes
- Disk > 90%
- etcd quorum perdu
- Node NotReady > 5 minutes
- Certificate expiration < 30 jours
- Longhorn replica degraded

---

## 🔧 Troubleshooting

### Commandes essentielles

Voir [Sécurité & Backup - Troubleshooting Guide](k3s-security-backup-troubleshooting.md#troubleshooting-guide)

### Checklist diagnostic

1. ❓ Symptôme exact
2. 🕐 Timeline du problème
3. 📊 Métriques (Grafana)
4. 📝 Logs (kubectl logs, journalctl)
5. 🔍 État composants (kubectl get pods/nodes)
6. 🌐 Réseau (ping, DNS, firewall)
7. 💾 Stockage (df -h, Longhorn UI)
8. 🔒 Sécurité (SELinux, RBAC)

---

## 🚀 Évolution future

### Phase 8 : Extensions possibles

1. **GitOps** : ArgoCD ou FluxCD pour déploiements automatisés
2. **CI/CD** : Jenkins, Tekton, ou GitLab Runner
3. **Service Mesh** : Istio ou Linkerd pour observabilité avancée
4. **Stockage tier 2** : Ajout HDDs 3.5" pour archives (tier slow Longhorn)
5. **Worker nodes** : Ajout de 1-2 nœuds workers supplémentaires
6. **External Secrets** : HashiCorp Vault pour secrets management

### Scaling horizontal

```bash
# Ajouter un nouveau worker node
# Sur le nouveau serveur :
export K3S_TOKEN="<token-from-existing-node>"
curl -sfL https://get.k3s.io | sh -s - agent \
  --server https://192.168.1.11:6443

# Le nouveau nœud rejoint automatiquement le cluster
kubectl get nodes
# Devrait afficher 4 nœuds
```

---

## 📞 Support et ressources

### Documentation officielle

- [K3s Documentation](https://docs.k3s.io/)
- [KubeVirt Documentation](https://kubevirt.io/user-guide/)
- [Longhorn Documentation](https://longhorn.io/docs/)
- [Rocky Linux Documentation](https://docs.rockylinux.org/)

### Communautés

- [K3s GitHub](https://github.com/k3s-io/k3s)
- [KubeVirt Slack](https://kubernetes.slack.com/messages/virtualization)
- [Longhorn Slack](https://cloud-native.slack.com/messages/longhorn)
- [Rocky Linux Forums](https://forums.rockylinux.org/)

### Outils recommandés

- **k9s** : TUI pour gérer Kubernetes ([k9scli.io](https://k9scli.io/))
- **kubectx/kubens** : Switch contextes/namespaces rapidement
- **Lens** : IDE Kubernetes (desktop app)
- **Argo CD** : GitOps deployment (futur)

---

## ✅ Checklist de production

### Avant mise en production

- [ ] Tous les nœuds en état Ready
- [ ] etcd quorum 3/3 healthy
- [ ] Longhorn replicas synchronisées
- [ ] MetalLB IP pool configuré
- [ ] Ingress controller opérationnel
- [ ] SSL/TLS certificats valides
- [ ] Monitoring actif (Prometheus + Grafana)
- [ ] Alertes configurées et testées
- [ ] Backup automatique configuré
- [ ] Test restore effectué avec succès
- [ ] Documentation ops à jour
- [ ] Runbooks disponibles

### Post-déploiement

- [ ] Monitoring quotidien des métriques
- [ ] Vérification hebdo des backups
- [ ] Review mensuel des alertes
- [ ] Update trimestriel des composants
- [ ] Test DR semestriel

---

## 📝 Changelog

| Version | Date | Changements |
|---------|------|-------------|
| **1.0** | Février 2026 | Documentation initiale complète |
| **1.1** | TBD | Ajout playbooks Ansible |
| **1.2** | TBD | Ajout exemples VMs et workloads |

---

## 📄 Licence

Cette documentation est libre d'utilisation. Le cluster utilise uniquement des composants open-source :

- Rocky Linux 9 : BSD License
- K3s : Apache 2.0
- KubeVirt : Apache 2.0
- Longhorn : Apache 2.0
- Prometheus : Apache 2.0
- Grafana : AGPL v3

---

## 🎉 Conclusion

Tu as maintenant une documentation complète pour déployer et opérer un cluster K3s production-ready avec :

✅ Haute disponibilité (3 control planes)  
✅ Virtualisation (VMs Windows/Linux)  
✅ Stockage distribué (Longhorn replica 2)  
✅ Monitoring complet (Prometheus/Grafana)  
✅ Sécurité renforcée (SELinux, RBAC, Network Policies)  
✅ Backup automatisé (Velero + Longhorn snapshots)  
✅ 100% gratuit et open-source  

**Prêt à déployer ! 🚀**

---

**Prochaine étape** : Consulter [k3s-configs-examples.md](k3s-configs-examples.md) pour les fichiers de configuration YAML concrets.
