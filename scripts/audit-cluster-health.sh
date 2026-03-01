#!/usr/bin/env bash
# =============================================================
# AUDIT SANTÉ CLUSTER K3S - Post-Hardening
# =============================================================
# Usage : ./scripts/audit-cluster-health.sh [KUBECONFIG]
#
# Vérifie :
#   1. Nœuds du cluster
#   2. Pods en erreur / non-ready / CrashLoop
#   3. Déploiements bloqués (rollout stuck)
#   4. ReplicaSets non satisfaits
#   5. PVC non liés
#   6. Events récents (warnings)
#   7. SecurityContext des pods (hardening)
#   8. Stratégie de déploiement (Recreate vs RollingUpdate + RWO)
#   9. Alertes Prometheus actives
#  10. Ressources (CPU/RAM) des nœuds
#  11. Longhorn santé volumes
#  12. Certificats TLS expiration
#
# Sortie : ./audit-reports/audit-cluster-health-<date>.txt
# =============================================================

set -euo pipefail

# --- Configuration ---
KUBECONFIG="${1:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG
KUBECTL="kubectl"

if command -v k3s &>/dev/null; then
    KUBECTL="k3s kubectl"
fi

REPORT_DIR="$(cd "$(dirname "$0")" && pwd)/audit-reports"
mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/audit-cluster-health-$(date +%Y%m%d-%H%M%S).txt"

# --- Compteurs globaux ---
TOTAL_OK=0
TOTAL_WARN=0
TOTAL_FAIL=0

# --- Couleurs ---
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
fi

# --- Fonctions utilitaires ---
separator() { echo "=================================================================="; }
section() {
    echo ""
    separator
    echo -e "  ${BOLD}$1${NC}"
    separator
}
ok()   { ((TOTAL_OK++))   || true; echo -e "  ${GREEN}[OK]${NC}   $1"; }
warn() { ((TOTAL_WARN++)) || true; echo -e "  ${YELLOW}[WARN]${NC} $1"; }
fail() { ((TOTAL_FAIL++)) || true; echo -e "  ${RED}[FAIL]${NC} $1"; }
info() { echo -e "  ${CYAN}[INFO]${NC} $1"; }

# =============================================================
# 0. PRÉREQUIS
# =============================================================
check_prerequisites() {
    section "0. CONNEXION AU CLUSTER"

    if ! $KUBECTL cluster-info &>/dev/null; then
        fail "Impossible de se connecter au cluster (KUBECONFIG=$KUBECONFIG)"
        echo "  Usage : $0 [chemin/vers/kubeconfig]"
        exit 1
    fi
    ok "Connexion au cluster OK"
    info "KUBECONFIG : $KUBECONFIG"
    info "Date audit : $(date '+%Y-%m-%d %H:%M:%S %Z')"

    local server_version
    server_version=$($KUBECTL version --short 2>/dev/null | grep Server || $KUBECTL version 2>/dev/null | grep "Server Version" | head -1)
    info "Version serveur : $server_version"
}

# =============================================================
# 1. NŒUDS
# =============================================================
audit_nodes() {
    section "1. SANTÉ DES NŒUDS"

    echo ""
    $KUBECTL get nodes -o wide 2>/dev/null
    echo ""

    local not_ready
    not_ready=$($KUBECTL get nodes --no-headers 2>/dev/null | grep -v " Ready " || true)
    if [ -n "$not_ready" ]; then
        fail "Nœuds NOT Ready détectés :"
        echo "$not_ready" | sed 's/^/    /'
    else
        ok "Tous les nœuds sont Ready"
    fi

    # Conditions anormales
    echo ""
    info "Conditions des nœuds :"
    $KUBECTL get nodes -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for node in data.get('items', []):
    name = node['metadata']['name']
    for cond in node.get('status', {}).get('conditions', []):
        t = cond['type']
        s = cond['status']
        # Ready=True est OK, les autres True sont des problèmes
        # EtcdIsVoter=True est normal en k3s HA (embedded etcd)
        if t == 'Ready' and s != 'True':
            print(f'  [FAIL] {name}: {t}={s} — {cond.get(\"message\",\"\")}')
        elif t in ('MemoryPressure', 'DiskPressure', 'PIDPressure', 'NetworkUnavailable') and s == 'True':
            print(f'  [FAIL] {name}: {t}={s} — {cond.get(\"message\",\"\")}')
        elif t not in ('Ready', 'EtcdIsVoter') and s == 'True':
            print(f'  [WARN] {name}: {t}={s} — {cond.get(\"message\",\"\")}')
" 2>/dev/null || true

    # Ressources
    echo ""
    info "Utilisation des ressources :"
    $KUBECTL top nodes 2>/dev/null || warn "metrics-server non disponible (kubectl top)"
}

