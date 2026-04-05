# 18 — Service Mesh

A service mesh handles cross-cutting concerns — mTLS, traffic management, observability — at the infrastructure layer, not the application layer.

---

## What a Service Mesh Solves

| Problem | Without Mesh | With Mesh |
|---------|-------------|-----------|
| Encryption in transit | App must implement TLS | Automatic mTLS |
| Retries and timeouts | App must implement | Configured in mesh |
| Circuit breaking | App must implement | Configured in mesh |
| Traffic splitting (canary) | Two Deployments + Service | VirtualService weights |
| Distributed tracing | App must propagate headers | Automatic span injection |
| Mutual authentication | App or API gateway | Automatic per-service |

---

## Architecture

```
  Sidecar model:
  Pod
  ├── App container
  └── Envoy proxy (injected sidecar)
        ├── Intercepts all inbound/outbound traffic
        └── Reports telemetry to control plane

  Control plane (Istio: istiod):
  ├── Pilot    — pushes route/endpoint config to Envoy
  ├── Citadel  — issues mTLS certificates
  └── Galley   — validates mesh config

  Ambient mesh model (Istio 1.15+, no sidecar):
  ├── ztunnel (node-level L4 proxy — mTLS, basic telemetry)
  └── Waypoint proxy (namespace-level L7 proxy — only when needed)
```

---

## Istio

### Install

```bash
# Install Istioctl
curl -L https://istio.io/downloadIstio | sh -
export PATH=$PWD/istio-*/bin:$PATH

# Install Istio (default profile)
istioctl install --set profile=default -y

# Verify
istioctl verify-install
kubectl get pods -n istio-system

# Enable sidecar injection on a namespace
kubectl label namespace production istio-injection=enabled

# Check injection
kubectl get namespace production --show-labels
```

### Ambient Mesh (no sidecar)

```bash
istioctl install --set profile=ambient -y

# Enable ambient for a namespace
kubectl label namespace production istio.io/dataplane-mode=ambient
```

---

## Traffic Management

### VirtualService

Controls how traffic is routed to a service.

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: my-app
spec:
  hosts:
  - my-app
  - my-app.example.com
  http:
  # Route based on header
  - match:
    - headers:
        x-version:
          exact: v2
    route:
    - destination:
        host: my-app
        subset: v2

  # Canary: 90% → v1, 10% → v2
  - route:
    - destination:
        host: my-app
        subset: v1
      weight: 90
    - destination:
        host: my-app
        subset: v2
      weight: 10

    # Timeouts and retries
    timeout: 5s
    retries:
      attempts: 3
      perTryTimeout: 2s
      retryOn: gateway-error,connect-failure,retriable-4xx
```

### DestinationRule

Defines subsets and load balancing for a service.

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-app
spec:
  host: my-app
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100
      http:
        h2UpgradePolicy: UPGRADE
        http1MaxPendingRequests: 50
        http2MaxRequests: 100
    loadBalancer:
      simple: LEAST_CONN   # or ROUND_ROBIN, RANDOM
    outlierDetection:        # circuit breaker
      consecutiveGatewayErrors: 5
      interval: 30s
      baseEjectionTime: 30s
      maxEjectionPercent: 50

  subsets:
  - name: v1
    labels:
      version: v1
  - name: v2
    labels:
      version: v2
    trafficPolicy:
      connectionPool:
        http:
          http1MaxPendingRequests: 10   # tighter limit on canary
```

### Ingress Gateway

```yaml
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: main-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: my-tls-secret
    hosts:
    - "*.example.com"
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: my-app-external
spec:
  hosts:
  - app.example.com
  gateways:
  - main-gateway
  - mesh              # also applies to internal mesh traffic
  http:
  - route:
    - destination:
        host: my-app
        port:
          number: 80
```

### Fault Injection (for chaos testing)

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: my-app-faults
spec:
  hosts:
  - my-app
  http:
  - fault:
      delay:
        percentage:
          value: 10.0    # 10% of requests get a 5s delay
        fixedDelay: 5s
      abort:
        percentage:
          value: 5.0     # 5% of requests get HTTP 500
        httpStatus: 500
    route:
    - destination:
        host: my-app
```

---

## mTLS

### PeerAuthentication — require mTLS

```yaml
# Strict mTLS for the entire namespace
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: production
spec:
  mtls:
    mode: STRICT   # PERMISSIVE allows plain text (migration mode)

# Override for a specific workload
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: legacy-app-exception
  namespace: production
spec:
  selector:
    matchLabels:
      app: legacy-app
  mtls:
    mode: PERMISSIVE
