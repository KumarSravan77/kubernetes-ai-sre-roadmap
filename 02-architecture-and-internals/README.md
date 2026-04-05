# 02 — Architecture & Internals

Understanding *why* Kubernetes behaves as it does requires tracing requests through its internals. This section goes below the surface.

---

## The API Server — Center of Everything

Every operation in Kubernetes flows through `kube-apiserver`. Nothing writes directly to etcd except the API server.

```
Client (kubectl / controller / kubelet)
  │
  ▼
kube-apiserver
  ├── Authentication    (who are you?)
  ├── Authorization     (are you allowed?)
  ├── Admission         (mutate + validate)
  └── etcd              (persist)
```

### Authentication

Multiple authenticator plugins, evaluated in order:

| Method | Use case |
|--------|---------|
| X.509 client certs | kubelet, kube-controller-manager |
| Bearer tokens (JWT) | ServiceAccount tokens, OIDC |
| Bootstrap tokens | Node bootstrapping |
| Webhook | External identity provider |
| OIDC | SSO (Google, Okta, Dex) |

```bash
# Inspect your own identity
kubectl auth whoami

# Check what a ServiceAccount can do
kubectl auth can-i list pods --as=system:serviceaccount:default:my-sa
```

### Authorization — RBAC

After authentication, the authorizer checks whether the identity is allowed to perform the action on the resource. RBAC is covered in depth in section 12.

```bash
kubectl auth can-i create deployments -n production
kubectl auth can-i '*' '*'   # cluster-admin check
```

### Admission Control

Admission runs **after** auth but **before** the object is persisted. Two phases:

1. **Mutating** — can modify the object (e.g., inject sidecars, set defaults)
2. **Validating** — can only accept or reject (e.g., enforce naming conventions)

Built-in admission plugins (enabled by default):
- `NamespaceLifecycle` — prevent creating resources in terminating namespaces
- `LimitRanger` — apply LimitRange defaults
- `ServiceAccount` — auto-mount service account token
- `ResourceQuota` — enforce quota
- `MutatingAdmissionWebhook` / `ValidatingAdmissionWebhook` — call external webhooks

```bash
# See active admission plugins
kube-apiserver --help | grep enable-admission-plugins
```

---

## etcd — The Source of Truth

etcd is a distributed, consistent key-value store using the **Raft** consensus algorithm.

```
Key format: /registry/<group>/<resource>/<namespace>/<name>
Example:    /registry/pods/default/nginx-abc123
```

```bash
# Install etcdctl
brew install etcd

# List all keys (requires certs from control plane)
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get / --prefix --keys-only

# Get a specific resource
ETCDCTL_API=3 etcdctl get /registry/pods/default/nginx --print-value-only | python3 -c "
import sys
data = sys.stdin.buffer.read()
# strip protobuf magic bytes and print
print(data[8:].decode('utf-8', errors='replace'))
"
```

### Raft Consensus

- Requires a quorum: majority of nodes must agree before a write is committed
- Optimal cluster size: 3 or 5 nodes (tolerates 1 or 2 failures respectively)
- **Never run an even number of etcd members**

```
3 members → tolerate 1 failure
5 members → tolerate 2 failures
7 members → tolerate 3 failures (rarely needed, higher latency)
```

### etcd Operations

```bash
# Backup
ETCDCTL_API=3 etcdctl snapshot save /backup/etcd-snapshot.db \
  --endpoints=... --cacert=... --cert=... --key=...

# Restore
ETCDCTL_API=3 etcdctl snapshot restore /backup/etcd-snapshot.db \
  --data-dir=/var/lib/etcd-restore

# Check health
ETCDCTL_API=3 etcdctl endpoint health --cluster

# Defragment (run periodically, during low traffic)
ETCDCTL_API=3 etcdctl defrag

# Compaction (free historical revisions)
ETCDCTL_API=3 etcdctl compact $(etcdctl endpoint status --write-out="json" | \
  python3 -c "import sys,json; print(json.load(sys.stdin)[0]['Status']['header']['revision'])")
```

---

## The Watch Mechanism

Kubernetes is **event-driven**. Controllers watch for changes by opening a long-lived HTTP/2 stream to the API server.

