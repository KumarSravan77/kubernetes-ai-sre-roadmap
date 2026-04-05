# 09 — Resource Management & QoS

Proper resource management prevents workloads from starving each other and controls costs. This section covers requests, limits, QoS classes, quotas, and right-sizing.

---

## CPU and Memory Units

```
CPU:
  1     = 1 vCPU / 1 core
  0.5   = 500m (millicores) = half a core
  100m  = 0.1 core

Memory:
  128Mi  = 134,217,728 bytes (mebibytes — powers of 2)
  1Gi    = 1,073,741,824 bytes
  128M   = 128,000,000 bytes (megabytes — powers of 10)
  # Always use Mi/Gi, not M/G, to avoid ambiguity
```

---

## Requests vs. Limits

```yaml
resources:
  requests:
    cpu: 100m       # scheduler uses this for placement
    memory: 128Mi   # scheduler uses this for placement
  limits:
    cpu: 500m       # container gets CPU-throttled if it exceeds this
    memory: 256Mi   # container gets OOMKilled if it exceeds this
```

| | Requests | Limits |
|-|---------|--------|
| **Purpose** | Scheduling (what's reserved) | Enforcement (what's allowed) |
| **CPU behavior** | Guaranteed minimum | Throttled via cgroups (never killed) |
| **Memory behavior** | Guaranteed minimum | OOMKilled if exceeded |
| **Effect on node** | Reduces available allocatable | Doesn't reduce allocatable |

### CPU Throttling

When a container exceeds its CPU limit, the kernel's CFS scheduler throttles it — the process runs slower but doesn't die.

```bash
# Detect CPU throttling via metrics
# container_cpu_cfs_throttled_periods_total
# container_cpu_cfs_periods_total
# Throttle rate = throttled_periods / total_periods

# Prometheus query
rate(container_cpu_cfs_throttled_periods_total[5m]) /
rate(container_cpu_cfs_periods_total[5m]) > 0.25
# Alert if >25% of CPU periods are throttled
```

> **Controversial advice:** Some engineers argue against setting CPU limits entirely for latency-sensitive services, because throttling causes unpredictable latency spikes. Use LimitRanges with high maxLimitRequestRatio instead of tight limits.

### OOMKill

When a container exceeds its memory limit, the OOM killer terminates it.

```bash
# Detect OOMKill
kubectl describe pod <name> | grep -A5 "Last State"
# Last State: Terminated
#   Reason: OOMKilled

# Node-level OOM events
kubectl get events --field-selector reason=OOMKilling
dmesg | grep -i oom
```

---

## QoS Classes

Kubernetes automatically assigns a QoS class based on requests and limits. This affects eviction order under node pressure.

### Guaranteed

```yaml
resources:
  requests:
    cpu: 500m
    memory: 256Mi
  limits:
    cpu: 500m       # requests == limits for BOTH cpu and memory
    memory: 256Mi
```
- **Eviction order:** Last to be evicted
- **OOM score:** -998 (very unlikely to be killed)
- **Use for:** Production databases, critical services

### Burstable

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
```
- Requests < limits for at least one resource
- **Eviction order:** Middle priority
- **Use for:** Most production workloads

### BestEffort

```yaml
# No resources specified at all
resources: {}
```
- **Eviction order:** First to be evicted
- **OOM score:** +999 (first to be killed by OOM killer)
- **Use for:** Non-critical batch jobs, testing

```bash
# Check QoS class of a pod
kubectl get pod <name> -o jsonpath='{.status.qosClass}'
```

---

## LimitRange

LimitRange sets default, minimum, and maximum resource values for a namespace.

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: production
spec:
  limits:
  # Container-level limits
  - type: Container
    default:         # applied if no limit specified
      cpu: 500m
      memory: 256Mi
    defaultRequest:  # applied if no request specified
      cpu: 100m
      memory: 128Mi
    min:
      cpu: 50m
      memory: 64Mi
    max:
      cpu: 2000m
      memory: 2Gi
    maxLimitRequestRatio:
      cpu: "4"       # limit can be at most 4x the request
      memory: "2"

  # Pod-level limits (sum of all containers)
  - type: Pod
    max:
      cpu: 4000m
      memory: 4Gi

  # PVC limits
  - type: PersistentVolumeClaim
    max:
      storage: 100Gi
    min:
      storage: 1Gi
```

```bash
kubectl get limitrange -n production
kubectl describe limitrange default-limits -n production
```

---

## ResourceQuota

ResourceQuota limits the total resources consumed by a namespace.

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: production-quota
  namespace: production
spec:
  hard:
    # Compute
    requests.cpu: "10"
    requests.memory: 20Gi
    limits.cpu: "20"
    limits.memory: 40Gi

    # Object counts
    pods: "50"
    services: "20"
    secrets: "50"
    configmaps: "30"
    persistentvolumeclaims: "20"

    # Storage
    requests.storage: 500Gi
    fast-ssd.storageclass.storage.k8s.io/requests.storage: 200Gi

    # LoadBalancer services
    services.loadbalancers: "2"
    services.nodeports: "0"
