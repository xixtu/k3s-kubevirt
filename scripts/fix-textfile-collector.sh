#!/bin/bash
# =============================================================================
# fix-textfile-collector.sh
# Corrige le textfile collector node_smart_* sans SSH via kubectl.
#
# Ce script remplace l'exécution du playbook monitoring-hardware.yml
# quand le SSH Ansible est cassé. Il :
#   1. Diagnostique l'état actuel (DaemonSet + Helm)
#   2. Corrige le volumeMount node-exporter via helm upgrade
#   3. Déploie smart-metrics.sh + cron sur chaque nœud (privileged pods)
#   4. Crée le répertoire textfile_collector sur chaque host
#   5. Exécute smart-metrics.sh une première fois sur chaque nœud
#   6. Attend le rollout et vérifie
#
# Usage : ./scripts/fix-textfile-collector.sh
# Prérequis : kubectl configuré, helm configuré
# =============================================================================

set -uo pipefail

NAMESPACE="monitoring"
RELEASE="kube-prometheus-stack"
CHART_VERSION="55.5.0"
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SMART_SCRIPT="$SCRIPT_DIR/smart-metrics.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()      { echo -e "  ${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "  ${YELLOW}[WARN]${RESET}  $*"; }
err()     { echo -e "  ${RED}[ERR]${RESET}    $*"; }
info()    { echo -e "  ${CYAN}[INFO]${RESET}   $*"; }
section() { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }

# ── Vérifier que smart-metrics.sh existe localement ──────────────────────────
if [[ ! -f "$SMART_SCRIPT" ]]; then
  err "scripts/smart-metrics.sh introuvable (attendu: $SMART_SCRIPT)"
  exit 1
fi

# =============================================================================
# ÉTAPE 1 : DIAGNOSTIC
# =============================================================================
section "ÉTAPE 1 : Diagnostic"

info "Volumes dans le DaemonSet node-exporter :"
kubectl get ds kube-prometheus-stack-prometheus-node-exporter \
  -n "$NAMESPACE" \
  -o jsonpath='{range .spec.template.spec.volumes[*]}  volume: {.name}  hostPath: {.hostPath.path}{"\n"}{end}' \
  2>/dev/null || warn "DaemonSet non trouvé"

echo ""
info "volumeMounts dans le conteneur :"
kubectl get ds kube-prometheus-stack-prometheus-node-exporter \
  -n "$NAMESPACE" \
  -o jsonpath='{range .spec.template.spec.containers[0].volumeMounts[*]}  mount: {.name}  → {.mountPath}{"\n"}{end}' \
  2>/dev/null || true

echo ""
info "Helm values (extraArgs/extraVolumes actuels) :"
helm get values "$RELEASE" -n "$NAMESPACE" 2>/dev/null \
  | grep -A12 'node-exporter\|textfile\|extraArg\|extraVolume' || warn "helm get values vide"

# =============================================================================
# ÉTAPE 2 : HELM UPGRADE (textfile volumeMount)
# =============================================================================
section "ÉTAPE 2 : Helm upgrade — ajout volumeMount textfile_collector"

cat > /tmp/node-exporter-hw-values.yml << 'HELMEOF'
prometheus-node-exporter:
  extraArgs:
    - --collector.textfile.directory=/host/textfile_collector
  extraVolumes:
    - name: textfile-collector
      hostPath:
        path: /var/lib/node_exporter/textfile_collector
        type: DirectoryOrCreate
  extraVolumeMounts:
    - name: textfile-collector
      mountPath: /host/textfile_collector
HELMEOF

info "Contenu du fichier de valeurs :"
cat /tmp/node-exporter-hw-values.yml | sed 's/^/  /'

echo ""
info "Lancement helm upgrade --reuse-values ..."
helm upgrade "$RELEASE" \
  prometheus-community/kube-prometheus-stack \
  --namespace "$NAMESPACE" \
  --reuse-values \
  --version "$CHART_VERSION" \
  --values /tmp/node-exporter-hw-values.yml \
  --wait \
  --timeout 5m \
  --atomic && ok "Helm upgrade réussi" || { err "Helm upgrade échoué"; exit 1; }

rm -f /tmp/node-exporter-hw-values.yml

# =============================================================================
# ÉTAPE 3 : SETUP SUR CHAQUE NŒUD (privileged pod)
# Pour chaque nœud : créer répertoire + déployer script + cron + run
# =============================================================================
section "ÉTAPE 3 : Setup host (répertoire + smart-metrics.sh + cron)"

NODES=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')

for NODE in $NODES; do
  echo ""
  echo -e "  ${BOLD}→ Nœud : ${NODE}${RESET}"
  POD="textfile-fix-${NODE/k3s-/}"

  # Nettoyer un éventuel pod résiduel
  kubectl delete pod "$POD" -n kube-system --ignore-not-found --wait=false 2>/dev/null || true
  sleep 1

  # Créer le pod privilégié avec la racine du host montée
  cat > "/tmp/fix-pod-${NODE}.yml" << PODEOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: kube-system
  labels:
    app: textfile-fix
