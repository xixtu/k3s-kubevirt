# Architecture Cluster K3s + KubeVirt + Longhorn
## Infrastructure Haute Disponibilité sur Rocky Linux 9

---

## 📋 Table des matières

1. [Vue d'ensemble](#vue-densemble)
2. [Schéma d'infrastructure physique](#schéma-dinfrastructure-physique)
3. [Schéma logique des composants](#schéma-logique-des-composants)
4. [Architecture réseau](#architecture-réseau)
5. [Schéma de déploiement](#schéma-de-déploiement)
6. [Stockage Longhorn](#stockage-longhorn)
7. [Flux de données](#flux-de-données)
8. [Plan de déploiement](#plan-de-déploiement)

---

## Vue d'ensemble

### Objectifs du cluster

- **Hébergement mixte** : VMs (Windows/Linux) + Conteneurs
- **Haute disponibilité** : 3 nœuds avec réplication
- **Monitoring** : Prometheus + Grafana
- **Production légère** : Sites web, services internes
- **Lab/Développement** : CI/CD, tests
- **Budget zéro** : 100% open-source gratuit

### Spécifications matérielles

| Composant | Spécification |
|-----------|---------------|
| **Serveurs** | 3x Dell Precision T5600 |
| **CPU** | 2x Xeon 6 cœurs (12 cores/serveur) |
| **RAM** | 128 GB par serveur (384 GB total) |
| **Stockage OS** | 1x SSD 500 GB par serveur |
| **Stockage Data** | 2x SSD 1 TB par serveur (6 TB total) |
| **Extension future** | 2x HDD 3.5" par serveur (optionnel) |

---

## Schéma d'infrastructure physique

```mermaid
graph TB
    subgraph "Infrastructure Physique - 3 Serveurs Dell Precision T5600"
        subgraph Node1["🖥️ k3s-node-1<br/>Dell T5600"]
            CPU1["2x Xeon E5-2667<br/>12 cores @ 2.9GHz<br/>24 threads"]
            RAM1["128 GB RAM<br/>DDR3 ECC"]
            
            subgraph Storage1["💾 Stockage Node 1"]
                SSD1A["SSD 500GB<br/>/dev/sda<br/>OS Rocky 9"]
                SSD1B["SSD 1TB<br/>/dev/sdb<br/>Longhorn"]
                SSD1C["SSD 1TB<br/>/dev/sdc<br/>Longhorn"]
            end
            
            NIC1["NIC 1Gbps<br/>192.168.1.11"]
        end
        
        subgraph Node2["🖥️ k3s-node-2<br/>Dell T5600"]
            CPU2["2x Xeon E5-2667<br/>12 cores @ 2.9GHz<br/>24 threads"]
            RAM2["128 GB RAM<br/>DDR3 ECC"]
            
            subgraph Storage2["💾 Stockage Node 2"]
                SSD2A["SSD 500GB<br/>/dev/sda<br/>OS Rocky 9"]
                SSD2B["SSD 1TB<br/>/dev/sdb<br/>Longhorn"]
                SSD2C["SSD 1TB<br/>/dev/sdc<br/>Longhorn"]
            end
            
            NIC2["NIC 1Gbps<br/>192.168.1.12"]
        end
        
        subgraph Node3["🖥️ k3s-node-3<br/>Dell T5600"]
            CPU3["2x Xeon E5-2667<br/>12 cores @ 2.9GHz<br/>24 threads"]
            RAM3["128 GB RAM<br/>DDR3 ECC"]
            
            subgraph Storage3["💾 Stockage Node 3"]
                SSD3A["SSD 500GB<br/>/dev/sda<br/>OS Rocky 9"]
                SSD3B["SSD 1TB<br/>/dev/sdb<br/>Longhorn"]
                SSD3C["SSD 1TB<br/>/dev/sdc<br/>Longhorn"]
            end
            
            NIC3["NIC 1Gbps<br/>192.168.1.13"]
        end
    end
    
    subgraph Network["🌐 Réseau Local"]
        Switch["Switch Gigabit<br/>192.168.1.0/24"]
        Router["Routeur/Gateway<br/>192.168.1.1"]
        Internet["☁️ Internet"]
    end
    
    NIC1 ---|1Gbps| Switch
    NIC2 ---|1Gbps| Switch
    NIC3 ---|1Gbps| Switch
    Switch ---|1Gbps| Router
    Router ---|WAN| Internet
    
    style Node1 fill:#e1f5ff,stroke:#01579b,stroke-width:3px
    style Node2 fill:#e1f5ff,stroke:#01579b,stroke-width:3px
    style Node3 fill:#e1f5ff,stroke:#01579b,stroke-width:3px
    style Switch fill:#fff3e0,stroke:#e65100,stroke-width:2px
    style Router fill:#f3e5f5,stroke:#4a148c,stroke-width:2px
```

---

## Schéma logique des composants

```mermaid
graph TB
    subgraph "🎯 Cluster Kubernetes K3s - Haute Disponibilité"
        
        subgraph ControlPlane["⚙️ Control Plane (3 nœuds)"]
            Master1["k3s-node-1<br/>Control Plane + Worker<br/>192.168.1.11"]
            Master2["k3s-node-2<br/>Control Plane + Worker<br/>192.168.1.12"]
            Master3["k3s-node-3<br/>Control Plane + Worker<br/>192.168.1.13"]
            
            ETCD["🗄️ etcd (embedded)<br/>Base de données distribuée<br/>Quorum: 2/3 nœuds"]
        end
        
        subgraph K8sCore["🔧 Composants Kubernetes Core"]
            APIServer["kube-apiserver<br/>Port 6443"]
            Scheduler["kube-scheduler"]
            ControllerMgr["kube-controller-manager"]
            KubeProxy["kube-proxy<br/>Mode: iptables"]
        end
        
        subgraph CNI["🌐 Réseau CNI"]
            Flannel["Flannel CNI<br/>Backend: VXLAN<br/>Pod Network: 10.42.0.0/16"]
            Multus["Multus CNI<br/>Multi-interfaces pour VMs"]
            CoreDNS["CoreDNS<br/>DNS interne cluster"]
        end
        
        subgraph Storage["💾 Stockage"]
            Longhorn["Longhorn v1.6+<br/>Stockage distribué<br/>Replica: 2<br/>6TB total → 3TB utilisable"]
            CSI["CSI Driver<br/>Dynamic provisioning"]
        end
        
        subgraph Virtualization["🖥️ Virtualisation"]
            KubeVirt["KubeVirt v1.2+<br/>VMs as Pods"]
            CDI["CDI<br/>Containerized Data Importer<br/>Import ISO/Images"]
            VirtAPI["virt-api<br/>virt-controller<br/>virt-handler"]
        end
        
        subgraph LoadBalancing["⚖️ Load Balancing & Ingress"]
            MetalLB["MetalLB<br/>Bare-metal LB<br/>IP Pool: 192.168.1.100-150"]
            Ingress["Traefik / Nginx Ingress<br/>HTTPS + Let's Encrypt<br/>Reverse Proxy"]
        end
        
        subgraph Monitoring["📊 Monitoring & Observabilité"]
            Prometheus["Prometheus<br/>Métriques temps réel<br/>Retention: 15 jours"]
            Grafana["Grafana<br/>Dashboards<br/>Alerting"]
            AlertManager["AlertManager<br/>Gestion alertes"]
            NodeExporter["Node Exporter<br/>Métriques système"]
        end
        
        subgraph Backup["💾 Backup & DR"]
            Velero["Velero<br/>Backup cluster<br/>+ Persistent Volumes"]
        end
        
        subgraph Workloads["🚀 Workloads"]
            Pods["📦 Conteneurs<br/>Services web<br/>Applications"]
            VMs["🖥️ VMs<br/>Windows Server<br/>Linux VMs"]
        end
    end
    
    %% Connexions Control Plane
    Master1 --> ETCD
    Master2 --> ETCD
    Master3 --> ETCD
    
    ETCD --> APIServer
    APIServer --> Scheduler
    APIServer --> ControllerMgr
    APIServer --> KubeProxy
    
    %% Réseau
    Flannel --> Pods
    Multus --> VMs
    CoreDNS --> Pods
    CoreDNS --> VMs
    
    %% Stockage
    Longhorn --> CSI
    CSI --> Pods
    CSI --> VMs
    
    %% Virtualisation
    KubeVirt --> VirtAPI
    CDI --> VirtAPI
    VirtAPI --> VMs
    
    %% Load Balancing
    MetalLB --> Ingress
    Ingress --> Pods
    Ingress --> VMs
    
    %% Monitoring
    Prometheus --> Grafana
    Prometheus --> AlertManager
    NodeExporter --> Prometheus
    Longhorn -.->|metrics| Prometheus
    KubeVirt -.->|metrics| Prometheus
    
    %% Backup
    Velero -.->|backup| Pods
    Velero -.->|backup| VMs
    Velero -.->|backup| CSI
    
    style ControlPlane fill:#e8f5e9,stroke:#2e7d32,stroke-width:3px
    style Storage fill:#fff3e0,stroke:#f57c00,stroke-width:2px
    style Virtualization fill:#e1f5fe,stroke:#0277bd,stroke-width:2px
    style Monitoring fill:#fce4ec,stroke:#c2185b,stroke-width:2px
    style Workloads fill:#f3e5f5,stroke:#7b1fa2,stroke-width:2px
```

---

## Architecture réseau

```mermaid
graph TB
    subgraph Internet["☁️ Internet Public"]
        Users["👥 Utilisateurs externes"]
    end
    
    subgraph DMZ["🔒 DMZ / Firewall"]
        Firewall["Firewall<br/>Ports: 80, 443"]
        Router["Router/Gateway<br/>192.168.1.1"]
    end
    
    subgraph LANPhysique["🌐 LAN Physique - 192.168.1.0/24"]
        Switch["Switch Gigabit"]
        
        Node1NIC["k3s-node-1<br/>eth0: 192.168.1.11"]
        Node2NIC["k3s-node-2<br/>eth0: 192.168.1.12"]
        Node3NIC["k3s-node-3<br/>eth0: 192.168.1.13"]
    end
    
    subgraph MetalLBPool["⚖️ MetalLB IP Pool"]
        VIP1["VIP: 192.168.1.100<br/>Web Frontend"]
        VIP2["VIP: 192.168.1.101<br/>API Services"]
        VIP3["VIP: 192.168.1.102<br/>Grafana"]
        VIPRange["Pool: 192.168.1.100-150<br/>50 IPs disponibles"]
    end
    
    subgraph K8sNetworks["🔷 Réseaux Kubernetes Overlay"]
        
        subgraph PodNetwork["Pod Network - Flannel VXLAN"]
            PodCIDR["10.42.0.0/16<br/>65,536 IPs"]
            PodNode1["10.42.0.0/24<br/>Node 1 Pods"]
            PodNode2["10.42.1.0/24<br/>Node 2 Pods"]
            PodNode3["10.42.2.0/24<br/>Node 3 Pods"]
        end
        
        subgraph ServiceNetwork["Service Network - ClusterIP"]
            ServiceCIDR["10.43.0.0/16<br/>VIPs internes"]
            K8sAPI["kubernetes.default<br/>10.43.0.1:443"]
            CoreDNSSvc["kube-dns<br/>10.43.0.10:53"]
            LonghornUI["longhorn-frontend<br/>10.43.x.x:80"]
        end
        
        subgraph VMNetwork["VM Network - Multus"]
            VMBridge["Bridge: br-vms<br/>192.168.10.0/24"]
            VMDHCP["DHCP pour VMs<br/>192.168.10.100-200"]
        end
    end
    
    subgraph IngressLayer["🔀 Ingress Layer"]
        TraefikPods["Traefik Pods<br/>Répartis sur 3 nœuds<br/>DaemonSet"]
        NginxPods["OU Nginx Ingress<br/>Répartis sur 3 nœuds"]
    end
    
    subgraph Workloads["🚀 Workloads"]
        WebPods["Pods Web<br/>10.42.x.x"]
        DBPods["Pods DB<br/>10.42.x.x"]
        WindowsVM["VM Windows<br/>192.168.10.10"]
        LinuxVM["VM Linux<br/>192.168.10.11"]
    end
    
    %% Flux réseau
    Users -->|HTTPS 443| Firewall
    Firewall --> Router
    Router --> Switch
    
    Switch --> Node1NIC
    Switch --> Node2NIC
    Switch --> Node3NIC
    
    Node1NIC -.->|ARP| VIP1
    Node2NIC -.->|ARP| VIP2
    Node3NIC -.->|ARP| VIP3
    
    VIP1 --> TraefikPods
    VIP2 --> TraefikPods
    VIP3 --> TraefikPods
    
    TraefikPods -->|Route| WebPods
    TraefikPods -->|Route| WindowsVM
    
    PodCIDR --> PodNode1
    PodCIDR --> PodNode2
    PodCIDR --> PodNode3
    
    WebPods -.->|DNS| CoreDNSSvc
    DBPods -.->|DNS| CoreDNSSvc
    
    VMBridge --> WindowsVM
    VMBridge --> LinuxVM
    
    style Internet fill:#ffebee,stroke:#c62828,stroke-width:2px
    style DMZ fill:#fff3e0,stroke:#e65100,stroke-width:2px
    style LANPhysique fill:#e8f5e9,stroke:#2e7d32,stroke-width:2px
    style K8sNetworks fill:#e1f5fe,stroke:#0277bd,stroke-width:3px
    style MetalLBPool fill:#f3e5f5,stroke:#7b1fa2,stroke-width:2px
```

### Tableau récapitulatif réseau

| Réseau | CIDR | Usage | Type |
|--------|------|-------|------|
| **LAN Physique** | 192.168.1.0/24 | Nœuds K3s, management | Physique |
| **Pod Network** | 10.42.0.0/16 | Conteneurs Kubernetes | Overlay (Flannel VXLAN) |
| **Service Network** | 10.43.0.0/16 | ClusterIP services | Virtuel (iptables) |
| **VM Network** | 192.168.10.0/24 | VMs KubeVirt | Bridge (Multus) |
| **MetalLB Pool** | 192.168.1.100-150 | LoadBalancer IPs | Physique (ARP) |

### Ports importants

| Service | Port | Protocole | Description |
|---------|------|-----------|-------------|
| **K3s API** | 6443 | TCP | Kubernetes API Server |
| **etcd** | 2379-2380 | TCP | Base de données cluster |
| **Kubelet** | 10250 | TCP | Node management |
| **Flannel VXLAN** | 8472 | UDP | Overlay network |
| **Longhorn** | 9500-9504 | TCP | Storage management |
| **HTTP** | 80 | TCP | Ingress web |
| **HTTPS** | 443 | TCP | Ingress web sécurisé |
| **Grafana** | 3000 | TCP | Monitoring UI |
| **Prometheus** | 9090 | TCP | Metrics |

---

## Schéma de déploiement

```mermaid
graph TB
    subgraph Phase1["📦 Phase 1: Préparation Infrastructure (Jour 1)"]
        P1_1["Installation Rocky Linux 9<br/>- Minimal install<br/>- Partitionnement<br/>- Configuration réseau"]
        P1_2["Configuration système<br/>- SELinux policies<br/>- Firewalld rules<br/>- Kernel modules"]
        P1_3["Installation prérequis<br/>- iscsi-initiator-utils<br/>- nfs-utils<br/>- Container runtime"]
        
        P1_1 --> P1_2 --> P1_3
    end
    
    subgraph Phase2["☸️ Phase 2: Déploiement K3s (Jour 1-2)"]
        P2_1["k3s-node-1<br/>Installation K3s server<br/>--cluster-init<br/>Mode: control-plane"]
        P2_2["k3s-node-2 & 3<br/>Join cluster<br/>Mode: control-plane<br/>etcd HA"]
        P2_3["Vérification cluster<br/>kubectl get nodes<br/>3 nœuds Ready"]
        
        P2_1 --> P2_2 --> P2_3
    end
    
    subgraph Phase3["💾 Phase 3: Stockage Longhorn (Jour 2)"]
        P3_1["Installation Longhorn<br/>via Helm Chart<br/>Version 1.6+"]
        P3_2["Configuration storage<br/>- Replica count: 2<br/>- Disks: /dev/sdb, /dev/sdc<br/>- Default storage class"]
        P3_3["Test PVC<br/>Création volume test<br/>Vérification réplication"]
        
        P3_1 --> P3_2 --> P3_3
    end
    
    subgraph Phase4["🖥️ Phase 4: KubeVirt (Jour 3)"]
        P4_1["Installation KubeVirt<br/>+ CDI operator<br/>Version 1.2+"]
        P4_2["Configuration réseau<br/>Multus CNI<br/>Bridge pour VMs"]
        P4_3["Création VM test<br/>Linux minimal<br/>Validation live migration"]
        
        P4_1 --> P4_2 --> P4_3
    end
    
    subgraph Phase5["⚖️ Phase 5: Load Balancing (Jour 3)"]
        P5_1["Installation MetalLB<br/>Mode: Layer 2<br/>IP Pool: 192.168.1.100-150"]
        P5_2["Installation Ingress<br/>Traefik ou Nginx<br/>+ Cert-manager"]
        P5_3["Test exposition<br/>Service LoadBalancer<br/>Ingress HTTP/HTTPS"]
        
        P5_1 --> P5_2 --> P5_3
    end
    
    subgraph Phase6["📊 Phase 6: Monitoring (Jour 4)"]
        P6_1["Installation kube-prometheus<br/>via Helm<br/>Stack complète"]
        P6_2["Configuration Grafana<br/>Dashboards Longhorn<br/>Dashboards KubeVirt<br/>Dashboards K3s"]
        P6_3["Configuration alertes<br/>AlertManager rules<br/>Notifications"]
        
        P6_1 --> P6_2 --> P6_3
    end
    
    subgraph Phase7["💾 Phase 7: Backup (Jour 4)"]
        P7_1["Installation Velero<br/>Backend: S3/MinIO/Local<br/>Configuration schedules"]
        P7_2["Test backup/restore<br/>Namespace complet<br/>PV snapshot"]
        
        P7_1 --> P7_2
    end
    
    subgraph Phase8["🚀 Phase 8: Production (Jour 5+)"]
        P8_1["Déploiement workloads<br/>- Sites web<br/>- VMs Windows<br/>- Services applicatifs"]
        P8_2["Configuration DNS<br/>Noms de domaine<br/>Let's Encrypt SSL"]
        P8_3["Documentation<br/>Procédures ops<br/>Runbooks"]
        
        P8_1 --> P8_2 --> P8_3
    end
    
    Phase1 --> Phase2
    Phase2 --> Phase3
    Phase3 --> Phase4
    Phase4 --> Phase5
    Phase5 --> Phase6
    Phase6 --> Phase7
    Phase7 --> Phase8
    
    style Phase1 fill:#e8f5e9,stroke:#2e7d32,stroke-width:2px
    style Phase2 fill:#e3f2fd,stroke:#1565c0,stroke-width:2px
    style Phase3 fill:#fff3e0,stroke:#e65100,stroke-width:2px
    style Phase4 fill:#f3e5f5,stroke:#6a1b9a,stroke-width:2px
    style Phase5 fill:#fce4ec,stroke:#c2185b,stroke-width:2px
    style Phase6 fill:#e0f2f1,stroke:#00695c,stroke-width:2px
    style Phase7 fill:#fff9c4,stroke:#f57f17,stroke-width:2px
    style Phase8 fill:#ffebee,stroke:#c62828,stroke-width:2px
```

---

## Stockage Longhorn

```mermaid
graph TB
    subgraph "💾 Architecture Stockage Longhorn - Replica 2"
        
        subgraph Node1Storage["Node 1 - Disques"]
            N1_SDB["/dev/sdb - 1TB<br/>Longhorn Disk 1"]
            N1_SDC["/dev/sdc - 1TB<br/>Longhorn Disk 2"]
        end
        
        subgraph Node2Storage["Node 2 - Disques"]
            N2_SDB["/dev/sdb - 1TB<br/>Longhorn Disk 1"]
            N2_SDC["/dev/sdc - 1TB<br/>Longhorn Disk 2"]
        end
        
        subgraph Node3Storage["Node 3 - Disques"]
            N3_SDB["/dev/sdb - 1TB<br/>Longhorn Disk 1"]
            N3_SDC["/dev/sdc - 1TB<br/>Longhorn Disk 2"]
        end
        
        subgraph LonghornManager["🎛️ Longhorn Manager"]
            LM["Longhorn Manager<br/>Orchestration<br/>Scheduling"]
            UI["Longhorn UI<br/>:80/dashboard"]
        end
        
        subgraph StoragePool["📦 Storage Pool Total"]
            TotalRaw["6 TB Brut<br/>(6x 1TB)"]
            TotalUsable["~3 TB Utilisable<br/>(Replica 2)"]
            Overhead["~10% Overhead<br/>Metadata + Snapshots"]
        end
        
        subgraph VolumeExample["📁 Exemple: Volume 100GB"]
            PVC["PersistentVolumeClaim<br/>100 GB demandé"]
            
            subgraph Replicas["Réplication"]
                R1["Replica 1<br/>100 GB<br/>Node 1: /dev/sdb"]
                R2["Replica 2<br/>100 GB<br/>Node 2: /dev/sdc"]
            end
            
            Engine["Longhorn Engine<br/>iSCSI Target<br/>HA Controller"]
        end
        
        subgraph Features["✨ Fonctionnalités"]
            Snap["📸 Snapshots<br/>Point-in-time"]
            Backup["☁️ Backup<br/>S3/NFS"]
            Clone["🔄 Clones<br/>Instant copy"]
            Resize["📏 Resize<br/>Online expansion"]
        end
    end
    
    %% Connexions
    N1_SDB -.-> TotalRaw
    N1_SDC -.-> TotalRaw
    N2_SDB -.-> TotalRaw
    N2_SDC -.-> TotalRaw
    N3_SDB -.-> TotalRaw
    N3_SDC -.-> TotalRaw
    
    TotalRaw --> TotalUsable
    TotalUsable -.->|overhead| Overhead
    
    LM --> UI
    LM --> Engine
    
    PVC --> Engine
    Engine --> R1
    Engine --> R2
    
    R1 -.->|stored on| N1_SDB
    R2 -.->|stored on| N2_SDC
    
    Engine -.-> Snap
    Engine -.-> Backup
    Engine -.-> Clone
    Engine -.-> Resize
    
    style Node1Storage fill:#e3f2fd,stroke:#1565c0,stroke-width:2px
    style Node2Storage fill:#e3f2fd,stroke:#1565c0,stroke-width:2px
    style Node3Storage fill:#e3f2fd,stroke:#1565c0,stroke-width:2px
    style StoragePool fill:#fff3e0,stroke:#e65100,stroke-width:2px
    style VolumeExample fill:#e8f5e9,stroke:#2e7d32,stroke-width:2px
    style Features fill:#f3e5f5,stroke:#6a1b9a,stroke-width:2px
```

### Calcul capacité Longhorn

```
Capacité brute totale     : 6 TB (6 disques × 1 TB)
Réplication (replica 2)   : ÷ 2
Capacité nette théorique  : 3 TB
Overhead Longhorn (~10%)  : - 300 GB
═══════════════════════════════════════════════
Capacité utilisable       : ~2.7 TB
```

### Stratégie de réplication

| Type de données | Replica Count | Justification |
|-----------------|---------------|---------------|
| **VMs critiques** | 2 | Production, HA |
| **Bases de données** | 2 | Données importantes |
| **Sites web statiques** | 2 | Disponibilité |
| **Cache/Temp** | 1 | Données volatiles |
| **Logs** | 1 | Peut être recréé |

---

## Flux de données

```mermaid
sequenceDiagram
    participant User as 👤 Utilisateur
    participant Ingress as 🔀 Ingress (Traefik)
    participant Service as ⚙️ Service K8s
    participant Pod as 📦 Pod Application
    participant VM as 🖥️ VM KubeVirt
    participant PV as 💾 Longhorn PV
    participant Prometheus as 📊 Prometheus
    participant Grafana as 📈 Grafana
    
    %% Flux web normal
    User->>Ingress: HTTPS Request<br/>mydomain.com
    Ingress->>Service: Route vers service backend
    Service->>Pod: Load balance
    Pod->>PV: Read/Write données
    PV-->>Pod: Data
    Pod-->>Service: Response
    Service-->>Ingress: Response
    Ingress-->>User: HTTPS Response
    
    %% Flux VM
    User->>Ingress: RDP/SSH Request<br/>vm.mydomain.com
    Ingress->>VM: Route vers VM
    VM->>PV: Read/Write disque VM
    PV-->>VM: Data
    VM-->>User: RDP/SSH Response
    
    %% Monitoring
    Pod->>Prometheus: Expose /metrics
    VM->>Prometheus: Expose /metrics
    PV->>Prometheus: Longhorn metrics
    Prometheus->>Grafana: Query metrics
    User->>Grafana: View dashboards
    Grafana-->>User: Display metrics
    
    Note over Pod,PV: Longhorn replica sync<br/>automatique en background
    Note over Prometheus,Grafana: Scrape interval: 30s<br/>Retention: 15 jours
```

---

## Plan de déploiement détaillé

### Timeline estimée

| Phase | Durée | Dépendances |
|-------|-------|-------------|
| **Phase 1** : Préparation infra | 4-6h | - |
| **Phase 2** : K3s cluster | 2-3h | Phase 1 |
| **Phase 3** : Longhorn | 2-3h | Phase 2 |
| **Phase 4** : KubeVirt | 3-4h | Phase 3 |
| **Phase 5** : Load Balancing | 2-3h | Phase 2 |
| **Phase 6** : Monitoring | 2-3h | Phase 2 |
| **Phase 7** : Backup | 1-2h | Phase 3 |
| **Phase 8** : Production | Variable | Toutes |
| **TOTAL** | **~2-4 jours** | - |

### Ordre de déploiement recommandé

```mermaid
graph LR
    A[Rocky Linux<br/>Installation] --> B[System Config<br/>SELinux/Firewall]
    B --> C[K3s Cluster<br/>3 nœuds HA]
    C --> D[Longhorn<br/>Storage]
    C --> E[MetalLB<br/>Load Balancer]
    D --> F[KubeVirt<br/>Virtualisation]
    E --> G[Ingress<br/>Traefik/Nginx]
    C --> H[Monitoring<br/>Prometheus/Grafana]
    D --> I[Backup<br/>Velero]
    
    F --> J[Tests VMs]
    G --> K[Tests Web]
    H --> L[Dashboards]
    
    J --> M[Production]
    K --> M
    L --> M
    I --> M
    
    style A fill:#e8f5e9,stroke:#2e7d32
    style C fill:#e3f2fd,stroke:#1565c0
    style D fill:#fff3e0,stroke:#e65100
    style F fill:#f3e5f5,stroke:#6a1b9a
    style M fill:#ffebee,stroke:#c62828
```

---

## Checklist de déploiement

### ✅ Pré-requis

- [ ] 3 serveurs Dell T5600 opérationnels
- [ ] Réseau configuré (192.168.1.0/24)
- [ ] Accès Internet depuis les serveurs
- [ ] ISO Rocky Linux 9 téléchargé
- [ ] Clés SSH générées
- [ ] Noms de domaine (optionnel)

### ✅ Phase 1 : OS

- [ ] Rocky Linux 9 installé sur les 3 nœuds
- [ ] Partitionnement correct (/dev/sda pour OS, /dev/sdb+sdc libres)
- [ ] Réseau configuré (IPs statiques)
- [ ] SELinux en mode Enforcing
- [ ] Firewalld configuré
- [ ] Modules kernel chargés (kvm, vhost_net)
- [ ] SSH fonctionnel
- [ ] Mise à jour système (`dnf update`)

### ✅ Phase 2 : K3s

- [ ] k3s-node-1 : server installé avec --cluster-init
- [ ] k3s-node-2 & 3 : joined au cluster
- [ ] `kubectl get nodes` : 3 nœuds Ready
- [ ] etcd quorum OK (2/3 minimum)
- [ ] CoreDNS fonctionnel
- [ ] Kubeconfig exporté

### ✅ Phase 3 : Longhorn

- [ ] Longhorn déployé via Helm
- [ ] UI accessible
- [ ] 6 disques détectés (2 par nœud)
- [ ] Storage class créée et default
- [ ] Test PVC créé et bound
- [ ] Réplication à 2 vérifiée

### ✅ Phase 4 : KubeVirt

- [ ] KubeVirt operator installé
- [ ] CDI operator installé
- [ ] VM Linux test créée
- [ ] VM démarrée et accessible
- [ ] Live migration testée
- [ ] Multus CNI configuré

### ✅ Phase 5 : Load Balancing

- [ ] MetalLB installé
- [ ] IP Pool configuré (192.168.1.100-150)
- [ ] Ingress controller installé
- [ ] Cert-manager installé
- [ ] Test service LoadBalancer OK
- [ ] Test Ingress HTTP/HTTPS OK

### ✅ Phase 6 : Monitoring

- [ ] kube-prometheus-stack installé
- [ ] Prometheus scraping OK
- [ ] Grafana accessible
- [ ] Dashboards importés
- [ ] Alertes configurées
- [ ] Node exporter sur tous les nœuds

### ✅ Phase 7 : Backup

- [ ] Velero installé
- [ ] Backend storage configuré
- [ ] Schedule backup créé
- [ ] Test restore OK

### ✅ Phase 8 : Production

- [ ] Workloads déployés
- [ ] DNS configuré
- [ ] SSL certificates OK
- [ ] Documentation à jour
- [ ] Monitoring actif
- [ ] Backup automatique

---

## Ressources et commandes utiles

### Vérification santé cluster

```bash
# Statut nœuds
kubectl get nodes -o wide

# Statut pods système
kubectl get pods -n kube-system

# Statut Longhorn
kubectl get pods -n longhorn-system

# Statut KubeVirt
kubectl get pods -n kubevirt

# Métriques nœuds
kubectl top nodes

# Métriques pods
kubectl top pods -A
```

### Accès aux UIs

```bash
# Longhorn UI
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80

# Grafana
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

# Prometheus
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
```

---

## Dimensionnement prévisionnel

### Répartition RAM (par nœud - 128GB)

| Composant | RAM allouée | Nombre | Total |
|-----------|-------------|--------|-------|
| **OS Rocky** | 2 GB | 1 | 2 GB |
| **K3s control plane** | 1.5 GB | 1 | 1.5 GB |
| **Longhorn** | 4 GB | 1 | 4 GB |
| **KubeVirt** | 2 GB | 1 | 2 GB |
| **Monitoring** | 4 GB | 1 | 4 GB |
| **System reserve** | 2 GB | 1 | 2 GB |
| **═════════════** | **═══** | **═** | **═════** |
| **Subtotal système** | - | - | **15.5 GB** |
| **Disponible workloads** | - | - | **~112 GB** |

### Workloads par nœud (estimation)

- **VMs moyennes** (8GB RAM) : 14 VMs par nœud → **42 VMs total**
- **Conteneurs** : Variable, ~50-100 pods légers par nœud
- **Mix réaliste** : 10 VMs + 30 conteneurs par nœud

---

## Évolution future

### Extensions possibles

1. **Stockage supplémentaire**
   - Ajout 2x HDD 3.5" par serveur
   - Tier de stockage "slow" pour archives
   - Longhorn : separate storage class

2. **Scaling horizontal**
   - Ajout de 1-2 worker nodes
   - Plus de capacité compute/storage

3. **GitOps**
   - ArgoCD pour déploiements
   - FluxCD alternative
   - Git as source of truth

4. **Service Mesh**
   - Istio ou Linkerd
   - Observabilité avancée
   - Traffic management

5. **CI/CD**
   - Jenkins ou Tekton
   - GitLab Runner
   - Pipeline automatisé

---

## Conclusion

Cette architecture offre :

✅ **Haute disponibilité** : 3 nœuds, quorum 2/3  
✅ **Flexibilité** : VMs + Conteneurs sur même plateforme  
✅ **Résilience** : Réplication stockage, no single point of failure  
✅ **Observabilité** : Monitoring complet Prometheus/Grafana  
✅ **Évolutivité** : Ajout de nœuds/stockage facile  
✅ **Coût zéro** : 100% open-source gratuit  
✅ **Production-ready** : Stack éprouvée en entreprise  

**Prêt pour la production légère et le lab/développement !**

---

**Version** : 1.0  
**Date** : Février 2026  
**Auteur** : Architecture K3s Cluster  
**Licence** : Documentation libre