```

### AuthorizationPolicy — L4/L7 access control

```yaml
# Deny all by default
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: production
spec: {}   # empty spec = deny all
---
# Allow frontend → backend only
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: production
spec:
  selector:
    matchLabels:
      app: backend
  action: ALLOW
  rules:
  - from:
    - source:
        principals:
        - cluster.local/ns/production/sa/frontend
    to:
    - operation:
        methods: [GET, POST]
        paths: ["/api/*"]
```

---

## Observability

```bash
# Install Istio addons
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/addons/prometheus.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/addons/grafana.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/addons/jaeger.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/addons/kiali.yaml

# Access dashboards
istioctl dashboard kiali
istioctl dashboard grafana
istioctl dashboard jaeger

# Check mesh metrics
istioctl proxy-status           # sync status of all Envoy proxies
istioctl proxy-config cluster <pod>   # route config
istioctl analyze                # detect config issues
```

Key Istio metrics (Prometheus):
```promql
# Request success rate
sum(rate(istio_requests_total{response_code!~"5.."}[5m])) by (destination_service) /
sum(rate(istio_requests_total[5m])) by (destination_service)

# P99 latency
histogram_quantile(0.99,
  sum(rate(istio_request_duration_milliseconds_bucket[5m])) by (destination_service, le)
)

# mTLS errors
rate(istio_tcp_connections_closed_total{response_flags="ssl_handshake_error"}[5m])
```

---

## Linkerd

Linkerd is a lightweight alternative with automatic mTLS and latency-aware load balancing.

```bash
# Install Linkerd
curl --proto '=https' --tlsv1.2 -sSfL https://run.linkerd.io/install | sh
export PATH=$PATH:$HOME/.linkerd2/bin

linkerd check --pre
linkerd install --crds | kubectl apply -f -
linkerd install | kubectl apply -f -
linkerd check

# Inject into a namespace
kubectl annotate namespace production linkerd.io/inject=enabled

# Viz extension (metrics UI)
linkerd viz install | kubectl apply -f -
linkerd viz dashboard &
```

### Linkerd vs Istio

| | Istio | Linkerd |
|-|-------|---------|
| **Resource overhead** | ~200MB/sidecar | ~10MB/sidecar |
| **Feature set** | Very rich | Focused |
| **mTLS** | Yes | Yes (automatic) |
| **L7 routing** | VirtualService/DR | SMI TrafficSplit |
| **gRPC** | Yes | Yes |
| **Learning curve** | High | Low |
| **No-sidecar mode** | Ambient mesh | Not available |

---

## Cilium Service Mesh (eBPF, no sidecar)

```bash
helm install cilium cilium/cilium \
  --set kubeProxyReplacement=strict \
  --set ingressController.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true
```

```yaml
# L7 policy (HTTP-aware NetworkPolicy)
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: api-policy
spec:
  endpointSelector:
    matchLabels:
      app: api
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
          path: /api/v1/.*
```

---

## When to Use a Service Mesh

**Use a service mesh when:**
- You need mTLS between all services (compliance requirement)
- You have polyglot services and can't implement retry/circuit-breaking in each
- You need canary deployments without application changes
- You need detailed per-service observability

**Don't use a service mesh when:**
- You have a small, simple cluster (overhead not worth it)
- All services are in one language with good library support
- You're just starting out — solve the basics first

---

## SRE Lens

- **Start with PERMISSIVE mTLS** and migrate to STRICT once you've verified all services work — don't flip to STRICT in prod all at once.
- **Sidecar injection failures silently break things** — if injection webhook is down, pods start without a sidecar and traffic bypasses policies.
- **Ambient mesh reduces overhead significantly** — for Istio users, migrate to ambient to eliminate per-pod sidecar memory overhead.
- **`istioctl analyze`** catches most config mistakes before they cause incidents.

---

## Resources

| Type | Link |
|------|------|
| Official Docs | [Istio](https://istio.io/latest/docs/) |
| Official Docs | [Linkerd](https://linkerd.io/docs/) |
| Official Docs | [Cilium Service Mesh](https://docs.cilium.io/en/stable/network/servicemesh/) |
| Tool | [Kiali](https://kiali.io/docs/) |
| Blog | [Istio Ambient Mesh](https://istio.io/latest/blog/2022/introducing-ambient-mesh/) |
| Blog | [Service Mesh Comparison (CNCF)](https://www.cncf.io/blog/2021/07/06/a-practical-guide-to-the-service-mesh-landscape/) |
