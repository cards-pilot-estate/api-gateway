# Runbooks: API gateway

Each section matches an alert name. Dashboards: Grafana, "API gateway" (requests by route and client, 4xx/5xx, 429s, p95).

## Gateway5xxHigh
More than 5% of requests answered 5xx for 5 minutes.
1. `kubectl -n envoy-gateway-system logs deploy/<envoy-api-gateway-api-…> -c envoy --since=10m | grep '"status":5'`. Look at `flags`: `UF` or `UH` means the backend is down or has no endpoints; `UT` means the backend timed out (10 s on channel routes).
2. `UF`/`UH`: check the backend (`kubectl -n cards-<env> get pods`). The gateway retries nothing, so channels retry with the same Idempotency-Key.
3. 5xx with no upstream flags: the gateway itself. `kubectl -n envoy-gateway-system logs deploy/envoy-gateway`, then the proxy's `/ready` (port 19003).

## Gateway429Surge
More than 10% of one client's requests refused with 429 for 10 minutes.
1. Which rule: the access log `route` plus the client. A per-customer burst (one customer key) is a customer or a bug in the channel's polling. A client-quota hit means the channel as a whole is over 600 a minute.
2. Do not raise a limit during the incident without the channel team. Raise it in `chart/api-gateway/values.yaml` (`limits`) through a PR.

## GatewayJwksFetchFailing
The proxy cannot fetch the identity provider's keys, so new signing keys are unknown and tokens may be refused with 401.
1. `kubectl -n iam get pods`; from the proxy namespace, the JWKS URI in `values.yaml` (`iam.jwksUri`) must answer.
2. Cached keys keep working for `cacheDuration` (60 s).
3. **After a Keycloak restart** (for example `make iam`, which CD runs), dev-mode Keycloak signs with new keys. Tokens issued after the restart are refused with 401 until the proxy refreshes its cache, for up to 60 s. Channels retry. Stable keys arrive with W8.02 (Keycloak on its own database).

## Rate-limit store down
`envoy-ratelimit` cannot reach `gateway-redis`. Envoy fails open (requests pass unlimited), and the platform's own limiter is the backstop. Restart `gateway-redis` (`kubectl -n api-gateway rollout restart deploy/gateway-redis`); it keeps no data worth saving.