# =============================================================
# 2. PODS EN ERREUR
# =============================================================
audit_pods() {
    section "2. PODS — État global"

    # Résumé par namespace
    echo ""
    info "Résumé par namespace :"
    $KUBECTL get pods --all-namespaces --no-headers 2>/dev/null | \
        awk '{ns=$1; status=$4; count[ns" "status]++} END {for (k in count) print "    "k": "count[k]}' | sort
    echo ""

    # Pods non-Running/non-Completed
    local problem_pods
    problem_pods=$($KUBECTL get pods --all-namespaces --no-headers 2>/dev/null | \
        grep -v -E "Running|Completed|Succeeded" || true)

    if [ -n "$problem_pods" ]; then
        fail "Pods en état anormal :"
        echo "$problem_pods" | while read -r line; do
            echo "    $line"
        done
    else
        ok "Tous les pods sont Running ou Completed"
    fi

    # CrashLoopBackOff
    echo ""
    local crash_pods
    crash_pods=$($KUBECTL get pods --all-namespaces --no-headers 2>/dev/null | \
        grep "CrashLoopBackOff" || true)
    if [ -n "$crash_pods" ]; then
        fail "Pods en CrashLoopBackOff :"
        echo "$crash_pods" | while read -r line; do
            ns=$(echo "$line" | awk '{print $1}')
            pod=$(echo "$line" | awk '{print $2}')
            echo "    $ns/$pod"
            echo "    Derniers logs :"
            $KUBECTL logs "$pod" -n "$ns" --tail=5 2>/dev/null | sed 's/^/      /' || true
        done
    else
        ok "Aucun pod en CrashLoopBackOff"
    fi

    # Pods en Pending
    echo ""
    local pending_pods
    pending_pods=$($KUBECTL get pods --all-namespaces --no-headers 2>/dev/null | \
        grep "Pending" || true)
    if [ -n "$pending_pods" ]; then
        fail "Pods en Pending (scheduling impossible) :"
        echo "$pending_pods" | while read -r line; do
            ns=$(echo "$line" | awk '{print $1}')
            pod=$(echo "$line" | awk '{print $2}')
            echo "    $ns/$pod"
            $KUBECTL describe pod "$pod" -n "$ns" 2>/dev/null | grep -A3 "Events:" | tail -3 | sed 's/^/      /' || true
        done
    else
        ok "Aucun pod en Pending"
    fi

    # Pods avec restart élevé
    echo ""
    info "Pods avec restarts > 5 :"
    local high_restart
    high_restart=$($KUBECTL get pods --all-namespaces --no-headers 2>/dev/null | \
        awk '{if ($5+0 > 5) print "    "$1"/"$2" restarts="$5}' || true)
    if [ -n "$high_restart" ]; then
        warn "Pods avec beaucoup de restarts :"
        echo "$high_restart"
    else
        ok "Aucun pod avec plus de 5 restarts"
    fi

    # Containers non-ready dans des pods Running
    echo ""
    local not_ready_containers
    not_ready_containers=$($KUBECTL get pods --all-namespaces --no-headers 2>/dev/null | \
        grep "Running" | awk '{split($3,a,"/"); if (a[1] != a[2]) print "    "$1"/"$2" ready="$3}' || true)
    if [ -n "$not_ready_containers" ]; then
        warn "Pods Running mais containers pas tous ready :"
        echo "$not_ready_containers"
    else
        ok "Tous les containers running sont ready"
    fi
}

