# Bootstrap Troubleshooting — Fix Log

This document records every root cause and fix applied to get `bash scripts/smoke-test.sh` from **0/30 passing** to **33/33 passing** on a fresh `kind` cluster.

It is also a **learning reference**: every diagnostic command and tool used is listed, explained, and linked to the fix that required it.

---

## Tools Used (Quick Reference)

| Tool | What It Does | Key Flags Used |
|------|-------------|----------------|
| `kubectl get pods` | List pods and their status | `-n <ns>`, `-A` (all namespaces), `-w` (watch), `-o wide` |
| `kubectl describe pod` | Full pod details: events, probe results, OOM kills | `-n <ns> <pod-name>` |
| `kubectl logs` | Stdout/stderr from a container | `--previous` (crashed container), `-f` (follow), `-n <ns>` |
| `kubectl wait` | Block until a condition is met | `--for=condition=Ready`, `--timeout=<duration>` |
| `kubectl rollout` | Manage Deployment rollouts | `restart`, `status`, `history` |
| `kubectl patch` | Update a resource in-place | `--type=merge`, `--type=json` |
| `kubectl exec` | Run a command inside a pod | `-it` (interactive), `--` separates kubectl args from command |
| `kubectl apply` | Create/update resources from YAML | `-f <file>`, stdin via pipe |
| `kubectl get events` | Cluster event log (pod kills, image pulls, etc.) | `-n <ns>`, `--sort-by=.lastTimestamp` |
| `docker ps` | List running containers (includes kind nodes) | `-a` (all), `--format` |
| `docker exec` | Run a command inside a Docker container | `-it` (interactive) |
| `curl` | HTTP requests for endpoint checks | `-s` (silent), `-k` (skip TLS), `-o /dev/null`, `-w "%{http_code}"`, `--max-time` |
| `kind` | Manage local Kubernetes clusters | `get clusters`, `get nodes`, `load docker-image` |
| `python3 -c` | Run an inline Python script | Used to parse JSON/YAML from kubectl output |
| `jq` | Parse and filter JSON on the command line | `.`, `.items[]`, `select(...)` |

---

## Diagnostic Commands Cheat Sheet

These are the exact commands used to diagnose problems during this session. Learn to reach for these first when something breaks.

### "Why is my pod not starting?"

```bash
# 1. See what phase the pod is in and how many restarts
kubectl get pods -n <namespace>

# 2. See events (image pull failures, probe failures, OOMKills)
kubectl describe pod <pod-name> -n <namespace>

# 3. Read the current container's logs
kubectl logs <pod-name> -n <namespace>

# 4. Read the PREVIOUS container's logs (after a crash — this is the key one)
kubectl logs <pod-name> -n <namespace> --previous

# 5. Stream logs in real time
kubectl logs <pod-name> -n <namespace> -f
```

### "Why is my HTTP endpoint returning 000 or timing out?"

```bash
# Test an endpoint — prints just the HTTP status code
curl -sk -o /dev/null -w "%{http_code}" https://api.service.net:30000/ecom/books

# Test with a timeout (avoids hanging forever)
curl -sk -o /dev/null -w "%{http_code}" --max-time 10 https://api.service.net:30000/ecom/books

# Test and also show the response body
curl -sk https://api.service.net:30000/ecom/books | python3 -m json.tool
```

### "Is Docker Desktop alive?"

```bash
# If this hangs, Docker Desktop is frozen
docker ps

# Check all kind cluster nodes
kind get nodes --name bookstore

# Check node status from Kubernetes perspective
kubectl get nodes
```

### "Is the Kafka consumer keeping up?"

```bash
# List all consumer groups
kubectl exec -n infra deploy/kafka -- \
  kafka-consumer-groups --bootstrap-server localhost:9092 --list

# Show lag for a specific group (LAG column = unconsumed messages)
kubectl exec -n infra deploy/kafka -- \
  kafka-consumer-groups --bootstrap-server localhost:9092 \
  --group inventory-service --describe
```

### "What is the gateway doing?"

```bash
# Read gateway Envoy logs (xDS errors show up here)
kubectl logs -n infra deploy/bookstore-gateway-istio -f

# Check the TLS certificate status
kubectl get certificate bookstore-gateway-cert -n infra -o yaml

# Patch NodePorts after a gateway restart (Istio may reset them)
kubectl patch svc bookstore-gateway-istio -n infra --type='merge' \
  -p='{"spec":{"ports":[
    {"name":"https","port":8443,"targetPort":8443,"nodePort":30000,"protocol":"TCP"},
    {"name":"http","port":8080,"targetPort":8080,"nodePort":30080,"protocol":"TCP"}
  ]}}'
```

