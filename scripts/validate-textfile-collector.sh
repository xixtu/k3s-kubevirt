#!/bin/bash
# =============================================================================
# validate-textfile-collector.sh
# Valide les métriques node_smart_* et node_hwmon_* exposées par le
# textfile collector de chaque node-exporter via kubectl port-forward.
#
# Usage : ./scripts/validate-textfile-collector.sh
# Prérequis : kubectl configuré (kubeconfig valide)
# =============================================================================

set -euo pipefail

NAMESPACE="monitoring"
# Label selector du DaemonSet node-exporter (kube-prometheus-stack)
SELECTOR="app.kubernetes.io/name=prometheus-node-exporter"
# Port local de base (incrémenté par pod pour éviter les conflits)
BASE_PORT=19100

# Métriques node_smart_* créées par smart-metrics.sh
SMART_METRICS=(
  node_smart_device_health
  node_smart_temperature_celsius
  node_smart_reallocated_sectors_total
  node_smart_pending_sectors_total
  node_smart_uncorrectable_errors_total
  node_smart_power_on_hours_total
  node_smart_power_cycles_total
  node_smart_collection_timestamp_seconds
)

# ── couleurs ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "  ${GREEN}[OK]${RESET}  $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${RESET} $*"; }
err()  { echo -e "  ${RED}[ERR]${RESET}  $*"; }

# ── attendre que le port-forward soit prêt ────────────────────────────────────
wait_for_port() {
  local port=$1 retries=15 i
  for ((i=0; i<retries; i++)); do
    if curl -sf --max-time 1 "http://localhost:${port}/metrics" &>/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# ── liste des pods node-exporter avec leur nœud ──────────────────────────────
echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${CYAN}  Validation textfile collector — node_smart_* & node_hwmon_*  ${RESET}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}\n"

mapfile -t POD_LINES < <(
  kubectl get pods -n "$NAMESPACE" -l "$SELECTOR" \
    -o jsonpath='{range .items[*]}{.metadata.name} {.spec.nodeName} {.status.podIP}{"\n"}{end}' \
    2>/dev/null
)

