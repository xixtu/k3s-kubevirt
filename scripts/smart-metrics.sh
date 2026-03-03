#!/bin/bash
# ==========================================================
# smart-metrics.sh - Métriques SMART au format Prometheus
# Exécuté par cron toutes les 5 minutes
# Sortie : /var/lib/node_exporter/textfile_collector/smart.prom
# ==========================================================
# Pas de set -e : smartctl retourne des codes non-nuls légitimes
# (bit 3 = FAILED, bit 4 = prefail attr, bit 6 = error log, etc.)

OUTPUT_FILE="/var/lib/node_exporter/textfile_collector/smart.prom"
TMP_FILE="${OUTPUT_FILE}.tmp"

# Extraire un attribut SATA (colonne RAW_VALUE = col 10) depuis $1
# head -1 : évite plusieurs lignes si l'attribut apparaît plusieurs fois
# grep -E '^[0-9]+$' : ne retourne rien si la valeur est composite (ex: 18013h+00m)
parse_attr() {
  echo "$1" | grep "$2" | awk '{print $10}' | head -1 | grep -E '^[0-9]+$'
}

# Tout le contenu est redirigé vers TMP_FILE via le bloc { }
# puis remplacé atomiquement — node-exporter ne lit jamais un fichier partiel
{
  echo "# HELP node_smart_device_health SMART overall health (1=PASSED 0=FAILED)"
  echo "# TYPE node_smart_device_health gauge"
  echo "# HELP node_smart_temperature_celsius Disk temperature in Celsius"
  echo "# TYPE node_smart_temperature_celsius gauge"
  echo "# HELP node_smart_reallocated_sectors_total Reallocated sector count (SMART attr 5)"
  echo "# TYPE node_smart_reallocated_sectors_total gauge"
  echo "# HELP node_smart_pending_sectors_total Current pending sector count (SMART attr 197)"
  echo "# TYPE node_smart_pending_sectors_total gauge"
  echo "# HELP node_smart_uncorrectable_errors_total Uncorrectable error count (SMART attr 198)"
  echo "# TYPE node_smart_uncorrectable_errors_total gauge"
  echo "# HELP node_smart_power_on_hours_total Power on hours total (SMART attr 9)"
  echo "# TYPE node_smart_power_on_hours_total gauge"
  echo "# HELP node_smart_power_cycles_total Power cycle count (SMART attr 12)"
  echo "# TYPE node_smart_power_cycles_total gauge"
  echo "# HELP node_smart_collection_timestamp_seconds Last successful collection (Unix timestamp)"
  echo "# TYPE node_smart_collection_timestamp_seconds gauge"

  # Détecter tous les disques blocs physiques (exclure partitions et loop)
  for disk in $(lsblk -dpno NAME 2>/dev/null | grep -E '^/dev/(sd|hd|nvme)'); do
    MODEL=$(smartctl -i "$disk" 2>/dev/null \
      | grep -E 'Device Model:|Model Number:' \
      | awk -F': ' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/ /, "_", $2); print $2}')
    [ -z "$MODEL" ] && MODEL="unknown"

    SERIAL=$(smartctl -i "$disk" 2>/dev/null \
      | grep 'Serial Number:' \
      | awk -F': ' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')
    [ -z "$SERIAL" ] && SERIAL="unknown"

    # Ignorer les volumes virtuels Longhorn (model et serial inconnus)
    [ "$MODEL" = "unknown" ] && [ "$SERIAL" = "unknown" ] && continue

    LABELS="device=\"${disk}\",model=\"${MODEL}\",serial=\"${SERIAL}\""

    # Santé globale (if absorbe le code retour non-nul de smartctl)
    if smartctl -H "$disk" 2>/dev/null | grep -q 'PASSED\|OK'; then
      echo "node_smart_device_health{${LABELS}} 1"
    else
      echo "node_smart_device_health{${LABELS}} 0"
    fi

    # Lire les attributs SMART (smartctl peut retourner != 0 sur disque dégradé)
    ATTRS=$(smartctl -A "$disk" 2>/dev/null) || true

    # Température (SATA HDD/SSD)
    TEMP=$(echo "$ATTRS" | grep -iE 'Temperature_Celsius|Airflow_Temperature_Cel' \
      | awk '{print $10}' | head -1)
    # Température (NVMe)
    if [ -z "$TEMP" ]; then
      TEMP=$(smartctl -A "$disk" 2>/dev/null | grep '^Temperature:' | awk '{print $2}') || true
    fi
    if [ -n "$TEMP" ] && [[ "$TEMP" =~ ^[0-9]+$ ]]; then
      echo "node_smart_temperature_celsius{${LABELS}} ${TEMP}"
    fi

    REALLOC=$(parse_attr "$ATTRS" 'Reallocated_Sector_Ct')
    [ -n "$REALLOC" ] && echo "node_smart_reallocated_sectors_total{${LABELS}} ${REALLOC}"

    PENDING=$(parse_attr "$ATTRS" 'Current_Pending_Sector')
    [ -n "$PENDING" ] && echo "node_smart_pending_sectors_total{${LABELS}} ${PENDING}"

    UNCORR=$(parse_attr "$ATTRS" 'Offline_Uncorrectable')
    [ -n "$UNCORR" ] && echo "node_smart_uncorrectable_errors_total{${LABELS}} ${UNCORR}"

    POH=$(parse_attr "$ATTRS" 'Power_On_Hours')
    [ -n "$POH" ] && echo "node_smart_power_on_hours_total{${LABELS}} ${POH}"

    CYCLES=$(parse_attr "$ATTRS" 'Power_Cycle_Count')
    [ -n "$CYCLES" ] && echo "node_smart_power_cycles_total{${LABELS}} ${CYCLES}"

  done

  echo "node_smart_collection_timestamp_seconds $(date +%s)"

} > "$TMP_FILE"

# Remplacement atomique (évite une lecture partielle par node-exporter)
mv "$TMP_FILE" "$OUTPUT_FILE"
