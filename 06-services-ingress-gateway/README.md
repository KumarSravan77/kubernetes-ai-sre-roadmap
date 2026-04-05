# 06 — Services, Ingress & Gateway API

Services provide stable network endpoints for Pods. Ingress and Gateway API route external traffic into the cluster.

---

## Services

A Service gives a stable DNS name and IP to a set of Pods selected by a label selector. It abstracts away Pod churn (Pods come and go, the Service stays).

### ClusterIP (default)

Accessible only within the cluster.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
spec:
  type: ClusterIP
  selector:
    app: my-app
  ports:
  - name: http
    port: 80          # Service port (what clients use)
    targetPort: 8080  # Container port (what the Pod listens on)
    protocol: TCP
```

```bash
# From any pod in the cluster:
curl http://my-app.default.svc.cluster.local
curl http://my-app  # (works within same namespace)
```

### NodePort

Opens a port (30000–32767) on every node. External traffic → NodeIP:NodePort → Service → Pod.

```yaml
spec:
  type: NodePort
  ports:
  - port: 80
    targetPort: 8080
    nodePort: 30080   # optional: auto-assigned if omitted
```

```bash
curl http://<any-node-ip>:30080
```

### LoadBalancer

Provisions a cloud load balancer (ELB, GCE LB, Azure LB). Includes NodePort and ClusterIP.

```yaml
spec:
  type: LoadBalancer
  ports:
  - port: 443
    targetPort: 8443
  loadBalancerSourceRanges:
  - 203.0.113.0/24   # restrict to your IPs
```

```bash
kubectl get svc my-app
# EXTERNAL-IP column shows the provisioned LB IP/hostname
```

### ExternalName

Maps a Service to a DNS name (CNAME). No selector, no proxying.

```yaml
spec:
  type: ExternalName
  externalName: my-database.rds.amazonaws.com
```

### Headless Service

Set `clusterIP: None`. DNS returns Pod IPs directly instead of a single ClusterIP. Used with StatefulSets.

```yaml
spec:
  clusterIP: None
  selector:
    app: postgres
```

```bash
# Returns all pod IPs
dig my-svc.default.svc.cluster.local
# Returns: 10.244.0.5, 10.244.1.3, 10.244.2.7

# For StatefulSets, individual pod DNS:
# postgres-0.postgres-headless.default.svc.cluster.local
```

---

## EndpointSlices

EndpointSlices replaced Endpoints for scalability. Each slice holds up to 100 endpoints.

```bash
kubectl get endpointslices -n default
kubectl describe endpointslice my-app-abc12
```

---

## Session Affinity

```yaml
spec:
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 3600
```

---

## Topology-Aware Routing (1.21+)

Route traffic to Pods in the same zone first (reduces cross-zone traffic costs).

```yaml
metadata:
  annotations:
    service.kubernetes.io/topology-mode: auto
```

---

## Ingress

Ingress is an L7 (HTTP/HTTPS) routing rule. It requires an Ingress Controller to implement it.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - app.example.com
    secretName: app-tls-cert
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: api-service
            port:
              number: 80
      - path: /
        pathType: Prefix
        backend:
          service:
            name: frontend-service
            port:
              number: 80
```

### Path types

| Type | Behavior |
|------|---------|
| `Exact` | Exact match only |
| `Prefix` | Prefix match on `/`-separated path segments |
| `ImplementationSpecific` | Ingress controller defines behavior |

### Common Ingress Controllers

| Controller | Helm chart |
|-----------|------------|
| NGINX | `ingress-nginx/ingress-nginx` |
| Traefik | `traefik/traefik` |
| HAProxy | `haproxytech/kubernetes-ingress` |
| AWS ALB | `aws/aws-load-balancer-controller` |

```bash
# Install ingress-nginx
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.replicaCount=2

kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx
```

---

## TLS with cert-manager

```bash
# Install cert-manager
helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set installCRDs=true
```

```yaml
# ClusterIssuer using Let's Encrypt
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
---
# Certificate
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: app-tls
  namespace: default
spec:
  secretName: app-tls-cert
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - app.example.com
  - www.example.com
```

```yaml
# Auto-issue via Ingress annotation (simpler)
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  tls:
  - hosts: [app.example.com]
    secretName: app-tls-cert   # cert-manager creates this
```

---

## Gateway API

Gateway API is the next generation of Ingress. It's more expressive, role-oriented, and supports more protocols.

