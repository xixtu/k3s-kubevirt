#!/usr/bin/env bash
# =============================================================
# AUDIT TLS / INGRESS / TRAEFIK / CERT-MANAGER
# =============================================================
# Usage : ./scripts/audit-tls-ingress.sh [KUBECONFIG]
#
# Exporte la configuration effective de :
#   1. Namespace traefik     : pods, services, helm values, TLSOption, Middleware
#   2. Namespace sys-letsencrypt : pods, ClusterIssuers, cert-manager config
#   3. Tous les Ingress      : annotations, TLS, secretName
#   4. Tous les IngressRoute : entryPoints, TLS, middlewares
#   5. Certificats           : état, algorithme, taille clé, expiration
#   6. Secrets TLS           : type de clé, courbe, validité
#
# Sortie : ./audit-tls-report-<date>.txt
# =============================================================

set -euo pipefail

# --- Configuration ---
KUBECONFIG="${1:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG
KUBECTL="kubectl"

# Vérifie si k3s kubectl est disponible
if command -v k3s &>/dev/null; then
    KUBECTL="k3s kubectl"
fi

REPORT_DIR="./audit-reports"
mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/audit-tls-report-$(date +%Y%m%d-%H%M%S).txt"

# --- Couleurs (désactivées si pas de terminal) ---
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC=''
fi

# --- Fonctions utilitaires ---
separator() {
    echo "=================================================================="
}

