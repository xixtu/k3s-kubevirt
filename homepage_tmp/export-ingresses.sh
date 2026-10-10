#!/bin/bash

# Vérifie que kubectl est accessible
if ! command -v kubectl &> /dev/null; then
    echo "Erreur : kubectl n'est pas installé ou accessible."
    exit 1
fi

echo "Exportation de tous les Ingress du cluster k3s..."
kubectl get ingress --all-namespaces -o json > ingresses.json

echo "Export terminé avec succès !"
echo "Fichier généré : ingresses.json"