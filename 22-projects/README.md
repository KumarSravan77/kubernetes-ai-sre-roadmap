# 22 — Capstone Projects

Hands-on projects that tie together everything from this roadmap. Each project is designed to be built incrementally and to simulate real production work.

---

## Project 1 — Production EKS Cluster

**Covers:** Sections 01–16  
**Goal:** Build a production-grade EKS cluster from scratch with all the essentials.

### Architecture

```
EKS Cluster (us-east-1)
├── Karpenter (node provisioning — spot + on-demand)
├── Cilium (CNI + NetworkPolicy)
├── cert-manager (TLS automation)
├── ingress-nginx (HTTP routing)
├── ArgoCD (GitOps delivery)
├── kube-prometheus-stack (metrics + alerting)
├── Loki + Fluent Bit (logs)
├── Tempo + OTel Collector (traces)
├── External Secrets Operator (secrets from AWS SSM)
└── Kyverno (policy enforcement)
```

### Step-by-Step

```bash
# 1. Bootstrap EKS with eksctl
cat << 'EOF' > cluster.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: prod-cluster
  region: us-east-1
  version: "1.29"
iam:
  withOIDC: true
addons:
- name: vpc-cni
- name: coredns
- name: kube-proxy
- name: aws-ebs-csi-driver
EOF
eksctl create cluster -f cluster.yaml

# 2. Install Karpenter
helm install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version 0.35.0 --namespace karpenter --create-namespace \
  --set settings.clusterName=prod-cluster

# 3. Install Cilium (replace kube-proxy)
helm install cilium cilium/cilium \
  --namespace kube-system \
  --set kubeProxyReplacement=strict \
  --set hubble.relay.enabled=true

# 4. Install cert-manager
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set installCRDs=true

# 5. Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 6. Bootstrap all other components via ArgoCD App-of-Apps
# Push ArgoCD application manifests to Git, then:
kubectl apply -f argocd/root-application.yaml
```

### Milestones

```
□ Cluster running, nodes healthy
□ Karpenter provisioning spot nodes for test workloads
□ ArgoCD sync loop green
□ cert-manager issuing Let's Encrypt certificates
□ Prometheus scraping all system components
□ Grafana dashboards showing cluster health
□ Loki receiving logs from all namespaces
□ NetworkPolicy default-deny in production namespace
□ Kyverno blocking latest tags and requiring resource limits
□ ESO syncing secrets from AWS SSM
```

---

## Project 2 — Multi-Tenant SaaS Platform

**Covers:** Sections 08, 12–14  
**Goal:** Build a self-service tenant provisioning system using Crossplane + Backstage.

### Architecture

```
Developer → Backstage template → GitHub PR
                                     ↓
                               ArgoCD syncs
                                     ↓
                           Crossplane creates:
                             - Namespace
                             - ResourceQuota
                             - NetworkPolicy (default deny)
                             - RBAC (team Role + Binding)
                             - ServiceAccount
                             - ESO SecretStore
                             - ECR repository
```

### Backstage Template

```yaml
# template.yaml
apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata:
  name: provision-tenant
  title: Provision New Tenant Namespace
spec:
  parameters:
  - title: Tenant Details
    properties:
      name:
        type: string
        pattern: '^[a-z][a-z0-9-]*$'
      team:
        type: string
      cpu_limit:
        type: string
        default: "10"
      memory_limit:
        type: string
        default: "20Gi"

  steps:
  - id: fetch
    action: fetch:template
    input:
      url: ./tenant-skeleton
      values:
        name: ${{ parameters.name }}
        team: ${{ parameters.team }}
        cpu_limit: ${{ parameters.cpu_limit }}
        memory_limit: ${{ parameters.memory_limit }}

  - id: pr
    action: publish:github:pull-request
    input:
      repoUrl: github.com?repo=k8s-tenants&owner=myorg
      title: "Provision tenant: ${{ parameters.name }}"
      branchName: provision/${{ parameters.name }}
      description: "Auto-generated tenant provisioning PR"
```