section() {
    echo ""
    separator
    echo "  $1"
    separator
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

fail() {
    echo -e "${RED}[FAIL]${NC} $1"
}

info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

# --- Vérification prérequis ---
check_prerequisites() {
    section "PRÉREQUIS"

    if ! $KUBECTL cluster-info &>/dev/null; then
        fail "Impossible de se connecter au cluster (KUBECONFIG=$KUBECONFIG)"
        echo "Usage : $0 [chemin/vers/kubeconfig]"
        exit 1
    fi
    ok "Connexion au cluster OK"
    echo "KUBECONFIG : $KUBECONFIG"
    echo "Date audit : $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "Kubectl    : $($KUBECTL version --client --short 2>/dev/null || $KUBECTL version --client 2>/dev/null | head -1)"
}

# =============================================================
# 1. NAMESPACE TRAEFIK
# =============================================================
audit_traefik() {
    section "1. NAMESPACE TRAEFIK - Configuration effective"

    echo ""
    echo "--- 1.1 Pods ---"
    $KUBECTL get pods -n traefik -o wide 2>/dev/null || warn "Namespace traefik introuvable"

    echo ""
    echo "--- 1.2 Services ---"
    $KUBECTL get svc -n traefik -o wide 2>/dev/null || warn "Pas de services dans traefik"

    echo ""
    echo "--- 1.3 Déploiements ---"
    $KUBECTL get deploy -n traefik -o wide 2>/dev/null || warn "Pas de déploiements dans traefik"

    echo ""
    echo "--- 1.4 Helm Release Traefik ---"
    if command -v helm &>/dev/null; then
        helm get values traefik -n traefik 2>/dev/null || warn "Helm release traefik introuvable"
    else
        warn "helm non disponible - skip helm values"
    fi

    echo ""
    echo "--- 1.5 Configuration du Pod Traefik (args + env) ---"
    local traefik_pod
    traefik_pod=$($KUBECTL get pods -n traefik -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$traefik_pod" ]; then
        echo "Pod: $traefik_pod"
        echo ""
        echo "Arguments de démarrage :"
        $KUBECTL get pod "$traefik_pod" -n traefik -o jsonpath='{.spec.containers[0].args}' 2>/dev/null | python3 -m json.tool 2>/dev/null || \
            $KUBECTL get pod "$traefik_pod" -n traefik -o jsonpath='{range .spec.containers[0].args[*]}{@}{"\n"}{end}' 2>/dev/null
        echo ""
        echo "Variables d'environnement :"
        $KUBECTL get pod "$traefik_pod" -n traefik -o jsonpath='{range .spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' 2>/dev/null || echo "(aucune)"
        echo ""
        echo "Ports exposés :"
        $KUBECTL get pod "$traefik_pod" -n traefik -o jsonpath='{range .spec.containers[0].ports[*]}  {.name}: {.containerPort}/{.protocol}{"\n"}{end}' 2>/dev/null
        echo ""
        echo "Resources (requests/limits) :"
        $KUBECTL get pod "$traefik_pod" -n traefik -o jsonpath='{.spec.containers[0].resources}' 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "(non définies)"
    else
        warn "Aucun pod Traefik trouvé"
    fi

    echo ""
    echo "--- 1.6 TLSOption (configuration TLS) ---"
    $KUBECTL get tlsoption -n traefik -o yaml 2>/dev/null || warn "Aucune TLSOption trouvée"

    echo ""
    echo "--- 1.7 Middlewares Traefik ---"
    $KUBECTL get middleware -n traefik -o yaml 2>/dev/null || warn "Aucun middleware trouvé dans traefik"
    echo ""
    echo "Middlewares dans tous les namespaces :"
    $KUBECTL get middleware --all-namespaces 2>/dev/null || warn "Aucun middleware CRD"

    echo ""
    echo "--- 1.8 IngressClass ---"
    $KUBECTL get ingressclass -o wide 2>/dev/null || warn "Aucune IngressClass"
}

# =============================================================
# 2. NAMESPACE SYS-LETSENCRYPT (cert-manager)
# =============================================================
audit_certmanager() {
    section "2. NAMESPACE SYS-LETSENCRYPT - cert-manager"

    echo ""
    echo "--- 2.1 Pods cert-manager ---"
    $KUBECTL get pods -n sys-letsencrypt -o wide 2>/dev/null || warn "Namespace sys-letsencrypt introuvable"

    echo ""
    echo "--- 2.2 Services cert-manager ---"
    $KUBECTL get svc -n sys-letsencrypt 2>/dev/null || warn "Pas de services"

    echo ""
    echo "--- 2.3 Déploiements cert-manager ---"
    $KUBECTL get deploy -n sys-letsencrypt -o wide 2>/dev/null || warn "Pas de déploiements"

    echo ""
    echo "--- 2.4 Helm Release cert-manager ---"
    if command -v helm &>/dev/null; then
        helm get values cert-manager -n sys-letsencrypt 2>/dev/null || warn "Helm release cert-manager introuvable"
    else
        warn "helm non disponible"
    fi

    echo ""
    echo "--- 2.5 Configuration des Pods cert-manager (args) ---"
    for pod in $($KUBECTL get pods -n sys-letsencrypt -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        echo ""
        echo "Pod: $pod"
        echo "  Arguments :"
        $KUBECTL get pod "$pod" -n sys-letsencrypt -o jsonpath='{range .spec.containers[0].args[*]}    {@}{"\n"}{end}' 2>/dev/null || echo "    (aucun)"
    done

    echo ""
    echo "--- 2.6 ClusterIssuers ---"
    $KUBECTL get clusterissuers -o wide 2>/dev/null || warn "Aucun ClusterIssuer"
    echo ""
    echo "Détails ClusterIssuers :"
    for issuer in $($KUBECTL get clusterissuers -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        echo ""
        echo "  === $issuer ==="
        $KUBECTL get clusterissuer "$issuer" -o yaml 2>/dev/null | grep -A 20 "spec:" || true
    done

    echo ""
    echo "--- 2.7 Issuers (namespace-scoped) ---"
    $KUBECTL get issuers --all-namespaces 2>/dev/null || warn "Aucun Issuer"
}

# =============================================================
# 3. TOUS LES INGRESS
# =============================================================
audit_ingress() {
    section "3. TOUS LES INGRESS - Configuration TLS"

    echo ""
    echo "--- 3.1 Liste de tous les Ingress ---"
    $KUBECTL get ingress --all-namespaces -o wide 2>/dev/null || warn "Aucun Ingress trouvé"

    echo ""
    echo "--- 3.2 Détail de chaque Ingress ---"
    local namespaces
    namespaces=$($KUBECTL get ingress --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null)

    for ns_name in $namespaces; do
        ns="${ns_name%%/*}"
        name="${ns_name##*/}"
        echo ""
        separator
        echo "  INGRESS: $name (namespace: $ns)"
        separator

        echo ""
        echo "  Annotations :"
        $KUBECTL get ingress "$name" -n "$ns" -o jsonpath='{range .metadata.annotations}{@}{"\n"}{end}' 2>/dev/null
        # Format plus lisible
        $KUBECTL get ingress "$name" -n "$ns" -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
annotations = data.get('metadata', {}).get('annotations', {})
for k, v in sorted(annotations.items()):
    print(f'    {k}: {v}')
" 2>/dev/null || true

        echo ""
        echo "  TLS :"
        $KUBECTL get ingress "$name" -n "$ns" -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
tls = data.get('spec', {}).get('tls', [])
for t in tls:
    print(f'    secretName: {t.get(\"secretName\", \"N/A\")}')
    print(f'    hosts: {t.get(\"hosts\", [])}')
" 2>/dev/null || echo "    (pas de TLS configuré)"

        echo ""
        echo "  Rules :"
        $KUBECTL get ingress "$name" -n "$ns" -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
rules = data.get('spec', {}).get('rules', [])
for r in rules:
    host = r.get('host', '*')
    paths = r.get('http', {}).get('paths', [])
    for p in paths:
        backend = p.get('backend', {})
        svc = backend.get('service', {})
        print(f'    {host}{p.get(\"path\",\"/\")} -> {svc.get(\"name\",\"?\")}:{svc.get(\"port\",{}).get(\"number\",\"?\")}')
" 2>/dev/null || true

        # Vérifications de sécurité
        echo ""
        echo "  Vérifications sécurité :"
        local annotations_json
        annotations_json=$($KUBECTL get ingress "$name" -n "$ns" -o json 2>/dev/null)

        # Check cert-manager issuer
        if echo "$annotations_json" | grep -q "cert-manager.io/cluster-issuer"; then
            issuer=$(echo "$annotations_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['metadata']['annotations'].get('cert-manager.io/cluster-issuer','?'))" 2>/dev/null)
            ok "cert-manager issuer: $issuer"
        else
            warn "Pas d'annotation cert-manager.io/cluster-issuer"
        fi

        # Check ECDSA
        if echo "$annotations_json" | grep -q "private-key-algorithm"; then
            algo=$(echo "$annotations_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['metadata']['annotations'].get('cert-manager.io/private-key-algorithm','?'))" 2>/dev/null)
            size=$(echo "$annotations_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['metadata']['annotations'].get('cert-manager.io/private-key-size','?'))" 2>/dev/null)
            if [ "$size" = "256" ]; then
                warn "Clé $algo P-$size — recommandé : P-384 pour une sécurité renforcée"
            elif [ "$size" = "384" ]; then
                ok "Clé $algo P-$size"
            else
                info "Clé $algo taille: $size"
            fi
        else
            warn "Pas d'annotation private-key-algorithm (clé RSA par défaut)"
        fi

        # Check redirect middleware
        if echo "$annotations_json" | grep -q "redirect-to-https"; then
            ok "Middleware redirect-to-https présent"
        else
            warn "Pas de middleware redirect-to-https"
        fi
    done
}

# =============================================================
# 4. TOUS LES INGRESSROUTE (Traefik CRD)
# =============================================================
audit_ingressroute() {
    section "4. INGRESSROUTES TRAEFIK (CRD)"

    echo ""
    echo "--- 4.1 Liste de tous les IngressRoute ---"
    $KUBECTL get ingressroute --all-namespaces 2>/dev/null || warn "Aucun IngressRoute (CRD non installé ?)"

    echo ""
    echo "--- 4.2 Détail de chaque IngressRoute ---"
    local items
    items=$($KUBECTL get ingressroute --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null)

    for ns_name in $items; do
        ns="${ns_name%%/*}"
        name="${ns_name##*/}"
        echo ""
        echo "  === $name (namespace: $ns) ==="
        $KUBECTL get ingressroute "$name" -n "$ns" -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
spec = data.get('spec', {})
print(f'    entryPoints: {spec.get(\"entryPoints\", [])}')
routes = spec.get('routes', [])
for r in routes:
    print(f'    match: {r.get(\"match\", \"?\")}')
    middlewares = r.get('middlewares', [])
    if middlewares:
        print(f'    middlewares: {middlewares}')
    for s in r.get('services', []):
        print(f'    service: {s.get(\"name\",\"?\")}:{s.get(\"port\",\"?\")}')
tls = spec.get('tls', {})
if tls:
    print(f'    tls.secretName: {tls.get(\"secretName\", \"N/A\")}')
    if 'options' in tls:
        print(f'    tls.options: {tls[\"options\"]}')
else:
    print('    tls: NON CONFIGURÉ')
" 2>/dev/null || echo "    (erreur de lecture)"
    done
}

# =============================================================
# 5. CERTIFICATS CERT-MANAGER
# =============================================================
audit_certificates() {
    section "5. CERTIFICATS cert-manager"

    echo ""
    echo "--- 5.1 Tous les Certificate ---"
    $KUBECTL get certificates --all-namespaces -o wide 2>/dev/null || warn "Aucun Certificate trouvé"

    echo ""
    echo "--- 5.2 Tous les CertificateRequest ---"
    $KUBECTL get certificaterequests --all-namespaces 2>/dev/null || warn "Aucun CertificateRequest"

    echo ""
    echo "--- 5.3 Détail des Certificate ---"
    local items
    items=$($KUBECTL get certificates --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null)

    for ns_name in $items; do
        ns="${ns_name%%/*}"
        name="${ns_name##*/}"
        echo ""
        echo "  === Certificate: $name (namespace: $ns) ==="
        $KUBECTL get certificate "$name" -n "$ns" -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
spec = data.get('spec', {})
status = data.get('status', {})

print(f'    secretName: {spec.get(\"secretName\", \"N/A\")}')
print(f'    issuerRef: {spec.get(\"issuerRef\", {})}')
pk = spec.get('privateKey', {})
if pk:
    print(f'    privateKey.algorithm: {pk.get(\"algorithm\", \"RSA (default)\")}')
    print(f'    privateKey.size: {pk.get(\"size\", \"2048 (default)\")}')
else:
    print('    privateKey: NON SPÉCIFIÉ (RSA 2048 par défaut)')

dns = spec.get('dnsNames', [])
print(f'    dnsNames: {dns}')

# Status
conditions = status.get('conditions', [])
for c in conditions:
    print(f'    status: {c.get(\"type\")}: {c.get(\"status\")} ({c.get(\"reason\",\"\")})')

renewal = status.get('renewalTime', 'N/A')
not_after = status.get('notAfter', 'N/A')
print(f'    notAfter: {not_after}')
print(f'    renewalTime: {renewal}')
" 2>/dev/null || echo "    (erreur de lecture)"
    done
}

# =============================================================
# 6. SECRETS TLS - Vérification des clés
# =============================================================
audit_tls_secrets() {
    section "6. SECRETS TLS - Analyse des clés"

    echo ""
    echo "Recherche de tous les secrets de type kubernetes.io/tls..."
    echo ""

    local items
    items=$($KUBECTL get secrets --all-namespaces --field-selector type=kubernetes.io/tls -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null)

    if [ -z "$items" ]; then
        warn "Aucun secret TLS trouvé"
        return
    fi

    for ns_name in $items; do
        ns="${ns_name%%/*}"
        name="${ns_name##*/}"
        echo "  === Secret: $name (namespace: $ns) ==="

        # Extraire et analyser la clé privée
        local key_b64
        key_b64=$($KUBECTL get secret "$name" -n "$ns" -o jsonpath='{.data.tls\.key}' 2>/dev/null)
        if [ -n "$key_b64" ]; then
            local key_info
            key_info=$(echo "$key_b64" | base64 -d 2>/dev/null | openssl pkey -noout -text 2>/dev/null | head -5)
            if echo "$key_info" | grep -qi "ec\|ecdsa"; then
                local curve
                curve=$(echo "$key_b64" | base64 -d 2>/dev/null | openssl ec -noout -text 2>/dev/null | grep -i "asn1 oid\|nist curve" | head -1)
                ok "Type: ECDSA | $curve"
            elif echo "$key_info" | grep -qi "rsa"; then
                local bits
                bits=$(echo "$key_info" | grep -i "key" | head -1)
                warn "Type: RSA | $bits — migration ECDSA recommandée"
            else
                info "Type: $(echo "$key_info" | head -1)"
            fi
        else
            warn "Clé privée vide ou inaccessible"
        fi

        # Analyser le certificat
        local cert_b64
        cert_b64=$($KUBECTL get secret "$name" -n "$ns" -o jsonpath='{.data.tls\.crt}' 2>/dev/null)
        if [ -n "$cert_b64" ]; then
            echo "$cert_b64" | base64 -d 2>/dev/null | openssl x509 -noout \
                -subject -issuer -dates -ext subjectAltName 2>/dev/null | \
                sed 's/^/    /' || true
        fi
        echo ""
    done
}

# =============================================================
# 7. RÉSUMÉ SÉCURITÉ
# =============================================================
audit_summary() {
    section "7. RÉSUMÉ ET RECOMMANDATIONS SÉCURITÉ"

    echo ""
    echo "--- 7.1 Vérifications globales ---"
    echo ""

    # TLSOption - TLS minimum
    local tls_min
    tls_min=$($KUBECTL get tlsoption -n traefik -o jsonpath='{.items[0].spec.minVersion}' 2>/dev/null)
    if [ "$tls_min" = "VersionTLS12" ] || [ "$tls_min" = "VersionTLS13" ]; then
        ok "TLS minimum : $tls_min"
    elif [ -n "$tls_min" ]; then
        warn "TLS minimum : $tls_min — recommandé : VersionTLS12 au minimum"
    else
        warn "TLSOption non configurée — TLS 1.0/1.1 potentiellement accepté"
    fi

    # sniStrict
    local sni
    sni=$($KUBECTL get tlsoption -n traefik -o jsonpath='{.items[0].spec.sniStrict}' 2>/dev/null)
    if [ "$sni" = "true" ]; then
        ok "sniStrict : activé"
    else
        warn "sniStrict : désactivé — le certificat par défaut Traefik est exposé"
    fi

    # HSTS
    local hsts
    hsts=$($KUBECTL get middleware security-headers -n traefik -o jsonpath='{.spec.headers.stsSeconds}' 2>/dev/null)
    if [ -n "$hsts" ] && [ "$hsts" -gt 0 ] 2>/dev/null; then
        ok "HSTS : activé (${hsts}s)"
        local preload
        preload=$($KUBECTL get middleware security-headers -n traefik -o jsonpath='{.spec.headers.stsPreload}' 2>/dev/null)
        [ "$preload" = "true" ] && ok "HSTS preload : activé" || warn "HSTS preload : désactivé"
    else
        warn "HSTS : non configuré"
    fi

    # Cipher suites CBC
    local ciphers
    ciphers=$($KUBECTL get tlsoption -n traefik -o jsonpath='{.items[0].spec.cipherSuites}' 2>/dev/null)
    if echo "$ciphers" | grep -qi "cbc"; then
        fail "Cipher suites CBC détectées — vulnérable (BEAST, Lucky13)"
    else
        ok "Pas de cipher CBC (GCM + CHACHA20 uniquement)"
    fi

    # Ingress sans TLS
    echo ""
    echo "--- 7.2 Ingress sans TLS ---"
    $KUBECTL get ingress --all-namespaces -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
found = False
for item in data.get('items', []):
    tls = item.get('spec', {}).get('tls', [])
    if not tls:
        ns = item['metadata']['namespace']
        name = item['metadata']['name']
        print(f'  [WARN] {ns}/{name} — pas de TLS configuré')
        found = True
if not found:
    print('  [OK] Tous les Ingress ont une configuration TLS')
" 2>/dev/null || warn "Impossible de vérifier"

    # ECDSA P-256 vs P-384
    echo ""
    echo "--- 7.3 Taille des clés ECDSA ---"
    $KUBECTL get ingress --all-namespaces -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data.get('items', []):
    ns = item['metadata']['namespace']
    name = item['metadata']['name']
    annotations = item.get('metadata', {}).get('annotations', {})
    algo = annotations.get('cert-manager.io/private-key-algorithm', '')
    size = annotations.get('cert-manager.io/private-key-size', '')
    if algo == 'ECDSA' and size == '256':
        print(f'  [WARN] {ns}/{name} — ECDSA P-256 (recommandé : P-384)')
    elif algo == 'ECDSA' and size == '384':
        print(f'  [OK]   {ns}/{name} — ECDSA P-384')
    elif algo == 'ECDSA':
        print(f'  [INFO] {ns}/{name} — ECDSA P-{size}')
    elif not algo:
        print(f'  [WARN] {ns}/{name} — algorithme non spécifié (RSA par défaut)')
    else:
        print(f'  [INFO] {ns}/{name} — {algo} {size}')
" 2>/dev/null || warn "Impossible de vérifier"

    echo ""
    echo "--- 7.4 Recommandations ---"
    echo ""
    echo "  1. ECDSA P-384 : Passer private-key-size de 256 à 384 sur tous les Ingress"
    echo "     → Sécurité 192 bits vs 128 bits, overhead négligeable"
    echo "     → Nécessite de supprimer les anciens secrets TLS et Certificate"
    echo "       pour forcer le renouvellement cert-manager"
    echo ""
    echo "  2. DNS CAA : Ajouter un enregistrement CAA chez le registrar DNS :"
    echo "     xixtu.eu. CAA 0 issue \"letsencrypt.org\""
    echo "     → Empêche d'autres CA d'émettre des certificats pour votre domaine"
    echo ""
    echo "  3. OCSP Stapling : Non supporté par Traefik v3 (limitation connue)"
    echo "     → Pas d'action possible côté Traefik"
    echo ""
    echo "  4. Traefik curvePreferences : Vérifier que CurveP384 est dans la liste"
    echo "     → Cohérence avec les certificats ECDSA P-384"
    echo ""
    echo "  5. Headers de sécurité supplémentaires à considérer :"
    echo "     → Content-Security-Policy, X-Content-Type-Options, X-Frame-Options"
    echo "     → Referrer-Policy, Permissions-Policy"
    echo ""
}

# =============================================================
# EXÉCUTION
# =============================================================
main() {
    echo "=============================================================="
    echo "  AUDIT TLS / INGRESS / TRAEFIK / CERT-MANAGER"
    echo "  $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "=============================================================="

    check_prerequisites
    audit_traefik
    audit_certmanager
    audit_ingress
    audit_ingressroute
    audit_certificates
    audit_tls_secrets
    audit_summary

    section "FIN DE L'AUDIT"
    echo ""
    echo "Rapport sauvegardé dans : $REPORT"
    echo ""
}

# Exécuter et sauvegarder le rapport
main 2>&1 | tee "$REPORT"
