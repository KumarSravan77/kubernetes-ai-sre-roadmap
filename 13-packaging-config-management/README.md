# 13 — Packaging & Config Management

Helm and Kustomize are the two dominant tools for managing Kubernetes manifests at scale. Know both.

---

## Helm

Helm is the Kubernetes package manager. A **chart** is a collection of templates that render Kubernetes manifests.

### Core Concepts

```
Chart         = package (templates + values + metadata)
Release       = installed instance of a chart in a cluster
Repository    = collection of charts (OCI or HTTP)
Values        = user-provided overrides for a chart
```

### Install Helm

```bash
brew install helm
helm version
```

### Working with Charts

```bash
# Add a repository
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# Search for charts
helm search repo bitnami/postgresql
helm search hub grafana   # searches Artifact Hub

# Install a chart
helm install my-postgres bitnami/postgresql \
  --namespace databases --create-namespace \
  --set auth.postgresPassword=secret \
  --set primary.persistence.size=20Gi

# Install with a values file
helm install my-postgres bitnami/postgresql \
  --namespace databases \
  -f values-production.yaml

# Upgrade a release
helm upgrade my-postgres bitnami/postgresql \
  -f values-production.yaml \
  --set image.tag=16.2.0

# Upgrade or install (idempotent)
helm upgrade --install my-postgres bitnami/postgresql \
  -f values-production.yaml

# Rollback
helm rollback my-postgres 1   # rollback to revision 1

# Uninstall
helm uninstall my-postgres -n databases
```

```bash
# Inspect a release
helm list -A
helm status my-postgres -n databases
helm history my-postgres -n databases
helm get values my-postgres -n databases      # installed values
helm get manifest my-postgres -n databases    # rendered manifests
```

---

## Creating a Chart

```bash
helm create my-app
```

This generates:

```
my-app/
├── Chart.yaml          ← chart metadata
├── values.yaml         ← default values
├── templates/
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── serviceaccount.yaml
│   ├── hpa.yaml
│   ├── _helpers.tpl    ← named template functions
│   └── NOTES.txt       ← post-install instructions
└── charts/             ← chart dependencies
```

### Chart.yaml

```yaml
apiVersion: v2
name: my-app
description: A Helm chart for my application
type: application          # or library
version: 1.2.3             # chart version (semver)
appVersion: "2.5.1"        # app version (informational)
dependencies:
- name: postgresql
  version: "13.x.x"
  repository: https://charts.bitnami.com/bitnami
  condition: postgresql.enabled
```

### values.yaml

```yaml
replicaCount: 2

image:
  repository: myorg/my-app
  tag: ""             # defaults to Chart.appVersion
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: 80

ingress:
  enabled: false
  className: nginx
  hosts:
  - host: app.example.com
    paths:
    - path: /
      pathType: Prefix

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi

autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 70

postgresql:
  enabled: true
  auth:
    database: myapp
```

### Template example

```yaml
# templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "my-app.fullname" . }}
  labels:
    {{- include "my-app.labels" . | nindent 4 }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "my-app.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "my-app.selectorLabels" . | nindent 8 }}
    spec:
      containers:
      - name: {{ .Chart.Name }}
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        ports:
        - containerPort: 8080
        resources:
          {{- toYaml .Values.resources | nindent 10 }}
        {{- with .Values.env }}
        env:
          {{- toYaml . | nindent 10 }}
        {{- end }}
```

### _helpers.tpl

```yaml
{{/*
Expand the name of the chart.
*/}}
{{- define "my-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "my-app.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "my-app.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "my-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
```

### Helm Hooks

```yaml
# Run a database migration before upgrade
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ .Release.Name }}-migrate
  annotations:
    "helm.sh/hook": pre-upgrade,pre-install
    "helm.sh/hook-weight": "-5"
    "helm.sh/hook-delete-policy": hook-succeeded
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: migrate
        image: myorg/migrate:{{ .Chart.AppVersion }}
        command: ["/migrate", "--run"]
```

### Testing a Chart