```
Controller → GET /api/v1/pods?watch=true&resourceVersion=12345
API server → streams events: ADDED, MODIFIED, DELETED
```

This is why Kubernetes is **level-triggered** (not edge-triggered):
- Controllers reconcile the **full desired state**, not just the diff
- If a watch is interrupted, the controller re-lists and catches up
- **Implication for operators:** your reconcile function must be idempotent

```bash
# Watch pods from kubectl
kubectl get pods --watch
kubectl get pods -w -o json   # raw watch events
```

---

## The Scheduler

The scheduler watches for Pods with `.spec.nodeName == ""` and assigns them to nodes.

### Scheduling Pipeline

```
Filter (predicates)          Score (priorities)
─────────────────           ────────────────────
NodeUnschedulable      →    LeastRequestedPriority
NodeResourcesFit       →    BalancedResourceAllocation
NodeAffinity           →    NodeAffinityPriority
TaintToleration        →    PodTopologySpread
PodTopologySpread      →    ImageLocality
VolumeBinding          →    ...
...
           ↓
    Highest-score node wins → nodeName written to Pod
```

```bash
# See scheduler events for a Pod
kubectl describe pod <name> | grep -A 5 Events

# Check scheduler logs
kubectl logs -n kube-system -l component=kube-scheduler --tail=50
```

---

## The Controller Manager

`kube-controller-manager` runs dozens of controllers in a single binary. Each controller:
1. **Watches** the API for its resource type
2. **Compares** actual state to desired state
3. **Acts** to reconcile differences
4. **Updates status** to reflect current state

Key controllers:

| Controller | Watches | Acts |
|------------|---------|------|
| ReplicaSet | ReplicaSets, Pods | Creates/deletes Pods |
| Deployment | Deployments, ReplicaSets | Creates/updates ReplicaSets |
| StatefulSet | StatefulSets, Pods | Creates/deletes Pods in order |
| Job | Jobs, Pods | Creates Pods, tracks completion |
| Node | Nodes | Taints unreachable nodes, evicts Pods |
| Namespace | Namespaces | Cleans up resources on deletion |
| ServiceAccount | ServiceAccounts | Creates default SA in new namespaces |

```bash
# Watch controller-manager logs
kubectl logs -n kube-system -l component=kube-controller-manager -f
```

---

## kubelet — The Node Agent

The kubelet runs on every node. Its job: make sure Pods defined by the API are running.

```
kubelet loop:
  1. Watch API server for Pods assigned to this node
  2. For each Pod:
     a. Pull images (via CRI)
     b. Create containers (via CRI)
     c. Run liveness/readiness/startup probes
     d. Report status back to API server
  3. Evict Pods if node is under memory/disk pressure
```

```bash
# kubelet config and logs on a node
systemctl status kubelet
journalctl -u kubelet -f
cat /var/lib/kubelet/config.yaml

# kubelet API (runs on each node)
curl -k https://localhost:10250/pods
curl -k https://localhost:10250/metrics
```

---

## Admission Webhooks

You can extend the admission pipeline with your own webhooks.

### Mutating Webhook (inject a sidecar)

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: sidecar-injector
webhooks:
- name: inject.example.com
  admissionReviewVersions: ["v1"]
  clientConfig:
    service:
      name: sidecar-injector-svc
      namespace: default
      path: /mutate
    caBundle: <base64-ca>
  rules:
  - operations: ["CREATE"]
    apiGroups: [""]
    apiVersions: ["v1"]
    resources: ["pods"]
  failurePolicy: Ignore   # or Fail — choose carefully!
  sideEffects: None
```

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: no-latest-tag
webhooks:
- name: no-latest.example.com
  admissionReviewVersions: ["v1"]
  clientConfig:
    service:
      name: policy-webhook
      namespace: policy-system
      path: /validate
    caBundle: <base64-ca>
  rules:
  - operations: ["CREATE", "UPDATE"]
    apiGroups: ["apps"]
    apiVersions: ["v1"]
    resources: ["deployments"]
  failurePolicy: Fail
  sideEffects: None
```

> **SRE Warning:** `failurePolicy: Fail` means if your webhook is down, the entire operation fails. Always use `failurePolicy: Ignore` for non-critical webhooks, and ensure critical webhooks are HA with PodDisruptionBudget and appropriate timeouts.