### Crossplane Composition

```yaml
# xrd for tenant
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xtenants.platform.example.com
spec:
  group: platform.example.com
  names:
    kind: XTenant
  claimNames:
    kind: Tenant
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
              team: {type: string}
              cpuLimit: {type: string}
              memoryLimit: {type: string}
```

### Milestones

```
□ Backstage running with GitHub auth
□ Tenant template creates PR in k8s-tenants repo
□ ArgoCD watches k8s-tenants repo
□ Crossplane provisions namespace + RBAC on PR merge
□ Team can kubectl to their namespace with scoped RBAC
□ ResourceQuota enforced — team can't exceed allocation
□ Default-deny NetworkPolicy in every tenant namespace
```

---

## Project 3 — ML Training + Serving Pipeline

**Covers:** Section 19  
**Goal:** End-to-end ML pipeline from data to serving on Kubernetes.

### Architecture

```
S3 (raw data)
     ↓
Argo Workflow (data prep + training)
     ↓
MLflow (experiment tracking + model registry)
     ↓
KServe (model serving with autoscaling)
     ↓
Prometheus (serving latency + throughput)
     ↓
Grafana (ML metrics dashboard)
```

### Pipeline Definition

```python
# pipeline.py
from kfp import dsl, compiler

@dsl.component(base_image="python:3.11", packages_to_install=["pandas","scikit-learn"])
def train(data_path: str, model_output: dsl.Output[dsl.Model], accuracy: dsl.Output[dsl.Metrics]):
    import pandas as pd
    from sklearn.ensemble import GradientBoostingClassifier
    from sklearn.model_selection import train_test_split
    import joblib, json

    df = pd.read_csv(data_path)
    X, y = df.drop("label", axis=1), df["label"]
    X_train, X_test, y_train, y_test = train_test_split(X, y)
    model = GradientBoostingClassifier()
    model.fit(X_train, y_train)
    score = model.score(X_test, y_test)

    joblib.dump(model, model_output.path)
    accuracy.log_metric("accuracy", score)

@dsl.pipeline(name="train-and-deploy")
def pipeline(data_path: str):
    train_task = train(data_path=data_path)

compiler.Compiler().compile(pipeline, "pipeline.yaml")
```

### Milestones

```
□ Kubeflow Pipelines running
□ Training pipeline executes on GPU nodes
□ MLflow tracking experiments with metrics
□ Model promoted to registry on accuracy > 0.90
□ KServe InferenceService serving model
□ Canary: 10% traffic to new model version
□ Grafana dashboard: model accuracy, latency, throughput
□ Karpenter scales GPU nodes to 0 when idle
```

---

## Project 4 — AI-Driven Incident Response

**Covers:** Section 20  
**Goal:** Build an AI-powered incident response bot.

### Architecture

```
Prometheus (alert fires)
     ↓
Alertmanager (webhook)
     ↓
AI Alert Pipeline (Flask app)
  ├── Gather context (kubectl, Prometheus)
  ├── Analyze with Claude claude-opus-4-6
  └── Post to Slack with diagnosis + suggested fix
     ↓
Argo Events (auto-remediation for safe actions)
  └── Restart crashing pod → notify Slack
```

### Implementation Steps

```bash
# 1. Deploy the alert pipeline (from section 20)
kubectl apply -f ai-alert-pipeline/

# 2. Configure Alertmanager to send to pipeline
# Add webhook receiver pointing to ai-alert-pipeline svc

# 3. Add Argo Events for auto-remediation
kubectl apply -f argo-events/

# 4. Test end-to-end
# Break a deployment and watch the bot analyze + post to Slack
kubectl set image deployment/test-app app=nginx:nonexistent
```

### Milestones

