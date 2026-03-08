#!/bin/bash
# =============================================================
# Samba 4 Active Directory Domain Controller - Entrypoint
# Rejoindre un domaine AD existant et assurer les rôles FSMO
# =============================================================
set -euo pipefail

# --- Variables d'environnement (avec valeurs par défaut) ---
DOMAIN="${DOMAIN:-corpl.lcl}"
REALM="${REALM:-CORPL.LCL}"
NETBIOS_DOMAIN="${NETBIOS_DOMAIN:-CORPL}"
DC_HOSTNAME="${DC_HOSTNAME:-dc2}"
ADMIN_USER="${ADMIN_USER:-Administrator}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?ERREUR: ADMIN_PASSWORD non défini}"
EXISTING_DC_IP="${EXISTING_DC_IP:?ERREUR: EXISTING_DC_IP non défini}"
DNS_FORWARDER="${DNS_FORWARDER:-8.8.8.8}"
MY_IP="${MY_IP:-$(hostname -I | awk '{print $1}')}"
# Plage RPC dynamique restreinte (nécessaire pour les containers)
RPC_LOW_PORT="${RPC_LOW_PORT:-49152}"
RPC_HIGH_PORT="${RPC_HIGH_PORT:-49200}"

# --- Fonctions utilitaires ---
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*" >&2; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2; exit 1; }

# --- Attente que le DC existant soit joignable ---
wait_for_dc() {
    log "Vérification de la connectivité vers le DC existant ${EXISTING_DC_IP}..."
    local max_attempts=30
    local attempt=0
    while ! ping -c 1 -W 2 "${EXISTING_DC_IP}" &>/dev/null; do
        attempt=$((attempt + 1))
        if [ "${attempt}" -ge "${max_attempts}" ]; then
            err "DC existant ${EXISTING_DC_IP} injoignable après ${max_attempts} tentatives"
        fi
        warn "DC existant injoignable, tentative ${attempt}/${max_attempts}..."
        sleep 5
    done
    log "DC existant ${EXISTING_DC_IP} joignable."
}

# --- Configuration du hostname ---
setup_hostname() {
    local fqdn="${DC_HOSTNAME}.${DOMAIN}"
    log "Configuration du hostname: ${fqdn}"

    # Hostname court
    hostname "${DC_HOSTNAME}" 2>/dev/null || true
    echo "${DC_HOSTNAME}" > /etc/hostname

    # /etc/hosts
    # Supprimer les anciennes entrées pour ce hostname
    sed -i "/\b${DC_HOSTNAME}\b/d" /etc/hosts

    # Ajouter entrée avec IP réelle
    echo "${MY_IP}    ${fqdn} ${DC_HOSTNAME}" >> /etc/hosts
    log "  hostname: ${DC_HOSTNAME}, FQDN: ${fqdn}, IP: ${MY_IP}"
}

# --- Configuration DNS initiale (pointe vers DC existant) ---
setup_initial_dns() {
    log "Configuration DNS initiale → ${EXISTING_DC_IP}"
    cat > /etc/resolv.conf << RESOLV
# DNS temporaire pointant vers le DC existant pour la jonction
nameserver ${EXISTING_DC_IP}
search ${DOMAIN}
RESOLV
}

# --- Synchronisation NTP (critique pour Kerberos ±5 min max) ---
sync_time() {
    log "Synchronisation NTP avec le DC existant..."
    ntpdate -u "${EXISTING_DC_IP}" 2>/dev/null \
        || ntpdate -u "pool.ntp.org" 2>/dev/null \
        || warn "Synchronisation NTP échouée - Kerberos peut dysfonctionner si décalage > 5 min"
}