# =============================================================
# 3. DÉPLOIEMENTS
# =============================================================
audit_deployments() {
    section "3. DÉPLOIEMENTS — Rollout status"

    echo ""
    $KUBECTL get deployments --all-namespaces -o wide 2>/dev/null
    echo ""

    # Déploiements avec replicas non satisfaits
    local stuck_deploys
    stuck_deploys=$($KUBECTL get deployments --all-namespaces --no-headers 2>/dev/null | \
        awk '{split($3,a,"/"); if (a[1] != a[2]) print $1"/"$2" ready="$3" available="$4}' || true)

    if [ -n "$stuck_deploys" ]; then
        fail "Déploiements non satisfaits (replicas manquants) :"
        echo "$stuck_deploys" | while read -r line; do
            echo "    $line"
        done
    else
        ok "Tous les déploiements ont leurs replicas satisfaits"
    fi

    # Vérification rollout stuck (condition Progressing=False)
    echo ""
    info "Vérification rollout stuck :"
    $KUBECTL get deployments --all-namespaces -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
stuck = False
for item in data.get('items', []):
    ns = item['metadata']['namespace']
    name = item['metadata']['name']
    for cond in item.get('status', {}).get('conditions', []):
        if cond.get('type') == 'Progressing' and cond.get('status') == 'False':
            print(f'  [FAIL] {ns}/{name} — rollout bloqué: {cond.get(\"message\",\"\")}')
            stuck = True
        if cond.get('type') == 'Available' and cond.get('status') == 'False':
            print(f'  [FAIL] {ns}/{name} — pas available: {cond.get(\"message\",\"\")}')
            stuck = True
if not stuck:
    print('  [OK]   Aucun rollout bloqué')
" 2>/dev/null || warn "Impossible de vérifier les conditions"

    # Vérification stratégie vs PVC RWO
    echo ""
    info "Stratégie de déploiement vs PVC RWO :"
    $KUBECTL get deployments --all-namespaces -o json 2>/dev/null | python3 -c "
import json, sys, subprocess

data = json.load(sys.stdin)
for item in data.get('items', []):
    ns = item['metadata']['namespace']
    name = item['metadata']['name']
    strategy = item.get('spec', {}).get('strategy', {}).get('type', 'RollingUpdate')

    # Chercher les PVC dans les volumes
    volumes = item.get('spec', {}).get('template', {}).get('spec', {}).get('volumes', [])
    has_pvc = any(v.get('persistentVolumeClaim') for v in volumes)

    if has_pvc and strategy == 'RollingUpdate':
        print(f'  [WARN] {ns}/{name} — RollingUpdate + PVC (risque Multi-Attach)')
    elif has_pvc and strategy == 'Recreate':
        print(f'  [OK]   {ns}/{name} — Recreate + PVC')
    elif has_pvc:
        print(f'  [INFO] {ns}/{name} — {strategy} + PVC')
" 2>/dev/null || true
}

# =============================================================
# 4. STATEFULSETS & DAEMONSETS
# =============================================================
audit_statefulsets() {
    section "4. STATEFULSETS & DAEMONSETS"

    echo ""
    echo "--- StatefulSets ---"
    $KUBECTL get statefulsets --all-namespaces -o wide 2>/dev/null || info "Aucun StatefulSet"

    local sts_issues
    sts_issues=$($KUBECTL get statefulsets --all-namespaces --no-headers 2>/dev/null | \
        awk '{split($3,a,"/"); if (a[1] != a[2]) print "    "$1"/"$2" ready="$3}' || true)
    if [ -n "$sts_issues" ]; then
        fail "StatefulSets non satisfaits :"
        echo "$sts_issues"
    else
        ok "Tous les StatefulSets sont satisfaits"
    fi

    echo ""
    echo "--- DaemonSets ---"
    $KUBECTL get daemonsets --all-namespaces -o wide 2>/dev/null || info "Aucun DaemonSet"

    local ds_issues
    ds_issues=$($KUBECTL get daemonsets --all-namespaces --no-headers 2>/dev/null | \
        awk '{if ($5+0 != $3+0) print "    "$1"/"$2" desired="$3" ready="$5}' || true)
    if [ -n "$ds_issues" ]; then
        warn "DaemonSets avec nœuds non ready :"
        echo "$ds_issues"
    else
        ok "Tous les DaemonSets ont leurs pods ready"
    fi
}