```
□ Alert fires → Slack message within 2 minutes
□ Slack message includes root cause analysis
□ Slack message includes step-by-step remediation
□ CrashLoopBackOff auto-restarts deployment after AI approval
□ Bot correctly identifies OOMKill and suggests memory increase
□ Bot correctly identifies ImagePullBackOff and suggests credential fix
□ Anonymization working (no cluster names in LLM requests)
```

---

## Project 5 — Custom Database Lifecycle Operator

**Covers:** Section 17  
**Goal:** Build a production-grade Kubernetes Operator that manages database lifecycle.

### What it manages

```
DatabaseInstance CRD
├── Creates a StatefulSet (postgres/mysql)
├── Creates a Service (headless + regular)
├── Creates a NetworkPolicy (restrict access to allowed apps)
├── Schedules backups via CronJob
├── Monitors health and updates status conditions
└── Handles version upgrades via rolling restart
```

### CRD

```yaml
apiVersion: db.example.com/v1
kind: DatabaseInstance
metadata:
  name: production-postgres
spec:
  engine: postgres
  version: "16"
  replicas: 3
  storage:
    size: 50Gi
    storageClass: fast-ssd
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
  backup:
    enabled: true
    schedule: "0 2 * * *"
    retentionDays: 30
    destination: s3://my-backups/postgres
  allowedFrom:
  - namespaceSelector:
      matchLabels:
        team: backend
```

### Milestones

```
□ Operator scaffolded with Kubebuilder
□ DatabaseInstance creates StatefulSet + Services
□ Status conditions updated accurately
□ Backup CronJob created and verified
□ NetworkPolicy restricts access to allowedFrom
□ Webhook validates: engine + version combination
□ Finalizer cleans up resources on deletion
□ Integration tests pass with envtest
□ Operator deployed to cluster via Helm chart
□ OLM bundle created for distribution
```

---

## Project 6 — CKA / CKAD / CKS Mock Exam Cluster

**Covers:** Section 21  
**Goal:** Build a practice environment that simulates the certification exams.

### Setup

```bash
# Multi-node kind cluster
cat << 'EOF' | kind create cluster --name cka-practice --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "node-role=control-plane"
- role: worker
  kubeadmConfigPatches:
  - |
    kind: JoinConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "node-role=worker"
- role: worker
- role: worker
EOF

# Set up aliases
alias k=kubectl
export do="--dry-run=client -o yaml"
export now="--force --grace-period=0"
source <(kubectl completion bash)
complete -F __start_kubectl k
```

### Practice Scenarios

```bash
# Scenario 1: Fix a broken cluster (control plane pod missing)
# Scenario 2: Backup and restore etcd
# Scenario 3: Upgrade cluster from 1.28 to 1.29
# Scenario 4: Debug a network connectivity issue
# Scenario 5: Create RBAC for a service account
# Scenario 6: Configure a NetworkPolicy
# Scenario 7: Mount secrets as volumes in a pod
# Scenario 8: Create a PV/PVC and mount it
# Scenario 9: Scale a deployment and configure HPA
# Scenario 10: Drain a node and reschedule workloads
```

---

## How to Approach the Projects

1. **Build incrementally** — get the simplest thing working, then add complexity
2. **Break things intentionally** — inject failures and practice debugging
3. **Document your runbooks** — write down what you learned for each failure
4. **Use GitOps** — manage everything through ArgoCD, not direct `kubectl apply`
5. **Measure everything** — add Prometheus metrics and Grafana dashboards from day one

---

## Resources

| Type | Link |
|------|------|
| Platform | [EKS Workshop](https://www.eksworkshop.com/) |
| Platform | [Kubeflow End-to-End Tutorial](https://www.kubeflow.org/docs/started/introduction/) |
| Platform | [Crossplane getting started](https://docs.crossplane.io/latest/getting-started/) |
| Platform | [Backstage Getting Started](https://backstage.io/docs/getting-started/) |
| Book | *Kubernetes Patterns* — Ibryam & Huss (O'Reilly) |
| Book | *Production Kubernetes* — Rosso et al. (O'Reilly) |
