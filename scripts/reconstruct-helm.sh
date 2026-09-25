#!/usr/bin/env bash
# reconstruct-helm.sh — recrée les ressources manquantes (PVC, etc.) en réappliquant les releases Helm.
#
# Usage :
#   ./reconstruct-helm.sh                 # réapplique TOUTES les releases helm (helm list -A)
#   ./reconstruct-helm.sh nas monitoring  # seulement les releases de ces namespaces
#
# Variables :
#   VALUES_DIR   dossier où sont tes fichiers de values (défaut : ~/git/k3s-kubevirt)
#   SC_NAME      StorageClass à garder en replicas=1 (défaut : longhorn-fast)
#   AUTO         =1 pour ne pas demander de confirmation
#
# NB : par défaut le script fait `helm upgrade <rel> --reuse-values` (réapplique le chart
#      avec les valeurs déjà en place). Si tes values vivent dans des fichiers, renseigne
#      la table VALUES ci-dessous pour qu'il utilise -f <fichier> à la place.
set -uo pipefail

VALUES_DIR="${VALUES_DIR:-$HOME/git/k3s-kubevirt}"
SC_NAME="${SC_NAME:-longhorn-fast}"
AUTO="${AUTO:-0}"

# ---- OPTIONNEL : associe une release à son fichier de values ----
#   clé = "namespace/release"   valeur = chemin du values.yaml
declare -A VALUES=(
  # ["nas/plex"]="$VALUES_DIR/nas/plex/values.yaml"
  # ["monitoring/kube-prometheus-stack"]="$VALUES_DIR/monitoring/kube-prometheus-stack/values.yaml"
)
# -----------------------------------------------------------------

c(){ printf '\n\033[1;36m>>> %s\033[0m\n' "$*"; }
warn(){ printf '\033[1;33m!! %s\033[0m\n' "$*"; }
die(){ printf '\033[1;31mXX %s\033[0m\n' "$*"; exit 1; }

command -v helm >/dev/null    || die "helm introuvable"
command -v kubectl >/dev/null || die "kubectl introuvable"
kubectl get --raw='/readyz' >/dev/null 2>&1 || die "API Kubernetes injoignable"

c "Releases Helm"
helm list -A

c "Pods non Running/Completed (avant)"
kubectl get pods -A | grep -vE 'Running|Completed' || echo "  (aucun)"

# --- sélection des releases : toutes, ou filtrées par namespaces passés en argument ---
NSFILTER=("$@")
mapfile -t ROWS < <(helm list -A -o json | python3 - "$@" <<'PY'
import json,sys
rows=json.load(sys.stdin); nss=set(sys.argv[1:])
for r in rows:
    if not nss or r["namespace"] in nss:
        print(r["namespace"]+"\t"+r["name"]+"\t"+r.get("chart",""))
PY
)
[ "${#ROWS[@]}" -gt 0 ] || die "Aucune release Helm correspondante."

c "Releases à réappliquer :"
printf '  %s\n' "${ROWS[@]}"

if [ "$AUTO" != "1" ]; then
  echo
  warn "helm upgrade va être relancé sur ces releases (recrée les PVC manquants ; volume Longhorn recréé = VIDE)."
  read -rp "Continuer ? [o/N] " a; { [ "$a" = "o" ] || [ "$a" = "O" ]; } || die "Abandon."
fi

# --- réapplication ---
fails=()
for row in "${ROWS[@]}"; do
  ns="${row%%$'\t'*}"; rest="${row#*$'\t'}"; rel="${rest%%$'\t'*}"
  key="$ns/$rel"; vfile="${VALUES[$key]:-}"
  c "helm upgrade  $rel  (ns $ns)"
  if [ -n "$vfile" ] && [ -f "$vfile" ]; then
    echo "   values : $vfile"
    helm upgrade "$rel" "$(helm get metadata "$rel" -n "$ns" -o json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin).get("chart",""))')" \
      -n "$ns" -f "$vfile" --reuse-values || { warn "échec $key"; fails+=("$key"); }
  else
    # pas de fichier de values connu : on réapplique le chart déjà installé avec ses valeurs actuelles
    helm upgrade "$rel" -n "$ns" --reuse-values "$(helm get metadata "$rel" -n "$ns" -o json 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("chart",""))')" 2>/dev/null \
      || helm upgrade "$rel" "$rel" -n "$ns" --reuse-values 2>/dev/null \
      || { warn "$key : impossible de déduire le chart — renseigne la table VALUES ou relance à la main : helm upgrade $rel <chart> -n $ns -f <values>"; fails+=("$key"); }
  fi
done

# --- protéger le correctif StorageClass ---
c "StorageClass $SC_NAME : garantir numberOfReplicas=1"
if kubectl get sc "$SC_NAME" >/dev/null 2>&1; then
  cur="$(kubectl get sc "$SC_NAME" -o jsonpath='{.parameters.numberOfReplicas}')"
  if [ "$cur" != "1" ]; then
    warn "SC repassée à '$cur' par un chart — re-correction à 1"
    kubectl get sc "$SC_NAME" -o yaml | sed -E 's/(numberOfReplicas: )"?[0-9]+"?/\1"1"/' | kubectl replace --force -f - >/dev/null
  fi
  kubectl get sc "$SC_NAME" -o jsonpath='{.parameters.numberOfReplicas}{"  default="}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}'
fi

# --- rapport ---
c "PVC (attente du binding, 15 s)"
sleep 15
kubectl get pvc -A | grep -vE 'Bound' || echo "  => tous les PVC sont Bound"
c "Pods encore non prêts"
kubectl get pods -A | grep -vE 'Running|Completed' || echo "  => tout Running/Completed"
c "Volumes Longhorn non healthy"
kubectl -n longhorn-system get volumes.longhorn.io -o wide 2>/dev/null | grep -vE 'healthy|^NAME' || echo "  => tous healthy"

[ "${#fails[@]}" -eq 0 ] || { echo; warn "Releases en échec : ${fails[*]} — à relancer à la main."; }
c "Terminé. Suivi :  kubectl get pods -A -w"
