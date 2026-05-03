#!/usr/bin/env bash
# scripts/smoke-test.sh
# Full-stack smoke test. Tests every endpoint, verifies Kafka consumer lag,
# checks all pods Running, and validates admin API access control.
# Exits 0 only if all checks pass.
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0

ok()   { echo -e "${GREEN}PASS${NC} $*"; ((PASS++)) || true; }
fail() { echo -e "${RED}FAIL${NC} $*"; ((FAIL++)) || true; }
info() { echo -e "${YELLOW}INFO${NC} $*"; }

http_check() {
  local label=$1 url=$2 expected=${3:-200}
  local code
  code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000")
  [[ "$code" == "$expected" ]] && ok "[$label] $url → $code" || fail "[$label] $url → expected=$expected actual=$code"
}

# Check a URL with a Bearer token; accepts a space-separated list of valid codes.
http_check_bearer() {
  local label=$1 url=$2 token=$3 expected_codes=${4:-200}
  local code
  code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 \
    -H "Authorization: Bearer $token" "$url" 2>/dev/null || echo "000")
  for exp in $expected_codes; do
    [[ "$code" == "$exp" ]] && { ok "[$label] $url → $code"; return; }
  done
  fail "[$label] $url → expected=$expected_codes actual=$code"
}

# Check a URL that should return one of a set of valid status codes (no token).
http_check_any() {
  local label=$1 url=$2 expected_codes=$3
  local code
  code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000")
  for exp in $expected_codes; do
    [[ "$code" == "$exp" ]] && { ok "[$label] $url → $code"; return; }
  done
  fail "[$label] $url → expected=$expected_codes actual=$code"
}

