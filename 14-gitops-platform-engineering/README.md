# 14 — GitOps & Platform Engineering

GitOps makes Git the single source of truth for cluster state. Platform Engineering builds self-service infrastructure on top of Kubernetes.

---

## GitOps Principles

GitOps (OpenGitOps) has four core principles:

1. **Declarative** — desired state is expressed declaratively
2. **Versioned and immutable** — desired state stored in Git (immutable history)
3. **Pulled automatically** — software agents pull and apply desired state
4. **Continuously reconciled** — agents continuously ensure actual state matches desired state

```
Developer pushes to Git
      │
      ▼
GitOps controller (ArgoCD/Flux) detects change
      │
      ▼
Controller applies changes to cluster
      │
      ▼
If cluster drifts → controller reconciles back to Git state
```

---

## ArgoCD

ArgoCD is a declarative GitOps controller for Kubernetes.

### Install

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Access UI
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Get initial admin password
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d

# Install argocd CLI
brew install argocd
argocd login localhost:8080
```

### Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io  # cascade delete on app removal
spec:
  project: default

  source:
    repoURL: https://github.com/myorg/k8s-manifests
    targetRevision: HEAD   # or a branch, tag, or commit SHA
    path: overlays/production

    # For Helm charts
    # chart: my-app
    # helm:
    #   valueFiles: [values-production.yaml]
    #   parameters:
    #   - name: image.tag
    #     value: v1.2.3

    # For Kustomize (auto-detected)
    # kustomize:
    #   images: [myorg/my-app:v1.2.3]

  destination:
    server: https://kubernetes.default.svc
    namespace: production

  syncPolicy:
    automated:
      prune: true           # delete resources removed from Git
      selfHeal: true        # reconcile if cluster drifts
      allowEmpty: false     # don't delete everything if source is empty
    syncOptions:
    - CreateNamespace=true
    - PrunePropagationPolicy=foreground
    - ApplyOutOfSyncOnly=true   # only apply changed resources
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

### App of Apps Pattern

```yaml
# Root application manages all other applications
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/myorg/k8s-manifests
    path: argocd/applications    # contains ArgoCD Application manifests
    targetRevision: HEAD
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### ApplicationSet

ApplicationSets generate Applications from a template and a generator:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: cluster-apps
  namespace: argocd
