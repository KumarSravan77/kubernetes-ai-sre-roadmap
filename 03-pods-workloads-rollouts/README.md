# 03 — Pods, Workloads & Rollouts

Pods are the atomic unit of Kubernetes. Everything else is a controller that manages Pods. This section covers the full workload API and how to deploy safely.

---

## The Pod

A Pod is a group of one or more containers that:
- Share the same network namespace (same IP, same `localhost`)
- Share the same IPC namespace
- Can share volumes

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-app
  labels:
    app: my-app
    version: v1
spec:
  # Which node to run on (usually set by scheduler)
  # nodeName: worker-1

  # Security settings for all containers
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 2000

  # Init containers run to completion before app containers start
  initContainers:
  - name: wait-for-db
    image: busybox:1.36
    command: ['sh', '-c', 'until nc -z postgres-svc 5432; do sleep 2; done']

  containers:
  - name: app
    image: my-org/my-app:v1.2.3
    ports:
    - containerPort: 8080
      name: http

    # Resource requests (used for scheduling) and limits (enforced)
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 256Mi

    # Environment variables
    env:
    - name: DATABASE_URL
      valueFrom:
        secretKeyRef:
          name: db-credentials
          key: url
    - name: LOG_LEVEL
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: log_level

    # Probes
    startupProbe:
      httpGet:
        path: /healthz
        port: 8080
      failureThreshold: 30
      periodSeconds: 10

    readinessProbe:
      httpGet:
        path: /ready
        port: 8080
      initialDelaySeconds: 5
      periodSeconds: 10
      failureThreshold: 3

    livenessProbe:
      httpGet:
        path: /healthz
        port: 8080
      initialDelaySeconds: 15
      periodSeconds: 20
      failureThreshold: 3

    # Lifecycle hooks
    lifecycle:
      preStop:
        exec:
          command: ["/bin/sh", "-c", "sleep 5"]  # drain in-flight requests

    # Security context for this container
    securityContext:
      readOnlyRootFilesystem: true
      allowPrivilegeEscalation: false
      capabilities:
        drop: [ALL]

    # Volume mounts
    volumeMounts:
    - name: tmp
      mountPath: /tmp
    - name: config
      mountPath: /etc/app

  volumes:
  - name: tmp
    emptyDir: {}
  - name: config
    configMap:
      name: app-config

  # Grace period before SIGKILL after SIGTERM
  terminationGracePeriodSeconds: 30

  # Restart policy (for naked Pods)
  restartPolicy: Always
```

---

## Pod Lifecycle

```
Pending → Running → Succeeded
                  ↘ Failed
         Unknown  (node unreachable)
```

### Phase vs. Condition

Phase is a high-level summary. Conditions give detail:

```bash
kubectl get pod my-app -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

| Condition | Meaning |
|-----------|---------|
| `PodScheduled` | Pod assigned to a node |
| `Initialized` | All init containers completed |
| `ContainersReady` | All containers passing readiness |
| `Ready` | Pod can serve traffic |

---

## Probes

### Three probe types

| Probe | Failure action | When to use |
|-------|---------------|-------------|
| `startupProbe` | Kill container | Slow-starting apps; disables liveness until passing |
| `readinessProbe` | Remove from Service Endpoints | App not ready to serve traffic (e.g., warming up cache) |
| `livenessProbe` | Kill + restart container | App is deadlocked or corrupted |

### Three probe mechanisms

```yaml
# HTTP GET — most common
httpGet:
  path: /healthz
  port: 8080
  httpHeaders:
  - name: X-Health-Check
    value: "true"

# TCP socket
tcpSocket:
  port: 5432

# Exec command — avoid for high-frequency probes (fork overhead)
exec:
  command: ["/bin/grpc_health_probe", "-addr=:50051"]

# gRPC (native, 1.24+)
grpc:
  port: 50051
  service: "my.grpc.service"
```

> **SRE Note:** A failing readiness probe silently removes the Pod from Service Endpoints without restarting it. This is the right behavior — the Pod is alive but not ready. A failing liveness probe kills and restarts the Pod.

---

## Init Containers

