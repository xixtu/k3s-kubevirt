#!/bin/bash
# =============================================================================
# validate-textfile-collector.sh
# Valide les métriques node_smart_* et node_hwmon_* exposées par le
# textfile collector de chaque node-exporter via kubectl port-forward.
#
# Usage : ./scripts/validate-textfile-collector.sh
# Prérequis : kubectl configuré (kubeconfig valide)
# =============================================================================

# -e retiré intentionnellement : wait sur un process tué retourne 143 (SIGTERM)
# et ferait quitter le script prématurément après le premier pod.
set -uo pipefail

NAMESPACE="monitoring"
SELECTOR="app.kubernetes.io/name=prometheus-node-exporter"
BASE_PORT=19100
TEXTFILE_DIR_HOST="/var/lib/node_exporter/textfile_collector"   # sur le host
TEXTFILE_DIR_CTR="/host/textfile_collector"                     # dans le conteneur

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
info() { echo -e "  ${CYAN}[INFO]${RESET} $*"; }

# ── attendre que le port-forward soit prêt ────────────────────────────────────
wait_for_port() {
  local port=$1 i
  for ((i=0; i<20; i++)); do
    if curl -sf --max-time 1 "http://localhost:${port}/metrics" &>/dev/null; then
      return 0
    fi
    sleep 0.4
  done
  return 1
}

# ── tuer proprement le port-forward (|| true évite set -e sur wait) ──────────
kill_pf() {
  local pid=$1
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null || true   # wait retourne 143 (SIGTERM) → || true obligatoire
}