# =============================================================
# 5. PVC
# =============================================================
audit_pvcs() {
    section "5. PERSISTENT VOLUME CLAIMS"

    echo ""
    $KUBECTL get pvc --all-namespaces -o wide 2>/dev/null
    echo ""

    # PVC non Bound
    local unbound
    unbound=$($KUBECTL get pvc --all-namespaces --no-headers 2>/dev/null | \
        grep -v "Bound" || true)
    if [ -n "$unbound" ]; then
        fail "PVC non liés (Pending/Lost) :"
        echo "$unbound" | sed 's/^/    /'
    else
        ok "Tous les PVC sont Bound"
    fi

    # Utilisation disque PVC (si metrics disponibles)
    echo ""
    info "Vérification usage PVC via Longhorn :"
    $KUBECTL get volumes.longhorn.io -n longhorn-system -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for vol in data.get('items', []):
    name = vol['metadata']['name']
    state = vol.get('status', {}).get('state', '?')
    robustness = vol.get('status', {}).get('robustness', '?')
    size = int(vol.get('spec', {}).get('size', '0'))
    actual = int(vol.get('status', {}).get('actualSize', '0'))

    size_gi = size / (1024**3) if size > 0 else 0
    actual_gi = actual / (1024**3) if actual > 0 else 0
    pct = (actual / size * 100) if size > 0 else 0

    status_icon = '[OK]  ' if state == 'attached' and robustness == 'healthy' else '[WARN]'
    if robustness == 'degraded':
        status_icon = '[WARN]'
    elif robustness == 'faulted':
        status_icon = '[FAIL]'
    elif state == 'detached' and robustness == 'unknown':
        # Detached volumes with unknown robustness are simply unused (e.g. benchmark PVCs)
        status_icon = '[INFO]'

    print(f'  {status_icon} {name[:45]:45s} state={state:10s} robustness={robustness:10s} {actual_gi:.1f}/{size_gi:.1f}Gi ({pct:.0f}%)')
" 2>/dev/null || warn "Impossible de lire les volumes Longhorn"
}

# =============================================================
# 6. EVENTS RÉCENTS (Warnings)
# =============================================================
audit_events() {
    section "6. EVENTS RÉCENTS (Warnings, dernière heure)"

    echo ""
    local warning_events
    warning_events=$($KUBECTL get events --all-namespaces --field-selector type=Warning \
        --sort-by='.lastTimestamp' 2>/dev/null | tail -30 || true)

    if [ -n "$warning_events" ] && [ "$(echo "$warning_events" | wc -l)" -gt 1 ]; then
        warn "Événements Warning récents :"
        echo "$warning_events" | sed 's/^/    /'
    else
        ok "Aucun événement Warning récent"
    fi

    # Events spécifiques critiques — vérifier si les pods concernés existent encore
    echo ""
    info "Recherche d'events critiques sur des pods ACTUELS :"

    # Collecter les pods actuels
    local current_pods
    current_pods=$($KUBECTL get pods --all-namespaces --no-headers 2>/dev/null | \
        awk '{print $1"/"$2}' || true)

    local critical_events
    critical_events=$($KUBECTL get events --all-namespaces --no-headers \
        --field-selector type=Warning 2>/dev/null | \
        grep -iE "FailedAttach|FailedMount|FailedScheduling|OOMKill|Evicted|BackOff|Multi-Attach" || true)

    local active_critical=""
    local stale_count=0
    if [ -n "$critical_events" ]; then
        while IFS= read -r line; do
            # Extraire namespace et pod name depuis la colonne OBJECT (format pod/name)
            local ev_ns ev_pod
            ev_ns=$(echo "$line" | awk '{print $1}')
            ev_pod=$(echo "$line" | awk '{print $5}' | sed 's|^pod/||')
            if echo "$current_pods" | grep -q "^${ev_ns}/${ev_pod}$"; then
                active_critical="${active_critical}${line}\n"
            else
                ((stale_count++)) || true
            fi
        done <<< "$critical_events"
    fi

    if [ -n "$active_critical" ]; then
        fail "Events critiques sur pods actifs :"
        echo -e "$active_critical" | head -15 | sed 's/^/    /'
    else
        ok "Aucun événement critique sur des pods actifs"
    fi
    if [ "$stale_count" -gt 0 ]; then
        info "$stale_count event(s) historique(s) ignoré(s) (pods déjà remplacés)"
    fi
}