# --- Jonction au domaine existant ---
join_domain() {
    log "=============================================="
    log " JONCTION AU DOMAINE: ${DOMAIN}"
    log " En tant que DC supplémentaire"
    log "=============================================="

    # Supprimer toute config Samba existante
    rm -f /etc/samba/smb.conf
    rm -rf /var/lib/samba/private/*

    samba-tool domain join "${DOMAIN}" DC \
        --dns-backend=SAMBA_INTERNAL \
        --username="${ADMIN_USER}" \
        --password="${ADMIN_PASSWORD}" \
        --server="${EXISTING_DC_IP}" \
        --option="interfaces=lo eth0" \
        --option="bind interfaces only=yes" \
        --option="dns forwarder=${DNS_FORWARDER}" \
        --option="rpc server dynamic port range=${RPC_LOW_PORT}-${RPC_HIGH_PORT}" \
        --realm="${REALM}" \
        2>&1 | tee /var/log/samba/domain-join.log

    log "Jonction au domaine ${DOMAIN} réussie !"
}

# --- Configuration post-jonction ---
post_join_config() {
    log "Configuration post-jonction..."

    # Ajouter options essentielles à smb.conf
    cat >> /etc/samba/smb.conf << SMBCONF

# --- Options ajoutées par entrypoint (post-jonction) ---
[global]
    # Plage RPC dynamique restreinte (pour les containers/firewalls)
    rpc server dynamic port range = ${RPC_LOW_PORT}-${RPC_HIGH_PORT}

    # Amélioration des performances Kerberos
    kerberos method = secrets and keytab

    # Logs
    log level = 1
    log file = /var/log/samba/log.%m
    max log size = 50
SMBCONF

    # Configurer Kerberos
    if [ -f /var/lib/samba/private/krb5.conf ]; then
        cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
        log "Configuration Kerberos copiée."
    fi
}

# --- Mise à jour DNS pour pointer vers soi-même ---
setup_final_dns() {
    log "Configuration DNS finale (self + DC existant pour fallback)"
    cat > /etc/resolv.conf << RESOLV
# DNS: soi-même en primaire, DC existant en secondaire
nameserver 127.0.0.1
nameserver ${EXISTING_DC_IP}
search ${DOMAIN}
RESOLV
}

# --- Afficher l'état de la réplication ---
show_replication_status() {
    log "Vérification de la réplication AD..."
    samba-tool drs showrepl 2>/dev/null \
        || warn "Impossible de vérifier la réplication (normal au premier démarrage)"
}

# --- Afficher les rôles FSMO ---
show_fsmo_roles() {
    log "Rôles FSMO actuels:"
    samba-tool fsmo show 2>/dev/null \
        || warn "Impossible d'afficher les rôles FSMO"
}

# --- Gestion arrêt propre ---
cleanup() {
    log "Signal d'arrêt reçu, arrêt de Samba en cours..."
    if [ -n "${SAMBA_PID:-}" ]; then
        kill -TERM "${SAMBA_PID}" 2>/dev/null || true
        wait "${SAMBA_PID}" 2>/dev/null || true
    fi
    log "Samba arrêté proprement."
}

trap cleanup SIGTERM SIGINT SIGQUIT

# =============================================================
# POINT D'ENTRÉE PRINCIPAL
# =============================================================
log "=============================================="
log " Samba 4 Active Directory Domain Controller"
log " Domaine: ${DOMAIN} (${REALM})"
log " Hostname: ${DC_HOSTNAME}"
log " Mon IP: ${MY_IP}"
log "=============================================="

# Toujours configurer le hostname
setup_hostname

# Vérifier si déjà joint au domaine
if [ -f /var/lib/samba/private/krb5.conf ] && [ -f /etc/samba/smb.conf ]; then
    log "Samba DC déjà configuré (${DOMAIN}), démarrage direct..."

    # Restaurer la config Kerberos
    cp /var/lib/samba/private/krb5.conf /etc/krb5.conf

    # DNS final
    setup_final_dns

else
    log "Première initialisation: jonction au domaine ${DOMAIN}..."

    # Attendre que le DC existant soit joignable
    wait_for_dc

    # Configurer DNS initial
    setup_initial_dns

    # Synchroniser le temps (critique pour Kerberos)
    sync_time

    # Rejoindre le domaine
    join_domain

    # Configuration post-jonction
    post_join_config

    # DNS final
    setup_final_dns

    log "Initialisation terminée !"
fi

# Démarrer Samba en foreground
log "Démarrage de Samba AD DC..."
samba --foreground --no-process-group &
SAMBA_PID=$!

# Attendre que Samba soit prêt
sleep 5

# Afficher l'état initial
show_replication_status || true
show_fsmo_roles || true

log "Samba AD DC opérationnel. PID=${SAMBA_PID}"
log ""
log "Pour transférer les rôles FSMO vers ce DC:"
log "  kubectl exec -it samba-dc-0 -n active-directory -- samba-tool fsmo transfer --role=all"
log ""

# Attendre la fin du processus Samba
wait "${SAMBA_PID}"