# ── liste des pods node-exporter ─────────────────────────────────────────────
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
  POD=$(awk '{print $1}' <<< "$line")
  NODE=$(awk '{print $2}' <<< "$line")
  IP=$(awk '{print $3}'   <<< "$line")

  echo -e "${BOLD}┌─ Pod : ${POD}${RESET}"
  echo -e   "│  Node: ${NODE}  IP: ${IP}  port-forward → localhost:${PORT}"

  # ── 0. Contenu réel du répertoire textfile (kubectl exec) ─────────────────
  echo -e "│"
  echo -e "│  ${BOLD}[0] Répertoire textfile_collector (kubectl exec)${RESET}"
  DIR_LS=$(kubectl exec -n "$NAMESPACE" "$POD" -- ls -la "$TEXTFILE_DIR_CTR" 2>&1) || true
  if echo "$DIR_LS" | grep -q 'No such file\|cannot access\|not found'; then
    err "Répertoire ${TEXTFILE_DIR_CTR} INTROUVABLE dans le conteneur"
    err "  → vérifier le volumeMount dans le DaemonSet node-exporter"
    GLOBAL_ERR=$((GLOBAL_ERR+1))
  else
    info "Contenu de ${TEXTFILE_DIR_CTR} :"
    while IFS= read -r l; do echo -e "  │    $l"; done <<< "$DIR_LS"

    # Afficher le contenu de smart.prom si présent
    PROM_CONTENT=$(kubectl exec -n "$NAMESPACE" "$POD" -- \
      cat "${TEXTFILE_DIR_CTR}/smart.prom" 2>/dev/null) || true
    if [[ -z "$PROM_CONTENT" ]]; then
      warn "smart.prom absent ou vide dans le conteneur"
      GLOBAL_WARN=$((GLOBAL_WARN+1))
    else
      PROM_LINES=$(wc -l <<< "$PROM_CONTENT")
      info "smart.prom : ${PROM_LINES} lignes"
      # Chercher des lignes suspectes (ne commençant pas par #, node_, ou vide)
      BAD=$(echo "$PROM_CONTENT" | grep -vE '^#|^node_|^[[:space:]]*$' || true)
      if [[ -n "$BAD" ]]; then
        err "Lignes invalides dans smart.prom (format Prometheus non respecté) :"
        while IFS= read -r bl; do echo -e "  │    ${RED}→ ${bl}${RESET}"; done <<< "$BAD"
        GLOBAL_ERR=$((GLOBAL_ERR+1))
      else
        ok "smart.prom : format valide (${PROM_LINES} lignes)"
        GLOBAL_OK=$((GLOBAL_OK+1))
      fi
    fi
  fi

  # ── port-forward ──────────────────────────────────────────────────────────
  kubectl port-forward -n "$NAMESPACE" "pod/${POD}" "${PORT}:9100" \
    >/tmp/pf-${POD}.log 2>&1 &
  PF_PID=$!

  if ! wait_for_port "$PORT"; then
    err "Port-forward échoué (log: /tmp/pf-${POD}.log)"
    kill_pf "$PF_PID"
    echo -e "└─"; echo ""
    PORT=$((PORT + 1)); GLOBAL_ERR=$((GLOBAL_ERR+1)); continue
  fi

  METRICS=$(curl -sf --max-time 10 "http://localhost:${PORT}/metrics" 2>/dev/null || true)

  if [[ -z "$METRICS" ]]; then
    err "Impossible de récupérer /metrics depuis localhost:${PORT}"
    kill_pf "$PF_PID"
    echo -e "└─"; echo ""
    PORT=$((PORT + 1)); GLOBAL_ERR=$((GLOBAL_ERR+1)); continue
  fi

  # ── 1. node_textfile_scrape_error ─────────────────────────────────────────
  echo -e "│"
  echo -e "│  ${BOLD}[1] Erreurs textfile collector${RESET}"
  # Accepte les variantes : avec labels "{path=...}" et sans labels (vieux node_exporter)
  SCRAPE_LINES=$(echo "$METRICS" | grep '^node_textfile_scrape_error' || true)
  if [[ -z "$SCRAPE_LINES" ]]; then
    warn "node_textfile_scrape_error ABSENT → répertoire textfile vide ou collector non activé"
    GLOBAL_WARN=$((GLOBAL_WARN+1))
  else
    while IFS= read -r eline; do
      [[ "$eline" =~ ^# ]] && continue   # ignorer les lignes HELP/TYPE
      val=$(awk '{print $NF}' <<< "$eline")
      # Extraire le path si présent, sinon "(global)"
      fpath=$(grep -oP 'path="[^"]+"' <<< "$eline" 2>/dev/null || echo '(global)')
      if [[ "$val" == "1" ]]; then
        err "SCRAPE ERROR  ${fpath}"
        GLOBAL_ERR=$((GLOBAL_ERR+1))
      else
        ok  "scrape OK    ${fpath}"
        GLOBAL_OK=$((GLOBAL_OK+1))
      fi
    done <<< "$SCRAPE_LINES"
  fi

  # ── 2. métriques node_smart_* ─────────────────────────────────────────────
  echo -e "│"
  echo -e "│  ${BOLD}[2] Métriques node_smart_*${RESET}"
  for m in "${SMART_METRICS[@]}"; do
    # Cherche les lignes de données (pas les commentaires)
    MLINES=$(echo "$METRICS" | grep "^${m}[{ ]" || true)
    count=$(echo "$MLINES" | grep -c . 2>/dev/null || true)
    if [[ $count -gt 0 ]]; then
      sample=$(head -1 <<< "$MLINES" | cut -c1-95)
      ok "${m}  (${count} série(s))   ${sample}"
      GLOBAL_OK=$((GLOBAL_OK+1))
    else
      warn "${m}  → ABSENT"
      GLOBAL_WARN=$((GLOBAL_WARN+1))
    fi
  done

  # ── 3. ventilateurs node_hwmon_fan_rpm ────────────────────────────────────
  echo -e "│"
  echo -e "│  ${BOLD}[3] Ventilateurs node_hwmon_fan_rpm${RESET}"
  FAN_LINES=$(echo "$METRICS" | grep '^node_hwmon_fan_rpm{' || true)
  if [[ -z "$FAN_LINES" ]]; then
    warn "node_hwmon_fan_rpm absent"
    GLOBAL_WARN=$((GLOBAL_WARN+1))
  else
    while IFS= read -r fline; do
      rpm=$(awk '{print $NF}' <<< "$fline")
      sensor=$(grep -oP 'sensor="[^"]+"' <<< "$fline" | cut -d'"' -f2 || echo "?")
      chip=$(grep -oP 'chip="[^"]+"'     <<< "$fline" | cut -d'"' -f2 || echo "?")
      if [[ "$rpm" == "0" ]]; then
        warn "${sensor} (${chip}) = 0 RPM"
        GLOBAL_WARN=$((GLOBAL_WARN+1))
      else
        ok  "${sensor} (${chip}) = ${rpm} RPM"
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

  # ── fin pod ───────────────────────────────────────────────────────────────
  kill_pf "$PF_PID"
  echo -e "└─"; echo ""
  PORT=$((PORT + 1))
done

# ── bilan global ──────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}══════════════════ BILAN ══════════════════${RESET}"
echo -e "  ${GREEN}OK    : ${GLOBAL_OK}${RESET}"
echo -e "  ${YELLOW}WARN  : ${GLOBAL_WARN}${RESET}"
echo -e "  ${RED}ERREUR: ${GLOBAL_ERR}${RESET}"

if [[ $GLOBAL_ERR -gt 0 ]]; then
  echo -e "\n${RED}→ Des erreurs détectées. Inspecter le smart.prom sur les nœuds :${RESET}"
  echo "  ansible k3s_cluster -a 'ls -la ${TEXTFILE_DIR_HOST}/'"
  echo "  ansible k3s_cluster -a 'cat ${TEXTFILE_DIR_HOST}/smart.prom'"
  echo "  ansible k3s_cluster -a '/usr/local/bin/smart-metrics.sh && echo OK'"
  exit 1
elif [[ $GLOBAL_WARN -gt 0 ]]; then
  echo -e "\n${YELLOW}→ Avertissements présents. Vérifier cron et modules kernel.${RESET}"
  exit 2
else
  echo -e "\n${GREEN}→ Tout est valide.${RESET}"
  exit 0
fi