### "Why is an init container failing?"

```bash
# -c flag selects which container (use init container name)
kubectl logs <pod-name> -n <namespace> -c <init-container-name>
kubectl logs <pod-name> -n <namespace> -c <init-container-name> --previous

# Watch the pod start up (see Init:0/1 → Init:Error etc.)
kubectl get pods -n <namespace> -w
```

### "What version of an image is the pod running?"

```bash
kubectl get pod <pod-name> -n <namespace> \
  -o jsonpath='{.spec.containers[*].image}'
```

---

## Summary of Fixes

| # | Symptom | Root Cause | Fix |
|---|---------|------------|-----|
| 1 | All pods `Unknown`, all HTTP `000` | Docker Desktop frozen/not responding | Restart Docker Desktop, then `bash scripts/up.sh` |
| 2 | `ztunnel` DaemonSet not found during recovery | Incomplete prior bootstrap (cluster only had `istio-system`, no app namespaces) | Run `bash scripts/up.sh --fresh` |
| 3 | CNPG operator timed out | 120s wait too short for first-time image pull of `ghcr.io/cloudnative-pg/cloudnative-pg:1.25.1` | `infra/cnpg/install.sh`: `--timeout=120s` → `--timeout=300s` |
| 4 | CNPG DB clusters timed out | 300s wait too short; each cluster needs ~6 min to initialise primary + replica | `scripts/up.sh`: all four cluster waits `--timeout=300s` → `--timeout=600s` |
| 5 | Redis/Kafka timed out | 300s too short for first image pull | `scripts/up.sh`: Redis, Kafka, kafka-topic-init waits → `600s` |
| 6 | Flink, app services, Superset bootstrap, Kiali, flink-sql-runner timed out | Same first-pull latency pattern | `scripts/up.sh`: all affected waits bumped to `600s` (Kiali/flink-sql-runner to `300s`) |
| 7 | `import yaml` / `ModuleNotFoundError: No module named 'yaml'` | Istio mesh-config patch script used PyYAML, which is not installed on macOS by default | `scripts/up.sh`: replaced `yaml.safe_load` / `yaml.dump` with stdlib string manipulation |
| 8 | ecom-service CrashLoopBackOff (~25 restarts) | `startupProbe` allowed only 150s (30 × 5s); Spring Boot + OTel agent takes 146–173s — SIGTERM on startup completion | `ecom-service/k8s/ecom-service.yaml`: `failureThreshold: 30` → `failureThreshold: 60` (300s) |
| 9 | Smoke test: pgadmin `Unknown` despite HTTP PASS | `pod_check` checked namespace `infra`; pgadmin is deployed to `admin-tools` | `scripts/smoke-test.sh`: `infra` → `admin-tools` |
| 10 | Superset init container `Init:Error` (37 restarts) | `uv` CLI not present in `apache/superset:4.1.2` image | `infra/superset/superset.yaml`: `uv pip install` → `pip install` |
| 11 | Superset `sqlite3.OperationalError: no such table: tables` | Stale/partial `superset.db` from a failed prior run blocked subsequent migrations | `docker exec bookstore-worker rm -f /data/superset/superset.db` |
| 12 | ecom endpoints timeout after rollout | Gateway Envoy held stale endpoint IPs from old pods; xDS stream to istiod had been broken for ~2 h | `kubectl rollout restart deploy/bookstore-gateway-istio -n infra` then re-patch NodePorts |

---

## Detailed Fixes

---

### Fix 1 — Docker Desktop frozen

**Symptom:** All pods `Unknown`, all HTTP responses `000`, `docker ps` hangs.

**Cause:** Docker Desktop daemon is not responding (frozen or mid-restart).

**How we diagnosed it:**
```bash
# 1. Check all pods across every namespace — all showed Unknown
kubectl get pods -A

# 2. Try to list Docker containers — this hung indefinitely (confirmed frozen daemon)
docker ps

# 3. Check kind nodes from kubectl — all NotReady
kubectl get nodes
```