if [[ ${#POD_LINES[@]} -eq 0 ]]; then
  echo -e "${RED}Aucun pod node-exporter trouvé dans namespace '${NAMESPACE}'.${RESET}"
  echo "  → kubectl get pods -n ${NAMESPACE} -l ${SELECTOR}"
  exit 1
fi

echo -e "Pods trouvés : ${#POD_LINES[@]}\n"

GLOBAL_OK=0; GLOBAL_WARN=0; GLOBAL_ERR=0
PORT=$BASE_PORT

for line in "${POD_LINES[@]}"; do
  POD=$(echo "$line"  | awk '{print $1}')
  NODE=$(echo "$line" | awk '{print $2}')
  IP=$(echo "$line"   | awk '{print $3}')

  echo -e "${BOLD}┌─ Pod : ${POD}${RESET}"
  echo -e   "│  Node: ${NODE}  IP: ${IP}  port-forward → localhost:${PORT}"

  # ── démarrer le port-forward ───────────────────────────────────────────────
  kubectl port-forward -n "$NAMESPACE" "pod/${POD}" "${PORT}:9100" \
    >/tmp/pf-${POD}.log 2>&1 &
  PF_PID=$!

  if ! wait_for_port "$PORT"; then
    err "Port-forward échoué (pod inaccessible)"
    kill "$PF_PID" 2>/dev/null; wait "$PF_PID" 2>/dev/null
    echo -e "└─\n"
    PORT=$((PORT + 1)); GLOBAL_ERR=$((GLOBAL_ERR+1)); continue
  fi

  # ── récupérer /metrics ─────────────────────────────────────────────────────
  METRICS=$(curl -sf --max-time 10 "http://localhost:${PORT}/metrics" 2>/dev/null || true)

  if [[ -z "$METRICS" ]]; then
    err "Impossible de récupérer /metrics"
    kill "$PF_PID" 2>/dev/null; wait "$PF_PID" 2>/dev/null
    echo -e "└─\n"
    PORT=$((PORT + 1)); GLOBAL_ERR=$((GLOBAL_ERR+1)); continue
  fi

  # ── 1. node_textfile_scrape_error ──────────────────────────────────────────
  echo -e "│"
  echo -e "│  ${BOLD}[1] Erreurs textfile collector${RESET}"
  SCRAPE_ERRORS=$(echo "$METRICS" | grep '^node_textfile_scrape_error{' || true)
  if [[ -z "$SCRAPE_ERRORS" ]]; then
    warn "Métrique node_textfile_scrape_error absente (scrape en cours ?)"
    GLOBAL_WARN=$((GLOBAL_WARN+1))
  else
    while IFS= read -r eline; do
      val=$(echo "$eline" | awk '{print $NF}')
      file=$(echo "$eline" | grep -oP 'path="[^"]+"' || echo "path=?")
      if [[ "$val" == "1" ]]; then
        err "SCRAPE ERROR  ${file}  → valeur=${val}"
        GLOBAL_ERR=$((GLOBAL_ERR+1))
      else
        ok  "scrape OK    ${file}"
        GLOBAL_OK=$((GLOBAL_OK+1))
      fi
    done <<< "$SCRAPE_ERRORS"
  fi

  # ── 2. métriques node_smart_* ──────────────────────────────────────────────
  echo -e "│"
  echo -e "│  ${BOLD}[2] Métriques node_smart_*${RESET}"
  for m in "${SMART_METRICS[@]}"; do
    count=$(echo "$METRICS" | grep -c "^${m}{" 2>/dev/null || true)
    if [[ $count -gt 0 ]]; then
      # Afficher un sample (premier disque)
      sample=$(echo "$METRICS" | grep "^${m}{" | head -1)
      ok  "${m}  (${count} série(s))   ex: $(echo "$sample" | cut -c1-90)"
      GLOBAL_OK=$((GLOBAL_OK+1))
    else
      # node_smart_collection_timestamp_seconds n'a pas de labels {}
      count2=$(echo "$METRICS" | grep -c "^${m} " 2>/dev/null || true)
      if [[ $count2 -gt 0 ]]; then
        sample=$(echo "$METRICS" | grep "^${m} " | head -1)
        ok "${m}  →  ${sample}"
        GLOBAL_OK=$((GLOBAL_OK+1))
      else
        warn "${m}  → ABSENT (pas encore généré ou tous les disques filtrés)"
        GLOBAL_WARN=$((GLOBAL_WARN+1))
      fi
    fi
  done

  # ── 3. ventilateurs node_hwmon_fan_rpm ────────────────────────────────────
  echo -e "│"
  echo -e "│  ${BOLD}[3] Ventilateurs node_hwmon_fan_rpm${RESET}"
  FAN_LINES=$(echo "$METRICS" | grep '^node_hwmon_fan_rpm{' || true)
  if [[ -z "$FAN_LINES" ]]; then
    warn "node_hwmon_fan_rpm absent (module dell-smm-hwmon non chargé ?)"
    GLOBAL_WARN=$((GLOBAL_WARN+1))
  else
    while IFS= read -r fline; do
      rpm=$(echo "$fline" | awk '{print $NF}')
      sensor=$(echo "$fline" | grep -oP 'sensor="[^"]+"' | cut -d= -f2 | tr -d '"')
      chip=$(echo "$fline"   | grep -oP 'chip="[^"]+"'   | cut -d= -f2 | tr -d '"')
      if [[ "$rpm" == "0" ]]; then
        warn "  ${sensor} (${chip}) = 0 RPM"
        GLOBAL_WARN=$((GLOBAL_WARN+1))
      else
        ok  "  ${sensor} (${chip}) = ${rpm} RPM"
        GLOBAL_OK=$((GLOBAL_OK+1))
      fi
    done <<< "$FAN_LINES"
  fi

  # ── 4. températures node_hwmon_temp_celsius ───────────────────────────────
  echo -e "│"
  echo -e "│  ${BOLD}[4] Températures node_hwmon_temp_celsius${RESET}"
  TEMP_COUNT=$(echo "$METRICS" | grep -c '^node_hwmon_temp_celsius{' 2>/dev/null || true)
  if [[ $TEMP_COUNT -gt 0 ]]; then
    ok "${TEMP_COUNT} série(s) de température hwmon"
    GLOBAL_OK=$((GLOBAL_OK+1))
  else
    warn "node_hwmon_temp_celsius absent"
    GLOBAL_WARN=$((GLOBAL_WARN+1))
  fi

  # ── fin pod ────────────────────────────────────────────────────────────────
  kill "$PF_PID" 2>/dev/null; wait "$PF_PID" 2>/dev/null
  echo -e "└─"
  echo ""
  PORT=$((PORT + 1))
done

# ── bilan global ──────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}══════════════════ BILAN ══════════════════${RESET}"
echo -e "  ${GREEN}OK    : ${GLOBAL_OK}${RESET}"
echo -e "  ${YELLOW}WARN  : ${GLOBAL_WARN}${RESET}"
echo -e "  ${RED}ERREUR: ${GLOBAL_ERR}${RESET}"

if [[ $GLOBAL_ERR -gt 0 ]]; then
  echo -e "\n${RED}→ Des erreurs sont présentes. Vérifier les fichiers .prom sur les nœuds :${RESET}"
  echo "  ansible k3s_cluster -a 'ls -la /var/lib/node_exporter/textfile_collector/'"
  echo "  ansible k3s_cluster -a 'cat /var/lib/node_exporter/textfile_collector/smart.prom'"
  exit 1
elif [[ $GLOBAL_WARN -gt 0 ]]; then
  echo -e "\n${YELLOW}→ Avertissements présents. Vérifier cron et modules kernel.${RESET}"
  exit 2
else
  echo -e "\n${GREEN}→ Tout est valide.${RESET}"
  exit 0
fi