# =============================================================
# 7. SECURITY CONTEXT (Hardening)
# =============================================================
audit_security() {
    section "7. SECURITY CONTEXT — Audit Hardening"

    echo ""
    info "Vérification des SecurityContext par namespace applicatif :"
    echo ""

    local app_namespaces
    app_namespaces="paheko mobilizon nextcloud headlamp nas monitoring kwaba-kinesiologie-redirect adguardhome"

    for ns in $app_namespaces; do
        # Vérifier si le namespace existe
        if ! $KUBECTL get namespace "$ns" &>/dev/null; then
            info "$ns — namespace inexistant, skip"
            continue
        fi

        echo "  --- $ns ---"
        $KUBECTL get pods -n "$ns" -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for pod in data.get('items', []):
    name = pod['metadata']['name']
    pod_sc = pod.get('spec', {}).get('securityContext', {})

    # Pod-level checks
    checks = []

    # seccompProfile
    seccomp = pod_sc.get('seccompProfile', {}).get('type', '')
    if seccomp == 'RuntimeDefault':
        checks.append(('[OK]', 'seccomp=RuntimeDefault'))
    elif seccomp:
        checks.append(('[INFO]', f'seccomp={seccomp}'))
    else:
        checks.append(('[WARN]', 'seccomp non défini'))

    # runAsNonRoot
    if pod_sc.get('runAsNonRoot'):
        checks.append(('[OK]', 'runAsNonRoot=true'))
    else:
        checks.append(('[INFO]', 'runAsNonRoot non défini (image peut nécessiter root)'))

    for container in pod.get('spec', {}).get('containers', []):
        cname = container['name']
        csc = container.get('securityContext', {})

        # allowPrivilegeEscalation
        if csc.get('allowPrivilegeEscalation') == False:
            checks.append(('[OK]', f'{cname}: allowPrivEsc=false'))
        else:
            checks.append(('[WARN]', f'{cname}: allowPrivilegeEscalation non défini ou true'))

        # capabilities
        caps = csc.get('capabilities', {})
        drop = caps.get('drop', [])
        add = caps.get('add', [])
        if 'ALL' in drop:
            checks.append(('[OK]', f'{cname}: drop ALL capabilities'))
        else:
            checks.append(('[WARN]', f'{cname}: capabilities.drop ne contient pas ALL'))

        if add:
            checks.append(('[INFO]', f'{cname}: capabilities.add={add}'))

        # readOnlyRootFilesystem
        if csc.get('readOnlyRootFilesystem'):
            checks.append(('[OK]', f'{cname}: readOnlyRootFilesystem=true'))
        else:
            checks.append(('[INFO]', f'{cname}: readOnlyRootFilesystem=false (peut être requis)'))

    for tag, msg in checks:
        if tag == '[OK]':
            print(f'    {tag}   {name}: {msg}')
        elif tag == '[WARN]':
            print(f'    {tag}  {name}: {msg}')
        else:
            print(f'    {tag}  {name}: {msg}')
" 2>/dev/null || warn "$ns — impossible de lire les pods"
        echo ""
    done
}

