#!/usr/bin/env bash
# Provision a Lodestar tenant: mint a bearer token, start that tenant's own
# coordinator (its own port + claims.log), and register it with the gateway.
# The plaintext token is printed ONCE — only its sha-256 hash is stored.
#
#   ./provision.sh <tenant-id> [coordinator-port]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TENANT="${1:?usage: provision.sh <tenant-id> [coordinator-port]}"
PORT="${2:-}"
FRAM="${FRAM_HOME:-$HOME/code/fram}"
REGISTRY="${GATEWAY_TENANTS:-$HERE/tenants.edn}"
DATA_ROOT="${LODESTAR_TENANT_ROOT:-$HOME/.local/state/lodestar/tenants}"

# pick the first free loopback port >= 7800 if none given
if [ -z "$PORT" ]; then
  PORT=7800
  while ss -tlnH "sport = :$PORT" 2>/dev/null | grep -q .; do PORT=$((PORT+1)); done
fi

TDIR="$DATA_ROOT/$TENANT"
mkdir -p "$TDIR"
LOG="$TDIR/claims.log"; touch "$LOG"

TOKEN="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
HASH="$(printf '%s' "$TOKEN" | sha256sum | cut -d' ' -f1)"

# start this tenant's coordinator on its own port + log (idempotent)
FRAM_PORT="$PORT" FRAM_LOG="$LOG" "$FRAM/bin/fram-up"

# upsert into the EDN registry (bb keeps it valid EDN)
bb -e "
(require '[clojure.edn :as edn] '[clojure.java.io :as io] '[clojure.pprint :as pp])
(def p \"$REGISTRY\")
(def reg (if (.exists (io/file p)) (edn/read-string (slurp p)) {}))
(spit p (with-out-str (pp/pprint (assoc reg \"$TENANT\"
                                        {:token-sha256 \"$HASH\" :coordinator-port $PORT}))))"

echo "provisioned tenant '$TENANT'  port=$PORT  log=$LOG"
echo "TOKEN (shown once — store it now; only the hash is kept):"
echo "  $TOKEN"
