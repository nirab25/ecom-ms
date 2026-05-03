#!/usr/bin/env bash
# scripts/up.sh
# Master startup script — brings the BookStore stack fully online from any state.
#
# Scenarios handled automatically:
#   1. No kind cluster exists  → fresh full bootstrap (create cluster + all services)
#   2. Cluster exists, healthy → verify connectors are registered, run smoke test
#   3. Cluster exists, degraded → recovery: restart ztunnel + all pods + connectors
#      (typical after Docker Desktop restart)
#
# Options:
#   --fresh         Delete existing cluster first, then full bootstrap from scratch
#   --fresh --data  Delete existing cluster + wipe ./data/, then bootstrap
#   --yes / -y      Skip all confirmation prompts
#
# Usage:
#   ./scripts/up.sh                  # smart start (recommended)
#   ./scripts/up.sh --fresh          # tear down cluster and rebuild (keep data)
#   ./scripts/up.sh --fresh --data   # tear down + wipe data, then rebuild
#   ./scripts/up.sh --yes            # non-interactive (for CI / automation)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}==>${NC} $*"; }
section() { echo -e "\n${YELLOW}════════════════════════════════════════${NC}\n  $*\n${YELLOW}════════════════════════════════════════${NC}"; }
warn()    { echo -e "${YELLOW}WARN:${NC} $*"; }
err()     { echo -e "${RED}ERROR:${NC} $*" >&2; }

# ── Parse options ────────────────────────────────────────────────────────────
FRESH=false
WIPE_DATA=false
YES=false
for arg in "$@"; do
  case "$arg" in
    --fresh)    FRESH=true ;;
    --data)     WIPE_DATA=true ;;
    --yes|-y)   YES=true ;;
    *) err "Unknown option: $arg"; echo "Usage: $0 [--fresh] [--data] [--yes|-y]"; exit 1 ;;
  esac
done

confirm() {
  $YES && return 0
  local ans
  read -r -p "$1 [y/N] " ans
  [[ "$ans" =~ ^[Yy] ]]
}

wait_deploy() {
  local name=$1 ns=$2 timeout=${3:-600s}
  kubectl rollout status deployment/"$name" -n "$ns" --timeout="$timeout" || {
    warn "Deployment '$name' in '$ns' did not roll out within $timeout — continuing anyway"
    return 0
  }
}