# =============================================================
# 8. SERVICES
# =============================================================
audit_services() {
    section "8. SERVICES — Endpoints"

    echo ""
    info "Services sans endpoints (trafic ne peut pas être routé) :"
    echo ""

    $KUBECTL get endpoints --all-namespaces --no-headers 2>/dev/null | while read -r line; do
        ns=$(echo "$line" | awk '{print $1}')
        name=$(echo "$line" | awk '{print $2}')
        endpoints=$(echo "$line" | awk '{print $3}')
        if [ "$endpoints" = "<none>" ]; then
            # Ignorer certains services système qui n'ont pas toujours d'endpoints
            case "$name" in
                kubernetes|kube-dns) continue ;;
            esac
            warn "$ns/$name — pas d'endpoints"
        fi
    done

    ok "Vérification endpoints terminée"

    # MetalLB IPs
    echo ""
    info "Services LoadBalancer (MetalLB) :"
    $KUBECTL get svc --all-namespaces --no-headers 2>/dev/null | \
        grep "LoadBalancer" | \
        awk '{printf "    %-30s %-20s IP=%s\n", $1"/"$2, $5, $4}' || true
}

# =============================================================
# 9. ALERTES PROMETHEUS
# =============================================================
audit_prometheus_alerts() {
    section "9. ALERTES PROMETHEUS"

    echo ""
    info "Tentative de récupération des alertes actives..."
    echo ""

    # Trouver le nom du service Prometheus (pour construire l'URL proxy)
    local prom_svc
    prom_svc=$($KUBECTL get svc -n monitoring --no-headers 2>/dev/null | \
        grep "prometheus" | grep -v "alertmanager\|operator\|grafana\|exporter\|metrics" | \
        awk '{print $1}' | head -1 || true)

    if [ -z "$prom_svc" ]; then
        warn "Service Prometheus non trouvé dans namespace monitoring"
        info "Vérifiez manuellement : https://prometheus.app.xixtu.eu/alerts"
    else
        # Query via kubectl API proxy (pas besoin d'exec ni de wget dans le container)
        local alerts_json
        alerts_json=$($KUBECTL get --raw \
            "/api/v1/namespaces/monitoring/services/${prom_svc}:9090/proxy/api/v1/alerts" \
            2>/dev/null || true)

        if [ -n "$alerts_json" ]; then
            echo "$alerts_json" | python3 -c "
import json, sys

# Liste des alertes 'normales' (faux positifs connus)
FALSE_POSITIVES = {
    'Watchdog',           # Alerte de test, toujours firing
    'InfoInhibitor',      # Inhibe les alertes info, toujours firing
}

# Prefixes d'alertes non pertinentes en k3s (pas d'etcd)
IGNORE_PREFIXES = ('etcd',)

try:
    data = json.load(sys.stdin)
    alerts = data.get('data', {}).get('alerts', [])
    firing = [a for a in alerts if a.get('state') == 'firing']
    pending = [a for a in alerts if a.get('state') == 'pending']

    # Separer faux positifs des vrais problemes
    real_firing = []
    fp_firing = []
    for a in firing:
        name = a.get('labels', {}).get('alertname', '?')
        if name in FALSE_POSITIVES or any(name.startswith(p) for p in IGNORE_PREFIXES):
            fp_firing.append(a)
        else:
            real_firing.append(a)

    if not real_firing and not pending:
        print('  [OK]   Aucune alerte reelle active')
    else:
        if real_firing:
            print(f'  [WARN] {len(real_firing)} alerte(s) firing :')
            for a in real_firing:
                labels = a.get('labels', {})
                name = labels.get('alertname', '?')
                severity = labels.get('severity', '?')
                ns = labels.get('namespace', '-')
                summary = a.get('annotations', {}).get('summary', '')
                description = a.get('annotations', {}).get('description', '')

                icon = '[FAIL]' if severity == 'critical' else '[WARN]'
                print(f'    {icon} {name} [{severity}] ns={ns}')
                if summary:
                    print(f'           {summary}')
                if description:
                    desc = description[:120] + '...' if len(description) > 120 else description
                    print(f'           {desc}')
                print()

        if pending:
            real_pending = [a for a in pending
                if a.get('labels',{}).get('alertname','') not in FALSE_POSITIVES
                and not any(a.get('labels',{}).get('alertname','').startswith(p) for p in IGNORE_PREFIXES)]
            if real_pending:
                print(f'  [INFO] {len(real_pending)} alerte(s) pending :')
                for a in real_pending:
                    labels = a.get('labels', {})
                    name = labels.get('alertname', '?')
                    severity = labels.get('severity', '?')
                    print(f'    [INFO] {name} [{severity}]')

    # Resume faux positifs
    if fp_firing:
        fp_names = sorted(set(a.get('labels',{}).get('alertname','?') for a in fp_firing))
        print(f'  [INFO] {len(fp_firing)} faux positif(s) ignores : {', '.join(fp_names)}')

except json.JSONDecodeError:
    print('  [WARN] Reponse Prometheus non-JSON')
except Exception as e:
    print(f'  [WARN] Erreur parsing alertes: {e}')
" 2>/dev/null || warn "Impossible de parser les alertes"
        else
            warn "Impossible de contacter Prometheus via kubectl proxy"
            info "Vérifiez manuellement : https://prometheus.app.xixtu.eu/alerts"
        fi
    fi

    # Fallback : vérifier les PrometheusRules configurées
    echo ""
    info "PrometheusRules configurées :"
    $KUBECTL get prometheusrules --all-namespaces 2>/dev/null | sed 's/^/    /' || \
        warn "CRD PrometheusRule non disponible"
}

