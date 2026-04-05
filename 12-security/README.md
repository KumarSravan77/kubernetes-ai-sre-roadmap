# 12 — Security

Kubernetes security is layered. This section covers the full attack surface from cluster access to runtime threats.

---

## Security Layers

```
Supply Chain          ← Are images trusted? Any vulnerable packages?
Cluster Access        ← Who can reach the API server?
Authentication        ← Who are you?
Authorization (RBAC)  ← What can you do?
Admission Control     ← Does this meet our policies?
Pod Security          ← What can this container do on the host?
Network               ← Who can this pod talk to?
Runtime               ← Is something behaving unexpectedly?
Data                  ← Are secrets encrypted? Are volumes protected?
```

---

## RBAC

Role-Based Access Control is the authorization system for Kubernetes.

### Core objects

```
Role            — grants permissions within a namespace
ClusterRole     — grants permissions cluster-wide (or reusable across namespaces)
RoleBinding     — binds a Role or ClusterRole to subjects within a namespace
ClusterRoleBinding — binds a ClusterRole to subjects cluster-wide
```

### Subject types

```
User            — authenticated human (from cert CN or OIDC token)
Group           — set of users (from cert O or OIDC groups claim)
ServiceAccount  — identity for Pods
```

### Role example

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: production
rules:
- apiGroups: [""]               # "" = core API group
  resources: ["pods", "pods/log"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch", "update", "patch"]
- apiGroups: [""]
  resources: ["pods/exec"]
  verbs: ["create"]             # allows kubectl exec
```

### ClusterRole example

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: node-reader
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "watch"]
- nonResourceURLs: ["/metrics", "/healthz"]
  verbs: ["get"]
```

### Binding

```yaml
# RoleBinding — user gets Role in one namespace
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jane-pod-reader
  namespace: production
subjects:
- kind: User
  name: jane@example.com
  apiGroup: rbac.authorization.k8s.io
- kind: Group
  name: sre-team
  apiGroup: rbac.authorization.k8s.io
- kind: ServiceAccount
  name: my-app-sa
  namespace: production
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

### Aggregated ClusterRoles

```yaml
# Add rules to "view" ClusterRole via aggregation
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: my-crd-viewer
  labels:
    rbac.authorization.k8s.io/aggregate-to-view: "true"
rules:
- apiGroups: ["example.com"]
  resources: ["databases"]
  verbs: ["get", "list", "watch"]
```

### RBAC Debugging

```bash
kubectl auth can-i list pods -n production
kubectl auth can-i '*' '*'   # cluster-admin?
kubectl auth can-i list pods --as=system:serviceaccount:production:my-sa -n production

# Who can do what?
kubectl who-can list secrets -n production   # kubectl-who-can plugin

# Check RoleBindings for a user/SA
kubectl get rolebindings,clusterrolebindings -A \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,SUBJECTS:.subjects[*].name' | \
  grep my-sa

# View effective permissions
kubectl auth reconcile -f rbac.yaml --dry-run=client
```

---

## ServiceAccount Best Practices

```yaml
# Minimal ServiceAccount with no automount
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-app-sa
  namespace: production
automountServiceAccountToken: false   # opt-in, not opt-out
---
# Pod uses the SA
spec:
  serviceAccountName: my-app-sa
  automountServiceAccountToken: false  # belt-and-suspenders
```

```yaml
# Bound Service Account Token (projected, short-lived, audience-scoped)
volumes:
- name: sa-token
  projected:
    sources:
    - serviceAccountToken:
        path: token
        expirationSeconds: 3600
        audience: vault          # only accepted by vault
```

---

## Pod Security Standards (PSS)

PSS defines three security levels for Pods:

| Level | Description |
|-------|-------------|
| `privileged` | Unrestricted (used by CNI, storage drivers) |
| `baseline` | Minimal restrictions; prevents obvious escalations |
| `restricted` | Best practices; most hardened |

### Pod Security Admission (PSA)

```yaml
# Label a namespace to enforce Restricted
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.28
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted
```

```bash
# Check what would fail in restricted mode
kubectl label --dry-run=server --overwrite namespace production \
  pod-security.kubernetes.io/enforce=restricted
```

### What Restricted requires

```yaml
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000       # must not be 0
    seccompProfile:
      type: RuntimeDefault
  containers:
  - securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: [ALL]
        add: []             # no added capabilities allowed in Restricted
```

---

## OPA/Gatekeeper and Kyverno

### Kyverno (simpler, no Rego)

```bash
helm install kyverno kyverno/kyverno -n kyverno --create-namespace
```

```yaml
# Block latest tag
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-tag
spec:
  validationFailureAction: Enforce   # or Audit
  rules:
  - name: require-image-tag
    match:
      resources:
        kinds: [Pod]
    validate:
      message: "Image tag 'latest' is not allowed. Use a specific version tag."
      pattern:
        spec:
          containers:
          - image: "!*:latest"
          initContainers:
          - image: "!*:latest"

---
# Auto-add labels
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-labels
spec:
  rules:
  - name: add-team-label
    match:
      resources:
        kinds: [Namespace]
    mutate:
      patchStrategicMerge:
        metadata:
          labels:
            +(managed-by): platform-team

---
# Require resource limits
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-limits
spec:
  validationFailureAction: Enforce
  rules:
  - name: check-container-resources
    match:
      resources:
        kinds: [Pod]
    validate:
      message: "Resource limits are required."
      pattern:
        spec:
          containers:
          - resources:
              limits:
                cpu: "?*"
                memory: "?*"
```

### OPA/Gatekeeper (Rego)

```yaml
# ConstraintTemplate
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8srequiredlabels
spec:
  crd:
    spec:
      names:
        kind: K8sRequiredLabels
      validation:
        openAPIV3Schema:
          type: object
          properties:
            labels:
              type: array
              items:
                type: string
  targets:
  - target: admission.k8s.gatekeeper.sh
    rego: |
      package k8srequiredlabels
      violation[{"msg": msg}] {
        provided := {label | input.review.object.metadata.labels[label]}
        required := {label | label := input.parameters.labels[_]}
        missing := required - provided
        count(missing) > 0
        msg := sprintf("Missing required labels: %v", [missing])
      }
---
# Constraint (uses the template)
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sRequiredLabels
metadata:
  name: require-team-label
spec:
  match:
    kinds:
    - apiGroups: [""]
      kinds: [Namespace]
  parameters:
    labels: [team, environment]
```

---

## Container Security Context

```yaml
spec:
  securityContext:
    # Pod-level
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 3000
    fsGroup: 2000
    fsGroupChangePolicy: OnRootMismatch  # faster than Always
    seccompProfile:
      type: RuntimeDefault   # or Localhost with custom profile
    sysctls:                 # privileged namespaces only
    - name: net.core.somaxconn
      value: "1024"
  containers:
  - name: app
    securityContext:
      # Container-level
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: [ALL]
        add: [NET_BIND_SERVICE]  # allow binding port <1024
      seccompProfile:
        type: RuntimeDefault
```

---

## Image Security

### Image Scanning

```bash
# Trivy — scan image for CVEs
trivy image nginx:latest
trivy image --severity HIGH,CRITICAL nginx:latest
trivy image --ignore-unfixed nginx:latest

# Scan a cluster
trivy k8s --report summary cluster

# In CI (fail on HIGH/CRITICAL)
trivy image --exit-code 1 --severity HIGH,CRITICAL myapp:latest
```

### Image Signing with Cosign

```bash
# Sign an image (OIDC keyless — no key management)
cosign sign --yes ghcr.io/myorg/myapp:v1.2.3

# Verify signature
cosign verify --certificate-oidc-issuer=https://accounts.google.com \
  --certificate-identity=ci@myorg.iam.gserviceaccount.com \
  ghcr.io/myorg/myapp:v1.2.3

# Policy Admission: enforce signed images with Kyverno
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature
spec:
  rules:
  - name: check-image-signature
    match:
      resources:
        kinds: [Pod]
    verifyImages:
    - image: "ghcr.io/myorg/*"
      attestors:
      - entries:
        - keyless:
            subject: "https://github.com/myorg/*"
            issuer: "https://token.actions.githubusercontent.com"
```

---

## Runtime Security with Falco

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm install falco falcosecurity/falco \
  --namespace falco --create-namespace \
  --set driver.kind=ebpf \
  --set falcosidekick.enabled=true
```

```yaml
# Custom Falco rules
- rule: Unexpected Shell in Container
  desc: A shell was spawned in a production container
  condition: >
    spawned_process and
    container and
    not container.image.repository in (allowed_images) and
    proc.name in (shell_binaries)
  output: >
    Shell spawned in container (user=%user.name container=%container.name
    image=%container.image.repository:%container.image.tag
    shell=%proc.name parent=%proc.pname)
  priority: WARNING
  tags: [container, shell]

- rule: Read Sensitive Files
  desc: Read access to sensitive files
  condition: >
    open_read and
    (fd.name in (sensitive_files) or
     fd.name startswith /etc/shadow or
     fd.name startswith /etc/kubernetes/pki)
  output: Sensitive file read (user=%user.name file=%fd.name container=%container.name)
  priority: ERROR
```

---

## CIS Benchmark

```bash
# kube-bench — runs CIS Kubernetes Benchmark
kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml
kubectl logs job/kube-bench

# Run specific checks
docker run --rm --pid=host \
  -v /:/host aquasec/kube-bench:latest \
  run --targets node

# Remediation script generated automatically
```

---

## Audit Logging

```yaml
# audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
# Log secret access at RequestResponse level
- level: RequestResponse
  resources:
  - group: ""
    resources: [secrets]

# Log Pod deletions
- level: Request
  verbs: [delete]
  resources:
  - group: ""
    resources: [pods]

# Log all changes in production namespace
- level: Metadata
  namespaces: [production]

# Skip noisy read operations
- level: None
  verbs: [get, list, watch]
  users: [system:kube-scheduler, system:kube-controller-manager]
```

---

## SRE Lens

- **RBAC: least privilege** — ServiceAccounts should only have the permissions they actually need. Audit quarterly.
- **Secrets encryption at rest is table stakes** — enable it on day one.
- **Falco alerts on shell access to containers** — in production, nobody should be `kubectl exec`-ing into a container. Alert on it.
- **Supply chain > runtime security** — it's easier to block a bad image at admission than to detect and respond to runtime exploits.
- **Admission webhooks are your last line of defense** — they catch what developers miss.

---

## Resources

| Type | Link |
|------|------|
| Official Docs | [RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/) |
| Official Docs | [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/) |
| Official Docs | [Audit Logging](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/) |
| Tool | [Falco](https://falco.org/docs/) |
| Tool | [Kyverno](https://kyverno.io/docs/) |
| Tool | [Trivy](https://aquasecurity.github.io/trivy/) |
| Tool | [Cosign/Sigstore](https://docs.sigstore.dev/) |
| Tool | [kube-bench](https://github.com/aquasecurity/kube-bench) |
| Guide | [NSA/CISA K8s Hardening Guide](https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF) |
| Book | *Hacking Kubernetes* — Rice & Martin (O'Reilly) |