**What `Unknown` pod phase means:**  
Kubernetes cannot contact the node's kubelet to get the pod's real status. It does not mean the pod crashed — it means the node itself is unreachable.

**Resolution:**
1. Restart Docker Desktop from the menu bar and wait for the whale icon to stabilise.
2. Run `bash scripts/up.sh` — it auto-detects the degraded cluster and runs recovery.

**Tool used:** `kubectl get pods -A`, `docker ps`, `kind get nodes`

---

### Fix 2 — Incomplete cluster (no app namespaces, no ztunnel)

**Symptom:** `bash scripts/up.sh` (recovery path) exits with `Error from server (NotFound): daemonsets.apps "ztunnel" not found`.

**Cause:** A previous bootstrap attempt had exited early (before step 3 of `bootstrap_fresh`). Only `default`, `istio-system`, and `kube-system` namespaces existed.

**How we diagnosed it:**
```bash
# List all namespaces — only the K8s system ones were present
kubectl get namespaces

# Confirm ztunnel DaemonSet missing
kubectl get daemonset ztunnel -n istio-system
# → Error from server (NotFound)
```

**What a DaemonSet is:**  
A DaemonSet ensures one pod runs on every node. `ztunnel` is Istio Ambient Mesh's per-node proxy — without it, no mTLS and no pod networking mesh.

**Resolution:** Full teardown and rebuild:
```bash
bash scripts/up.sh --fresh --data
```

**Tool used:** `kubectl get namespaces`, `kubectl get daemonset`

---

### Fix 3 — CNPG operator timeout

**File:** `infra/cnpg/install.sh`

**Cause:** `kubectl wait --timeout=120s` for `cnpg-controller-manager`. The operator image (`ghcr.io/cloudnative-pg/cloudnative-pg:1.25.1`, ~280 MB) takes longer than 120s to pull on first run.

**How we diagnosed it:**
```bash
# Check what the operator pod was doing
kubectl get pods -n cnpg-system
# → Showed ImagePullBackOff or ContainerCreating

# See the image pull event
kubectl describe pod -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg
# → Events: Pulling image "ghcr.io/cloudnative-pg/cloudnative-pg:1.25.1"
#            Successfully pulled image ... (after 145s)

# The wait command itself
kubectl wait --for=condition=Available deployment/cnpg-controller-manager \
  -n cnpg-system --timeout=120s
# → error: timed out waiting for the condition
```

**What `kubectl wait` does:**  
Blocks your shell until a Kubernetes resource reaches a specified condition (e.g., `Available`, `Ready`) or the timeout expires. Used in scripts to gate later steps.

```diff
- kubectl wait --for=condition=Available deployment/cnpg-controller-manager -n cnpg-system --timeout=120s
+ kubectl wait --for=condition=Available deployment/cnpg-controller-manager -n cnpg-system --timeout=300s
```

**Tool used:** `kubectl get pods`, `kubectl describe pod`, `kubectl wait`

---

### Fix 4 — CNPG database clusters timeout

**File:** `scripts/up.sh`

**Cause:** Each CNPG cluster requires ~6 minutes to: pull the image, initialise the primary pod, then bring up the replica. The 300s (5 min) timeout was too close.

**How we diagnosed it:**
```bash
# Check CNPG cluster status (custom resource)
kubectl get cluster -A
# → Shows PHASE column: "Initialising", "Creating primary", etc.

# Watch a specific cluster
kubectl get cluster ecom-db -n ecom -w
# → Transitions through phases in real time

# See what the individual pods were doing
kubectl get pods -n ecom
# → ecom-db-1 ContainerCreating, ecom-db-2 Pending

# Describe to see why it was slow
kubectl describe cluster ecom-db -n ecom
# → Events show image pull timing
```

**What a CNPG Cluster resource is:**  
`cluster.postgresql.cnpg.io` is a custom resource (CRD) defined by the CloudNativePG operator. It represents a full PostgreSQL HA cluster. The operator watches this resource and creates pods, services, and PVCs for you.