# ── Bootstrap function: full fresh cluster + all services ────────────────────
bootstrap_fresh() {
  # ── 1. Kind cluster + Istio + KGateway (~4-6 min, sequential) ───────────────
  section "Creating kind cluster 'bookstore'"
  free_required_ports
  mkdir -p "${REPO_ROOT}/data"/{superset,kafka,redis,flink,grafana,prometheus}
  DATA_DIR="${REPO_ROOT}/data"
  sed "s|DATA_DIR|${DATA_DIR}|g" "${REPO_ROOT}/infra/kind/cluster.yaml" > /tmp/bookstore-cluster.yaml
  kind create cluster --name bookstore --config /tmp/bookstore-cluster.yaml
  kubectl config use-context kind-bookstore
  kubectl wait --for=condition=Ready nodes --all --timeout=120s

  section "Installing Istio Ambient Mesh"
  bash "${REPO_ROOT}/infra/istio/install.sh"

  section "Installing Kubernetes Gateway API (kgateway)"
  bash "${REPO_ROOT}/infra/kgateway/install.sh"

  section "Installing cert-manager"
  bash "${REPO_ROOT}/infra/cert-manager/install.sh"

  section "Applying namespaces and Gateway resource"
  kubectl apply -f "${REPO_ROOT}/infra/namespaces.yaml"
  # Apply CA issuer + certificate chain (cert-manager must be ready first)
  info "Creating CA issuer and certificate chain..."
  kubectl apply -f "${REPO_ROOT}/infra/cert-manager/ca-issuer.yaml"
  # Wait for CA certificate to be issued
  info "Waiting for CA certificate to be ready..."
  for _ca_i in $(seq 1 30); do
    if kubectl get certificate bookstore-ca -n cert-manager -o jsonpath='{.status.conditions[0].status}' 2>/dev/null | grep -q "True"; then
      info "CA certificate ready."
      break
    fi
    [[ $_ca_i -eq 30 ]] && warn "CA certificate not ready after 150s — continuing anyway"
    sleep 5
  done
  # Apply gateway certificate (needs CA issuer)
  kubectl apply -f "${REPO_ROOT}/infra/cert-manager/gateway-certificate.yaml"
  kubectl apply -f "${REPO_ROOT}/infra/cert-manager/rotation-config.yaml"
  # Wait for gateway TLS certificate
  info "Waiting for gateway TLS certificate to be ready..."
  for _tls_i in $(seq 1 30); do
    if kubectl get certificate bookstore-gateway-cert -n infra -o jsonpath='{.status.conditions[0].status}' 2>/dev/null | grep -q "True"; then
      info "Gateway TLS certificate ready."
      break
    fi
    [[ $_tls_i -eq 30 ]] && warn "Gateway TLS certificate not ready after 150s — continuing anyway"
    sleep 5
  done

  kubectl apply -f "${REPO_ROOT}/infra/kgateway/gateway.yaml"
  # Istio creates the gateway Service with random NodePorts; patch HTTPS (8443) to 30000
  # so the kind extraPortMapping (host:30000 → container:30000) routes correctly.
  info "Waiting for Istio to create bookstore-gateway-istio service..."
  for i in $(seq 1 30); do
    if kubectl get svc bookstore-gateway-istio -n infra &>/dev/null 2>&1; then
      # Patch HTTPS (8443) → NodePort 30000, HTTP (8080) → NodePort 30080.
      # Istio names the ports based on listener names from the Gateway spec.
      kubectl patch svc bookstore-gateway-istio -n infra --type='merge' \
        -p='{"spec":{"ports":[{"name":"https","port":8443,"targetPort":8443,"nodePort":30000,"protocol":"TCP"},{"name":"http","port":8080,"targetPort":8080,"nodePort":30080,"protocol":"TCP"}]}}' 2>/dev/null || \
      kubectl patch svc bookstore-gateway-istio -n infra --type='json' \
        -p='[{"op":"replace","path":"/spec/ports/0/nodePort","value":30000},{"op":"replace","path":"/spec/ports/1/nodePort","value":30080}]' 2>/dev/null || true
      info "Patched bookstore-gateway-istio NodePorts → HTTPS:30000, HTTP:30080"
      break
    fi
    info "  Service not ready yet (${i}/30), retrying in 5s..."
    sleep 5
  done

  section "Applying StorageClass and PersistentVolumes"
  kubectl apply -f "${REPO_ROOT}/infra/storage/storageclass.yaml"
  kubectl apply -f "${REPO_ROOT}/infra/storage/persistent-volumes.yaml"

  # ── 2. Start Docker builds in parallel background ────────────────────────────
  # Builds run concurrently while infrastructure is deploying below. Logs go to
  # /tmp/build-*.log; we print them only on failure. Images are kind-loaded after
  # all builds complete (kind load is serialized to avoid contention).
  # Using plain variables (not associative arrays) for bash 3.2 compatibility
  # (macOS ships bash 3.2 as /bin/bash).
  section "Starting parallel Docker image builds (background)"
  GIT_SHA=$(cd "${REPO_ROOT}" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
  info "  Git SHA: ${GIT_SHA}"
  _ECOM_PID="" _INV_PID="" _FLINK_PID="" _UI_PID="" _CSRF_PID=""
  if docker image inspect bookstore/ecom-service:latest &>/dev/null; then
    info "  bookstore/ecom-service:latest already exists — skipping build."
  else
    info "  Building bookstore/ecom-service:latest (background)..."
    (docker build -t bookstore/ecom-service:latest "${REPO_ROOT}/ecom-service" && \
      docker tag bookstore/ecom-service:latest "bookstore/ecom-service:${GIT_SHA}") \
      >/tmp/build-ecom.log 2>&1 &
    _ECOM_PID=$!
  fi
  if docker image inspect bookstore/inventory-service:latest &>/dev/null; then
    info "  bookstore/inventory-service:latest already exists — skipping build."
  else
    info "  Building bookstore/inventory-service:latest (background)..."
    (docker build -t bookstore/inventory-service:latest "${REPO_ROOT}/inventory-service" && \
      docker tag bookstore/inventory-service:latest "bookstore/inventory-service:${GIT_SHA}") \
      >/tmp/build-inventory.log 2>&1 &
    _INV_PID=$!
  fi
  if docker image inspect bookstore/flink:latest &>/dev/null; then
    info "  bookstore/flink:latest already exists — skipping build."
  else
    info "  Building bookstore/flink:latest (background)..."
    (docker build -t bookstore/flink:latest "${REPO_ROOT}/analytics/flink" && \
      docker tag bookstore/flink:latest "bookstore/flink:${GIT_SHA}") \
      >/tmp/build-flink.log 2>&1 &
    _FLINK_PID=$!
  fi
  if docker image inspect bookstore/csrf-service:latest &>/dev/null; then
    info "  bookstore/csrf-service:latest already exists — skipping build."
  else
    info "  Building bookstore/csrf-service:latest (background)..."
    (docker build -t bookstore/csrf-service:latest "${REPO_ROOT}/csrf-service" && \
      docker tag bookstore/csrf-service:latest "bookstore/csrf-service:${GIT_SHA}") \
      >/tmp/build-csrf.log 2>&1 &
    _CSRF_PID=$!
  fi
  # UI always rebuilt — VITE vars are baked in at build time
  info "  Building bookstore/ui-service:latest (background)..."
  (docker build \
    --build-arg VITE_KEYCLOAK_AUTHORITY=https://idp.keycloak.net:30000/realms/bookstore \
    --build-arg VITE_KEYCLOAK_CLIENT_ID=ui-client \
    --build-arg VITE_REDIRECT_URI=https://localhost:30000/callback \
    -t bookstore/ui-service:latest "${REPO_ROOT}/ui" && \
    docker tag bookstore/ui-service:latest "bookstore/ui-service:${GIT_SHA}") \
    >/tmp/build-ui.log 2>&1 &
  _UI_PID=$!

  # ── 3. CloudNativePG database clusters ────────────────────────────────────────
  # IMPORTANT: use explicit PID tracking for all parallel waits so that bare
  # `wait` never accidentally reaps the background docker build processes.
  section "Installing CloudNativePG operator"
  bash "${REPO_ROOT}/infra/cnpg/install.sh"

  section "Deploying CNPG database clusters"
  kubectl apply -f "${REPO_ROOT}/infra/cnpg/ecom-db-cluster.yaml"
  kubectl apply -f "${REPO_ROOT}/infra/cnpg/inventory-db-cluster.yaml"
  kubectl apply -f "${REPO_ROOT}/infra/cnpg/analytics-db-cluster.yaml"
  kubectl apply -f "${REPO_ROOT}/infra/cnpg/keycloak-db-cluster.yaml"
  kubectl apply -f "${REPO_ROOT}/infra/cnpg/peer-auth.yaml"
  info "Waiting for all CNPG clusters to be ready..."
  kubectl wait --for=condition=Ready cluster/ecom-db -n ecom --timeout=600s & _P1=$!
  kubectl wait --for=condition=Ready cluster/inventory-db -n inventory --timeout=600s & _P2=$!
  kubectl wait --for=condition=Ready cluster/analytics-db -n analytics --timeout=600s & _P3=$!
  kubectl wait --for=condition=Ready cluster/keycloak-db -n identity --timeout=600s & _P4=$!
  wait $_P1 $_P2 $_P3 $_P4

  # ── 4. Analytics DDL (before Flink — JDBC sink requires tables to pre-exist) ─
  section "Applying analytics DB schema"
  if [[ -f "${REPO_ROOT}/analytics/schema/analytics-ddl.sql" ]]; then
    info "Waiting for analytics-db pod..."
    kubectl wait --for=condition=Ready pod -n analytics -l cnpg.io/cluster=analytics-db,cnpg.io/instanceRole=primary --timeout=60s
    ANALYTICS_POD=$(kubectl get pod -n analytics -l cnpg.io/cluster=analytics-db,cnpg.io/instanceRole=primary \
      -o jsonpath='{.items[0].metadata.name}')
    # CNPG uses peer auth on local sockets — use postgres superuser for DDL, then grant to app user
    cat "${REPO_ROOT}/analytics/schema/analytics-ddl.sql" | \
      kubectl exec -i -n analytics "$ANALYTICS_POD" -- \
      psql -U postgres -d analyticsdb || \
      warn "Analytics DDL apply failed — check schema manually"
    # Grant ownership of all tables/views to analyticsuser
    kubectl exec -n analytics "$ANALYTICS_POD" -- \
      psql -U postgres -d analyticsdb -c \
      "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO analyticsuser; GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO analyticsuser;" 2>/dev/null || true
    info "Analytics schema applied."
  fi

  # ── 5. Redis + Kafka in parallel ─────────────────────────────────────────────
  section "Deploying Redis + Kafka (KRaft)"
  kubectl apply -f "${REPO_ROOT}/infra/redis/redis.yaml"
  kubectl apply -f "${REPO_ROOT}/infra/kafka/zookeeper.yaml" 2>/dev/null || true  # intentionally empty placeholder
  kubectl apply -f "${REPO_ROOT}/infra/kafka/kafka.yaml"
  info "Waiting for Redis + Kafka in parallel..."
  kubectl rollout status deployment/redis -n infra --timeout=600s & _P1=$!
  kubectl rollout status deployment/kafka -n infra --timeout=600s & _P2=$!
  wait $_P1 $_P2
  # Apply topic-init Job separately (never re-apply kafka.yaml here — that would
  # reconfigure the Deployment and could restart Kafka mid-job).
  kubectl delete job kafka-topic-init -n infra --ignore-not-found
  kubectl apply -f "${REPO_ROOT}/infra/kafka/kafka-topics-init.yaml"
  kubectl wait --for=condition=complete job/kafka-topic-init -n infra --timeout=600s

  # ── 5b. Kafka Exporter (Prometheus metrics for consumer lag) ────────────────
  info "Deploying Kafka Exporter..."
  kubectl apply -f "${REPO_ROOT}/infra/kafka/kafka-exporter.yaml"
  wait_deploy kafka-exporter infra

  # ── 5c. Schema Registry + JSON Schema registration ─────────────────────────
  info "Deploying Schema Registry..."
  kubectl apply -f "${REPO_ROOT}/infra/schema-registry/schema-registry.yaml"
  wait_deploy schema-registry infra
  info "Registering JSON Schemas..."
  bash "${REPO_ROOT}/infra/schema-registry/register-schemas.sh" || \
    warn "Schema registration failed — non-fatal, continuing"

  # ── 6. Debezium Server + PgAdmin ─────────────────────────────────────────────
  section "Deploying Debezium Server (ecom + inventory) + PgAdmin"
  # Debezium Server pods run in `infra` namespace; DB secrets live in `ecom`/`inventory`.
  # Kubernetes secrets are namespace-scoped — copy credentials into infra namespace.
  ECOM_USER=$(kubectl get secret -n ecom ecom-db-cnpg-auth -o jsonpath='{.data.username}' | base64 -d)
  ECOM_PASS=$(kubectl get secret -n ecom ecom-db-cnpg-auth -o jsonpath='{.data.password}' | base64 -d)
  INV_USER=$(kubectl get secret -n inventory inventory-db-cnpg-auth -o jsonpath='{.data.username}' | base64 -d)
  INV_PASS=$(kubectl get secret -n inventory inventory-db-cnpg-auth -o jsonpath='{.data.password}' | base64 -d)
  kubectl create secret generic debezium-db-credentials -n infra \
    --from-literal=ECOM_DB_USER="$ECOM_USER" \
    --from-literal=ECOM_DB_PASSWORD="$ECOM_PASS" \
    --from-literal=INVENTORY_DB_USER="$INV_USER" \
    --from-literal=INVENTORY_DB_PASSWORD="$INV_PASS" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f "${REPO_ROOT}/infra/debezium/debezium-server-ecom.yaml"
  kubectl apply -f "${REPO_ROOT}/infra/debezium/debezium-server-inventory.yaml"
  # PgAdmin — deployed in admin-tools namespace (ambient mesh, connects to DBs via ztunnel)
  # Fix potential NodePort conflict: gateway status-port may grab 31111 on fresh cluster
  kubectl patch svc bookstore-gateway-istio -n infra --type='json' \
    -p='[{"op":"replace","path":"/spec/ports/0/nodePort","value":31841}]' 2>/dev/null || true
  kubectl apply -f "${REPO_ROOT}/infra/pgadmin/pgadmin.yaml"
  # Label admin-tools namespace for ambient mesh (PgAdmin needs ztunnel for DB access)
  kubectl label ns admin-tools istio.io/dataplane-mode=ambient --overwrite 2>/dev/null || true
  # Apply Keycloak manifests now so it starts pulling images while we wait for Debezium
  kubectl apply -f "${REPO_ROOT}/infra/keycloak/keycloak.yaml"
  kubectl apply -f "${REPO_ROOT}/infra/keycloak/keycloak-nodeport.yaml"
  # Wait for both Debezium Server instances (PgAdmin + Keycloak continue in background)
  wait_deploy debezium-server-ecom infra
  wait_deploy debezium-server-inventory infra

  # ── 7. Wait for Docker builds, then kind load ────────────────────────────────
  # Must happen BEFORE deploying Flink or app services (they use custom images).
  # Builds have been running in background since step 2 (overlapping all infra).
  section "Waiting for Docker builds to complete"
  _BUILD_OK=true
  _wait_build() {
    local _tag=$1 _pid=$2 _log=$3
    [[ -z "$_pid" ]] && { info "  $_tag skipped (pre-existing image)"; return 0; }
    if wait "$_pid"; then
      info "  $_tag built successfully."
    else
      err "  $_tag build FAILED. Log: $_log"
      cat "$_log" >&2
      _BUILD_OK=false
    fi
  }
  _wait_build "bookstore/ecom-service:latest"      "$_ECOM_PID"  "/tmp/build-ecom.log"
  _wait_build "bookstore/inventory-service:latest" "$_INV_PID"   "/tmp/build-inventory.log"
  _wait_build "bookstore/flink:latest"             "$_FLINK_PID" "/tmp/build-flink.log"
  _wait_build "bookstore/ui-service:latest"        "$_UI_PID"    "/tmp/build-ui.log"
  _wait_build "bookstore/csrf-service:latest"     "$_CSRF_PID"  "/tmp/build-csrf.log"
  $_BUILD_OK || { err "One or more Docker builds failed — aborting."; exit 1; }

  section "Loading images into kind cluster (serialized)"
  for _img in \
    "bookstore/ecom-service:latest" \
    "bookstore/inventory-service:latest" \
    "bookstore/flink:latest" \
    "bookstore/ui-service:latest" \
    "bookstore/csrf-service:latest"; do
    info "  Loading $_img..."
    kind load docker-image "$_img" --name bookstore
  done

  # ── 8. Flink cluster (now that custom image is in kind) ───────────────────────
  section "Deploying Flink cluster"
  kubectl apply -f "${REPO_ROOT}/infra/flink/flink-pvc.yaml"
  kubectl apply -f "${REPO_ROOT}/infra/flink/flink-config.yaml"
  kubectl apply -f "${REPO_ROOT}/infra/flink/flink-cluster.yaml"
  info "Waiting for Flink JobManager + TaskManager in parallel..."
  kubectl rollout status deployment/flink-jobmanager  -n analytics --timeout=600s & _P1=$!
  kubectl rollout status deployment/flink-taskmanager -n analytics --timeout=600s & _P2=$!
  wait $_P1 $_P2
  kubectl delete job flink-sql-runner -n analytics --ignore-not-found
  kubectl apply -f "${REPO_ROOT}/infra/flink/flink-sql-runner.yaml"
  info "Flink SQL runner submitted (fire-and-forget — will verify at end)"

  # ── 9. Wait for Keycloak, import realm, reset passwords ─────────────────────
  # Keycloak was applied in step 6, should be nearly ready by now.
  section "Waiting for Keycloak + importing realm"
  wait_deploy keycloak identity
  bash "${REPO_ROOT}/scripts/keycloak-import.sh"

  # Reset bookstore user passwords using kcadm.sh inside the Keycloak pod.
  # Cannot use the external URL (idp.keycloak.net:30000) at this stage because
  # HTTPRoutes are applied later in bootstrap_fresh. kcadm.sh connects to
  # localhost:8080 directly, bypassing the Gateway entirely.
  # All kcadm commands run in ONE exec so the /tmp/kcadm.config token is shared.
  info "Resetting bookstore user passwords..."
  _KC_POD=$(kubectl get pod -n identity -l app=keycloak \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "$_KC_POD" ]]; then
    if kubectl exec -n identity "$_KC_POD" -- bash -c "
        /opt/keycloak/bin/kcadm.sh config credentials \
          --config /tmp/kcadm.config \
          --server http://localhost:8080 \
          --realm master --user admin --password CHANGE_ME &&
        /opt/keycloak/bin/kcadm.sh set-password \
          --config /tmp/kcadm.config \
          -r bookstore --username user1 --new-password CHANGE_ME &&
        /opt/keycloak/bin/kcadm.sh set-password \
          --config /tmp/kcadm.config \
          -r bookstore --username admin1 --new-password CHANGE_ME
      " &>/dev/null; then
      info "  Passwords set for user1 and admin1"
    else
      warn "  kcadm.sh password reset failed — realm-export.json sets passwords on import"
    fi
  else
    warn "  Keycloak pod not found — skipping password reset"
  fi

  # ── 10. Deploy application services (custom images already in kind) ───────────
  section "Deploying application services"
  # ServiceAccounts must exist before Deployments reference them
  kubectl apply -f "${REPO_ROOT}/infra/istio/security/serviceaccounts.yaml"
  kubectl apply -f "${REPO_ROOT}/ecom-service/k8s/"
  [[ -d "${REPO_ROOT}/inventory-service/k8s/" ]] && kubectl apply -f "${REPO_ROOT}/inventory-service/k8s/"
  [[ -d "${REPO_ROOT}/ui/k8s/" ]]                && kubectl apply -f "${REPO_ROOT}/ui/k8s/"
  info "Waiting for app services in parallel..."
  kubectl rollout status deployment/ecom-service      -n ecom      --timeout=600s & _P1=$!
  kubectl rollout status deployment/inventory-service -n inventory --timeout=600s & _P2=$!
  kubectl rollout status deployment/ui-service        -n ecom      --timeout=600s & _P3=$!
  wait $_P1 $_P2 $_P3 || warn "One or more app service rollouts timed out — check pod logs"

  # ── 10b. Deploy CSRF service (gateway-level CSRF protection) ────────────────
  section "Deploying CSRF service"
  kubectl apply -f "${REPO_ROOT}/csrf-service/k8s/csrf-service.yaml"
  wait_deploy csrf-service infra

  # Register Istio extensionProvider for CSRF ext_authz (if not already present)
  _MESH_CFG=$(kubectl get configmap istio -n istio-system -o jsonpath='{.data.mesh}' 2>/dev/null)
  if ! echo "$_MESH_CFG" | grep -q "csrf-ext-authz"; then
    info "Registering csrf-ext-authz extensionProvider in Istio mesh config..."
    kubectl get configmap istio -n istio-system -o json | python3 -c "
import sys, json
cm = json.load(sys.stdin)
mesh = cm['data']['mesh']
new_entry = (
    '- name: csrf-ext-authz\n'
    '  envoyExtAuthzHttp:\n'
    '    service: csrf-service.infra.svc.cluster.local\n'
    '    port: 8080\n'
    '    failOpen: true\n'
    '    headersToUpstreamOnAllow: []\n'
    '    includeRequestHeadersInCheck:\n'
    '    - authorization\n'
    '    - x-csrf-token\n'
    '    - origin\n'
    '    - referer\n'
)
if 'extensionProviders:' in mesh:
    mesh = mesh.replace('extensionProviders:\n', 'extensionProviders:\n' + new_entry, 1)
else:
    mesh = mesh.rstrip('\n') + '\nextensionProviders:\n' + new_entry
cm['data']['mesh'] = mesh
json.dump(cm, sys.stdout)
" | kubectl apply -f -
  fi

  # CSRF NetworkPolicies
  kubectl apply -f - <<'CSRF_NP_EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: csrf-service-ingress
  namespace: infra
spec:
  podSelector:
    matchLabels:
      app: csrf-service
  ingress:
    - from:
        - podSelector:
            matchLabels:
              gateway.networking.k8s.io/gateway-name: bookstore-gateway
      ports:
        - port: 8080
    - from: []
      ports:
        - port: 15008
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: csrf-service-egress
  namespace: infra
spec:
  podSelector:
    matchLabels:
      app: csrf-service
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: redis
      ports:
        - port: 6379
    - to:
        - namespaceSelector: {}
      ports:
        - port: 53
          protocol: UDP
    - to: []
      ports:
        - port: 15008
CSRF_NP_EOF

  # CSRF PeerAuthentication (PERMISSIVE for gateway access)
  kubectl apply -f - <<'CSRF_PA_EOF'
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: csrf-service-permissive
  namespace: infra
spec:
  selector:
    matchLabels:
      app: csrf-service
  mtls:
    mode: STRICT
  portLevelMtls:
    "8080":
      mode: PERMISSIVE
CSRF_PA_EOF

  # Patch gateway-egress to allow csrf-service
  _GW_EGRESS=$(kubectl get networkpolicy gateway-egress -n infra -o json 2>/dev/null || echo "")
  if [[ -n "$_GW_EGRESS" ]] && ! echo "$_GW_EGRESS" | grep -q "csrf-service"; then
    info "Patching gateway-egress for csrf-service..."
    echo "$_GW_EGRESS" | python3 -c "
import sys, json
pol = json.load(sys.stdin)
pol['spec']['egress'].insert(0, {
    'to': [{'podSelector': {'matchLabels': {'app': 'csrf-service'}}}],
    'ports': [{'port': 8080, 'protocol': 'TCP'}]
})
json.dump(pol, sys.stdout)
" | kubectl apply -f -
  fi

  # ── 11. Networking + policies ─────────────────────────────────────────────────
  section "Applying HTTPRoutes (kgateway)"
  kubectl apply -R -f "${REPO_ROOT}/infra/kgateway/"

  section "Applying Istio security policies"
  kubectl apply -R -f "${REPO_ROOT}/infra/istio/security/"

  # Apply CSRF AuthorizationPolicy (ext_authz on gateway)
  kubectl apply -f "${REPO_ROOT}/infra/istio/csrf-envoy-filter.yaml"

  section "Applying Kubernetes policies (HPA, PDB, NetworkPolicies)"
  kubectl apply -R -f "${REPO_ROOT}/infra/kubernetes/"

  # Grant PgAdmin (admin-tools) access to all 4 DB namespaces
  # Both AuthorizationPolicy AND NetworkPolicy must allow admin-tools
  for _db_pair in "ecom:ecom-db-policy:ecom-db-policy" "inventory:inventory-db-policy:inventory-db-policy" "analytics:analytics-db-policy:analytics-db-ingress" "identity:keycloak-db-policy:keycloak-db-ingress"; do
    _db_ns="${_db_pair%%:*}"; _rest="${_db_pair#*:}"
    _authz="${_rest%%:*}"; _netp="${_rest#*:}"
    # AuthorizationPolicy
    _AP=$(kubectl get authorizationpolicy "$_authz" -n "$_db_ns" -o json 2>/dev/null)
    if [[ -n "$_AP" ]] && ! echo "$_AP" | grep -q "admin-tools"; then
      echo "$_AP" | python3 -c "import sys,json;p=json.load(sys.stdin);p['spec']['rules'].append({'from':[{'source':{'namespaces':['admin-tools']}}]});json.dump(p,sys.stdout)" | kubectl apply -f - 2>/dev/null
    fi
    # NetworkPolicy
    _NP=$(kubectl get networkpolicy "$_netp" -n "$_db_ns" -o json 2>/dev/null)
    if [[ -n "$_NP" ]] && ! echo "$_NP" | grep -q "admin-tools"; then
      echo "$_NP" | python3 -c "import sys,json;p=json.load(sys.stdin);p['spec']['ingress'].append({'from':[{'namespaceSelector':{'matchLabels':{'kubernetes.io/metadata.name':'admin-tools'}}}]});json.dump(p,sys.stdout)" | kubectl apply -f - 2>/dev/null
    fi
  done
  info "PgAdmin DB access policies applied."

  # ── 12. Superset ─────────────────────────────────────────────────────────────
  section "Deploying Apache Superset"
  kubectl apply -f "${REPO_ROOT}/infra/superset/superset.yaml"
  wait_deploy superset analytics
  if [[ -f "${REPO_ROOT}/infra/superset/bootstrap-job.yaml" ]]; then
    kubectl delete job superset-bootstrap -n analytics --ignore-not-found
    kubectl apply -f "${REPO_ROOT}/infra/superset/bootstrap-job.yaml"
    kubectl wait --for=condition=complete job/superset-bootstrap -n analytics --timeout=600s || \
      warn "superset-bootstrap did not complete — dashboards may need manual setup"
  fi

  # ── 13. Prometheus + Kiali (moved to end — Kiali helm was the biggest blocker) ─
  section "Deploying Prometheus"
  kubectl apply -f "${REPO_ROOT}/infra/observability/prometheus/prometheus.yaml"
  kubectl apply -f "${REPO_ROOT}/infra/observability/kiali/prometheus-alias.yaml"

  section "Installing Kiali (service mesh observability)"
  helm repo add kiali https://kiali.org/helm-charts 2>/dev/null || true
  helm repo update kiali
  if helm status kiali-server -n istio-system &>/dev/null; then
    info "Kiali already installed, upgrading..."
    helm upgrade kiali-server kiali/kiali-server \
      -n istio-system \
      --version 1.86.0 \
      --set auth.strategy=anonymous \
      --wait
  else
    helm install kiali-server kiali/kiali-server \
      -n istio-system \
      --version 1.86.0 \
      --set auth.strategy=anonymous \
      --wait
  fi
  kubectl apply -f "${REPO_ROOT}/infra/observability/kiali/kiali-config-patch.yaml"
  kubectl apply -f "${REPO_ROOT}/infra/observability/kiali/kiali-nodeport.yaml"
  kubectl rollout restart deployment/kiali -n istio-system
  kubectl rollout status deployment/kiali -n istio-system --timeout=300s

  # ── 13b. Grafana + AlertManager + kube-state-metrics + OTel stack ────────────
  section "Deploying Grafana, AlertManager, kube-state-metrics"
  kubectl apply -f "${REPO_ROOT}/infra/observability/alertmanager/alertmanager.yaml"
  kubectl apply -f "${REPO_ROOT}/infra/observability/kube-state-metrics/kube-state-metrics.yaml"
  kubectl apply -f "${REPO_ROOT}/infra/observability/grafana/grafana.yaml"
  wait_deploy alertmanager observability
  wait_deploy kube-state-metrics observability
  wait_deploy grafana observability

  section "Deploying OTel stack (Tempo + Loki + OTel Collector)"
  kubectl apply -f "${REPO_ROOT}/infra/observability/otel-collector.yaml"
  kubectl apply -f "${REPO_ROOT}/infra/observability/tempo/tempo.yaml"
  kubectl apply -f "${REPO_ROOT}/infra/observability/loki/loki.yaml"
  wait_deploy otel-collector otel
  wait_deploy tempo otel
  wait_deploy loki otel

  # ── 13c. Cert Dashboard Operator (OLM + CRD + operator + CR) ─────────────────
  if [[ -f "${REPO_ROOT}/scripts/cert-dashboard-up.sh" ]]; then
    section "Deploying Cert Dashboard Operator"
    bash "${REPO_ROOT}/scripts/cert-dashboard-up.sh" || \
      warn "cert-dashboard-up.sh failed — cert dashboard may need manual setup"
  fi

  # ── 14. Wait for Debezium Server health ───────────────────────────────────────
  section "Waiting for Debezium Server health"
  bash "${REPO_ROOT}/infra/debezium/register-connectors.sh"

  # ── 15. Verify Flink SQL runner completed ─────────────────────────────────────
  section "Verifying Flink SQL runner"
  kubectl wait --for=condition=complete job/flink-sql-runner -n analytics --timeout=300s || \
    warn "flink-sql-runner not yet complete — check: kubectl logs -n analytics -l job-name=flink-sql-runner"

  # ── 16. Extract CA certificate for browser trust ──────────────────────────────
  section "Extracting CA certificate and installing into Keychain"
  _TRUST_ARGS="--install"
  $YES && _TRUST_ARGS="--install --yes"
  bash "${REPO_ROOT}/scripts/trust-ca.sh" $_TRUST_ARGS

  # trust-ca.sh handles interactive CA install prompt above.

  # ── 17. Smoke test ──────────────────────────────────────────────────────────────
  section "Smoke test"
  bash "${REPO_ROOT}/scripts/smoke-test.sh"

  echo ""
  echo -e "${GREEN}✔ Full bootstrap complete. Stack is running.${NC}"
  _print_endpoints
}