# =============================================================
# 10. CERTIFICATS TLS
# =============================================================
audit_certificates() {
    section "10. CERTIFICATS TLS — Expiration"

    echo ""
    $KUBECTL get certificates --all-namespaces 2>/dev/null | sed 's/^/  /' || \
        warn "Aucun Certificate cert-manager"

    echo ""
    info "Détail expiration :"
    $KUBECTL get certificates --all-namespaces -o json 2>/dev/null | python3 -c "
import json, sys
from datetime import datetime, timezone

data = json.load(sys.stdin)
now = datetime.now(timezone.utc)

for cert in data.get('items', []):
    ns = cert['metadata']['namespace']
    name = cert['metadata']['name']

    ready = 'Unknown'
    for cond in cert.get('status', {}).get('conditions', []):
        if cond.get('type') == 'Ready':
            ready = cond.get('status', 'Unknown')

    not_after = cert.get('status', {}).get('notAfter', '')
    renewal = cert.get('status', {}).get('renewalTime', '')

    days_left = '?'
    if not_after:
        try:
            expiry = datetime.fromisoformat(not_after.replace('Z', '+00:00'))
            days_left = (expiry - now).days
        except:
            pass

    if ready != 'True':
        print(f'  [FAIL] {ns}/{name} — Ready={ready}')
    elif isinstance(days_left, int) and days_left < 7:
        print(f'  [FAIL] {ns}/{name} — expire dans {days_left}j !')
    elif isinstance(days_left, int) and days_left < 30:
        print(f'  [WARN] {ns}/{name} — expire dans {days_left}j')
    else:
        print(f'  [OK]   {ns}/{name} — Ready, expire dans {days_left}j')
" 2>/dev/null || warn "Impossible de vérifier les certificats"
}

