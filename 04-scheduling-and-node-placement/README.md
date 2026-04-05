# 04 — Scheduling & Node Placement

Scheduling determines *where* your Pods run. Getting this right prevents noisy-neighbor problems, ensures HA across zones, and controls costs.

---

## The Scheduler Pipeline

```
Unscheduled Pod
      │
      ▼
  ┌─────────┐     nodes that don't pass are eliminated
  │ FILTER  │ ──► feasible nodes
  └─────────┘
      │
      ▼
  ┌─────────┐     each feasible node gets a score 0–100
  │  SCORE  │ ──► ranked nodes
  └─────────┘
      │
      ▼
  Highest score node wins → Pod.spec.nodeName = winner
```

### Key Filter Plugins

| Plugin | What it checks |
|--------|---------------|
| `NodeResourcesFit` | Node has enough CPU/memory |
| `NodeAffinity` | Node matches Pod's nodeAffinity |
| `TaintToleration` | Pod tolerates node's taints |
| `PodTopologySpread` | Spread constraints are satisfiable |
| `VolumeBinding` | Required volumes can be provisioned on this node |
| `NodeUnschedulable` | Node is not cordoned |

### Key Score Plugins

| Plugin | What it scores |
|--------|---------------|
| `LeastAllocated` | Prefer nodes with more free resources |
| `BalancedAllocation` | Prefer nodes where CPU and memory usage are balanced |
| `NodeAffinity` | Preferred affinity rules |
| `PodTopologySpread` | Prefer even spread |
| `ImageLocality` | Prefer nodes that already have the image |

---

## nodeSelector — Simple Node Selection

```yaml
spec:
  nodeSelector:
    kubernetes.io/os: linux
    node.kubernetes.io/instance-type: m5.xlarge
    disktype: ssd
```

```bash
# Label a node
kubectl label node worker-1 disktype=ssd
kubectl label node worker-1 disktype-    # remove label

# Find nodes with a label
kubectl get nodes -l disktype=ssd
```

---

## Node Affinity

More expressive than nodeSelector. Two types:
- `requiredDuringSchedulingIgnoredDuringExecution` — **hard** rule (filter)
- `preferredDuringSchedulingIgnoredDuringExecution` — **soft** rule (score)

```yaml
spec:
  affinity:
    nodeAffinity:
      # HARD: must run on a node with SSD
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: disktype
            operator: In
            values: [ssd]
      # SOFT: prefer us-east-1a, weight 80/100
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 80
        preference:
          matchExpressions:
          - key: topology.kubernetes.io/zone
            operator: In
            values: [us-east-1a]
      - weight: 20
        preference:
          matchExpressions:
          - key: topology.kubernetes.io/zone
            operator: In
            values: [us-east-1b]
```

### Operators

| Operator | Meaning |
|----------|---------|
| `In` | Value in set |
| `NotIn` | Value not in set |
| `Exists` | Key exists |
| `DoesNotExist` | Key does not exist |
| `Gt` | Value greater than |
| `Lt` | Value less than |

---

## Pod Affinity and Anti-Affinity

Schedule Pods *relative to other Pods*. Uses `topologyKey` to define what "co-located" means.

```yaml
spec:
  affinity:
    # HARD: run on a node that already has a matching pod
    podAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: cache
        topologyKey: kubernetes.io/hostname

    # HARD: do NOT run on same node as another frontend pod
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: frontend
        topologyKey: kubernetes.io/hostname

    # SOFT: prefer same zone as app=backend pods
    podAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 50
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app: backend
          topologyKey: topology.kubernetes.io/zone
```

> **SRE Use Case:** Use `podAntiAffinity` with `topologyKey: topology.kubernetes.io/zone` to spread replicas across AZs for high availability.

---

## Taints and Tolerations

**Taints** are applied to nodes to repel Pods.
**Tolerations** are applied to Pods to allow them onto tainted nodes.

### Taint a node

```bash
# Add a taint
kubectl taint node worker-gpu gpu=true:NoSchedule

# Remove a taint
kubectl taint node worker-gpu gpu=true:NoSchedule-

# List taints on all nodes
kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints'
```

### Taint effects

| Effect | Behavior |
|--------|---------|
| `NoSchedule` | New Pods without matching toleration are not scheduled here |
| `PreferNoSchedule` | Scheduler tries to avoid, but may still place Pods here |
| `NoExecute` | Evicts existing Pods without matching toleration + blocks new ones |

### Add a toleration to a Pod

