#!/bin/bash

echo "Upgrading all sections with deep content..."

# -------- 01 FOUNDATIONS --------
cat > 01-foundations/README.md <<'EOT'
# Foundations (Deep)

## Core Idea
Kubernetes manages desired state via controllers.

## Deep Concepts
- Pod lifecycle is ephemeral
- Deployment manages ReplicaSets
- Service uses label selectors → endpoints

## Failure Scenarios
- CrashLoopBackOff → app crash or bad config
- Readiness fail → traffic drops but pod alive
- Liveness fail → restart loop

## Interview Answer Pattern
Define → Behavior → Failure → Debug → Trade-off

## Debug
kubectl describe pod
kubectl logs --previous

## Senior Insight
Readiness controls traffic, NOT lifecycle.
EOT

# -------- 02 INTERNALS --------
cat > 02-architecture-and-internals/README.md <<'EOT'
# Internals (Deep)

## Control Plane Flow
kubectl → API Server → etcd → Scheduler → Kubelet

## Key Behavior
- etcd = source of truth
- Controllers = reconciliation loop

## Failure Cases
- etcd down → cluster unstable
- scheduler down → pods Pending

## Senior Insight
Running pods survive control plane issues (data plane vs control plane)
EOT

# -------- 03 WORKLOADS --------
cat > 03-pods-workloads-rollouts/README.md <<'EOT'
# Workloads (Deep)

## Rollout Mechanics
Deployment → new ReplicaSet → shift traffic

## Critical Config
- maxSurge
- maxUnavailable

## Failure
- rollout stuck → readiness fail
- old pods not terminating

## Senior Insight
Rollouts are controlled by readiness, not just replica count
EOT

# -------- 04 SCHEDULING --------
cat > 04-scheduling-and-node-placement/README.md <<'EOT'
# Scheduling (Deep)

## Key Concepts
- taints / tolerations
- affinity / anti-affinity

## Failure
Pod Pending causes:
- no resources
- taint mismatch
- volume issue

## Senior Insight
Scheduler filters → scores → binds
EOT

# -------- 05 NETWORKING --------
cat > 05-networking/README.md <<'EOT'
# Networking (Deep)

## Stack
CNI + kube-proxy + DNS

## Flow
Pod → Service → iptables/IPVS → Pod

## Failure
- DNS fail
- no endpoints
- MTU issue

## Senior Insight
Most "network issues" are actually readiness or selector issues
EOT

# -------- 06 SERVICES --------
cat > 06-services-ingress-gateway/README.md <<'EOT'
# Services & Ingress (Deep)

## Flow
Client → LB → Ingress → Service → Pod

## Failure
- wrong selector
- targetPort mismatch
- ingress rule wrong

## Senior Insight
Service is abstraction, endpoints decide reality
EOT

# -------- 07 STORAGE --------
cat > 07-storage-and-statefulsets/README.md <<'EOT'
# Storage (Deep)

## Flow
PVC → StorageClass → PV

## Failure
- PVC Pending
- wrong zone
- access mode mismatch

## Senior Insight
StatefulSet = identity + storage, not just replicas
EOT

# -------- 08 CONFIG --------
cat > 08-configmaps-secrets/README.md <<'EOT'
# Config & Secrets (Deep)

## Behavior
Env vars DO NOT auto update

## Risk
Secrets are base64, not secure by default

## Senior Insight
Use external secret managers in production
EOT

# -------- 09 RESOURCES --------
cat > 09-resource-management-qos/README.md <<'EOT'
# Resources (Deep)

## Concepts
- requests = scheduling
- limits = enforcement

## Failure
- CPU throttling
- OOM kill

## Senior Insight
Memory kills, CPU throttles
EOT

# -------- 10 DEBUGGING --------
cat > 10-troubleshooting-debugging/README.md <<'EOT'
# Debugging (Deep)

## Flow
Pod → Container → App → Service → Network

## Golden Rule
Never guess. Narrow down.

## Senior Insight
Most issues are config + readiness + networking combo
EOT

# -------- 11 OBSERVABILITY --------
cat > 11-observability/README.md <<'EOT'
# Observability (Deep)

## Stack
Metrics + Logs + Traces

## Advanced
- SLO
- burn rate

## Senior Insight
Observability = system understanding, not dashboards
EOT

# -------- 12 SECURITY --------
cat > 12-security/README.md <<'EOT'
# Security (Deep)

## Layers
- RBAC
- NetworkPolicy
- Runtime

## Tools
Kyverno, OPA, Falco

## Senior Insight
Security = layers, not one tool
EOT

# -------- 13 PACKAGING --------
cat > 13-packaging-config-management/README.md <<'EOT'
# Packaging (Deep)

## Helm vs Kustomize
Helm = templating  
Kustomize = overlays

## Senior Insight
Use both depending on use case
EOT

# -------- 14 GITOPS --------
cat > 14-gitops-platform-engineering/README.md <<'EOT'
# GitOps (Deep)

## Flow
Git → ArgoCD → Cluster

## Key
Drift detection

## Senior Insight
Git = source of truth
EOT

# -------- 15 CLUSTER --------
cat > 15-cluster-management/README.md <<'EOT'
# Cluster Management (Deep)

## Topics
- EKS
- upgrades
- multi-cluster

## Senior Insight
Managed ≠ fully managed
EOT

# -------- 16 SCALING --------
cat > 16-autoscaling-cost/README.md <<'EOT'
# Scaling (Deep)

## Stack
HPA + Karpenter

## Problem
Scaling lag

## Senior Insight
Scaling is system-level, not just HPA
EOT

# -------- 17 OPERATORS --------
cat > 17-operators-kubebuilder/README.md <<'EOT'
# Operators (Deep)

## Concept
Reconciliation loop

## Use
Automation

## Senior Insight
Operator = codified operations
EOT

# -------- 18 MESH --------
cat > 18-service-mesh/README.md <<'EOT'
# Service Mesh (Deep)

## Tools
Istio, Linkerd

## Use
mTLS, traffic control

## Senior Insight
Use only when needed
EOT

# -------- 19 ML --------
cat > 19-ml-platform/README.md <<'EOT'
# ML Platform (Deep)

## Tools
Kubeflow, MLflow

## Senior Insight
ML infra = platform problem
EOT

# -------- 20 AI --------
cat > 20-ai-aiops/README.md <<'EOT'
# AI / AIOps (Deep)

## Flow
Alert → AI → RCA → Fix

## Senior Insight
AI helps triage, not magic fix
EOT

# -------- 21 INTERVIEW --------
cat > 21-interview-prep/README.md <<'EOT'
# Interview Prep (Deep)

## Focus
- failures
- trade-offs
- debugging

## Senior Insight
Explain behavior, not definitions
EOT

# -------- 22 PROJECTS --------
cat > 22-projects/README.md <<'EOT'
# Projects (Deep)

## Must Build
- GitOps platform
- observability stack
- operator
- AI SRE workflow

## Senior Insight
Projects = proof of thinking
EOT

echo "🔥 ALL SECTIONS UPGRADED SUCCESSFULLY"