spec:
  generators:
  # Deploy the same app to multiple clusters
  - clusters:
      selector:
        matchLabels:
          environment: production

  # Deploy all apps in a directory
  - git:
      repoURL: https://github.com/myorg/k8s-manifests
      revision: HEAD
      directories:
      - path: apps/*

  # Matrix generator — all combinations
  - matrix:
      generators:
      - list:
          elements:
          - cluster: us-east-1
          - cluster: eu-west-1
      - list:
          elements:
          - app: frontend
          - app: backend

  template:
    metadata:
      name: '{{cluster}}-{{app}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/myorg/k8s-manifests
        targetRevision: HEAD
        path: 'apps/{{app}}'
      destination:
        name: '{{cluster}}'
        namespace: '{{app}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
```

### ArgoCD Projects

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: team-a
  namespace: argocd
spec:
  description: Team A applications
  sourceRepos:
  - https://github.com/myorg/team-a-manifests
  - https://charts.bitnami.com/bitnami

  destinations:
  - namespace: team-a-*
    server: https://kubernetes.default.svc

  clusterResourceWhitelist: []   # no cluster-scoped resources
  namespaceResourceWhitelist:
  - group: apps
    kind: Deployment
  - group: ""
    kind: Service

  roles:
  - name: developer
    policies:
    - p, proj:team-a:developer, applications, get, team-a/*, allow
    - p, proj:team-a:developer, applications, sync, team-a/*, allow
    groups:
    - team-a-developers
```

### ArgoCD CLI

```bash
# App management
argocd app list
argocd app get my-app
argocd app sync my-app
argocd app sync my-app --prune
argocd app diff my-app
argocd app history my-app
argocd app rollback my-app 3

# Manual sync with specific revision
argocd app set my-app --revision v1.2.3
argocd app sync my-app
```

---

## Flux

Flux is a CNCF project that implements GitOps with a different model: multiple focused controllers instead of one central UI.

### Install

```bash
brew install fluxcd/tap/flux
flux install

# Bootstrap with GitHub
flux bootstrap github \
  --owner=myorg \
  --repository=k8s-fleet \
  --branch=main \
  --path=clusters/production \
  --personal
```

### GitRepository Source

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: my-manifests
  namespace: flux-system
spec:
  interval: 1m
  url: https://github.com/myorg/k8s-manifests
  ref:
    branch: main
  secretRef:
    name: git-credentials
```

### Kustomization

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: my-app
  namespace: flux-system
spec:
  interval: 10m
  path: ./overlays/production
  sourceRef:
    kind: GitRepository
    name: my-manifests
  prune: true
  wait: true
  timeout: 5m
  healthChecks:
  - apiVersion: apps/v1
    kind: Deployment
    name: my-app
    namespace: production
```

### HelmRelease

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: prometheus-community
  namespace: flux-system
spec:
  interval: 1h
  url: https://prometheus-community.github.io/helm-charts
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: kube-prometheus-stack
  namespace: flux-system
spec:
  interval: 1h
  chart:
    spec:
      chart: kube-prometheus-stack
      version: ">=56.0.0 <57.0.0"
      sourceRef:
        kind: HelmRepository
        name: prometheus-community
  targetNamespace: monitoring
  install:
    createNamespace: true
  upgrade:
    cleanupOnFail: true
  rollback:
    timeout: 10m
  values:
    grafana:
      adminPassword: "${GRAFANA_PASSWORD}"
```

---

## ArgoCD vs Flux

| | ArgoCD | Flux |
|-|--------|------|
| **UI** | Rich web UI | CLI + Grafana dashboards |
| **Multi-tenancy** | AppProjects + RBAC | GitRepository per team |
| **Multi-cluster** | Native | Built-in |
| **Progressive delivery** | Argo Rollouts integration | Flagger integration |
| **Secret management** | Plugin | SOPS/ESO native |
| **Complexity** | Single component | Multiple controllers |
| **Community** | Larger | Growing (CNCF graduated) |

---

## Platform Engineering

### What is it?

Platform Engineering builds internal platforms that make developers self-sufficient — they don't need SRE/ops involvement for routine tasks.

```
Before:  Developer → files ticket → SRE creates namespace, RBAC, CI → 3 days
After:   Developer → runs template → platform provisions automatically → 5 minutes
```

### Internal Developer Platform (IDP) Stack

```
Backstage (developer portal)
  └── Software Catalog      (all services in one place)
  └── Scaffolder Templates  (golden paths for new services)
  └── TechDocs             (living documentation)
  └── Plugins               (Kubernetes, ArgoCD, PagerDuty views)

Crossplane (infrastructure GitOps)
  └── Composite Resources  (abstract over cloud APIs)
  └── Providers            (AWS, GCP, Azure, Helm)

ArgoCD / Flux (GitOps delivery)
Kyverno (policy enforcement)
```

### Backstage Quick Start

```bash
npx @backstage/create-app@latest
cd my-backstage-app
yarn dev
```

### Backstage Software Template

```yaml
# template.yaml — creates a new service with all the boilerplate
apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata:
  name: new-microservice
  title: New Microservice
  description: Creates a new Go microservice with CI/CD
spec:
  owner: platform-team
  type: service

  parameters:
  - title: Service Details
    required: [name, owner, description]
    properties:
      name:
        type: string
        pattern: '^[a-z][a-z0-9-]*$'
      owner:
        type: string
        ui:field: OwnerPicker
      description:
        type: string

  steps:
  - id: fetch-template
    name: Fetch Template
    action: fetch:template
    input:
      url: ./skeleton
      values:
        name: ${{ parameters.name }}
        owner: ${{ parameters.owner }}

  - id: publish
    name: Create GitHub Repository
    action: publish:github
    input:
      repoUrl: github.com?repo=${{ parameters.name }}&owner=myorg
      defaultBranch: main

  - id: create-argocd-app
    name: Register in ArgoCD
    action: argocd:create-application
    input:
      appName: ${{ parameters.name }}
      argoInstance: production

  output:
    links:
    - title: Repository
      url: ${{ steps.publish.output.remoteUrl }}
```

### Crossplane Infrastructure GitOps

```yaml
# XRD — define your infrastructure abstraction
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xpostgresqlinstances.example.com
spec:
  group: example.com
  names:
    kind: XPostgreSQLInstance
    plural: xpostgresqlinstances
  claimNames:
    kind: PostgreSQLInstance
    plural: postgresqlinstances
  versions:
  - name: v1alpha1
    served: true
    referenceable: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              parameters:
                type: object
                properties:
                  storageGB:
                    type: integer
                  version:
                    type: string
                    enum: ["14", "15", "16"]
---
# Composition — maps XRD to real cloud resources
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: xpostgresqlinstances.aws.example.com
spec:
  compositeTypeRef:
    apiVersion: example.com/v1alpha1
    kind: XPostgreSQLInstance
  resources:
  - name: rdsinstance
    base:
      apiVersion: rds.aws.upbound.io/v1beta1
      kind: Instance
      spec:
        forProvider:
          region: us-east-1
          instanceClass: db.t3.micro
          engine: postgres
          skipFinalSnapshot: true
    patches:
    - fromFieldPath: spec.parameters.storageGB
      toFieldPath: spec.forProvider.allocatedStorage
    - fromFieldPath: spec.parameters.version
      toFieldPath: spec.forProvider.engineVersion
---
# Claim — what the developer creates
apiVersion: example.com/v1alpha1
kind: PostgreSQLInstance
metadata:
  name: my-app-db
  namespace: production
spec:
  parameters:
    storageGB: 20
    version: "16"
  writeConnectionSecretToRef:
    name: my-app-db-credentials
```

---

## SRE Lens

- **Self-heal + prune** — enable both in ArgoCD. Without prune, deleted resources in Git remain in the cluster forever.
- **GitOps doesn't mean no CI** — CI validates and builds. GitOps deploys. Don't conflate the two.
- **ApplicationSets scale GitOps** — when you have 50+ apps, hand-crafting Application objects is painful. ApplicationSets generate them.
- **Platform teams reduce toil** — the best platform removes 80% of routine ops tickets without requiring ticket filing.

---

## Resources

| Type | Link |
|------|------|
| Official Docs | [ArgoCD](https://argo-cd.readthedocs.io/en/stable/) |
| Official Docs | [Flux](https://fluxcd.io/docs/) |
| Official Docs | [Backstage](https://backstage.io/docs/) |
| Official Docs | [Crossplane](https://docs.crossplane.io/) |
| Standard | [OpenGitOps Principles](https://opengitops.dev/) |
| Book | *Platform Engineering on Kubernetes* (Manning) |
| Blog | [ArgoCD Best Practices](https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/) |
