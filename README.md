# api-gateway

The edge API gateway of the card onboarding estate, owned by the API platform team. Channels (the web channel first) reach the onboarding platform and the comms service **only** through it. It authenticates the calling application, publishes an allow-list of routes, applies quotas per channel client and per customer, and replaces headers a caller must not set.

Design and decisions live with the platform: `card-onboarding-platform/docs/channels/README.md` (§ API gateway) and ADR-0019 (Envoy Gateway behind Traefik).

## What runs

| Component | Namespace | What it is |
| --- | --- | --- |
| Envoy Gateway controller v1.9.3 | `envoy-gateway-system` | Turns the Gateway API resources below into Envoy configuration (`make install`) |
| Envoy proxy, Service `api-gateway` | `envoy-gateway-system` | The data plane. Channels call `http://api-gateway.envoy-gateway-system` with `Host: api.<env>.localtest.me` |
| Rate-limit service | `envoy-gateway-system` | Envoy Gateway's global rate limiter |
| `gateway-redis` | `api-gateway` | The rate-limit counters (no persistence, reachable only from the rate-limit service) |
| `Gateway` `api`, routes and policies | `api-gateway` | This repository's chart (`make deploy`) |

## Routes (allow-list)

| Class | Method and path | Backend | Token audience | Clients |
| --- | --- | --- | --- | --- |
| channel | `POST /api/v1/applications` | `onboarding-service.cards-<env>:8080` | `onboarding-api-<env>` | `channel-web-<env>` |
| channel | `GET /api/v1/applications/{uuid}/next-action` | same | same | same |
| channel | `POST /api/v1/applications/{uuid}/withdrawal` | same | same | same |
| channel | `POST /api/v1/applications/{uuid}/offer-acceptance` (the customer's answer to their offer, W10.04) | same | same | same |
| channel | `POST /api/v1/applications/{uuid}/erasure-requests` | same | same | same |
| comms | `POST /otp/v1/challenges`, `.../{uuid}/resend`, `.../{uuid}/verification`; `GET /otp/v1/jwks.json`; `POST /sms/v1/messages` | `otp-service.comms-<env>:8080` | `comms-api-<env>` | same |

Everything else answers 404, including the raw status read, `/api/v1/applicants/**`, `/api/v1/ops/**`, `/actuator/**` and the API docs. Every channel call must carry `x-customer-key` (the channel's opaque customer key, an HMAC); without it, there is no route.

## Policies

- **JWT:** issuer `http://iam.localtest.me/realms/cards`, keys from Keycloak in-cluster, cached 60 s (dev Keycloak makes new keys on every restart; see `docs/runbooks.md`). No token gives 401. A valid token from a client not on the route's list gives 403.
- **Headers:** `x-channel-client` is removed on arrival, then set from the token's `azp`. `X-Forwarded-For` is believed only from the perimeter's pod range.
- **Rate limits** (fixed calendar windows, counters in `gateway-redis`). A refusal is 429 with `Retry-After: 60` and `{"errorCode":"RATE_LIMITED"}`.

  | Rule | Limit |
  | --- | --- |
  | Per channel client, channel routes | 600 per minute |
  | Per customer, channel routes (GET included) | 30 per minute |
  | Per channel client, comms routes | 300 per minute |
  | Per customer, OTP sends | 10 per hour |
  | Per customer, OTP verifications | 30 per hour |

- **Timeouts:** 10 s on channel routes, 5 s on comms. There are no retries at the gateway: channels retry with the same `Idempotency-Key`.
- **Access log:** JSON on stdout (to Loki) with method, path without query, route, status, duration, request id, correlation id and client. No bodies, tokens or customer keys.

## Use

```bash
make install            # once per cluster: the controller (CRDs included)
make deploy             # the gateway, routes and policies for dev and uat
make test ENV=dev       # live checks; needs ../card-onboarding-platform for tokens
make lint               # what CI runs
```

`make test` proves each acceptance item with a live call:
- no token gives 401, and a client not on the list gives 403;
- unlisted paths give 404;
- a listed route reaches the platform, and a forged `x-channel-client` is replaced;
- the 31st call in a minute from one customer gets 429 with `Retry-After`, while another customer is unaffected.

## Known limits of this slice

- `gateway-redis` has no password. A NetworkPolicy admits only the rate-limit service, as a compensating control. A password needs the rate-limit service's Redis auth setting, which this chart version does not expose.
- One proxy replica on the laptop. uat and prod run two.
- Traefik sends `api.dev.localtest.me` here (WG.05); uat keeps its direct route until uat runs a Keycloak-era platform image.
- Each backend grants this gateway's routes access with its own `ReferenceGrant` (`allow-api-gateway` in `cards-<env>` and `comms-<env>`): the backend's owner decides.
- Alerts and the dashboard are described in `docs/runbooks.md`. Wiring them into the shared observability stack is a follow-up.
