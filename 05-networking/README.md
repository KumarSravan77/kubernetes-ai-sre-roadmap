# 05 — Networking

Kubernetes networking is often where engineers get stuck. This section builds a complete mental model from first principles.

---

## The Three Networking Rules

Kubernetes imposes three fundamental networking requirements:

1. **Pod-to-Pod**: Every Pod gets a unique cluster-wide IP. Pods can communicate with any other Pod directly — no NAT.
2. **Pod-to-Service**: Pods reach Services via a stable ClusterIP (virtual IP). No NAT at the Pod level.
3. **External-to-Service**: External traffic enters via NodePort, LoadBalancer, or Ingress.

---

## How Pod IPs Work

Each node gets a **Pod CIDR** subnet. Pods on a node get IPs from that subnet.

```
Cluster CIDR:  10.244.0.0/16
Node 1 CIDR:   10.244.0.0/24  → Pods: 10.244.0.1 – 10.244.0.254
Node 2 CIDR:   10.244.1.0/24  → Pods: 10.244.1.1 – 10.244.1.254
Node 3 CIDR:   10.244.2.0/24  → Pods: 10.244.2.1 – 10.244.2.254
```

The CNI plugin is responsible for:
1. Assigning IPs to Pods
2. Setting up veth pairs (Pod ↔ node bridge)
3. Programming routes so inter-node Pod traffic works

---

## CNI — Container Network Interface

CNI is a spec that defines how network plugins interact with the container runtime.

```
kubelet creates Pod
  └── calls CNI plugin binary
        └── plugin sets up network (IP, routes, iptables)
              └── returns IP to kubelet
```

### Popular CNI Plugins

| Plugin | Dataplane | Key feature |
|--------|-----------|-------------|
| **Calico** | iptables / eBPF | NetworkPolicy + BGP routing |
| **Cilium** | eBPF | Full NetworkPolicy, L7 policy, Hubble observability |
| **Flannel** | VXLAN / host-gw | Simple, minimal features |
| **Weave** | VXLAN | Multi-cloud mesh |
| **AWS VPC CNI** | Native VPC routing | Pod IPs from VPC subnet (ENI-based) |

```bash
# Check which CNI is installed
ls /etc/cni/net.d/
kubectl get pods -n kube-system | grep -E 'calico|cilium|flannel|weave'

# Cilium status
cilium status
cilium connectivity test
```

---

## kube-proxy and Service Implementation

`kube-proxy` watches Services and Endpoints, then programs the host network (iptables or ipvs) so that traffic to a Service ClusterIP gets load-balanced to healthy Pod IPs.

### iptables mode (default)

```
Client Pod → ClusterIP:Port
  └── iptables DNAT rule (randomly selects a backend Pod IP)
        └── Backend Pod
```

```bash
# See iptables rules for a service
iptables -t nat -L KUBE-SERVICES -n --line-numbers
iptables -t nat -L KUBE-SVC-XXXXXXXXXX -n
```

### ipvs mode (better for large clusters)

```bash
# Enable ipvs mode in kube-proxy configmap
kubectl edit configmap kube-proxy -n kube-system
# Set: mode: "ipvs"

# Inspect ipvs rules
ipvsadm -Ln
```

### eBPF mode (Cilium replaces kube-proxy)

```bash
# Deploy Cilium with kube-proxy replacement
helm install cilium cilium/cilium \
  --set kubeProxyReplacement=strict \
  --set k8sServiceHost=<API_SERVER_IP> \
  --set k8sServicePort=6443
```

---

## DNS in Kubernetes

CoreDNS runs as a Deployment in `kube-system` and provides DNS for the cluster.

### DNS names

```
Service:    <service>.<namespace>.svc.cluster.local
Pod:        <pod-ip-dashed>.<namespace>.pod.cluster.local

# Short forms work within the same namespace:
my-service           → my-service.default.svc.cluster.local
my-service.other-ns  → my-service.other-ns.svc.cluster.local
```

### Pod DNS config

```bash
# Default resolv.conf inside a Pod
cat /etc/resolv.conf
# nameserver 10.96.0.10           ← CoreDNS ClusterIP
# search default.svc.cluster.local svc.cluster.local cluster.local
# options ndots:5
```

`ndots:5` means a name with fewer than 5 dots is tried with search domains first. This can cause extra DNS lookups for external names (e.g., `api.example.com` → tries `api.example.com.default.svc.cluster.local` first).

```yaml
# Tune DNS for a Pod
spec:
  dnsPolicy: ClusterFirst   # default — use CoreDNS
  dnsConfig:
    options:
    - name: ndots
      value: "2"   # reduce unnecessary search-domain lookups
    - name: single-request-reopen
```

```bash
# Debug DNS from inside a Pod
kubectl run -it dns-debug --image=nicolaka/netshoot --rm -- bash
  dig my-service.default.svc.cluster.local
  nslookup my-service
  dig +search api.example.com   # see all attempted names

# Check CoreDNS logs
kubectl logs -n kube-system -l k8s-app=kube-dns
```