```

```bash
kubectl get resourcequota -n production
kubectl describe resourcequota production-quota -n production
# Shows: Used vs Hard limits

# What happens when quota is exceeded:
# kubectl apply fails with: "exceeded quota: production-quota"
```

### Quota scopes

```yaml
spec:
  hard:
    pods: "10"
  scopeSelector:
    matchExpressions:
    - operator: In
      scopeName: PriorityClass
      values: [high-priority]
# Limits only high-priority pods in this namespace
```

---

## Vertical Pod Autoscaler (VPA)

VPA recommends (and optionally sets) CPU and memory requests/limits based on actual usage.

```bash
# Install VPA
helm repo add fairwinds-stable https://charts.fairwinds.com/stable
helm install vpa fairwinds-stable/vpa --namespace vpa --create-namespace
```

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: my-app-vpa
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  updatePolicy:
    updateMode: "Off"    # Off | Initial | Recreate | Auto
  resourcePolicy:
    containerPolicies:
    - containerName: app
      minAllowed:
        cpu: 50m
        memory: 64Mi
      maxAllowed:
        cpu: 2000m
        memory: 2Gi
      controlledResources: [cpu, memory]
```

### VPA Modes

| Mode | Behavior |
|------|---------|
| `Off` | Only provides recommendations, no changes |
| `Initial` | Sets resources when Pod is first created |
| `Recreate` | Evicts Pods to apply new resources |
| `Auto` | Currently same as Recreate |

```bash
# Check VPA recommendations
kubectl get vpa my-app-vpa -o yaml | grep -A20 recommendation

# Goldilocks — VPA in Off mode with a nice UI
helm install goldilocks fairwinds-stable/goldilocks --namespace goldilocks --create-namespace
kubectl label namespace production goldilocks.fairwinds.com/enabled=true
```

> **SRE Note:** Don't use VPA `Auto` mode together with HPA on the same resource (CPU/memory). They will conflict. Use VPA for memory sizing + KEDA/HPA for replica scaling.

---

## Namespace Resource Strategy

A production multi-tenant cluster pattern:

```
Cluster
├── namespace: team-a-production
│   ├── ResourceQuota (limits total usage)
│   ├── LimitRange (sets defaults and bounds per container)
│   └── Workloads (automatically get defaults from LimitRange)
│
├── namespace: team-b-production
│   ├── ResourceQuota
│   ├── LimitRange
│   └── Workloads
│
└── namespace: kube-system (no quota — system components)
```

---

## Right-Sizing in Practice

```bash
# Step 1: Get actual usage
kubectl top pods -n production --sort-by=memory
kubectl top nodes

# Step 2: Prometheus queries for right-sizing
# CPU: actual usage vs request
sum(rate(container_cpu_usage_seconds_total[1h])) by (pod, container)
  /
sum(kube_pod_container_resource_requests{resource="cpu"}) by (pod, container)

# Memory: actual usage vs request
sum(container_memory_working_set_bytes) by (pod, container)
  /
sum(kube_pod_container_resource_requests{resource="memory"}) by (pod, container)

# Step 3: Use VPA recommendations
kubectl get vpa -A

# Step 4: Apply new requests/limits (via Helm values update or patch)
kubectl set resources deployment my-app \
  --requests=cpu=200m,memory=256Mi \
  --limits=cpu=500m,memory=512Mi
```

---

## SRE Lens

- **Always set requests** — pods without requests are BestEffort and get evicted first. They also cause unpredictable scheduling.
- **Be careful with CPU limits** — CPU throttling causes latency spikes that are hard to debug. Consider setting no CPU limits for latency-sensitive services.
- **Memory limits should be set** — OOMKill is recoverable; a node running out of memory is not.
- **LimitRange defaults save you** — without them, developers who forget to set resources create BestEffort pods that hurt everyone.
- **ResourceQuota prevents runaway costs** — one team's autoscaler bug shouldn't exhaust the whole cluster.

---

## Resources

| Type | Link |
|------|------|
| Official Docs | [Resource Management](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/) |
| Official Docs | [LimitRange](https://kubernetes.io/docs/concepts/policy/limit-range/) |
| Official Docs | [Resource Quotas](https://kubernetes.io/docs/concepts/policy/resource-quotas/) |
| Official Docs | [QoS Classes](https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/) |
| Tool | [VPA](https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler) |
| Tool | [Goldilocks](https://goldilocks.docs.fairwinds.com/) |
| Blog | [Stop Using CPU Limits (Robusta)](https://home.robusta.dev/blog/stop-using-cpu-limits) |
| Blog | [Understanding OOM](https://kubernetes.io/docs/tasks/configure-pod-container/assign-memory-resource/) |