Init containers run sequentially before app containers start. They're useful for:
- Waiting for dependencies
- Database migrations
- Copying binaries into shared volumes
- Generating config files

```yaml
initContainers:
- name: migrate
  image: my-org/migrate:v5
  command: ["migrate", "-path", "/migrations", "-database", "$(DB_URL)", "up"]
  env:
  - name: DB_URL
    valueFrom:
      secretKeyRef:
        name: db-credentials
        key: url
  volumeMounts:
  - name: migrations
    mountPath: /migrations
```

### Native Sidecar Containers (Kubernetes 1.29+)

```yaml
initContainers:
- name: otel-collector
  image: otel/opentelemetry-collector:latest
  restartPolicy: Always   # marks this as a sidecar — starts before app, stays running
```

---

## Workload Resources

### Deployment

For stateless apps. Manages ReplicaSets for rolling updates.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: my-app
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1        # extra pods during update
      maxUnavailable: 0  # no pods removed until new one is ready
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
      - name: app
        image: my-org/my-app:v1.2.3
```

### DaemonSet

Runs exactly one Pod per node (or per selected nodes). Used for: log collectors, monitoring agents, CNI plugins, storage daemons.

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
spec:
  selector:
    matchLabels:
      app: node-exporter
  template:
    metadata:
      labels:
        app: node-exporter
    spec:
      tolerations:
      - operator: Exists    # run on all nodes including control-plane
      hostPID: true
      hostNetwork: true
      containers:
      - name: node-exporter
        image: prom/node-exporter:v1.7.0
        ports:
        - containerPort: 9100
          hostPort: 9100
```

### StatefulSet

For stateful apps needing stable identity or ordered deployment (covered deeply in section 07).

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  serviceName: postgres-headless
  replicas: 3
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:16
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ReadWriteOnce]
      resources:
        requests:
          storage: 10Gi
```

### Job

Runs Pods to completion. For batch tasks.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-seed
spec:
  completions: 1
  parallelism: 1
  backoffLimit: 3
  activeDeadlineSeconds: 300
  template:
    spec:
      restartPolicy: OnFailure   # Never or OnFailure (not Always)
      containers:
      - name: seed
        image: my-org/seed:latest
        command: ["/seed", "--env=production"]
```

### CronJob

Schedules Jobs on a cron schedule.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nightly-report
spec:
  schedule: "0 2 * * *"          # 2am every day
  timeZone: "America/New_York"   # 1.27+
  concurrencyPolicy: Forbid      # Allow | Forbid | Replace
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  startingDeadlineSeconds: 60    # skip if missed by 60s
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
          - name: report
            image: my-org/reports:latest
            command: ["/generate-report"]
```

---

## Deployment Strategies

### RollingUpdate (default)

```
Before: [v1] [v1] [v1]
Step 1: [v1] [v1] [v2]   ← surge: add new, wait for ready
Step 2: [v1] [v2] [v2]   ← remove old
Step 3: [v2] [v2] [v2]
```

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1        # or "25%"
    maxUnavailable: 0  # zero-downtime
```

### Recreate

```
Before: [v1] [v1] [v1]
Step 1: []  []  []       ← all old pods deleted (DOWNTIME)
Step 2: [v2] [v2] [v2]
```

Use for: apps that cannot run two versions simultaneously.

```yaml
strategy:
  type: Recreate
```

### Blue/Green (two Deployments)

```yaml
# Green deployment (current live)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app-green
spec:
  replicas: 3
  template:
    metadata:
      labels:
        app: my-app
        slot: green
---
# Blue deployment (new version)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app-blue
spec:
  replicas: 3
  template:
    metadata:
      labels:
        app: my-app
        slot: blue
---
# Service — switch by changing selector
apiVersion: v1
kind: Service
metadata:
  name: my-app
spec:
  selector:
    app: my-app
    slot: green   # change to "blue" to cut over
```

### Canary (weighted traffic)

```yaml
# Stable (90% of pods)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app-stable
spec:
  replicas: 9
  template:
    metadata:
      labels:
        app: my-app
---
# Canary (10% of pods)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app-canary
spec:
  replicas: 1
  template:
    metadata:
      labels:
        app: my-app
---
apiVersion: v1
kind: Service
metadata:
  name: my-app
spec:
  selector:
    app: my-app   # selects pods from BOTH deployments
```