```diff
- kubectl wait --for=condition=Ready cluster/ecom-db       -n ecom       --timeout=300s & _P1=$!
- kubectl wait --for=condition=Ready cluster/inventory-db  -n inventory  --timeout=300s & _P2=$!
- kubectl wait --for=condition=Ready cluster/analytics-db  -n analytics  --timeout=300s & _P3=$!
- kubectl wait --for=condition=Ready cluster/keycloak-db   -n identity   --timeout=300s & _P4=$!
+ kubectl wait --for=condition=Ready cluster/ecom-db       -n ecom       --timeout=600s & _P1=$!
+ kubectl wait --for=condition=Ready cluster/inventory-db  -n inventory  --timeout=600s & _P2=$!
+ kubectl wait --for=condition=Ready cluster/analytics-db  -n analytics  --timeout=600s & _P3=$!
+ kubectl wait --for=condition=Ready cluster/keycloak-db   -n identity   --timeout=600s & _P4=$!
```

The `& _P1=$!` pattern runs each wait in the background (`&`) and saves its PID (`$!`) so the script can later `wait $_P1 $_P2 $_P3 $_P4` to block until all four complete in parallel.

Also bumped the same waits in the `recovery()` function from `300s` → `600s`.

**Tool used:** `kubectl get cluster`, `kubectl describe cluster`, `kubectl get pods`, `kubectl wait`

---

### Fix 5 & 6 — Redis, Kafka, Flink, app services, Superset, Kiali timeouts

**File:** `scripts/up.sh`

**Cause:** All `300s` timeouts in `bootstrap_fresh` were too short for first-run image pulls across many services.

**How we diagnosed it:**
```bash
# See current rollout status
kubectl rollout status deployment/redis -n infra
# → Timed out waiting for rollout to finish

# See events for the pod (image pull timing)
kubectl get events -n infra --sort-by=.lastTimestamp | grep redis
# → Pulling image "redis:7.2-alpine"  →  Successfully pulled image (after 4min)

# Check which pod was failing
kubectl get pods -n infra
# → redis-xxx: ContainerCreating (stuck)
```

**What `kubectl rollout status` does:**  
Watches a Deployment and reports when all pods in the new ReplicaSet are Running and Ready. Exits 0 on success, non-zero on timeout. Used in CI and bootstrap scripts to gate the next step.

Changes made:

| Location | Before | After |
|----------|--------|-------|
| `wait_deploy` default | `300s` | `600s` |
| Redis + Kafka rollout | `300s` | `600s` |
| `kafka-topic-init` job | `300s` | `600s` |
| Flink JobManager + TaskManager rollout | `300s` | `600s` |
| ecom, inventory, ui-service rollout | `300s` | `600s` |
| `superset-bootstrap` job | `300s` | `600s` |
| Kiali rollout | `120s` | `300s` |
| `flink-sql-runner` job (bootstrap) | `120s` | `300s` |
| `flink-sql-runner` job (recovery) | `120s` | `300s` |

**Tool used:** `kubectl rollout status`, `kubectl get events`, `kubectl get pods`

---

### Fix 7 — PyYAML not available on host

**File:** `scripts/up.sh` (inline Python in CSRF extensionProvider registration)

**Cause:** The inline Python script used `import yaml` (PyYAML) to parse and rewrite the Istio mesh ConfigMap. PyYAML is not part of the Python standard library and was not installed.

**How we diagnosed it:**
```bash
# Run the failing line directly to reproduce the error
kubectl get configmap istio -n istio-system -o json | python3 -c "import yaml"
# → ModuleNotFoundError: No module named 'yaml'

# Confirm PyYAML is absent
python3 -c "import yaml; print(yaml.__version__)"
# → ModuleNotFoundError

# Check what IS available
python3 -c "import sys; print(sys.version)"
python3 -c "import json; print('json ok')"   # stdlib — always present
```

**What this script does:**  
`kubectl get configmap ... -o json | python3 -c "..."` reads the ConfigMap as JSON, modifies the `data.mesh` field (which is a YAML string), and pipes the result back to `kubectl apply -f -`. The `-` means "read from stdin."

**Resolution:** Rewrote the script using only stdlib (`json` + string manipulation):