pod_check() {
  local label=$1 ns=$2 selector=$3
  local phase
  phase=$(kubectl get pods -n "$ns" -l "$selector" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Unknown")
  [[ "$phase" == "Running" ]] && ok "[$label] pod Running" || fail "[$label] pod phase=$phase"
}

echo "==============================="
echo "  Book Store Smoke Test"
echo "==============================="
echo ""

# ── 1. Pod health checks ────────────────────────────────────────────────────
info "Checking pod status..."
pod_check "ecom-service" ecom "app=ecom-service"
pod_check "ecom-db" ecom "cnpg.io/cluster=ecom-db,cnpg.io/instanceRole=primary"
pod_check "inventory-service" inventory "app=inventory-service"
pod_check "inventory-db" inventory "cnpg.io/cluster=inventory-db,cnpg.io/instanceRole=primary"
pod_check "analytics-db" analytics "cnpg.io/cluster=analytics-db,cnpg.io/instanceRole=primary"
pod_check "keycloak" identity "app=keycloak"
pod_check "redis" infra "app=redis"
pod_check "kafka" infra "app=kafka"
pod_check "debezium-server-ecom" infra "app=debezium-server-ecom"
pod_check "debezium-server-inventory" infra "app=debezium-server-inventory"
pod_check "pgadmin" admin-tools "app=pgadmin"
pod_check "superset" analytics "app=superset"
pod_check "ui-service" ecom "app=ui-service"

echo ""
# ── 2. HTTP endpoint checks ─────────────────────────────────────────────────
info "Checking HTTP endpoints..."
http_check "Keycloak OIDC" "https://idp.keycloak.net:30000/realms/bookstore/.well-known/openid-configuration"
http_check "UI catalog" "https://myecom.net:30000/"
http_check "ecom GET /books" "https://api.service.net:30000/ecom/books"
http_check "ecom GET /books/search" "https://api.service.net:30000/ecom/books/search?q=kafka"
http_check "ecom GET /cart (no auth→401)" "https://api.service.net:30000/ecom/cart" "401"
http_check "inventory health" "https://api.service.net:30000/inven/health"
http_check "PgAdmin" "http://localhost:31111/misc/ping"
http_check "Superset" "http://localhost:32000/health"

echo ""
# ── 3. Kafka consumer lag ────────────────────────────────────────────────────
info "Checking Kafka consumer lag..."
LAG=$(kubectl exec -n infra deploy/kafka -- \
  kafka-consumer-groups --bootstrap-server localhost:9092 \
  --group inventory-service \
  --describe 2>/dev/null | awk '/inventory-service/{sum+=$6} END{print sum+0}' || echo "-1")

if [[ "$LAG" == "0" || "$LAG" == "" ]]; then
  ok "[Kafka lag] inventory-service consumer lag=0"
else
  fail "[Kafka lag] inventory-service consumer lag=$LAG (expected 0)"
fi

echo ""
# ── 4. Debezium Server health ─────────────────────────────────────────────────
info "Checking Debezium Server health..."
for pair in "ecom:http://localhost:32300" "inventory:http://localhost:32301"; do
  name="${pair%%:*}"
  url="${pair#*:}"
  STATUS=$(curl -s --max-time 10 "${url}/q/health" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','UNKNOWN'))" 2>/dev/null \
    || echo "UNKNOWN")
  [[ "$STATUS" == "UP" ]] && ok "[Debezium Server] ${name}=UP" || fail "[Debezium Server] ${name}=${STATUS}"
done

echo ""
# ── 5. Admin API access control ──────────────────────────────────────────────
# Verifies: unauthenticated requests are rejected, admin token grants access,
# customer token is denied. Depends on Keycloak realm having admin1 + admin role.
info "Checking admin API access control..."

# No-token requests must be rejected
http_check "ecom admin no-token→401"  "https://api.service.net:30000/ecom/admin/books" "401"
# FastAPI HTTPBearer returns 403 (not 401) when Authorization header is absent
http_check_any "inven admin no-token→401/403" \
  "https://api.service.net:30000/inven/admin/stock" "401 403"

# Fetch admin token via Resource Owner Password grant (directAccessGrantsEnabled=true on ui-client)
ADMIN_TOKEN=$(curl -sk --max-time 15 -X POST \
  "https://idp.keycloak.net:30000/realms/bookstore/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=ui-client&username=admin1&password=CHANGE_ME" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")

if [[ -n "$ADMIN_TOKEN" ]]; then
  ok "[Admin token] Fetched admin1 token from Keycloak"
  http_check_bearer "ecom admin GET /books→200"  \
    "https://api.service.net:30000/ecom/admin/books" "$ADMIN_TOKEN" "200"
  http_check_bearer "inven admin GET /stock→200" \
    "https://api.service.net:30000/inven/admin/stock" "$ADMIN_TOKEN" "200"
else
  fail "[Admin token] Could not fetch admin1 token — check Keycloak realm import"
fi

# Customer token must be denied on admin endpoints (role enforcement)
CUSTOMER_TOKEN=$(curl -sk --max-time 15 -X POST \
  "https://idp.keycloak.net:30000/realms/bookstore/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=ui-client&username=user1&password=CHANGE_ME" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")

if [[ -n "$CUSTOMER_TOKEN" ]]; then
  http_check_bearer "ecom admin customer→403"  \
    "https://api.service.net:30000/ecom/admin/books" "$CUSTOMER_TOKEN" "403"
  http_check_bearer "inven admin customer→403" \
    "https://api.service.net:30000/inven/admin/stock" "$CUSTOMER_TOKEN" "403"
else
  fail "[Customer token] Could not fetch user1 token — check Keycloak realm import"
fi

# ── 6. TLS certificate check ─────────────────────────────────────────────────
info "Checking TLS certificate..."
CERT_READY=$(kubectl get certificate bookstore-gateway-cert -n infra \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
[[ "$CERT_READY" == "True" ]] && ok "[TLS] Gateway certificate Ready" || fail "[TLS] Gateway certificate status=$CERT_READY"

# ── 7. HTTP→HTTPS redirect ───────────────────────────────────────────────────
info "Checking HTTP→HTTPS redirect (port 30080 → 301 → https://:30000)..."
http_check "HTTP→HTTPS redirect" "http://myecom.net:30080/" "301"

echo ""
echo "==============================="
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "==============================="
[[ $FAIL -eq 0 ]] && echo -e "${GREEN}✔ All smoke tests passed${NC}" || { echo -e "${RED}FAIL: Some checks failed${NC}"; exit 1; }
