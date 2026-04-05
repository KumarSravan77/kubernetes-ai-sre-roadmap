# 01 — Foundations

Before touching a production cluster, you need a solid mental model of containers and why Kubernetes exists. This section builds that foundation.

---

## Why Kubernetes?

Containers solved "it works on my machine." Kubernetes solves "how do I run 500 containers across 50 machines reliably?"

Key problems Kubernetes addresses:
- **Scheduling** — where does a container run?
- **Self-healing** — restart crashed containers, replace unhealthy nodes
- **Scaling** — add/remove replicas based on load
- **Networking** — give every container a routable IP
- **Service discovery** — find other services by name, not IP
- **Config & Secrets** — inject config without rebuilding images
- **Rolling updates** — deploy new versions without downtime

---

## Container Fundamentals

### Namespaces and cgroups

Containers are not VMs. They are isolated processes built from two Linux primitives:

| Primitive | What it does |
|-----------|-------------|
| **Namespaces** | Isolate: pid, net, mnt, uts, ipc, user |
| **cgroups** | Limit: CPU, memory, disk I/O, network bandwidth |

```bash
# See namespaces a running container uses
lsns -p <pid>

# See cgroup limits for a container
cat /sys/fs/cgroup/memory/docker/<id>/memory.limit_in_bytes
```

### OCI Spec