```diff
- kubectl get configmap istio -n istio-system -o json | python3 -c "
- import sys, json, yaml
- cm = json.load(sys.stdin)
- mesh = yaml.safe_load(cm['data']['mesh'])
- ...
- cm['data']['mesh'] = yaml.dump(mesh, default_flow_style=False)
- json.dump(cm, sys.stdout)
- " | kubectl apply -f -
+ kubectl get configmap istio -n istio-system -o json | python3 -c "
+ import sys, json
+ cm = json.load(sys.stdin)
+ mesh = cm['data']['mesh']
+ new_entry = ('- name: csrf-ext-authz\n  envoyExtAuthzHttp:\n    ...\n')
+ if 'extensionProviders:' in mesh:
+     mesh = mesh.replace('extensionProviders:\n', 'extensionProviders:\n' + new_entry, 1)
+ else:
+     mesh = mesh.rstrip('\n') + '\nextensionProviders:\n' + new_entry
+ cm['data']['mesh'] = mesh
+ json.dump(cm, sys.stdout)
+ " | kubectl apply -f -
```

**Lesson:** Bootstrap scripts should only use tools guaranteed to be present on any developer machine. For Python, that means the standard library only (`json`, `re`, `sys`, `os`, `subprocess`). Never assume `pip` packages are pre-installed.

**Tool used:** `python3 -c`, `kubectl get configmap`, `kubectl apply -f -`

---

### Fix 8 — ecom-service CrashLoopBackOff (startupProbe race condition)

**File:** `ecom-service/k8s/ecom-service.yaml`

**Cause:** The `startupProbe` allowed a maximum of `30 × 5s = 150s` for the app to start. Spring Boot 4 + OpenTelemetry Java agent routinely takes 146–173s on this hardware. Kubernetes sent SIGTERM (exit 143) the instant the app finished starting, triggering graceful shutdown immediately.

**How we diagnosed it:**
```bash
# Step 1: Spot the crash loop
kubectl get pods -n ecom
# → ecom-service-xxx    0/1    CrashLoopBackOff    25    40m

# Step 2: Check why (current container logs — often empty after SIGTERM)
kubectl logs deploy/ecom-service -n ecom
# → (empty — pod already terminated)

# Step 3: THE KEY COMMAND — read the previous container's logs
kubectl logs deploy/ecom-service -n ecom --previous
# → Started EcomServiceApplication in 146.469 seconds   ← app started successfully
# → Commencing graceful shutdown.                       ← SIGTERM received immediately
# → Graceful shutdown complete.

# Step 4: Confirm exit code
kubectl describe pod <ecom-pod> -n ecom
# → Last State: Terminated  Reason: Error  Exit Code: 143
# (Exit 143 = 128 + 15 = killed by SIGTERM signal)

# Step 5: Check the probe config
kubectl get deployment ecom-service -n ecom -o yaml | grep -A8 startupProbe
# → periodSeconds: 5
# → failureThreshold: 30   (5 × 30 = 150s max)
```

**What exit code 143 means:**  
Unix exit code 143 = 128 + 15, where 15 is the SIGTERM signal number. When Kubernetes decides a probe has failed too many times, it sends SIGTERM to the container. A well-behaved Java app catches it and shuts down gracefully (which is why you see "Commencing graceful shutdown" in the logs).

**What `--previous` does:**  
`kubectl logs --previous` reads the logs from the *last terminated* instance of the container. This is essential for debugging crash loops because the current container is usually empty or also crashing.

```diff
  startupProbe:
    httpGet:
      path: /ecom/actuator/health/liveness
      port: 8080
    periodSeconds: 5
-   failureThreshold: 30   # 150s max
+   failureThreshold: 60   # 300s max
```

**Tool used:** `kubectl get pods`, `kubectl logs --previous`, `kubectl describe pod`, `kubectl get deployment -o yaml`

---

### Fix 9 — Smoke test pgadmin namespace mismatch

**File:** `scripts/smoke-test.sh`

**Cause:** `pod_check "pgadmin" infra "app=pgadmin"` checked the `infra` namespace. pgadmin is deployed to `admin-tools` by `up.sh`.

**How we diagnosed it:**
```bash
# The HTTP check passed (port 31111 was reachable) but pod_check failed
# Manually check what namespace pgadmin is actually in
kubectl get pods -A | grep pgadmin
# → admin-tools    pgadmin-xxx    1/1    Running    0    5h

# Confirm nothing in infra namespace with that label
kubectl get pods -n infra -l app=pgadmin
# → No resources found in infra namespace.
```

**What `-A` (all namespaces) does:**  
`kubectl get pods -A` lists pods from every namespace at once. When you don't know where a pod lives, this is the first command to run.

```diff
- pod_check "pgadmin" infra "app=pgadmin"
+ pod_check "pgadmin" admin-tools "app=pgadmin"
```