spec:
  nodeName: ${NODE}
  restartPolicy: Never
  tolerations:
  - operator: Exists
  hostPID: true
  containers:
  - name: fix
    image: alpine:3.19
    command: ["sleep", "180"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: host-root
      mountPath: /host
  volumes:
  - name: host-root
    hostPath:
      path: /
PODEOF

  kubectl apply -f "/tmp/fix-pod-${NODE}.yml" -n kube-system >/dev/null
  rm -f "/tmp/fix-pod-${NODE}.yml"

  # Attendre que le pod soit Running
  info "Démarrage du pod ${POD}..."
  if ! kubectl wait pod/"$POD" -n kube-system \
       --for=condition=Ready --timeout=60s 2>/dev/null; then
    err "Pod ${POD} ne démarre pas"
    kubectl describe pod "$POD" -n kube-system | tail -10
    kubectl delete pod "$POD" -n kube-system --wait=false 2>/dev/null || true
    continue
  fi

  # ── Créer le répertoire textfile_collector ─────────────────────────────────
  kubectl exec "$POD" -n kube-system -- \
    mkdir -p "/host${TEXTFILE_DIR}" && \
    ok "Répertoire ${TEXTFILE_DIR} créé/vérifié" || \
    err "Échec création répertoire"

  kubectl exec "$POD" -n kube-system -- \
    chmod 755 "/host${TEXTFILE_DIR}"

  # ── Déployer smart-metrics.sh sur le host ─────────────────────────────────
  info "Copie de smart-metrics.sh vers /host/usr/local/bin/ ..."
  kubectl cp "$SMART_SCRIPT" "kube-system/${POD}:/tmp/smart-metrics.sh" && \
    kubectl exec "$POD" -n kube-system -- \
      cp /tmp/smart-metrics.sh /host/usr/local/bin/smart-metrics.sh && \
    kubectl exec "$POD" -n kube-system -- \
      chmod 755 /host/usr/local/bin/smart-metrics.sh && \
    ok "smart-metrics.sh déployé" || \
    err "Échec déploiement smart-metrics.sh"

  # ── Vérifier que smartctl est disponible sur le host ──────────────────────
  if kubectl exec "$POD" -n kube-system -- \
       ls /host/usr/sbin/smartctl &>/dev/null; then
    ok "smartctl présent sur le host"
  else
    warn "smartctl absent ! Installation via chroot apt-get ..."
    kubectl exec "$POD" -n kube-system -- \
      chroot /host apt-get install -y --no-install-recommends smartmontools \
      2>&1 | tail -3 | sed 's/^/      /' || err "Impossible d'installer smartmontools"
  fi

  # ── Créer le cron job ─────────────────────────────────────────────────────
  info "Configuration cron /etc/cron.d/smart-metrics-prom ..."
  kubectl exec "$POD" -n kube-system -- sh -c \
    "printf '*/5 * * * * root /usr/local/bin/smart-metrics.sh 2>/dev/null\n' \
     > /host/etc/cron.d/smart-metrics-prom && chmod 644 /host/etc/cron.d/smart-metrics-prom" && \
    ok "Cron configuré (toutes les 5 min)" || \
    err "Échec configuration cron"

  # ── Exécuter smart-metrics.sh une première fois (via chroot host) ─────────
  info "Exécution initiale de smart-metrics.sh (chroot host) ..."
  kubectl exec "$POD" -n kube-system -- \
    chroot /host /usr/local/bin/smart-metrics.sh 2>&1 | sed 's/^/      /' || \
    warn "Script retourné avec code non-nul (vérifier les disques)"

  # ── Afficher le résultat ──────────────────────────────────────────────────
  PROM_LINES=$(kubectl exec "$POD" -n kube-system -- \
    sh -c "wc -l < /host${TEXTFILE_DIR}/smart.prom 2>/dev/null || echo 0")
  PROM_CONTENT=$(kubectl exec "$POD" -n kube-system -- \
    cat "/host${TEXTFILE_DIR}/smart.prom" 2>/dev/null || true)

  if [[ -z "$PROM_CONTENT" ]]; then
    warn "smart.prom vide ou absent après exécution"
    info "Contenu de ${TEXTFILE_DIR} :"
    kubectl exec "$POD" -n kube-system -- ls -la "/host${TEXTFILE_DIR}/" | sed 's/^/      /'
  else
    ok "smart.prom généré (${PROM_LINES} lignes)"
    echo "$PROM_CONTENT" | grep '^node_smart_device_health' | sed 's/^/      /'
  fi

  # ── Supprimer le pod ──────────────────────────────────────────────────────
  kubectl delete pod "$POD" -n kube-system --wait=false 2>/dev/null || true
done

# =============================================================================
# ÉTAPE 4 : ATTENDRE LE ROLLOUT DU DAEMONSET
# =============================================================================
section "ÉTAPE 4 : Rollout DaemonSet node-exporter"

info "Attente du rollout DaemonSet (helm upgrade l'a déclenché)..."
kubectl rollout status daemonset/kube-prometheus-stack-prometheus-node-exporter \
  -n "$NAMESPACE" --timeout=120s && \
  ok "DaemonSet ready" || \
  warn "Rollout toujours en cours — attendre quelques secondes et vérifier"

# =============================================================================
# ÉTAPE 5 : VÉRIFICATION FINALE
# =============================================================================
section "ÉTAPE 5 : Vérification"

info "Attente 10s pour que les pods soient stables..."
sleep 10

VALIDATE="$SCRIPT_DIR/validate-textfile-collector.sh"
if [[ -x "$VALIDATE" ]]; then
  "$VALIDATE"
else
  warn "validate-textfile-collector.sh non trouvé — vérifier manuellement :"
  echo "  kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=prometheus-node-exporter"
fi
