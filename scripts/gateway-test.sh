#!/usr/bin/env bash
# Live checks of the API gateway (WG.04). Each line is one acceptance item; the script exits
# non-zero if any fails. Needs kubectl access to the cluster and two channel tokens:
#   WEB_TOKEN    a channel-web-<env> token (allowed client)
#   OTHER_TOKEN  a channel-app-<env> token (a valid token from a client NOT on the allow-list)
#   UAT_TOKEN    optional: a channel-web token for another environment (wrong audience)
# With the platform repo next door, the defaults fetch them:
#   CHANNEL_CLIENT=channel-web ../card-onboarding-platform/scripts/token.sh dev
set -uo pipefail

ENV="${1:-dev}"
HOST="api.$ENV.localtest.me"
PORT="${PORT:-18080}"
PLATFORM="${PLATFORM:-$(dirname "$0")/../../card-onboarding-platform}"
token() { bash "$PLATFORM/scripts/token.sh" "$@"; }
WEB_TOKEN="${WEB_TOKEN:-$(CHANNEL_CLIENT=channel-web token "$ENV")}"
OTHER_TOKEN="${OTHER_TOKEN:-$(token "$ENV")}"
OTHER_ENV=$([ "$ENV" = dev ] && echo uat || echo dev)
UAT_TOKEN="${UAT_TOKEN:-$(CHANNEL_CLIENT=channel-web token "$OTHER_ENV" 2>/dev/null || true)}"

kubectl -n envoy-gateway-system port-forward svc/api-gateway "$PORT:80" >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
for _ in $(seq 1 30); do curl -s -o /dev/null "http://127.0.0.1:$PORT" && break; sleep 0.5; done

BASE="http://127.0.0.1:$PORT"
CUSTOMER="test-customer-$(openssl rand -hex 12)"
FAILED=0
check() {  # name expected actual
  if [ "$2" = "$3" ]; then echo "PASS  $1 ($3)"; else echo "FAIL  $1: expected $2, got $3"; FAILED=1; fi
}
code() { curl -s -o /dev/null -w '%{http_code}' -H "Host: $HOST" "$@"; }

BODY=$(cat <<JSON
{"applicant":{"fullName":"Gateway Test","pan":"ABCPG$(printf '%04d' $((RANDOM % 10000)))K","dateOfBirth":"1990-04-12",
 "phone":"+919800000001","email":"gateway.test@example.com","addressLine1":"1 Test Road","city":"Bengaluru",
 "state":"Karnataka","pincode":"560025"},"cardType":"GOLD","monthlyIncome":90000,"monthlyObligation":10000,
 "employerName":"Test Co","employmentType":"SALARIED","consentMITC":true,"consentBureauPull":true,
 "consentDataProcessing":true,"mitcVersion":"MITC-2026.1","kycReferenceId":"$(uuidgen | tr A-Z a-z)",
 "fraudScreenId":"$(uuidgen | tr A-Z a-z)"}
JSON
)

check "no token is refused at the gateway" 401 \
  "$(code -X POST "$BASE/api/v1/applications" -H "x-customer-key: $CUSTOMER")"
check "a client not on the allow-list is refused" 403 \
  "$(code -H "Authorization: Bearer $OTHER_TOKEN" -H "x-customer-key: $CUSTOMER" "$BASE/api/v1/applications/$(uuidgen)/next-action")"
if [ -n "$UAT_TOKEN" ]; then
  # Wrong audience and wrong client at once: the gateway answers 403 (authorization) or 401 (JWT).
  C=$(code -H "Authorization: Bearer $UAT_TOKEN" -H "x-customer-key: $CUSTOMER" "$BASE/api/v1/applications/$(uuidgen)/next-action")
  check "a token for another environment is refused" refused "$([ "$C" = 401 ] || [ "$C" = 403 ] && echo refused || echo "$C")"
fi
for path in "/api/v1/applicants/$(uuidgen)" "/api/v1/applications/$(uuidgen)" "/api/v1/ops/me" "/actuator/health" "/v3/api-docs"; do
  check "unlisted GET $path is not routed" 404 \
    "$(code -H "Authorization: Bearer $WEB_TOKEN" -H "x-customer-key: $CUSTOMER" "$BASE$path")"
done
check "a call without a customer key is not routed" 404 \
  "$(code -H "Authorization: Bearer $WEB_TOKEN" "$BASE/api/v1/applications/$(uuidgen)/next-action")"

RESPONSE=$(curl -s -w '\n%{http_code}' -H "Host: $HOST" -X POST "$BASE/api/v1/applications" \
  -H "Authorization: Bearer $WEB_TOKEN" -H "x-customer-key: $CUSTOMER" -H "x-channel-client: channel-app-$ENV" \
  -H "Idempotency-Key: gw-$(uuidgen)" -H "X-Channel-ID: WEB" -H "Content-Type: application/json" -d "$BODY")
check "a listed route reaches the platform (forged x-channel-client sent)" 202 "$(tail -1 <<<"$RESPONSE")"
APP=$(head -1 <<<"$RESPONSE" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("applicationId",""))' 2>/dev/null)

# Envoy buffers its access log; look for the line for up to 20 s.
PROXY=$(kubectl -n envoy-gateway-system get pods -l gateway.envoyproxy.io/owning-gateway-name=api -o name | head -1)
LOGGED=""
for _ in $(seq 1 10); do
  sleep 2
  LOGGED=$(kubectl -n envoy-gateway-system logs "$PROXY" -c envoy --since=90s 2>/dev/null \
    | grep '"method":"POST"' | grep '"status":202' | grep '/api/v1/applications"' | tail -1 \
    | python3 -c 'import sys,json; print(json.loads(sys.stdin.read() or "{}").get("client") or "")' 2>/dev/null)
  [ -n "$LOGGED" ] && break
done
check "the forged x-channel-client is replaced by the token's azp" "channel-web-$ENV" "$LOGGED"

check "the customer view answers through the gateway" 200 \
  "$(code -H "Authorization: Bearer $WEB_TOKEN" -H "x-customer-key: $CUSTOMER" "$BASE/api/v1/applications/$APP/next-action")"

# Per-customer limit: 30 a minute, GET included. Windows are fixed calendar minutes, so start a
# fresh customer early in a minute and count the calls until the first refusal.
CUSTOMER="limit-$CUSTOMER"
SEC=$(date +%S); [ "${SEC#0}" -gt 40 ] && sleep $((61 - ${SEC#0}))
LAST=200; N=0
while [ "$LAST" != 429 ] && [ $N -lt 40 ]; do
  N=$((N + 1))
  LAST=$(code -H "Authorization: Bearer $WEB_TOKEN" -H "x-customer-key: $CUSTOMER" "$BASE/api/v1/applications/$APP/next-action")
done
check "the per-customer limit refuses call 31 in the minute" 31 "$N"
RETRY=$(curl -s -D - -o /dev/null -H "Host: $HOST" -H "Authorization: Bearer $WEB_TOKEN" -H "x-customer-key: $CUSTOMER" \
  "$BASE/api/v1/applications/$APP/next-action" | tr -d '\r' | awk -F': ' 'tolower($1)=="retry-after"{print $2}')
check "a refusal carries Retry-After" 60 "$RETRY"
check "another customer of the same channel is not affected" 200 \
  "$(code -H "Authorization: Bearer $WEB_TOKEN" -H "x-customer-key: other-$CUSTOMER" "$BASE/api/v1/applications/$APP/next-action")"

[ $FAILED = 0 ] && echo "All gateway checks passed" || echo "Some gateway checks FAILED"
exit $FAILED