```yaml
spec:
  tolerations:
  # Match specific taint
  - key: gpu
    operator: Equal
    value: "true"
    effect: NoSchedule

  # Tolerate any taint with this key
  - key: dedicated
    operator: Exists
    effect: NoSchedule

  # Tolerate node.kubernetes.io/not-ready for 300s before eviction
  - key: node.kubernetes.io/not-ready
    operator: Exists
    effect: NoExecute
    tolerationSeconds: 300
```

### Common built-in taints

```
node.kubernetes.io/not-ready          — node is not ready
node.kubernetes.io/unreachable        — node controller can't reach node
node.kubernetes.io/disk-pressure      — node has disk pressure
node.kubernetes.io/memory-pressure    — node has memory pressure
node.kubernetes.io/pid-pressure       — node has PID pressure
node.kubernetes.io/unschedulable      — node is cordoned
node.kubernetes.io/network-unavailable — node network not configured
```

### Dedicated node pattern

```bash
kubectl taint node gpu-node-1 dedicated=ml-training:NoSchedule
kubectl label node gpu-node-1 dedicated=ml-training
```

```yaml
spec:
  tolerations:
  - key: dedicated
    value: ml-training
    effect: NoSchedule
  nodeSelector:
    dedicated: ml-training
```

---

## Topology Spread Constraints

Fine-grained control over how Pods spread across topology domains.

```yaml
spec:
  topologySpreadConstraints:
  # Spread evenly across zones, max 1 skew
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule   # or ScheduleAnyway
    labelSelector:
      matchLabels:
        app: my-app
    matchLabelKeys: [pod-template-hash]  # 1.27+: exclude pods from old ReplicaSets

  # Also spread across nodes, max 2 skew
  - maxSkew: 2
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app: my-app
```

```
Zone A: [pod] [pod]
Zone B: [pod] [pod]
Zone C: [pod]
               ↑ next pod goes here (keeps skew ≤ 1)
```

---

## Priority Classes and Preemption

When a cluster is full, high-priority Pods evict lower-priority Pods.

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: high-priority-production
value: 1000000
globalDefault: false
preemptionPolicy: PreemptLowerPriority
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: low-priority-batch
value: 100
preemptionPolicy: Never   # won't evict others but can still be evicted
```

```yaml
spec:
  priorityClassName: high-priority-production
```

```bash
kubectl get priorityclasses
# Built-in system classes:
# system-node-critical:    2000001000
# system-cluster-critical: 2000000000
```

---

## Cordon and Drain

```bash
# Cordon — prevent new pods from scheduling here
kubectl cordon worker-1

# Uncordon — restore scheduling
kubectl uncordon worker-1

# Drain — evict pods gracefully (respects PDBs)
kubectl drain worker-1 \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --grace-period=60

# Check drain progress
kubectl get pods -A --field-selector spec.nodeName=worker-1
```

---

## Scheduler Debugging

```bash
# Why is my pod Pending?
kubectl describe pod <name> | grep -A 20 "Events:"

# Common messages:
# "0/5 nodes are available: 2 Insufficient cpu, 3 node(s) had taint..."
# "0/5 nodes are available: 5 pod topology spread constraints not satisfiable"

# Node resource view
kubectl describe node <name> | grep -A 10 "Allocated resources"
kubectl top nodes

# Scheduler logs
kubectl logs -n kube-system -l component=kube-scheduler | tail -50
```

### Pending Pod Checklist

```
❏ Enough CPU and memory on any node?
❏ nodeSelector / nodeAffinity matches any node?
❏ Taints on nodes have matching tolerations?
❏ topologySpreadConstraints are satisfiable?
❏ PVCs are bound? (VolumeBinding filter)
❏ Node is not cordoned?
❏ Node is under max Pods limit (default 110)?
```

---

## SRE Lens

- **Zone spread is HA** — spread across AZs using `topologySpreadConstraints`. One AZ going down should not take out your service.
- **Taint control-plane nodes** — workloads should not land on control-plane nodes by accident.
- **Priority classes protect production** — batch jobs should use low priority so they get evicted first under pressure.
- **Alert on Pending Pods** — `kube_pod_status_phase{phase="Pending"} > 0` for more than 5 minutes is a signal to investigate.

---

## Resources

| Type | Link |
|------|------|
| Official Docs | [Assigning Pods to Nodes](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/) |
| Official Docs | [Taints and Tolerations](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/) |
| Official Docs | [Topology Spread Constraints](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/) |
| Official Docs | [Pod Priority and Preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/) |
| Official Docs | [Scheduler Framework](https://kubernetes.io/docs/concepts/scheduling-eviction/scheduling-framework/) |
| Blog | [Topology Spread Deep Dive](https://kubernetes.io/blog/2020/05/introducing-podtopologyspread/) |