### Resources

| Resource | Role |
|----------|------|
| `GatewayClass` | Defines a class of Gateways (e.g., nginx, istio) — cluster-scoped |
| `Gateway` | Listens on specific ports/protocols — namespace-scoped |
| `HTTPRoute` | Routes HTTP traffic to backends |
| `TCPRoute` | Routes TCP traffic |
| `TLSRoute` | Routes TLS SNI traffic |
| `GRPCRoute` | Routes gRPC traffic (1.28+ stable) |

```yaml
# GatewayClass (created by controller, not usually by users)
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: nginx
spec:
  controllerName: k8s.nginx.org/nginx-gateway-controller
---
# Gateway
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: prod-gateway
  namespace: infra
spec:
  gatewayClassName: nginx
  listeners:
  - name: https
    protocol: HTTPS
    port: 443
    tls:
      mode: Terminate
      certificateRefs:
      - name: app-tls-cert
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            gateway: prod
---
# HTTPRoute (in app namespace)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app-route
  namespace: default
  labels:
    gateway: prod
spec:
  parentRefs:
  - name: prod-gateway
    namespace: infra
    sectionName: https
  hostnames:
  - app.example.com
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /api
    backendRefs:
    - name: api-service
      port: 80
      weight: 100

  # Traffic splitting (canary)
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: frontend-v1
      port: 80
      weight: 90
    - name: frontend-v2
      port: 80
      weight: 10
```

### Why Gateway API over Ingress?

| Feature | Ingress | Gateway API |
|---------|---------|-------------|
| Multi-team support | Annotations only | Native role separation |
| Traffic splitting | Controller-specific | Native |
| TCP/UDP routing | Not supported | Supported |
| gRPC routing | Not supported | Supported (GRPCRoute) |
| Header manipulation | Annotations | Native HTTPRoute filters |
| Portability | Controller-specific annotations | Standardized |

---

## gRPC Load Balancing

gRPC uses HTTP/2 which multiplexes requests over a single TCP connection. Standard round-robin Service load balancing doesn't work — all traffic goes to one Pod.

Solutions:
1. **Headless Service + client-side load balancing** (grpc-go built-in)
2. **Service Mesh** (Istio, Linkerd) — handles gRPC transparently
3. **Ingress with gRPC support** (nginx with `grpc_pass`)
4. **Gateway API GRPCRoute** (1.28+)

```yaml
# nginx Ingress for gRPC
metadata:
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: GRPC
```

---

## Debugging Services

```bash
# Does the Service have healthy endpoints?
kubectl get endpoints my-svc
kubectl describe svc my-svc

# Test ClusterIP from a Pod
kubectl exec -it debug-pod -- curl http://my-svc.default.svc.cluster.local:80

# Test NodePort directly
curl http://<node-ip>:30080

# Check iptables rules for service
iptables -t nat -L | grep <service-clusterip>

# Check LoadBalancer events
kubectl describe svc my-lb-svc | grep -A 10 Events

# Common issues:
# Endpoints empty → selector doesn't match any pod labels
# Connection refused → targetPort wrong, app not listening
# No external IP → cloud LB provisioning failed (check cloud provider events)
```

---

## SRE Lens

- **Empty Endpoints = no traffic** — always verify `kubectl get endpoints <svc-name>` when a service is unreachable. Label mismatch between Deployment and Service selector is a common bug.
- **LoadBalancer Services cost money** — each one provisions a cloud LB. Use a single Ingress or Gateway instead of many LoadBalancer Services.
- **Gateway API > Ingress** — for new clusters, start with Gateway API. Ingress is effectively in maintenance mode.
- **cert-manager automates TLS** — never manually manage TLS certificates in Kubernetes.

---

## Resources

| Type | Link |
|------|------|
| Official Docs | [Services](https://kubernetes.io/docs/concepts/services-networking/service/) |
| Official Docs | [Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/) |
| Official Docs | [Gateway API](https://gateway-api.sigs.k8s.io/) |
| Tool | [cert-manager](https://cert-manager.io/docs/) |
| Tool | [ingress-nginx](https://kubernetes.github.io/ingress-nginx/) |
| Tool | [NGINX Gateway Fabric](https://docs.nginx.com/nginx-gateway-fabric/) |
| Blog | [Gateway API vs Ingress](https://gateway-api.sigs.k8s.io/concepts/api-overview/) |
