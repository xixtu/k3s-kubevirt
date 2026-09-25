#!/usr/bin/env bash
# git-push.sh — ajoute tout, committe et pousse le dépôt.
# Usage :
#   ./git-push.sh                       # message par défaut
#   ./git-push.sh "mon message"         # message personnalisé
set -euo pipefail

REPO="${REPO:-$HOME/git/k3s-kubevirt}"
MSG="${1:-elimination node 2 et 3}"

cd "$REPO"

echo ">> Dépôt : $(pwd)"
echo ">> Branche : $(git rev-parse --abbrev-ref HEAD)"

echo ">> Fichiers concernés :"
git add -A
git status --short

if git diff --cached --quiet; then
  echo ">> Rien à committer, dépôt déjà à jour."
  exit 0
fi

echo ">> Commit : $MSG"
git commit -m "$MSG"

echo ">> Push..."
git push

echo ">> Terminé."
git log -1 --stat --oneline