```bash
helm lint my-app/                              # lint
helm template my-app/ -f values-prod.yaml      # render without installing
helm template my-app/ | kubeval               # validate against K8s schema
helm template my-app/ | kubeconform -         # modern schema validator

# Install and run tests
helm install test-release my-app/ --dry-run
helm test test-release
```

---

## Kustomize

Kustomize uses overlays (plain YAML patches) instead of templates. No templating language — just YAML.

### Structure

```
base/
├── kustomization.yaml
├── deployment.yaml
└── service.yaml

overlays/
├── development/
│   ├── kustomization.yaml   ← references base + dev-specific patches
│   └── replica-patch.yaml
├── staging/
│   ├── kustomization.yaml
│   └── config-patch.yaml
└── production/
    ├── kustomization.yaml
    ├── hpa.yaml
    └── resources-patch.yaml
```

### Base kustomization.yaml

```yaml
# base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- deployment.yaml
- service.yaml

commonLabels:
  app: my-app

images:
- name: my-app
  newName: myorg/my-app
  newTag: latest
```

### Production overlay

```yaml
# overlays/production/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: production

bases:
- ../../base

resources:
- hpa.yaml
- networkpolicy.yaml

patches:
# Strategic merge patch
- path: resources-patch.yaml

# Inline JSON 6902 patch
- target:
    kind: Deployment
    name: my-app
  patch: |
    - op: replace
      path: /spec/replicas
      value: 5
    - op: add
      path: /spec/template/spec/containers/0/env/-
      value:
        name: ENVIRONMENT
        value: production

images:
- name: my-app
  newName: myorg/my-app
  newTag: v1.2.3        # pin to specific version in production

configMapGenerator:
- name: app-config
  literals:
  - LOG_LEVEL=warning
  - FEATURE_FLAG=enabled

secretGenerator:
- name: db-password
  envs:
  - .env.production
```

### Strategic Merge Patch

```yaml
# overlays/production/resources-patch.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app   # must match
spec:
  template:
    spec:
      containers:
      - name: app
        resources:
          requests:
            cpu: 500m
            memory: 512Mi
          limits:
            cpu: 2000m
            memory: 1Gi
```

### Apply Kustomize

```bash
# Preview
kubectl kustomize overlays/production/

# Apply
kubectl apply -k overlays/production/

# With ArgoCD (in Application spec)
source:
  repoURL: https://github.com/myorg/k8s-manifests
  path: overlays/production
```

---

## Helm vs Kustomize

| | Helm | Kustomize |
|-|------|-----------|
| **Templating** | Go templates | None (patches only) |
| **Values** | Typed values.yaml | Overlays |
| **Packaging** | OCI/HTTP charts | Git-native |
| **Versioning** | Chart version | Git commit |
| **Dependencies** | Built-in | Manual composition |
| **Learning curve** | Higher | Lower |
| **Best for** | Reusable packages | Environment overlays |

**In practice:** Use Helm for third-party software (Prometheus, Cert-Manager), Kustomize for your own app overlays.

---

## Schema Validation

```bash
# kubeconform — fast, built-in schema support
brew install kubeconform
helm template my-app/ | kubeconform -strict -
kubectl kustomize overlays/prod/ | kubeconform -strict -

# With CRD schemas
kubeconform -strict -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  manifests/
```

---

## SRE Lens

- **Pin chart versions** — never use `helm upgrade` without specifying a chart version in production.
- **Values in Git** — keep `values-production.yaml` in Git, not passed via `--set` flags in CI. Reviewable, auditable.
- **Helm history is your rollback** — `helm rollback` is faster than re-running CI. Use it for hot fixes.
- **`helm diff` before upgrade** — `helm plugin install https://github.com/databus23/helm-diff` shows you exactly what will change.

---

## Resources

| Type | Link |
|------|------|
| Official Docs | [Helm Documentation](https://helm.sh/docs/) |
| Official Docs | [Kustomize](https://kustomize.io/) |
| Tool | [Artifact Hub](https://artifacthub.io/) |
| Tool | [kubeconform](https://github.com/yannh/kubeconform) |
| Tool | [helm-diff plugin](https://github.com/databus23/helm-diff) |
| Blog | [Helm vs Kustomize (Codefresh)](https://codefresh.io/blog/helm-vs-kustomize/) |
