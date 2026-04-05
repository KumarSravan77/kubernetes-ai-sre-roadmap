# Kubernetes + AI SRE Expert Roadmap

A complete, structured path from Kubernetes beginner to AI-driven SRE expert. Each section builds on the previous and includes learning objectives, key topics, hands-on labs, and curated resources.

---

## How to Use This Roadmap

- Work through sections in order — later sections assume earlier ones
- Each section folder contains labs, manifests, and deeper notes
- "SRE Lens" callouts highlight production-relevant failure modes
- Interview prep is in [21-interview-prep](../21-interview-prep/) and cross-referenced throughout

---

## Learning Path Overview

| # | Section | Level | Est. Time |
|---|---------|-------|-----------|
| 01 | [Foundations](#01-foundations) | Beginner | 1 week |
| 02 | [Architecture & Internals](#02-architecture--internals) | Beginner–Mid | 1 week |
| 03 | [Pods, Workloads & Rollouts](#03-pods-workloads--rollouts) | Mid | 1 week |
| 04 | [Scheduling & Node Placement](#04-scheduling--node-placement) | Mid | 3–4 days |
| 05 | [Networking](#05-networking) | Mid | 1 week |
| 06 | [Services, Ingress & Gateway API](#06-services-ingress--gateway-api) | Mid | 1 week |
| 07 | [Storage & StatefulSets](#07-storage--statefulsets) | Mid | 1 week |
| 08 | [ConfigMaps & Secrets](#08-configmaps--secrets) | Mid | 3 days |
| 09 | [Resource Management & QoS](#09-resource-management--qos) | Mid–Senior | 3–4 days |
| 10 | [Troubleshooting & Debugging](#10-troubleshooting--debugging) | Mid–Senior | 1 week |
| 11 | [Observability](#11-observability) | Senior | 1–2 weeks |
| 12 | [Security](#12-security) | Senior | 1–2 weeks |
| 13 | [Packaging & Config Management](#13-packaging--config-management) | Senior | 1 week |
| 14 | [GitOps & Platform Engineering](#14-gitops--platform-engineering) | Senior | 1–2 weeks |
| 15 | [Cluster Management](#15-cluster-management) | Senior | 1 week |
| 16 | [Autoscaling & Cost Optimization](#16-autoscaling--cost-optimization) | Senior | 1 week |
| 17 | [Operators & Kubebuilder](#17-operators--kubebuilder) | Expert | 1–2 weeks |
| 18 | [Service Mesh](#18-service-mesh) | Expert | 1 week |
| 19 | [ML Platform on Kubernetes](#19-ml-platform-on-kubernetes) | Expert | 1–2 weeks |
| 20 | [AI & AIOps](#20-ai--aiops) | Expert | 1–2 weeks |
| 21 | [Interview Prep](#21-interview-prep) | All | Ongoing |
| 22 | [Capstone Projects](#22-capstone-projects) | All | Ongoing |

---

## 01 — Foundations

**Folder:** [../01-foundations/](../01-foundations/)

### Learning Objectives
- Understand containers, images, and the container runtime interface (CRI)
- Know why Kubernetes exists and what problems it solves
- Set up a local cluster and interact with it via `kubectl`

### Key Topics
- Docker / containerd / CRI-O basics; image layers and OCI spec
- Kubernetes components at a glance: control plane vs. data plane
- `kubectl` essentials: get, describe, apply, delete, exec, logs, port-forward
- YAML structure: apiVersion, kind, metadata, spec, status
- Namespaces, labels, annotations, and selectors
- kubeconfig, contexts, and multi-cluster access

### Hands-on Labs
- Run a container locally with Docker, then replicate with a Pod manifest
- Deploy nginx via `kubectl run`, then via a YAML file
- Practice label selectors and field selectors

### Resources
| Type | Link |
|------|------|
| Official Docs | [Kubernetes Concepts](https://kubernetes.io/docs/concepts/) |
| Official Docs | [kubectl Cheat Sheet](https://kubernetes.io/docs/reference/kubectl/cheatsheet/) |
| Tutorial | [Kubernetes Basics (k8s.io interactive)](https://kubernetes.io/docs/tutorials/kubernetes-basics/) |
| Course | [Introduction to Kubernetes (LFS158 — free)](https://training.linuxfoundation.org/training/introduction-to-kubernetes/) |
| Book | *Kubernetes: Up and Running* — Burns, Beda, Hightower (O'Reilly) |
| Tool | [kind — Kubernetes IN Docker](https://kind.sigs.k8s.io/) |
| Tool | [minikube](https://minikube.sigs.k8s.io/docs/) |
| Tool | [k9s — terminal UI](https://k9scli.io/) |

---

## 02 — Architecture & Internals

**Folder:** [../02-architecture-and-internals/](../02-architecture-and-internals/)

### Learning Objectives
- Trace what happens when you run `kubectl apply`
- Understand the role of each control-plane component
- Read and interpret `etcd` data; understand watch/list mechanics

### Key Topics
- Control plane: kube-apiserver, etcd, kube-scheduler, kube-controller-manager, cloud-controller-manager
- Data plane: kubelet, kube-proxy, container runtime
- Reconciliation loop and level-triggered vs. edge-triggered design
- API server request lifecycle: authentication → authorization → admission → validation → etcd write
- Admission webhooks: MutatingAdmissionWebhook, ValidatingAdmissionWebhook
- CRDs and the extension API server pattern
- etcd: Raft consensus, compaction, defragmentation, backup/restore

### Hands-on Labs
- Use `etcdctl` to inspect live cluster data
- Trace a Pod creation with `kubectl get events --watch` and audit logs
- Write a simple ValidatingWebhookConfiguration

### Resources
| Type | Link |
|------|------|
| Official Docs | [Kubernetes Components](https://kubernetes.io/docs/concepts/overview/components/) |
| Official Docs | [API Overview](https://kubernetes.io/docs/reference/using-api/) |
| Deep-dive | [What happens when k8s](https://github.com/jamiehannaford/what-happens-when-k8s) |
| Deep-dive | [Kubernetes Internals (Learnk8s)](https://learnk8s.io/kubernetes-internals-scheduler) |
| Video | [Kubernetes the Hard Way — Kelsey Hightower](https://github.com/kelseyhightower/kubernetes-the-hard-way) |
| Paper | [etcd documentation](https://etcd.io/docs/) |
| Blog | [A Guide to the Kubernetes Networking Model](https://sookocheff.com/post/kubernetes/understanding-kubernetes-networking-model/) |

---

## 03 — Pods, Workloads & Rollouts

**Folder:** [../03-pods-workloads-rollouts/](../03-pods-workloads-rollouts/)

### Learning Objectives
- Choose the right workload type for every use case
- Configure robust Pods with probes, lifecycle hooks, and init containers
- Perform and rollback safe deployments

### Key Topics
- Pod lifecycle: Pending → Running → Succeeded/Failed; phase vs. condition
- Liveness, readiness, and startup probes (HTTP, TCP, exec, gRPC)
- Init containers and sidecar containers (native sidecar in 1.29+)
- Workload resources: Deployment, ReplicaSet, StatefulSet, DaemonSet, Job, CronJob
- Deployment strategies: RollingUpdate, Recreate, Blue/Green, Canary
- `kubectl rollout`: status, history, undo, pause, resume
- Pod Disruption Budgets (PDB)
- Ephemeral containers for live debugging

### Hands-on Labs
- Break a readiness probe and observe traffic impact
- Deploy a canary with two Deployments behind one Service
- Trigger a rollback with `kubectl rollout undo`
- Attach an ephemeral debug container to a running Pod

### Resources
| Type | Link |
|------|------|
| Official Docs | [Workloads](https://kubernetes.io/docs/concepts/workloads/) |
| Official Docs | [Pod Lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/) |
| Official Docs | [Disruption Budgets](https://kubernetes.io/docs/tasks/run-application/configure-pdb/) |
| Blog | [Kubernetes Deployment Strategies (Weaveworks)](https://www.weave.works/blog/kubernetes-deployment-strategies) |
| Blog | [Ephemeral Containers](https://kubernetes.io/docs/concepts/workloads/pods/ephemeral-containers/) |
| Tool | [Argo Rollouts](https://argoproj.github.io/rollouts/) |

---

## 04 — Scheduling & Node Placement

**Folder:** [../04-scheduling-and-node-placement/](../04-scheduling-and-node-placement/)

### Learning Objectives
- Control precisely where Pods land in a cluster
- Understand the scheduler's filter and score pipeline
- Diagnose Pods stuck in Pending state

### Key Topics
- Scheduler phases: filtering (predicates) and scoring (priorities)
- `nodeSelector`, `nodeName`
- Node Affinity / Anti-affinity (required vs. preferred)
- Pod Affinity / Anti-affinity; topology keys
- Taints and Tolerations; taint effects: NoSchedule, PreferNoSchedule, NoExecute
- Topology Spread Constraints
- Priority classes and preemption
- Custom schedulers and scheduler extenders
- `kube-scheduler` profiles (multiple scheduling profiles, 1.18+)

### Hands-on Labs
- Taint a node and schedule a toleration-bearing Pod onto it
- Use `topologySpreadConstraints` to spread Pods across zones
- Simulate a preemption event with PriorityClasses

### Resources
| Type | Link |
|------|------|
| Official Docs | [Assigning Pods to Nodes](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/) |
| Official Docs | [Taints and Tolerations](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/) |
| Official Docs | [Pod Priority and Preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/) |
| Deep-dive | [Scheduler Framework](https://kubernetes.io/docs/concepts/scheduling-eviction/scheduling-framework/) |
| Blog | [Topology Spread Constraints (Learnk8s)](https://learnk8s.io/spring-boot-kubernetes-guide) |

---

## 05 — Networking

**Folder:** [../05-networking/](../05-networking/)

### Learning Objectives
- Explain the Kubernetes networking model from first principles
- Configure and debug CNI plugins
- Understand NetworkPolicy enforcement

### Key Topics
- The three Kubernetes networking requirements: Pod-to-Pod, Pod-to-Service, External-to-Service
- CNI plugin model; popular options: Calico, Cilium, Flannel, Weave
- iptables vs. eBPF data planes
- kube-proxy modes: iptables, ipvs, nftables (1.29+)
- DNS in Kubernetes: CoreDNS, ndots, search domains, headless services
- NetworkPolicy: ingress/egress rules, namespace/pod selectors, CIDR blocks
- Pod CIDR, Service CIDR, Node IP routing
- IPv4/IPv6 dual-stack

### Hands-on Labs
- Deploy Cilium and inspect eBPF maps with `cilium monitor`
- Write a NetworkPolicy that allows only frontend → backend traffic
- Debug a DNS resolution failure with `dig` and CoreDNS logs

### Resources
| Type | Link |
|------|------|
| Official Docs | [Cluster Networking](https://kubernetes.io/docs/concepts/cluster-administration/networking/) |
| Official Docs | [Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/) |
| Deep-dive | [Kubernetes Networking Guide (Learnk8s)](https://learnk8s.io/kubernetes-network-packets) |
| Deep-dive | [eBPF and Cilium](https://cilium.io/docs/) |
| Tool | [NetworkPolicy Editor (Cilium)](https://editor.networkpolicy.io/) |
| Book | *Kubernetes Networking* — Vallières & Hausenblas (O'Reilly) |

---

## 06 — Services, Ingress & Gateway API

**Folder:** [../06-services-ingress-gateway/](../06-services-ingress-gateway/)

### Learning Objectives
- Route external and internal traffic reliably
- Know when to use Service types, Ingress, or Gateway API
- Operate and debug common ingress controllers

### Key Topics
- Service types: ClusterIP, NodePort, LoadBalancer, ExternalName, headless
- Endpoints and EndpointSlices
- Session affinity, topology-aware routing
- Ingress resource and ingress controllers: NGINX, Traefik, HAProxy
- TLS termination, cert-manager, Let's Encrypt
- Gateway API: GatewayClass, Gateway, HTTPRoute, TCPRoute, GRPCRoute
- gRPC load balancing considerations

### Hands-on Labs
- Expose an app with each Service type; observe iptables rules
- Configure NGINX ingress with TLS and path-based routing
- Migrate an Ingress resource to Gateway API HTTPRoute

### Resources
| Type | Link |
|------|------|
| Official Docs | [Services](https://kubernetes.io/docs/concepts/services-networking/service/) |
| Official Docs | [Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/) |
| Official Docs | [Gateway API](https://gateway-api.sigs.k8s.io/) |
| Tool | [cert-manager](https://cert-manager.io/docs/) |
| Tool | [ingress-nginx](https://kubernetes.github.io/ingress-nginx/) |
| Blog | [Gateway API vs Ingress (Gateway API SIG)](https://gateway-api.sigs.k8s.io/concepts/api-overview/) |

---

## 07 — Storage & StatefulSets

**Folder:** [../07-storage-and-statefulsets/](../07-storage-and-statefulsets/)

### Learning Objectives
- Provision and manage persistent storage in Kubernetes
- Design StatefulSets for databases and queues
- Handle storage expansion, snapshots, and backup

### Key Topics
- Volume types: emptyDir, hostPath, configMap, secret, projected, CSI
- PersistentVolume (PV), PersistentVolumeClaim (PVC), StorageClass
- Access modes: RWO, ROX, RWX, RWOP
- Dynamic provisioning, Reclaim policies: Retain, Delete, Recycle
- CSI drivers: AWS EBS, GCP Persistent Disk, Azure Disk, Longhorn, OpenEBS, Rook/Ceph
- Volume expansion, snapshots (VolumeSnapshot API)
- StatefulSet guarantees: stable network identity, ordered deployment, rolling updates
- Headless service + StatefulSet DNS patterns
- Running Postgres/MySQL/Redis on Kubernetes

### Hands-on Labs
- Deploy a StatefulSet with volumeClaimTemplates
- Resize a PVC dynamically
- Take a VolumeSnapshot and restore from it

### Resources
| Type | Link |
|------|------|
| Official Docs | [Storage](https://kubernetes.io/docs/concepts/storage/) |
| Official Docs | [StatefulSets](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/) |
| Official Docs | [CSI](https://kubernetes.io/docs/concepts/storage/volumes/#csi) |
| Tool | [Rook Ceph](https://rook.io/docs/rook/latest/) |
| Tool | [Longhorn](https://longhorn.io/docs/) |
| Blog | [Kubernetes StatefulSet Gotchas](https://learnk8s.io/stateful-kubernetes) |

---

## 08 — ConfigMaps & Secrets

**Folder:** [../08-configmaps-secrets/](../08-configmaps-secrets/)

### Learning Objectives
- Inject configuration into workloads without rebuilding images
- Manage secrets securely at rest and in transit
- Integrate with external secret managers

### Key Topics
- ConfigMap creation: literals, files, env files, directory
- Consuming ConfigMaps: envFrom, env valueFrom, volume mounts
- Secret types: Opaque, kubernetes.io/tls, dockerconfigjson, service-account-token
- Secrets encryption at rest (EncryptionConfiguration)
- Immutable ConfigMaps and Secrets
- External Secrets Operator (ESO) — AWS Secrets Manager, HashiCorp Vault, GCP Secret Manager
- Sealed Secrets (Bitnami) for GitOps workflows
- Secret rotation patterns

### Hands-on Labs
- Mount a ConfigMap as a file and trigger a live config reload
- Enable encryption at rest for secrets in etcd
- Sync an AWS Secrets Manager secret with External Secrets Operator

### Resources
| Type | Link |
|------|------|
| Official Docs | [ConfigMaps](https://kubernetes.io/docs/concepts/configuration/configmap/) |
| Official Docs | [Secrets](https://kubernetes.io/docs/concepts/configuration/secret/) |
| Official Docs | [Encrypting Secret Data at Rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/) |
| Tool | [External Secrets Operator](https://external-secrets.io/) |
| Tool | [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) |
| Tool | [HashiCorp Vault on K8s](https://developer.hashicorp.com/vault/docs/platform/k8s) |

---

## 09 — Resource Management & QoS

**Folder:** [../09-resource-management-qos/](../09-resource-management-qos/)

### Learning Objectives
- Set accurate resource requests and limits
- Understand how QoS classes affect eviction order
- Apply LimitRanges and ResourceQuotas to tenants

### Key Topics
- CPU and memory: requests vs. limits; throttling vs. OOMKill
- QoS classes: Guaranteed, Burstable, BestEffort
- LimitRange: default, min, max, maxLimitRequestRatio
- ResourceQuota: compute, object count, storage
- Vertical Pod Autoscaler (VPA): Recommender, Admission Plugin, Updater modes
- Kubernetes resource units: millicores, mebibytes
- Memory overcommit risks and `oom_score_adj`

### Hands-on Labs
- Trigger a CPU throttle event and observe it with `container_cpu_cfs_throttled_seconds_total`
- Trigger an OOMKill and interpret the node event
- Apply a ResourceQuota to a namespace and hit the limit

### Resources
| Type | Link |
|------|------|
| Official Docs | [Resource Management for Pods](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/) |
| Official Docs | [LimitRange](https://kubernetes.io/docs/concepts/policy/limit-range/) |
| Official Docs | [Resource Quotas](https://kubernetes.io/docs/concepts/policy/resource-quotas/) |
| Official Docs | [QoS Classes](https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/) |
| Tool | [VPA](https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler) |
| Blog | [CPU Limits and Throttling (Robusta)](https://home.robusta.dev/blog/stop-using-cpu-limits) |

---

## 10 — Troubleshooting & Debugging

**Folder:** [../10-troubleshooting-debugging/](../10-troubleshooting-debugging/)

### Learning Objectives
- Diagnose any Pod or cluster issue using a systematic method
- Use advanced `kubectl` and OS-level tools during incidents
- Build runbooks for common failure patterns

### Key Topics
- Troubleshooting methodology: Observe → Hypothesize → Test → Fix
- `kubectl describe`, `kubectl logs --previous`, `kubectl get events`
- CrashLoopBackOff, ImagePullBackOff, OOMKilled, Evicted — root causes
- Node-level debugging: `crictl`, `journalctl -u kubelet`, `dmesg`
- Network debugging: `netshoot`, `kubectl exec` into a debug pod
- DNS failures: ndots, search domain, CoreDNS tuning
- Ephemeral containers and `kubectl debug`
- Slow API server: etcd latency, admission webhook timeouts
- Common RBAC errors: Forbidden 403, impersonation

### Hands-on Labs
- Inject each common failure (CrashLoop, OOM, ImagePull) and fix it
- Diagnose a "service not reachable" network issue end-to-end
- Use `kubectl debug node/...` to exec into a node

### Resources
| Type | Link |
|------|------|
| Official Docs | [Troubleshooting](https://kubernetes.io/docs/tasks/debug/) |
| Official Docs | [Debug Running Pods](https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/) |
| Tool | [netshoot](https://github.com/nicolaka/netshoot) |
| Tool | [kubectl-neat](https://github.com/itaysk/kubectl-neat) |
| Tool | [Robusta — open-source K8s debugger](https://home.robusta.dev/) |
| Blog | [Kubernetes Troubleshooting Flowchart (Learnk8s)](https://learnk8s.io/troubleshooting-deployments) |

---

## 11 — Observability

**Folder:** [../11-observability/](../11-observability/)

### Learning Objectives
- Implement the three pillars of observability: metrics, logs, traces
- Design a production-grade monitoring stack
- Build SLO-based alerting

### Key Topics
- Metrics: Prometheus, PromQL, recording rules, alerting rules
- Visualization: Grafana dashboards, Kubernetes mixin dashboards
- Logging: Fluentd, Fluent Bit, Loki, structured logging patterns
- Distributed tracing: OpenTelemetry (OTel), Jaeger, Tempo
- OpenTelemetry Collector: receivers, processors, exporters
- Kubernetes metrics: kube-state-metrics, node-exporter, metrics-server
- SLI / SLO / SLA / Error Budget
- Alertmanager: routing, grouping, inhibition, silences
- Continuous profiling: Parca, Pyroscope

### Hands-on Labs
- Deploy kube-prometheus-stack via Helm; build a custom Grafana dashboard
- Write a multi-window multi-burn-rate SLO alert
- Instrument a Go app with OTel SDK and view traces in Jaeger

### Resources
| Type | Link |
|------|------|
| Official Docs | [Prometheus](https://prometheus.io/docs/) |
| Official Docs | [OpenTelemetry](https://opentelemetry.io/docs/) |
| Tool | [kube-prometheus-stack Helm chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) |
| Tool | [Grafana](https://grafana.com/docs/grafana/latest/) |
| Tool | [Loki](https://grafana.com/docs/loki/latest/) |
| Tool | [Tempo](https://grafana.com/docs/tempo/latest/) |
| Book | *Site Reliability Engineering* — Google (free online) |
| Blog | [SLO Alerting (Alex Hidalgo)](https://www.alex-hidalgo.com/the-slo-book) |

---

## 12 — Security

**Folder:** [../12-security/](../12-security/)

### Learning Objectives
- Harden clusters, workloads, and the supply chain
- Implement least-privilege RBAC
- Detect and respond to runtime threats

### Key Topics
- RBAC: Roles, ClusterRoles, Bindings; aggregated ClusterRoles
- ServiceAccount tokens: automounting, bound tokens, token projections
- Pod Security Standards (PSS): Privileged, Baseline, Restricted
- Pod Security Admission (PSA) and OPA/Gatekeeper / Kyverno policies
- securityContext: runAsNonRoot, readOnlyRootFilesystem, capabilities, seccompProfile
- Network segmentation with NetworkPolicy
- Supply chain security: image signing (Cosign/Sigstore), SBOM, admission verification
- Secrets management: Vault, ESO, IRSA / Workload Identity
- Runtime security: Falco rules, eBPF-based detection
- CIS Kubernetes Benchmark; kube-bench
- Audit logging

### Hands-on Labs
- Audit RBAC with `kubectl-who-can` and `rbac-lookup`
- Enforce Restricted PSS on a namespace
- Write a Kyverno policy blocking `latest` image tags
- Run kube-bench and remediate findings

### Resources
| Type | Link |
|------|------|
| Official Docs | [RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/) |
| Official Docs | [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/) |
| Tool | [Falco](https://falco.org/docs/) |
| Tool | [Kyverno](https://kyverno.io/docs/) |
| Tool | [OPA/Gatekeeper](https://open-policy-agent.github.io/gatekeeper/) |
| Tool | [kube-bench (CIS)](https://github.com/aquasecurity/kube-bench) |
| Tool | [Trivy](https://aquasecurity.github.io/trivy/) |
| Tool | [Cosign / Sigstore](https://docs.sigstore.dev/) |
| Guide | [NSA/CISA Kubernetes Hardening Guide](https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF) |

---

## 13 — Packaging & Config Management

**Folder:** [../13-packaging-config-management/](../13-packaging-config-management/)

### Learning Objectives
- Package and version Kubernetes applications with Helm
- Use Kustomize for environment-specific overlays
- Understand when to use each tool

### Key Topics
- Helm 3: charts, values, templates, helpers, hooks, tests
- Helm chart development: `helm create`, `helm lint`, `helm template`
- Helm library charts; Helm OCI registries
- Kustomize: bases, overlays, patches (strategic merge, JSON 6902), transformers
- Kustomize components and cross-cutting concerns
- Helm vs. Kustomize vs. raw YAML — trade-offs
- Schema validation: `kubeconform`, `helm schema`
- Managing chart dependencies: `Chart.yaml` dependencies, `helm dependency update`

### Hands-on Labs
- Write a Helm chart from scratch for a 3-tier app
- Build a Kustomize overlay for dev/staging/prod environments
- Publish a chart to an OCI registry (GHCR)

### Resources
| Type | Link |
|------|------|
| Official Docs | [Helm Documentation](https://helm.sh/docs/) |
| Official Docs | [Kustomize](https://kustomize.io/) |
| Tool | [Artifact Hub](https://artifacthub.io/) |
| Tool | [kubeconform](https://github.com/yannh/kubeconform) |
| Blog | [Helm vs Kustomize (Codefresh)](https://codefresh.io/blog/helm-vs-kustomize/) |

---

## 14 — GitOps & Platform Engineering

**Folder:** [../14-gitops-platform-engineering/](../14-gitops-platform-engineering/)

### Learning Objectives
- Implement GitOps with ArgoCD and Flux
- Build an Internal Developer Platform (IDP)
- Design multi-tenant platform abstractions

### Key Topics
- GitOps principles: declarative, versioned, automated, continuously reconciled
- ArgoCD: Applications, AppProjects, ApplicationSets, sync policies, health checks
- Argo Image Updater; ArgoCD Notifications
- Flux: Kustomization, HelmRelease, ImageAutomation, multi-tenancy model
- ArgoCD vs. Flux — trade-offs
- Platform Engineering concepts: golden paths, paved roads, developer portals
- Backstage: software catalog, TechDocs, scaffolder templates
- Crossplane: composite resources, providers, XRDs for infrastructure GitOps

### Hands-on Labs
- Deploy ArgoCD and bootstrap a repository with App of Apps pattern
- Set up ApplicationSet for multi-cluster deployment
- Build a Backstage software template that provisions a new service

### Resources
| Type | Link |
|------|------|
| Official Docs | [ArgoCD](https://argo-cd.readthedocs.io/en/stable/) |
| Official Docs | [Flux](https://fluxcd.io/docs/) |
| Official Docs | [Backstage](https://backstage.io/docs/) |
| Official Docs | [Crossplane](https://docs.crossplane.io/) |
| Blog | [GitOps Principles (OpenGitOps)](https://opengitops.dev/) |
| Book | *Platform Engineering on Kubernetes* — Codefresh (free) |

---

## 15 — Cluster Management

**Folder:** [../15-cluster-management/](../15-cluster-management/)

### Learning Objectives
- Provision and upgrade production clusters on AWS, GCP, and Azure
- Manage multi-cluster fleets with Federation or clusterpools
- Operate cluster add-ons at scale

### Key Topics
- Managed K8s: EKS, GKE, AKS — architecture differences, upgrade strategies
- Cluster provisioners: kubeadm, kOps, Cluster API (CAPI)
- Node management: node groups, managed node groups, spot/preemptible instances
- Cluster upgrades: control plane first, rolling node replacement
- Multi-cluster: KubeFed, Submariner, Admiralty, Liqo
- Cluster API providers; ClusterClass for fleet standardization
- Add-on management: Helm, Fleet (Rancher), Cluster API Add-on Orchestration
- etcd operations: backup, restore, compaction scheduling

### Hands-on Labs
- Bootstrap a cluster with Cluster API on AWS
- Perform a zero-downtime in-place upgrade of an EKS cluster
- Back up and restore etcd

### Resources
| Type | Link |
|------|------|
| Official Docs | [Cluster API](https://cluster-api.sigs.k8s.io/) |
| Official Docs | [kubeadm](https://kubernetes.io/docs/reference/setup-tools/kubeadm/) |
| Official Docs | [EKS Best Practices Guide](https://aws.github.io/aws-eks-best-practices/) |
| Tool | [kOps](https://kops.sigs.k8s.io/) |
| Tool | [Rancher Fleet](https://fleet.rancher.io/) |
| Blog | [Cluster Upgrades (Learnk8s)](https://learnk8s.io/kubernetes-upgrade) |

---

## 16 — Autoscaling & Cost Optimization

**Folder:** [../16-autoscaling-cost/](../16-autoscaling-cost/)

### Learning Objectives
- Scale workloads and clusters based on real demand signals
- Reduce cloud spend without compromising reliability
- Use spot/preemptible instances safely

### Key Topics
- Horizontal Pod Autoscaler (HPA): CPU, memory, custom metrics (KEDA)
- KEDA: ScaledObject, ScaledJob, 50+ scalers (Kafka, SQS, Prometheus, cron)
- Vertical Pod Autoscaler (VPA): modes, limitations with HPA
- Cluster Autoscaler (CA): scale-up, scale-down, safe-to-evict annotation
- Karpenter: NodePool, NodeClass, bin-packing, consolidation, drift
- Spot/preemptible best practices: PDB, node termination handler, on-demand base capacity
- FinOps tooling: Kubecost, OpenCost, cloud provider cost explorer
- Right-sizing: VPA recommendations, Goldilocks
- Scheduling tricks: pause containers, kube-downscaler for non-prod

### Hands-on Labs
- Configure KEDA with an SQS scaler
- Replace Cluster Autoscaler with Karpenter on EKS
- Run Kubecost and identify top cost drivers

### Resources
| Type | Link |
|------|------|
| Official Docs | [HPA](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/) |
| Official Docs | [Cluster Autoscaler](https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler) |
| Official Docs | [KEDA](https://keda.sh/docs/) |
| Official Docs | [Karpenter](https://karpenter.sh/docs/) |
| Tool | [Kubecost](https://www.kubecost.com/) |
| Tool | [OpenCost](https://www.opencost.io/) |
| Tool | [Goldilocks](https://goldilocks.docs.fairwinds.com/) |

---

## 17 — Operators & Kubebuilder

**Folder:** [../17-operators-kubebuilder/](../17-operators-kubebuilder/)

### Learning Objectives
- Build production-grade Kubernetes Operators in Go
- Design robust CRDs with validation and conversion webhooks
- Implement controller reconciliation patterns

### Key Topics
- Operator pattern: CRD + controller = self-healing system
- Kubebuilder scaffolding: `kubebuilder init`, `create api`, `create webhook`
- controller-runtime: Reconciler, Manager, Client, Scheme
- Reconciliation loop design: idempotency, status conditions, exponential backoff
- Finalizers and deletion protection
- Owner references and garbage collection
- Admission webhooks: defaulting and validation
- Conversion webhooks for multi-version CRDs
- Operator SDK (alternative to Kubebuilder)
- Operator Lifecycle Manager (OLM) for distribution
- Testing operators: envtest, ginkgo/gomega

### Hands-on Labs
- Build a `DatabaseBackup` operator that schedules CronJobs
- Add a validating webhook that rejects invalid specs
- Write controller integration tests with envtest

### Resources
| Type | Link |
|------|------|
| Official Docs | [Kubebuilder Book](https://book.kubebuilder.io/) |
| Official Docs | [controller-runtime](https://pkg.go.dev/sigs.k8s.io/controller-runtime) |
| Official Docs | [Operator SDK](https://sdk.operatorframework.io/docs/) |
| Resource | [OperatorHub.io](https://operatorhub.io/) |
| Blog | [Writing a Kubernetes Operator (Dex)](https://dexidp.io/docs/kubernetes/) |
| Book | *Programming Kubernetes* — Hausenblas & Schimanski (O'Reilly) |

---

## 18 — Service Mesh

**Folder:** [../18-service-mesh/](../18-service-mesh/)

### Learning Objectives
- Understand the data plane / control plane split in a service mesh
- Implement mTLS, traffic management, and observability with Istio or Cilium Mesh
- Know when a service mesh is (and isn't) the right tool

### Key Topics
- Service mesh concepts: sidecar proxy (Envoy), data plane, control plane
- Istio architecture: istiod, Envoy sidecar injection, Pilot, Citadel, Galley
- Traffic management: VirtualService, DestinationRule, Gateway, ServiceEntry
- Istio resilience: retries, timeouts, circuit breakers, fault injection
- mTLS: PeerAuthentication, AuthorizationPolicy
- Observability: Istio telemetry, Kiali, distributed tracing with Jaeger
- Ambient mesh (Istio 1.15+): ztunnel, waypoint proxies
- Cilium Service Mesh: no-sidecar eBPF-based mesh
- Linkerd: lightweight alternative, mTLS, latency-aware load balancing

### Hands-on Labs
- Deploy Istio with ambient mode; enable mTLS cluster-wide
- Configure a canary split with VirtualService weights
- Inject a 5-second delay fault and verify circuit breaker trips

### Resources
| Type | Link |
|------|------|
| Official Docs | [Istio](https://istio.io/latest/docs/) |
| Official Docs | [Linkerd](https://linkerd.io/docs/) |
| Official Docs | [Cilium Service Mesh](https://docs.cilium.io/en/stable/network/servicemesh/) |
| Tool | [Kiali](https://kiali.io/docs/) |
| Blog | [Istio Ambient Mesh Explained](https://istio.io/latest/blog/2022/introducing-ambient-mesh/) |

---

## 19 — ML Platform on Kubernetes

**Folder:** [../19-ml-platform/](../19-ml-platform/)

### Learning Objectives
- Run end-to-end ML workflows on Kubernetes
- Serve models at scale with GPU-aware scheduling
- Build reproducible ML pipelines

### Key Topics
- GPU support: NVIDIA device plugin, node labels, resource limits (`nvidia.com/gpu`)
- MIG (Multi-Instance GPU) partitioning for cost efficiency
- Kubeflow Pipelines: pipeline components, DAGs, artifacts, caching
- Kubeflow Training Operator: TFJob, PyTorchJob, MXJob, PaddleJob
- Model serving: KServe (formerly KFServing), Triton Inference Server, Seldon Core
- Feast — feature store on Kubernetes
- MLflow on Kubernetes: experiment tracking, model registry, deployment
- Ray on Kubernetes (KubeRay): RayCluster, RayJob, RayService
- Data pipelines: Apache Airflow on Kubernetes (KubernetesExecutor), Argo Workflows

### Hands-on Labs
- Schedule a PyTorchJob training run on GPU nodes
- Deploy a KServe InferenceService and test autoscaling with Knative
- Build a Kubeflow Pipeline with a data prep → training → evaluation DAG

### Resources
| Type | Link |
|------|------|
| Official Docs | [Kubeflow](https://www.kubeflow.org/docs/) |
| Official Docs | [KServe](https://kserve.github.io/website/) |
| Official Docs | [KubeRay](https://docs.ray.io/en/latest/cluster/kubernetes/index.html) |
| Official Docs | [NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/overview.html) |
| Tool | [Volcano — batch scheduler](https://volcano.sh/en/docs/) |
| Blog | [ML on Kubernetes at Spotify](https://engineering.atspotify.com/2023/01/scaling-mlops-infrastructure-at-spotify/) |

---

## 20 — AI & AIOps

**Folder:** [../20-ai-aiops/](../20-ai-aiops/)

### Learning Objectives
- Apply LLMs and ML models to automate SRE workflows
- Build AI-assisted root cause analysis pipelines
- Understand responsible automation boundaries

### Key Topics
- AIOps concepts: anomaly detection, predictive alerting, intelligent triage
- LLM-based tools for SRE: ChatOps bots, incident summarization, runbook generation
- Kubernetes event analysis with LLMs (K8sGPT, Robusta Holmes)
- Anomaly detection on metrics: Prophet, LSTM, Prometheus ML exporters
- Log intelligence: clustering log patterns, reducing alert noise
- Auto-remediation: event-driven playbooks with Argo Events + LLM decision layer
- OpenAI / Anthropic API integration patterns for ops tooling
- Agent frameworks: LangChain, CrewAI, AutoGen for infrastructure agents
- Human-in-the-loop automation and guardrails
- Building a cost-aware AI workload scheduler

### Hands-on Labs
- Deploy K8sGPT and analyze a failing deployment
- Build an alert → summarize → Slack notification pipeline using an LLM API
- Write an auto-remediation controller that restarts pods based on LLM triage

### Resources
| Type | Link |
|------|------|
| Tool | [K8sGPT](https://k8sgpt.ai/) |
| Tool | [Robusta Holmes](https://home.robusta.dev/holmes/) |
| Tool | [Argo Events](https://argoproj.github.io/argo-events/) |
| Official Docs | [OpenAI API](https://platform.openai.com/docs/) |
| Official Docs | [Anthropic API](https://docs.anthropic.com/) |
| Framework | [LangChain](https://python.langchain.com/docs/) |
| Blog | [AIOps on Kubernetes (CNCF)](https://www.cncf.io/blog/2023/11/14/aiops-in-the-cloud-native-ecosystem/) |

---

## 21 — Interview Prep

**Folder:** [../21-interview-prep/](../21-interview-prep/)

### Learning Objectives
- Confidently answer L5–L7 SRE / Platform Engineer interview questions
- Work through system design questions for distributed Kubernetes systems
- Practice incident scenarios and debugging walkthroughs

### Key Topics
- Common K8s interview question banks (L4–Staff)
- System design: design a multi-region, multi-cluster deployment platform
- Incident scenarios: "the deployment is stuck", "all pods OOMKill at 3am"
- CKA / CKAD / CKS exam tips and practice environments
- Behavioral: handling production incidents, on-call culture, blameless postmortems

### Resources
| Type | Link |
|------|------|
| Practice | [Killer.sh (CKA/CKAD/CKS simulator)](https://killer.sh/) |
| Practice | [KodeKloud labs](https://kodekloud.com/) |
| Practice | [Killercoda K8s scenarios](https://killercoda.com/kubernetes) |
| Exam | [CKA Certification](https://training.linuxfoundation.org/certification/certified-kubernetes-administrator-cka/) |
| Exam | [CKAD Certification](https://training.linuxfoundation.org/certification/certified-kubernetes-application-developer-ckad/) |
| Exam | [CKS Certification](https://training.linuxfoundation.org/certification/certified-kubernetes-security-specialist/) |
| Repo | [K8s interview questions (dgkanatsios)](https://github.com/dgkanatsios/CKAD-exercises) |

---

## 22 — Capstone Projects

**Folder:** [../22-projects/](../22-projects/)

### Projects
| Project | Covers |
|---------|--------|
| Production EKS cluster with Karpenter, Istio, ArgoCD, and OTel | 01–18 |
| Multi-tenant SaaS platform with Crossplane and Backstage | 13–15 |
| ML training + serving pipeline with Kubeflow + KServe | 19 |
| AI-driven incident response bot with K8sGPT + Argo Events | 20 |
| Custom Operator for database lifecycle management | 17 |
| CKA/CKAD/CKS mock exam cluster | 21 |

---

## Quick Reference

### Essential Tools

| Tool | Purpose |
|------|---------|
| kubectl | Primary Kubernetes CLI |
| k9s | Terminal UI for clusters |
| helm | Package manager |
| kustomize | Config management overlays |
| stern | Multi-pod log tailing |
| kubectx / kubens | Context and namespace switching |
| kube-ps1 | Shell prompt with cluster/namespace |
| kubecolor | Colorized kubectl output |
| kubectl-neat | Clean up noisy `get -o yaml` output |
| popeye | Cluster sanity scanner |
| kube-bench | CIS benchmark runner |
| trivy | Vulnerability + config scanner |
| k8sgpt | AI-powered cluster analysis |

### Learning Philosophy

> **Junior** → Learn the tools  
> **Senior** → Understand the systems  
> **Expert** → Build automation + intelligence

The difference between a junior and an expert Kubernetes engineer is not knowing more `kubectl` flags — it is understanding **why** the system behaves the way it does and being able to design and automate solutions before problems occur.

---

*This roadmap is maintained alongside the rest of this repository. Open a PR to suggest additions or corrections.*