**Tool used:** `kubectl get pods -A`, `kubectl get pods -n <namespace> -l <label>`

---

### Fix 10 — Superset init container: `uv` not found

**File:** `infra/superset/superset.yaml`

**Cause:** The init container command used `uv pip install psycopg2-binary`. The `uv` CLI is not present in `apache/superset:4.1.2`. `pip` is available in the image.

**How we diagnosed it:**
```bash
# Step 1: See init container status
kubectl get pods -n analytics
# → superset-xxx    0/1    Init:Error    37    2h

# Step 2: Read init container logs by specifying its name with -c
kubectl logs -n analytics <superset-pod> -c superset-init --previous
# → sh: 2: uv: not found

# Step 3: Confirm pip is available in the image
kubectl run test-superset --rm -it --image=apache/superset:4.1.2 \
  --restart=Never -- which pip
# → /usr/local/bin/pip
```

**What `-c` (container) flag does:**  
A pod can have multiple containers (and init containers). By default `kubectl logs` reads the first regular container. Use `-c <name>` to read a specific one — essential for init container debugging.

**What `kubectl run --rm -it` does:**  
Creates a temporary pod, drops you into an interactive shell (or runs a command), then deletes the pod when done. Used to test what's available inside an image without modifying your deployment.

```diff
- uv pip install psycopg2-binary --target /extra-packages --quiet && \
+ pip install psycopg2-binary --target /extra-packages --quiet && \
```

**Tool used:** `kubectl get pods`, `kubectl logs -c <container>`, `kubectl run --rm -it`

---

### Fix 11 — Stale partial superset.db

**Symptom:** Superset init container fails with `sqlite3.OperationalError: no such table: tables` on every restart.

**Cause:** A previous failed bootstrap run had partially executed `superset db upgrade`, leaving a 73 KB SQLite file. Subsequent init container runs found the file and failed because the schema was incomplete.

**How we diagnosed it:**
```bash
# Read the init container logs to get the actual error
kubectl logs -n analytics <superset-pod> -c superset-init --previous
# → sqlalchemy.exc.OperationalError: (sqlite3.OperationalError) no such table: tables

# Inspect the kind worker node directly to find the file
docker exec bookstore-worker ls -lh /data/superset/
# → -rw-r--r-- 1 1000 1000 73K May 2 11:32 superset.db
# (73K = partial migration — a fully initialised DB would be ~300K)

# Delete the stale file
docker exec bookstore-worker rm -f /data/superset/superset.db
```

**What `docker exec bookstore-worker` does:**  
kind clusters run each Kubernetes node as a Docker container. `bookstore-worker` is the name of the kind worker node container. `docker exec` runs a command inside it — useful for inspecting the host-mounted data directories that pods write to.

**Why the file persisted:**  
kind mounts `./data/` from your Mac into the worker node container. When `scripts/down.sh --data` is run, it deletes `./data/` from your Mac, which also removes the bind-mounted path inside the container. But if `down.sh --data` was never run between bootstrap attempts, the file survives.

**Resolution (one-time runtime command):**
```bash
docker exec bookstore-worker rm -f /data/superset/superset.db
```

After deleting the file, the init container creates a fresh database on next restart.

**Tool used:** `kubectl logs -c`, `docker exec`, `ls`, `rm`

---

### Fix 12 — ecom endpoints timeout after rollout (stale gateway xDS)

**Symptom:** After the ecom-service rolling update, `GET /ecom/books` timed out through the gateway while `GET /inven/health` worked fine.

**Cause:** The gateway Envoy proxy had been unable to connect to istiod's xDS gRPC stream for ~2 hours (`dial tcp 10.96.248.60:15012: i/o timeout` repeated in gateway logs). The gateway was routing to the **old ecom pod IPs** (which no longer existed after the rollout). Inventory worked because its pods had not been restarted, so the cached IPs were still valid.