# ── Recovery function: after Docker restart (pods need rolling restart) ───────
recovery() {
  section "Recovery mode — restarting ztunnel and all pods"
  info "See docs/restart-app.md for full explanation."

  info "Restarting istiod (xDS control plane — may have expired workload certs)..."
  kubectl rollout restart deploy/istiod -n istio-system
  kubectl rollout status deploy/istiod -n istio-system --timeout=90s

  info "Restarting ztunnel (HBONE network plumbing reset)..."
  kubectl rollout restart daemonset/ztunnel -n istio-system
  kubectl rollout status daemonset/ztunnel -n istio-system --timeout=90s
  info "ztunnel ready — waiting 10s for mesh to stabilize..."
  sleep 10

  info "Restarting gateway (must re-establish xDS stream + endpoint discovery)..."
  kubectl rollout restart deploy/bookstore-gateway-istio -n infra 2>/dev/null || true
  kubectl rollout status deploy/bookstore-gateway-istio -n infra --timeout=90s 2>/dev/null || true
  # Re-patch NodePorts after gateway restart (Istio may reassign them)
  kubectl patch svc bookstore-gateway-istio -n infra --type='merge' \
    -p='{"spec":{"ports":[{"name":"https","port":8443,"targetPort":8443,"nodePort":30000,"protocol":"TCP"},{"name":"http","port":8080,"targetPort":8080,"nodePort":30080,"protocol":"TCP"}]}}' 2>/dev/null || true

  section "Restarting DB pods (dependencies first)"
  info "Restarting CNPG database pods..."
  kubectl delete pod -n ecom -l cnpg.io/cluster=ecom-db --wait=false 2>/dev/null || true
  kubectl delete pod -n inventory -l cnpg.io/cluster=inventory-db --wait=false 2>/dev/null || true
  kubectl delete pod -n identity -l cnpg.io/cluster=keycloak-db --wait=false 2>/dev/null || true
  kubectl delete pod -n analytics -l cnpg.io/cluster=analytics-db --wait=false 2>/dev/null || true
  info "Waiting for CNPG clusters to recover..."
  kubectl wait --for=condition=Ready cluster/ecom-db -n ecom --timeout=600s || true
  kubectl wait --for=condition=Ready cluster/inventory-db -n inventory --timeout=600s || true
  kubectl wait --for=condition=Ready cluster/keycloak-db -n identity --timeout=600s || true
  kubectl wait --for=condition=Ready cluster/analytics-db -n analytics --timeout=600s || true

  section "Restarting application pods"
  kubectl rollout restart deploy/kafka -n infra
  kubectl rollout restart deploy/redis -n infra
  kubectl rollout restart deploy/keycloak -n identity
  kubectl rollout restart deploy/ecom-service -n ecom
  kubectl rollout restart deploy/inventory-service -n inventory
  kubectl rollout restart deploy/ui-service -n ecom
  kubectl rollout restart deploy/debezium-server-ecom -n infra
  kubectl rollout restart deploy/debezium-server-inventory -n infra
  kubectl rollout restart deploy/pgadmin -n admin-tools 2>/dev/null || true
  kubectl rollout restart deploy/csrf-service -n infra 2>/dev/null || true
  kubectl rollout restart deploy/kafka-exporter -n infra 2>/dev/null || true
  kubectl rollout restart deploy/schema-registry -n infra 2>/dev/null || true
  kubectl rollout restart deploy/flink-jobmanager -n analytics
  kubectl rollout restart deploy/flink-taskmanager -n analytics
  kubectl rollout restart deploy/superset -n analytics
  kubectl rollout restart deploy/prometheus -n observability
  kubectl rollout restart deploy/kiali -n istio-system || true
  # OTel stack + Grafana + AlertManager + kube-state-metrics (session 23+)
  kubectl rollout restart deploy/grafana -n observability 2>/dev/null || true
  kubectl rollout restart deploy/alertmanager -n observability 2>/dev/null || true
  kubectl rollout restart deploy/kube-state-metrics -n observability 2>/dev/null || true
  kubectl rollout restart deploy/otel-collector -n otel 2>/dev/null || true
  kubectl rollout restart deploy/tempo -n otel 2>/dev/null || true
  kubectl rollout restart deploy/loki -n otel 2>/dev/null || true

  info "Waiting for critical services..."
  wait_deploy kafka infra
  wait_deploy keycloak identity
  wait_deploy ecom-service ecom
  wait_deploy inventory-service inventory
  wait_deploy debezium-server-ecom infra
  wait_deploy debezium-server-inventory infra
  wait_deploy flink-jobmanager analytics
  wait_deploy flink-taskmanager analytics

  section "Waiting for Debezium Server health"
  # Check for stale offset crash loops before waiting (common after CNPG migration)
  sleep 15  # give pods time to crash if offsets are stale
  for _dbz_pair in "debezium-server-ecom:debezium.ecom.offsets" "debezium-server-inventory:debezium.inventory.offsets"; do
    _dbz_name="${_dbz_pair%%:*}"
    _dbz_topic="${_dbz_pair##*:}"
    if _debezium_crash_looping "$_dbz_name" infra && _debezium_has_stale_offset "$_dbz_name" infra; then
      _fix_debezium_stale_offset "$_dbz_name" "$_dbz_name" "$_dbz_topic"
    fi
  done
  bash "${REPO_ROOT}/infra/debezium/register-connectors.sh"

  # ── Resubmit Flink SQL pipeline ─────────────────────────────────────────────
  # Flink Session Cluster loses all streaming jobs when the JobManager pod
  # restarts — the JM does not auto-recover session jobs from checkpoints on
  # pod restart (only during task failover). The sql-runner Job is a one-shot
  # K8s Job (backoffLimit:0) that already completed; delete + recreate to rerun.
  section "Resubmitting Flink SQL pipeline"
  info "Waiting for Flink SQL Gateway to be ready..."
  _gw_i=0
  until kubectl exec -n analytics deploy/flink-jobmanager -c sql-gateway -- \
    curl -sf http://localhost:9091/v1/info > /dev/null 2>&1; do
    _gw_i=$((_gw_i + 1))
    [[ $_gw_i -ge 24 ]] && { warn "SQL Gateway not ready after 2m — skipping sql-runner"; break; }
    echo "  SQL Gateway not ready, retrying in 5s..."
    sleep 5
  done
  if [[ $_gw_i -lt 24 ]]; then
    kubectl delete job flink-sql-runner -n analytics --ignore-not-found
    kubectl apply -f "${REPO_ROOT}/infra/flink/flink-sql-runner.yaml"
    kubectl wait --for=condition=complete job/flink-sql-runner -n analytics --timeout=300s || \
      warn "flink-sql-runner did not complete — check: kubectl logs -n analytics -l job-name=flink-sql-runner"
    info "Flink SQL pipeline resubmitted."
  fi

  section "Smoke test"
  bash "${REPO_ROOT}/scripts/smoke-test.sh"

  echo ""
  echo -e "${GREEN}✔ Recovery complete. Stack is running.${NC}"
  _print_endpoints
}