# =============================================================
# 11. LONGHORN
# =============================================================
audit_longhorn() {
    section "11. LONGHORN — Santé stockage"

    echo ""
    info "Nœuds Longhorn :"
    $KUBECTL get nodes.longhorn.io -n longhorn-system 2>/dev/null | sed 's/^/  /' || \
        warn "CRD Longhorn non disponible"

    echo ""
    info "État des répliques :"
    $KUBECTL get replicas.longhorn.io -n longhorn-system --no-headers 2>/dev/null | \
        awk '{state=$NF; count[state]++} END {for (s in count) print "    "s": "count[s]}' || true

    local failed_replicas
    failed_replicas=$($KUBECTL get replicas.longhorn.io -n longhorn-system --no-headers 2>/dev/null | \
        grep -v "running\|stopped" || true)
    if [ -n "$failed_replicas" ]; then
        warn "Répliques en état anormal :"
        echo "$failed_replicas" | head -10 | sed 's/^/    /'
    else
        ok "Toutes les répliques Longhorn sont saines"
    fi

    echo ""
    info "Engines Longhorn :"
    $KUBECTL get engines.longhorn.io -n longhorn-system --no-headers 2>/dev/null | \
        awk '{state=$NF; count[state]++} END {for (s in count) print "    "s": "count[s]}' || true
}

# =============================================================
# 12. INGRESS / ROUTES
# =============================================================
audit_ingress_health() {
    section "12. INGRESS — Accessibilité"

    echo ""
    info "IngressRoutes Traefik :"
    $KUBECTL get ingressroute --all-namespaces 2>/dev/null | sed 's/^/  /' || \
        warn "Aucun IngressRoute"

    echo ""
    info "Ingress standard :"
    $KUBECTL get ingress --all-namespaces 2>/dev/null | sed 's/^/  /' || \
        warn "Aucun Ingress"
}

# =============================================================
# 13. RÉSUMÉ GLOBAL
# =============================================================
print_summary() {
    section "RÉSUMÉ GLOBAL"

    echo ""
    echo -e "  ${GREEN}OK${NC}   : $TOTAL_OK"
    echo -e "  ${YELLOW}WARN${NC} : $TOTAL_WARN"
    echo -e "  ${RED}FAIL${NC} : $TOTAL_FAIL"
    echo ""

    if [ "$TOTAL_FAIL" -gt 0 ]; then
        echo -e "  ${RED}${BOLD}=> Des problèmes critiques ont été détectés.${NC}"
        echo "     Examinez les [FAIL] ci-dessus et corrigez-les."
    elif [ "$TOTAL_WARN" -gt 0 ]; then
        echo -e "  ${YELLOW}${BOLD}=> Des avertissements ont été détectés.${NC}"
        echo "     Examinez les [WARN] ci-dessus. Certains peuvent être des faux positifs."
    else
        echo -e "  ${GREEN}${BOLD}=> Cluster en bonne santé !${NC}"
    fi

    echo ""
    echo "  Rapport sauvegardé dans : $REPORT"
    echo ""

    echo ""
    echo "  AIDE POUR LES FAUX POSITIFS COURANTS :"
    echo "  ─────────────────────────────────────────"
    echo "  • KubeDeploymentRolloutStuck : Peut se déclencher jusqu'à 15min après"
    echo "    un redéploiement — attendre la fin du rollout."
    echo "  • KubePodNotReady : Peut apparaître pour des Jobs terminés ou"
    echo "    des pods de migration (Helm hooks). Vérifier si le pod est attendu."
    echo "  • Watchdog / InfoInhibitor : Alertes de test — toujours firing, c'est normal."
    echo "  • CPUThrottlingHigh : Courant si limits CPU trop basses vs requests."
    echo "    Vérifier si l'app fonctionne normalement malgré le throttling."
    echo "  • etcd_* alertes : Normales en k3s (utilise SQLite/dqlite, pas etcd)."
    echo ""
}

# =============================================================
# MAIN
# =============================================================
main() {
    echo "=============================================================="
    echo "  AUDIT SANTÉ CLUSTER K3S — Post-Hardening"
    echo "  $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "=============================================================="

    check_prerequisites
    audit_nodes
    audit_pods
    audit_deployments
    audit_statefulsets
    audit_pvcs
    audit_events
    audit_security
    audit_services
    audit_prometheus_alerts
    audit_certificates
    audit_longhorn
    audit_ingress_health
    print_summary
}

main 2>&1 | tee "$REPORT"