**How we diagnosed it:**
```bash
# Step 1: Confirm the HTTP symptom
curl -sk -o /dev/null -w "%{http_code}" --max-time 10 https://api.service.net:30000/ecom/books
# → 000  (timeout — curl exit code 28)

curl -sk -o /dev/null -w "%{http_code}" --max-time 10 https://api.service.net:30000/inven/health
# → 200  (inventory works fine)

# Step 2: Confirm new ecom pods are healthy
kubectl get pods -n ecom
# → ecom-service-xxx    2/2    Running    0    10m  ← pods are up

# Step 3: Check the gateway logs for xDS errors
kubectl logs -n infra deploy/bookstore-gateway-istio -f
# → dial tcp 10.96.248.60:15012: i/o timeout  ← repeated every 30s
# → (istiod's ClusterIP was unreachable — xDS stream broken)

# Step 4: Check current ecom pod IPs
kubectl get pods -n ecom -o wide
# → ecom-service-xxx  10.244.2.15  ...  (new IPs)

# Step 5: What IPs does the gateway think ecom has? (Envoy config dump)
kubectl exec -n infra deploy/bookstore-gateway-istio \
  -- pilot-agent request GET /clusters | grep ecom
# → ecom-service.ecom.svc.cluster.local::10.244.2.8::  ← old IP, no longer exists
```

**What xDS is:**  
xDS is Envoy's dynamic configuration protocol. `istiod` (the Istio control plane) pushes route and endpoint updates to every Envoy sidecar and gateway via a long-lived gRPC stream. If that stream breaks (e.g., after Docker Desktop restarts), the gateway keeps using its last-known config — including pod IPs from before the rollout.

**What `pilot-agent request GET /clusters` does:**  
Envoy exposes an admin API on port 15000 inside the pod. `pilot-agent request` proxies a request to it. `/clusters` returns the current upstream cluster config, including which IP:port endpoints Envoy will route to.

**Resolution:**
```bash
# Restart the gateway pod so it connects a fresh xDS stream to istiod
kubectl rollout restart deploy/bookstore-gateway-istio -n infra

# Re-patch NodePorts after restart (Istio may reset them)
kubectl patch svc bookstore-gateway-istio -n infra --type='merge' \
  -p='{"spec":{"ports":[
    {"name":"https","port":8443,"targetPort":8443,"nodePort":30000,"protocol":"TCP"},
    {"name":"http","port":8080,"targetPort":8080,"nodePort":30080,"protocol":"TCP"}
  ]}}'

# Verify the gateway is back and NodePorts are set
kubectl get svc bookstore-gateway-istio -n infra
```

The new gateway pod establishes a fresh xDS connection to istiod and picks up the current endpoint IPs.

**Tool used:** `curl`, `kubectl logs -f`, `kubectl get pods -o wide`, `kubectl exec`, `kubectl rollout restart`, `kubectl patch`

---

## Final State

After all fixes, `bash scripts/smoke-test.sh` exits 0:

```
Results: 33 passed, 0 failed
✔ All smoke tests passed
```

---

## Preventive Notes for Future Bootstraps

- **Always use `--fresh --data` when re-bootstrapping** to avoid stale SQLite/Kafka/Redis state from a previous failed run.
- **Gateway xDS breaks after Docker Desktop restarts.** Use `bash scripts/up.sh` which runs `recovery()` and restarts the gateway.
- **ecom-service startup takes ~2.5 minutes.** The `startupProbe` now allows 5 minutes. Do not reduce `failureThreshold` below 48 (240s).
- **Image pulls on a fresh Docker Desktop cache** will push all `kubectl wait` timeouts to their limits. The 600s values are sized for a cold cache; cached runs complete in <2 minutes.
- **Bootstrap scripts must be self-contained.** Never import Python packages that aren't in the standard library. Never rely on tools that aren't in the base OS.

---

## Practice Exercises

Try these yourself to build muscle memory with the diagnostic commands:

1. **Simulate a CrashLoop:** Set `startupProbe.failureThreshold: 1` in `ecom-service.yaml`, apply it, watch it crash, read `--previous` logs, then restore the correct value.

2. **Find a pod in an unknown namespace:** Run `kubectl get pods -A | grep <name>` to locate any pod cluster-wide.

3. **Inspect a kind node filesystem:** Run `docker exec bookstore-worker ls /data` to see the mounted host directories.

4. **Check Kafka consumer lag:** Run the `kafka-consumer-groups --describe` command and observe the LAG column before and after consuming a message.

5. **Test an endpoint manually:** Use `curl -sk -o /dev/null -w "%{http_code}" <url>` to check any service endpoint from your Mac terminal.

6. **Break and fix the gateway xDS:** Run `kubectl rollout restart deploy/bookstore-gateway-istio -n infra`, then re-patch the NodePorts, and confirm all smoke tests still pass.
