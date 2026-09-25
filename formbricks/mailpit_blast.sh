#!/usr/bin/env bash
# Monte le port-forward vers Mailpit puis lance le bombardier Python.
# Usage :
#   ./mailpit_blast.sh                 # 100 mails
#   ./mailpit_blast.sh 1000            # 1000 mails
#   ./mailpit_blast.sh 1000 --workers 10 --per-conn 50
#   NAMESPACE=formbricks ./mailpit_blast.sh 500
set -euo pipefail

NAMESPACE="${NAMESPACE:-}"                 # ex : formbricks (sinon namespace courant)
SVC="${SVC:-svc/formbricks-mailpit}"       # service Mailpit
COUNT="${1:-100}"; shift || true           # 1er arg = nombre de mails
EXTRA=("$@")                                # args supplémentaires passés à python

NS_ARG=(); [ -n "$NAMESPACE" ] && NS_ARG=(-n "$NAMESPACE")
HERE="$(cd "$(dirname "$0")" && pwd)"

echo ">> Port-forward $SVC : 1025->1025 (SMTP), 8025->8025 (UI)"
kubectl "${NS_ARG[@]}" port-forward "$SVC" 1025:1025 8025:8025 >/tmp/mailpit-pf.log 2>&1 &
PF_PID=$!
cleanup(){ kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# attendre que le port SMTP réponde (max ~10 s)
echo -n ">> Attente du port 1025 "
for _ in $(seq 1 40); do
  if (exec 3<>/dev/tcp/127.0.0.1/1025) 2>/dev/null; then exec 3>&- 3<&-; echo "OK"; ready=1; break; fi
  echo -n "."; sleep 0.25
done
if [ "${ready:-0}" != "1" ]; then
  echo; echo "!! Port 1025 injoignable. Log du port-forward :"; cat /tmp/mailpit-pf.log; exit 1
fi

echo ">> Envoi de $COUNT mails…"
python3 "$HERE/mailpit_blast.py" --count "$COUNT" "${EXTRA[@]}"