---

## CRDs — Extending the API

Custom Resource Definitions allow you to add your own object types to Kubernetes.

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: databases.example.com
spec:
  group: example.com
  names:
    kind: Database
    plural: databases
    singular: database
    shortNames: [db]
  scope: Namespaced
  versions:
  - name: v1alpha1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            required: [engine, version]
            properties:
              engine:
                type: string
                enum: [postgres, mysql]
              version:
                type: string
              replicas:
                type: integer
                minimum: 1
                maximum: 5
    subresources:
      status: {}
      scale:
        specReplicasPath: .spec.replicas
        statusReplicasPath: .status.replicas
```

```bash
kubectl apply -f database-crd.yaml
kubectl get crd
kubectl get databases -A
```

---

## API Groups and Versions

```bash
# List all API resources
kubectl api-resources

# List all API versions
kubectl api-versions

# Get API group details
kubectl get --raw /apis/apps/v1 | python3 -m json.tool

# Explain any field
kubectl explain deployment.spec.strategy.rollingUpdate
```

Version semantics:
- `v1alpha1` — unstable, may change or be removed
- `v1beta1` — mostly stable, may change
- `v1` — stable, backwards compatible

---

## Tracing a `kubectl apply`

```
1. kubectl reads YAML → sends HTTP PATCH/PUT to /apis/apps/v1/namespaces/default/deployments/my-app

2. kube-apiserver:
   a. TLS termination
   b. Authentication (client cert or bearer token)
   c. Authorization (RBAC check: can this user update deployments in default namespace?)
   d. Mutating admission webhooks (e.g., inject labels, set defaults)
   e. Schema validation (against CRD or built-in OpenAPI spec)
   f. Validating admission webhooks (e.g., no latest tag)
   g. Persist to etcd
   h. Return 200 OK with updated object

3. Deployment controller (in kube-controller-manager):
   a. Watch notifies: Deployment changed
   b. Compute desired ReplicaSet state
   c. Create new ReplicaSet (or update existing)
   d. Scale down old ReplicaSet, scale up new one

4. ReplicaSet controller:
   a. Watch notifies: ReplicaSet needs more Pods
   b. Create Pod objects (spec only — no node assigned yet)

5. kube-scheduler:
   a. Watch notifies: Pod with no .spec.nodeName
   b. Filter nodes (resources, affinity, taints)
   c. Score remaining nodes
   d. PATCH Pod.spec.nodeName = "worker-1"

6. kubelet on worker-1:
   a. Watch notifies: Pod assigned to this node
   b. Pull image via containerd
   c. Create container
   d. Run startup probe, then readiness probe
   e. PATCH Pod.status.conditions[Ready]=True

7. Endpoints controller:
   a. Pod is Ready → add to Service Endpoints
   b. kube-proxy on all nodes updates iptables rules
```

---

## SRE Lens

- **etcd is the single point of failure** — back it up, monitor its disk latency (`etcd_disk_wal_fsync_duration_seconds`), and keep it on dedicated fast SSDs.
- **Admission webhook timeouts** cause mysterious slowdowns. Set `timeoutSeconds: 5` and monitor webhook latency.
- **The watch cache** (API server's in-memory cache) means `kubectl get pods` may return slightly stale data. Use `--watch` or set `resourceVersion=0` for cache reads vs. `resourceVersion=""` for etcd reads.
- **Controller reconciliation is eventually consistent** — don't assume a write instantly affects the world. Poll status or watch for events.

---

## Resources

| Type | Link |
|------|------|
| Official Docs | [Kubernetes Components](https://kubernetes.io/docs/concepts/overview/components/) |
| Deep-dive | [What happens when k8s](https://github.com/jamiehannaford/what-happens-when-k8s) |
| Deep-dive | [Kubernetes the Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way) |
| Official Docs | [etcd](https://etcd.io/docs/) |
| Official Docs | [Admission Controllers](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/) |
| Official Docs | [CRDs](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/) |
| Blog | [A deep dive into Kubernetes controllers](https://engineering.bitnami.com/articles/a-deep-dive-into-kubernetes-controllers.html) |