### CoreDNS config

```bash
kubectl get configmap coredns -n kube-system -o yaml
```

```
Corefile: |
  .:53 {
      errors
      health { lameduck 5s }
      ready
      kubernetes cluster.local in-addr.arpa ip6.arpa {
          pods insecure
          fallthrough in-addr.arpa ip6.arpa
      }
      prometheus :9153
      forward . /etc/resolv.conf          # forward non-cluster DNS to host resolver
      cache 30
      loop
      reload
      loadbalance
  }
```

---

## NetworkPolicy

NetworkPolicy controls which Pods can communicate with each other and with external endpoints. It's enforced by the CNI plugin (not all CNIs support it).

### Default deny all

```yaml
# Deny all ingress and egress for pods in this namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: production
spec:
  podSelector: {}   # applies to all pods
  policyTypes:
  - Ingress
  - Egress
```

### Allow specific traffic

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Ingress
  ingress:
  # Allow from frontend pods in same namespace
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 8080

  # Allow from monitoring namespace
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: monitoring
    ports:
    - protocol: TCP
      port: 9090
```

```yaml
# Allow egress to specific CIDR (e.g., external database)
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Egress
  egress:
  - to:
    - ipBlock:
        cidr: 10.100.0.0/24
        except:
        - 10.100.0.1/32
    ports:
    - protocol: TCP
      port: 5432
  # Always allow DNS
  - to:
    - namespaceSelector: {}
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
```

> **SRE Note:** Always allow DNS egress (UDP/TCP port 53) explicitly when using egress NetworkPolicy, otherwise all DNS lookups fail.

### NetworkPolicy tips

```bash
# Visualize NetworkPolicies
# Use: https://editor.networkpolicy.io/

# Check if CNI enforces NetworkPolicy
kubectl get pods -n kube-system | grep -E 'calico|cilium'

# Cilium: trace policy decisions
cilium policy trace --src-pod default/frontend --dst-pod default/backend --dport 8080/TCP
```

---

## eBPF Networking (Cilium)

eBPF bypasses iptables entirely, with better performance and observability.

```bash
# Install Cilium
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium --version 1.15.0 \
  --namespace kube-system \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true

# Observe network flows
cilium hubble observe --follow
cilium hubble observe --pod default/frontend --follow

# L7 policy (HTTP)
# Cilium can enforce HTTP method/path policies
```

```yaml
# Cilium L7 NetworkPolicy
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-get-only
spec:
  endpointSelector:
    matchLabels:
      app: backend
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: frontend
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
      rules:
        http:
        - method: GET
          path: "/api/.*"
```

---

## IPv4/IPv6 Dual-Stack

```yaml
# Enable in cluster config
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
networking:
  podSubnet: "10.244.0.0/16,fd00:10:244::/56"
  serviceSubnet: "10.96.0.0/12,fd00:10:96::/108"
```

```yaml
# Service with dual-stack
apiVersion: v1
kind: Service
spec:
  ipFamilyPolicy: RequireDualStack
  ipFamilies:
  - IPv4
  - IPv6
```

---

## Common Networking Debug Commands

```bash
# Check Pod connectivity
kubectl exec -it pod-a -- curl http://pod-b-ip:8080
kubectl exec -it pod-a -- nc -zv pod-b-ip 8080

# Test service connectivity
kubectl exec -it pod-a -- curl http://my-service.namespace.svc.cluster.local

# DNS debug
kubectl exec -it pod-a -- nslookup kubernetes.default.svc.cluster.local

# Deploy a debug pod
kubectl run debug --image=nicolaka/netshoot -it --rm -- bash

# Check node-level routing
ip route
ip neighbor
bridge fdb show

# Watch conntrack entries
conntrack -L | grep <pod-ip>
```

---

## SRE Lens

- **NetworkPolicy is opt-in** — without a default-deny policy, all pods can talk to all pods. Always add default deny in production namespaces.
- **DNS is the #1 cause of mysterious timeouts** — check ndots, search domains, CoreDNS restarts.
- **kube-proxy iptables rules grow with the cluster** — at 5,000+ services, switch to ipvs or Cilium eBPF.
- **Pod CIDR exhaustion** — if pod CIDR is too small, new pods can't get IPs. Monitor with `kube_node_status_allocatable{resource="pods"}`.

---

## Resources

| Type | Link |
|------|------|
| Official Docs | [Cluster Networking](https://kubernetes.io/docs/concepts/cluster-administration/networking/) |
| Official Docs | [Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/) |
| Official Docs | [DNS for Services and Pods](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/) |
| Deep-dive | [Kubernetes Networking Packets (Learnk8s)](https://learnk8s.io/kubernetes-network-packets) |
| Tool | [Cilium](https://cilium.io/docs/) |
| Tool | [NetworkPolicy Editor](https://editor.networkpolicy.io/) |
| Tool | [netshoot](https://github.com/nicolaka/netshoot) |
| Book | *Kubernetes Networking* — Vallières & Hausenblas (O'Reilly) |