For proper weighted canary, use Argo Rollouts or a service mesh.

---

## Rollout Management

```bash
# Watch rollout progress
kubectl rollout status deployment/my-app

# See history
kubectl rollout history deployment/my-app
kubectl rollout history deployment/my-app --revision=3

# Pause (freeze mid-rollout for canary observation)
kubectl rollout pause deployment/my-app

# Resume
kubectl rollout resume deployment/my-app

# Rollback to previous version
kubectl rollout undo deployment/my-app

# Rollback to specific revision
kubectl rollout undo deployment/my-app --to-revision=2

# Restart all pods (force re-pull, pick up secret changes)
kubectl rollout restart deployment/my-app
```

Add `--record` note: this flag is deprecated; use annotations instead:

```bash
# Annotate before updating
kubectl annotate deployment my-app kubernetes.io/change-cause="Update to v1.2.3 — adds feature X"
```

---

## Pod Disruption Budgets

PDBs limit how many Pods can be disrupted simultaneously during voluntary actions (node drains, Deployment rollouts).

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: my-app-pdb
spec:
  selector:
    matchLabels:
      app: my-app
  minAvailable: 2      # at least 2 must stay up
  # OR
  # maxUnavailable: 1  # at most 1 can be down at once
```

```bash
kubectl get pdb
kubectl describe pdb my-app-pdb

# Test: draining a node respects PDBs
kubectl drain worker-1 --ignore-daemonsets --delete-emptydir-data
```

> **SRE Note:** Always create PDBs for production workloads. Without one, a `kubectl drain` can take down all replicas simultaneously.

---

## Ephemeral Containers

Debug a running Pod without modifying its spec:

```bash
# Add a debug container to a running pod
kubectl debug -it my-app-pod-abc123 --image=nicolaka/netshoot --target=app

# Debug a node (runs a pod with access to node namespaces)
kubectl debug node/worker-1 -it --image=ubuntu
```

---

## Lifecycle Hooks

```yaml
lifecycle:
  postStart:
    exec:
      command: ["/bin/sh", "-c", "echo started > /tmp/started"]
  preStop:
    exec:
      command: ["/bin/sh", "-c", "nginx -s quit; sleep 5"]
```

> **SRE Note:** The `preStop` hook is critical for zero-downtime deployments. When a Pod is deleted, the termination sequence is:
> 1. Pod removed from Endpoints (stops receiving traffic)
> 2. `preStop` hook runs
> 3. `SIGTERM` sent to container
> 4. `terminationGracePeriodSeconds` countdown begins
> 5. `SIGKILL` if still running after grace period
>
> Steps 1 and 2 happen concurrently. Use `preStop: sleep 5` to ensure the Pod stops receiving traffic before shutdown begins.

---

## SRE Lens

- **CrashLoopBackOff**: container exits immediately. Check `kubectl logs <pod> --previous` for the crash reason.
- **ImagePullBackOff**: image not found or bad credentials. Check `kubectl describe pod` for exact error.
- **`maxUnavailable: 0`** with `maxSurge: 1` is the safest zero-downtime rolling update strategy.
- **Always set a PDB** for stateless apps with 2+ replicas.
- **`startupProbe` prevents liveness from killing slow-starting containers** — essential for JVM apps.

---

## Resources

| Type | Link |
|------|------|
| Official Docs | [Workloads](https://kubernetes.io/docs/concepts/workloads/) |
| Official Docs | [Pod Lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/) |
| Official Docs | [Disruption Budgets](https://kubernetes.io/docs/tasks/run-application/configure-pdb/) |
| Official Docs | [Ephemeral Containers](https://kubernetes.io/docs/concepts/workloads/pods/ephemeral-containers/) |
| Tool | [Argo Rollouts](https://argoproj.github.io/rollouts/) |
| Blog | [Kubernetes Deployment Strategies (Weaveworks)](https://www.weave.works/blog/kubernetes-deployment-strategies) |
| Blog | [Zero-downtime deployments](https://learnk8s.io/graceful-shutdown) |
