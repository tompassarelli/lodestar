#!/usr/bin/env bash
# Integration smoke test for the auth gateway: stands up a real coordinator + the
# gateway, then asserts authed requests pass through and unauthed ones are 401.
#   ./smoke_test.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FRAM="${FRAM_HOME:-$HOME/code/fram}"
CPORT=7891          # test coordinator port
GPORT=8891          # test gateway port
TMP="$(mktemp -d)"
LOG="$TMP/claims.log"; : > "$LOG"
REG="$TMP/tenants.edn"
TOKEN="test-token-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
HASH="$(printf '%s' "$TOKEN" | sha256sum | cut -d' ' -f1)"
printf '{"acme" {:token-sha256 "%s" :coordinator-port %s}}\n' "$HASH" "$CPORT" > "$REG"

COORD_PID=""; GW_PID=""
cleanup() { [ -n "$GW_PID" ] && kill "$GW_PID" 2>/dev/null || true
            [ -n "$COORD_PID" ] && kill "$COORD_PID" 2>/dev/null || true
            rm -rf "$TMP"; }
trap cleanup EXIT

echo "starting coordinator on :$CPORT ..."
( cd "$FRAM" && exec bb -cp out cnf_coord_daemon.clj serve-flat "$CPORT" "$LOG" ) >"$TMP/coord.log" 2>&1 &
COORD_PID=$!
for _ in $(seq 40); do
  bb -e "(require '[clojure.edn :as e]) (import '[java.net Socket InetSocketAddress])
         (try (with-open [s (Socket.)] (.connect s (InetSocketAddress. \"127.0.0.1\" $CPORT) 500)
                (let [o (.getOutputStream s)] (.write o (.getBytes \"{:op :version}\n\")) (.flush o)) (System/exit 0))
              (catch Exception _ (System/exit 1)))" 2>/dev/null && break
  sleep 0.25
done

echo "starting gateway on :$GPORT ..."
GATEWAY_PORT="$GPORT" GATEWAY_TENANTS="$REG" bb "$HERE/gateway.clj" >"$TMP/gw.log" 2>&1 &
GW_PID=$!
for _ in $(seq 40); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$GPORT/healthz" 2>/dev/null)" = "200" ] && break
  sleep 0.25
done

pass=0; fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  [PASS] $1"; pass=$((pass+1))
  else echo "  [FAIL] $1 — expected '$2' got '$3'"; fail=$((fail+1)); fi
}

# 1. health
check "healthz is 200" "200" "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$GPORT/healthz)"

# 2. authed RPC forwards to the coordinator (expect a :version reply)
body="$(curl -s -H "Authorization: Bearer $TOKEN" -H 'content-type: application/edn' \
        --data '{:op :version}' http://127.0.0.1:$GPORT/v1/rpc)"
case "$body" in *":version"*) check "authed /v1/rpc reaches coordinator" "ok" "ok";;
                *)             check "authed /v1/rpc reaches coordinator" "ok" "got:$body";; esac

# 3. wrong token -> 401
check "bad token is 401" "401" "$(curl -s -o /dev/null -w '%{http_code}' \
       -H 'Authorization: Bearer wrong' --data '{:op :version}' http://127.0.0.1:$GPORT/v1/rpc)"

# 4. no auth -> 401
check "missing auth is 401" "401" "$(curl -s -o /dev/null -w '%{http_code}' \
       --data '{:op :version}' http://127.0.0.1:$GPORT/v1/rpc)"

echo
if [ "$fail" -eq 0 ]; then echo "gateway smoke: ALL $pass PASS"; else echo "gateway smoke: $fail FAILED"; exit 1; fi