# ── Ensure Debezium Server instances are healthy (healthy cluster check) ──────
_debezium_health() {
  local port=$1
  curl -sf --max-time 10 "http://localhost:${port}/q/health" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo ""
}

_debezium_crash_looping() {
  local deploy=$1 ns=$2
  local restarts
  restarts=$(kubectl get pods -n "$ns" -l "app=$deploy" -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
  [[ "$restarts" -ge 3 ]]
}

_debezium_has_stale_offset() {
  local deploy=$1 ns=$2
  kubectl logs -n "$ns" -l "app=$deploy" --tail=20 2>/dev/null \
    | grep -q "no longer available on the server" 2>/dev/null
}

_fix_debezium_stale_offset() {
  local name=$1 deploy=$2 offset_topic=$3
  warn "$name has stale WAL offset — resetting offset topic '${offset_topic}' and restarting..."
  kubectl exec -n infra deploy/kafka -- \
    kafka-topics --bootstrap-server localhost:9092 --delete --topic "$offset_topic" 2>/dev/null || true
  kubectl rollout restart "deploy/$deploy" -n infra
  kubectl rollout status "deploy/$deploy" -n infra --timeout=120s
}

ensure_connectors() {
  local ecom_status inv_status
  ecom_status=$(_debezium_health 32300)
  inv_status=$(_debezium_health 32301)

  if [[ "$ecom_status" == "UP" ]] && [[ "$inv_status" == "UP" ]]; then
    info "Both Debezium Server instances healthy (ecom=UP, inventory=UP)"
    return
  fi

  info "Debezium Server not fully healthy (ecom='${ecom_status}', inventory='${inv_status}') — diagnosing..."

  # Check for stale offset crash loops (common after CNPG migration or WAL recycling)
  if [[ "$ecom_status" != "UP" ]] && _debezium_crash_looping debezium-server-ecom infra \
      && _debezium_has_stale_offset debezium-server-ecom infra; then
    _fix_debezium_stale_offset "debezium-server-ecom" "debezium-server-ecom" "debezium.ecom.offsets"
  fi

  if [[ "$inv_status" != "UP" ]] && _debezium_crash_looping debezium-server-inventory infra \
      && _debezium_has_stale_offset debezium-server-inventory infra; then
    _fix_debezium_stale_offset "debezium-server-inventory" "debezium-server-inventory" "debezium.inventory.offsets"
  fi

  # Wait for both to become healthy
  bash "${REPO_ROOT}/infra/debezium/register-connectors.sh"
}

# ── Print service endpoints ───────────────────────────────────────────────────
_print_endpoints() {
  echo ""
  echo "  Service endpoints (TLS — use -k for self-signed cert):"
  echo "    UI:            https://localhost:30000"
  echo "    Admin Panel:   https://localhost:30000/admin  (login: admin1 / CHANGE_ME)"
  echo "    API (ecom):    https://api.service.net:30000/ecom/books"
  echo "    API (inven):   https://api.service.net:30000/inven/health"
  echo "    Swagger UI:    https://api.service.net:30000/ecom/swagger-ui/index.html"
  echo "    Keycloak:      https://idp.keycloak.net:30000"
  echo "    KC Admin:      http://localhost:32400/admin  (admin / CHANGE_ME) [direct NodePort]"
  echo "                   https://idp.keycloak.net:30000/admin  [via gateway]"
  echo "    PgAdmin:       http://localhost:31111"
  echo "    Superset:      http://localhost:32000"
  echo "    Kiali:         http://localhost:32100/kiali"
  echo "    Flink:         http://localhost:32200"
  echo "    Debezium ecom: http://localhost:32300/q/health"
  echo "    Debezium inv:  http://localhost:32301/q/health"
  echo ""
  echo "  Credentials:  user1 / CHANGE_ME (customer)   admin1 / CHANGE_ME (admin)"
  echo "  HTTP redirect: http://*:30080 → https://*:30000 (301)"
  echo "  TLS: self-signed cert. Run 'bash scripts/trust-ca.sh --install' to trust CA."
  echo "  All ports served directly via kind NodePort (no proxy containers needed)."
}

# ── Free ports required by kind extraPortMappings ─────────────────────────────
# kind create cluster fails with "port is already allocated" if another Docker
# container (e.g. another kind cluster) is listening on any of our host ports.
# This function stops those containers before cluster creation.
free_required_ports() {
  # All hostPorts from infra/kind/cluster.yaml
  local REQUIRED_PORTS=(30000 30080 31111 32000 32100 32200 32300 32301 32400 32500 32600)
  local blocked_containers=()

  for port in "${REQUIRED_PORTS[@]}"; do
    # Find Docker containers binding this host port (format: "container_name")
    local container
    container=$(docker ps --format '{{.Names}}' --filter "publish=${port}" 2>/dev/null || true)
    if [[ -n "$container" ]]; then
      # Don't stop our own bookstore cluster nodes
      if [[ "$container" != bookstore-* ]]; then
        # Deduplicate: same container may bind multiple ports
        local already_listed=false
        for c in "${blocked_containers[@]+"${blocked_containers[@]}"}"; do
          [[ "$c" == "$container" ]] && already_listed=true && break
        done
        $already_listed || blocked_containers+=("$container")
      fi
    fi
  done

  if [[ ${#blocked_containers[@]} -eq 0 ]]; then
    info "All required ports are free."
    return 0
  fi

  warn "The following containers are blocking required ports:"
  for container in "${blocked_containers[@]}"; do
    local ports
    ports=$(docker port "$container" 2>/dev/null | grep -oE '0\.0\.0\.0:[0-9]+' | sed 's/0.0.0.0://' | sort -n | tr '\n' ',' | sed 's/,$//')
    echo "    $container (ports: $ports)"
  done

  if ! confirm "Stop these containers to free the ports?"; then
    err "Cannot proceed — required ports are in use. Free them manually or use --yes."
    exit 1
  fi

  for container in "${blocked_containers[@]}"; do
    info "Stopping $container..."
    docker stop "$container" >/dev/null 2>&1 || warn "Failed to stop $container"
  done

  # Verify ports are now free
  sleep 1
  local still_blocked=false
  for port in "${REQUIRED_PORTS[@]}"; do
    if docker ps --format '{{.Names}}' --filter "publish=${port}" 2>/dev/null | grep -qv "^bookstore-"; then
      err "Port $port is still in use after stopping containers"
      still_blocked=true
    fi
  done
  $still_blocked && { err "Could not free all required ports — aborting."; exit 1; }
  info "All required ports are now free."
}

# ── Pre-flight checks ────────────────────────────────────────────────────────
section "Pre-flight checks"
for cmd in kind kubectl docker helm istioctl python3; do
  command -v "$cmd" &>/dev/null || { err "'$cmd' not found on PATH. Please install it."; exit 1; }
done
info "All prerequisites found."

MISSING_HOSTS=()
for host in idp.keycloak.net myecom.net api.service.net; do
  grep -q "$host" /etc/hosts 2>/dev/null || MISSING_HOSTS+=("$host")
done
if [[ ${#MISSING_HOSTS[@]} -gt 0 ]]; then
  warn "The following hosts are missing from /etc/hosts: ${MISSING_HOSTS[*]}"
  warn "Add this line: 127.0.0.1  idp.keycloak.net  myecom.net  api.service.net"
fi

# ── Stack health check (with retry) ──────────────────────────────────────────
_stack_healthy() {
  # Try the ecom API twice with a short pause — avoids false negatives from
  # transient network hiccups right after Docker Desktop resumes.
  for _attempt in 1 2; do
    if curl -sk --max-time 10 -o /dev/null -w "%{http_code}" \
         "https://api.service.net:30000/ecom/books" 2>/dev/null | grep -q "^200$"; then
      return 0
    fi
    [[ $_attempt -eq 1 ]] && { info "Health check attempt 1 failed, retrying in 5s..."; sleep 5; }
  done
  return 1
}

# ── Determine scenario ───────────────────────────────────────────────────────
CLUSTER_EXISTS=false
kind get clusters 2>/dev/null | grep -q "^bookstore$" && CLUSTER_EXISTS=true

# --fresh: tear down first
if $FRESH && $CLUSTER_EXISTS; then
  DOWN_ARGS="--yes"
  $WIPE_DATA && DOWN_ARGS="--data --yes"
  confirm "This will DELETE the existing 'bookstore' cluster$(${WIPE_DATA} && echo ' and ALL data'). Continue?" || \
    { info "Aborted — cluster untouched."; exit 0; }
  bash "${REPO_ROOT}/scripts/down.sh" ${DOWN_ARGS}
  CLUSTER_EXISTS=false
fi

# ── Execute scenario ─────────────────────────────────────────────────────────
if ! $CLUSTER_EXISTS; then
  # Scenario 1: No cluster — full bootstrap
  section "No cluster found — starting fresh bootstrap"
  bootstrap_fresh
elif ! _stack_healthy; then
  # Scenario 3: Cluster exists but stack is not responding — recovery
  section "Cluster exists but stack is not responding — starting recovery"
  kubectl config use-context kind-bookstore
  recovery
else
  # Scenario 2: Cluster healthy — ensure connectors and smoke test
  section "Cluster is healthy"
  kubectl config use-context kind-bookstore
  ensure_connectors
  bash "${REPO_ROOT}/scripts/smoke-test.sh"
  echo ""
  echo -e "${GREEN}✔ Stack is running.${NC}"
  _print_endpoints
fi