An image is a set of filesystem layers + a config JSON. The [OCI Image Spec](https://github.com/opencontainers/image-spec) standardises this so any runtime (Docker, containerd, CRI-O) can run any image.

```
Image = config.json + [ layer.tar.gz, layer.tar.gz, ... ]
```

### Container Runtimes

```
kubelet
  └── CRI (Container Runtime Interface — gRPC)
        ├── containerd  (most common)
        │     └── runc  (OCI runtime — actually forks the process)
        ├── CRI-O
        └── Docker (via dockershim — removed in 1.24)
```

---

## Kubernetes Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│                   Control Plane                     │
│  ┌──────────────┐  ┌───────┐  ┌──────────────────┐ │
│  │ kube-apiserver│  │ etcd  │  │ kube-scheduler   │ │
│  └──────────────┘  └───────┘  └──────────────────┘ │
│  ┌────────────────────────┐  ┌─────────────────────┐│
│  │ kube-controller-manager│  │cloud-controller-mgr ││
│  └────────────────────────┘  └─────────────────────┘│
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│                   Worker Nodes                      │
│  ┌─────────┐  ┌────────────┐  ┌──────────────────┐ │
│  │ kubelet │  │ kube-proxy │  │ container runtime│ │
│  └─────────┘  └────────────┘  └──────────────────┘ │
│  ┌──────┐  ┌──────┐  ┌──────┐                      │
│  │ Pod  │  │ Pod  │  │ Pod  │  ...                  │
│  └──────┘  └──────┘  └──────┘                      │
└─────────────────────────────────────────────────────┘
```

| Component | Role |
|-----------|------|
| **kube-apiserver** | Single entry point for all cluster state changes. Validates, authenticates, and persists to etcd. |
| **etcd** | Distributed KV store — the source of truth for all cluster state. |
| **kube-scheduler** | Watches for unscheduled Pods and assigns them to nodes. |
| **kube-controller-manager** | Runs control loops: Node, ReplicaSet, Deployment, Job, etc. |
| **cloud-controller-manager** | Talks to cloud APIs (LBs, volumes, routes). |
| **kubelet** | Node agent. Ensures Pods described in the API are running. |
| **kube-proxy** | Manages iptables/ipvs rules for Service ClusterIPs. |

---

## YAML Anatomy

Every Kubernetes object has four top-level fields:

```yaml
apiVersion: apps/v1      # API group + version
kind: Deployment         # Object type
metadata:
  name: my-app
  namespace: default
  labels:
    app: my-app
  annotations:
    deployment.kubernetes.io/revision: "1"
spec:                    # Desired state — YOU write this
  replicas: 3
  ...
# status:               # Actual state — Kubernetes writes this (never set manually)
```

### Resource naming

```
<apiGroup>/<version>/<kind>
apps/v1/Deployment
batch/v1/Job
networking.k8s.io/v1/NetworkPolicy
""  /v1/Pod          (core group has empty apiGroup)
```

---

## kubectl Essentials

### Setup

```bash
# Install kubectl
brew install kubectl        # macOS
# OR
curl -LO "https://dl.k8s.io/release/$(curl -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

# Autocomplete (add to ~/.zshrc or ~/.bashrc)
source <(kubectl completion zsh)
alias k=kubectl
complete -F __start_kubectl k
```

### Context management

```bash
kubectl config get-contexts          # list all contexts
kubectl config use-context <name>    # switch context
kubectl config current-context       # show current
kubectl config set-context --current --namespace=my-ns  # set default namespace

# kubectx/kubens (faster)
brew install kubectx
kubectx staging           # switch cluster
kubens kube-system        # switch namespace
```

### Read operations

```bash
kubectl get pods                          # list pods in current namespace
kubectl get pods -A                       # all namespaces
kubectl get pods -o wide                  # with node and IP
kubectl get pods -o yaml                  # full YAML output
kubectl get pods -l app=nginx             # label selector
kubectl get all                           # pods, services, deployments, replicasets

kubectl describe pod <name>               # events, conditions, detailed spec
kubectl describe node <name>              # node conditions, capacity, allocatable

kubectl explain deployment.spec.template  # API field documentation
kubectl explain pod --recursive           # all fields
```

### Write operations

```bash
kubectl apply -f manifest.yaml            # create or update (idempotent)
kubectl apply -f ./dir/                   # apply a directory
kubectl delete -f manifest.yaml           # delete resources defined in file
kubectl delete pod <name>                 # delete by name
kubectl delete pod <name> --force --grace-period=0  # force delete (use sparingly)

kubectl scale deployment my-app --replicas=5
kubectl set image deployment/my-app app=myimage:v2
```

### Debugging

```bash
kubectl logs <pod>                        # stdout/stderr
kubectl logs <pod> -c <container>         # specific container
kubectl logs <pod> --previous             # previous container instance (after crash)
kubectl logs <pod> -f                     # follow / stream

kubectl exec -it <pod> -- /bin/sh         # shell into pod
kubectl exec -it <pod> -c <container> -- bash

kubectl port-forward pod/<name> 8080:80   # forward local port to pod
kubectl port-forward svc/<name> 8080:80   # forward local port to service

kubectl cp <pod>:/path/to/file ./local    # copy from pod
```

### Events

```bash
kubectl get events --sort-by='.lastTimestamp'
kubectl get events --field-selector reason=BackOff
kubectl get events -n kube-system
```

---

## Namespaces

Namespaces are virtual clusters within a cluster. They scope names, RBAC, and ResourceQuotas.

```bash
kubectl get namespaces
kubectl create namespace my-team

# Default namespaces
# default       — where resources land if no namespace specified
# kube-system   — Kubernetes system components
# kube-public   — publicly readable (cluster-info)
# kube-node-lease — node heartbeat Lease objects
```

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: my-team
  labels:
    team: platform
```

---

## Labels, Annotations, and Selectors

**Labels** are key/value pairs used for grouping and selecting.
**Annotations** are key/value pairs used for metadata (not for selecting).

```yaml
metadata:
  labels:
    app: frontend
    tier: web
    version: v2
    env: production
  annotations:
    git-commit: "abc1234"
    last-deployed-by: "ci-pipeline"
    prometheus.io/scrape: "true"
```

```bash
# Equality selector
kubectl get pods -l app=frontend

# Set-based selector
kubectl get pods -l 'env in (staging,production)'
kubectl get pods -l 'tier notin (database)'
kubectl get pods -l 'app=frontend,env=production'
```

---

## Your First Pod

```yaml
# pod-nginx.yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
  labels:
    app: nginx
spec:
  containers:
  - name: nginx
    image: nginx:1.25
    ports:
    - containerPort: 80
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 200m
        memory: 256Mi
```

```bash
kubectl apply -f pod-nginx.yaml
kubectl get pod nginx
kubectl describe pod nginx
kubectl port-forward pod/nginx 8080:80
curl localhost:8080
kubectl delete pod nginx
```

---

## Local Cluster Setup

### kind (recommended for local labs)

```bash
brew install kind

# Single-node cluster
kind create cluster --name lab

# Multi-node cluster
cat <<EOF | kind create cluster --name lab --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
EOF

kind get clusters
kind delete cluster --name lab
```

### minikube

```bash
brew install minikube
minikube start --cpus 4 --memory 8192 --driver docker
minikube status
minikube dashboard
minikube stop
```

---

## kubeconfig Deep Dive

```yaml
# ~/.kube/config
apiVersion: v1
kind: Config
clusters:
- name: my-cluster
  cluster:
    server: https://api.my-cluster.example.com
    certificate-authority-data: <base64-ca-cert>
users:
- name: my-user
  user:
    client-certificate-data: <base64-cert>
    client-key-data: <base64-key>
contexts:
- name: my-context
  context:
    cluster: my-cluster
    user: my-user
    namespace: default
current-context: my-context
```

```bash
# Merge multiple kubeconfigs
export KUBECONFIG=~/.kube/config:~/.kube/eks-config
kubectl config view --flatten > ~/.kube/config-merged
```

---

## SRE Lens

- Never run `kubectl delete pod` on a production database pod without checking if it has a PDB and will reschedule cleanly.
- `kubectl get events` is often the fastest way to understand why a deployment is failing.
- Always set `resources.requests` — pods without requests can starve other workloads and get evicted first.
- Prefer `kubectl apply` over `kubectl create` — apply is idempotent and safe to re-run.

---

## Resources

| Type | Link |
|------|------|
| Official Docs | [Kubernetes Concepts](https://kubernetes.io/docs/concepts/) |
| Official Docs | [kubectl Cheat Sheet](https://kubernetes.io/docs/reference/kubectl/cheatsheet/) |
| Interactive | [Kubernetes Basics Tutorial](https://kubernetes.io/docs/tutorials/kubernetes-basics/) |
| Course | [LFS158 — Introduction to Kubernetes (free)](https://training.linuxfoundation.org/training/introduction-to-kubernetes/) |
| Book | *Kubernetes: Up and Running* — Burns, Beda, Hightower |
| Tool | [kind](https://kind.sigs.k8s.io/) |
| Tool | [k9s](https://k9scli.io/) |
| Tool | [kubectx/kubens](https://github.com/ahmetb/kubectx) |
