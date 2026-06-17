# Lodestar auth gateway

The network-safe edge in front of the (loopback-only, unauthenticated) coordinator.
It is the single component that takes Lodestar from *single-machine* to *remote
and multi-tenant* — without changing the claim model, the write-safety, or the
"export and walk away" guarantee.

```
client ──HTTPS──▶ reverse proxy (TLS) ──HTTP──▶ gateway ──EDN/loopback──▶ tenant coordinator
                                                  │  bearer token → tenant → that tenant's port
```

## Why a gateway (and why per-tenant)

The coordinator is a sole-writer daemon that binds `127.0.0.1` and speaks an
**unauthenticated** line-delimited EDN protocol. That's correct for a single
operator on one machine. To serve other people you need (a) authentication and
(b) tenant isolation. The gateway adds both, and isolation is done the only safe
way: **one coordinator + one `claims.log` per tenant.** The per-assertion `frame`
is *provenance, not authorization* — never the tenancy boundary.

## Endpoints

| method | path | auth | body | does |
|--------|------|------|------|------|
| `GET`  | `/healthz` | none | — | liveness, `200 ok` |
| `POST` | `/v1/rpc`  | `Authorization: Bearer <token>` | one EDN map, e.g. `{:op :version}` | forwards to the caller's tenant coordinator, relays the EDN reply |

`:op` values are the coordinator's: `:version`, `:status`, `:validate`,
`:assert {:te :p :r :base}`, `:retract {…}`. Unknown token → `401`; coordinator
down → `502`; malformed body → `400`.

## Config (env)

- `GATEWAY_PORT` — listen port (default `8088`). **Plain HTTP by design** — put TLS in front.
- `GATEWAY_TENANTS` — path to the registry (default `./tenants.edn`):

```clojure
{"acme"   {:token-sha256 "<hex>" :coordinator-port 7801}
 "globex" {:token-sha256 "<hex>" :coordinator-port 7802 :coordinator-host "127.0.0.1"}}
```

Tokens are stored **sha-256 hashed**, never in plaintext. The file is re-read when
its mtime changes, so `provision.sh` adds a tenant with no gateway restart.
`:coordinator-host` is optional (default `127.0.0.1`) for when a coordinator lives
on a private network rather than co-located.

## Run it

```sh
# provision a tenant (mints a token, starts its coordinator, registers it)
./provision.sh acme 7801          # prints the bearer token ONCE

# start the gateway
GATEWAY_TENANTS=$PWD/tenants.edn bb gateway.clj

# call it
curl -s -H "Authorization: Bearer <token>" --data '{:op :version}' \
  http://127.0.0.1:8088/v1/rpc
```

`./smoke_test.sh` stands up a real coordinator + gateway and asserts authed
requests pass and unauthed ones are `401` (this runs in CI).

## Scope and hardening checklist

This is the **first real slice** of the auth layer — proven end-to-end, but not
yet everything a public SaaS needs. Before exposing it to the internet:

- [ ] **TLS** terminated in a reverse proxy (Caddy/nginx) ahead of the gateway.
- [ ] **Same-host (or shared-netns) coordinators** — the gateway forwards over
      loopback by default; cross-host needs a configurable coordinator bind + mTLS.
- [ ] **Rate limiting / request size caps** (at the proxy or here).
- [ ] **Token rotation + revocation** policy (registry edit + reload is the hook).
- [ ] **Audit logging** of who-asserted-what at the edge.
- [ ] **Per-tenant daemon supervision** (systemd template unit or one container each).

See `../../docs/hosting.md` for the full picture and roadmap.
