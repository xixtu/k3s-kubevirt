#!/bin/bash

if ! command -v kubectl &> /dev/null; then
    echo "Erreur : kubectl n'est pas accessible."
    exit 1
fi

echo "Exportation des ressources du cluster k3s..."

# Création d'un fichier JSON global propre avec jq ou un format multi-ressources
# On s'assure que jq est présent, sinon on fait un format brut
if ! command -v jq &> /dev/null; then
    echo "Attention : 'jq' n'est pas installé. Le fichier combiné sera basique."
fi

cat <<EOF > cluster-export.json
{
  "ingresses": $(kubectl get ingress --all-namespaces -o json),
  "issuers": $(kubectl get issuers --all-namespaces -o json 2>/dev/null || echo '{"items":[]}'),
  "clusterissuers": $(kubectl get clusterissuers -o json 2>/dev/null || echo '{"items":[]}'),
  "storageclasses": $(kubectl get storageclass -o json 2>/dev/null || echo '{"items":[]}')
}
EOF

echo "Export terminé avec succès ! Fichier généré : cluster-export.json"