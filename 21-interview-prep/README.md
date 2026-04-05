# 21 — Interview Prep

Preparation for Kubernetes SRE / Platform Engineer interviews at L4–Staff level. Covers core concepts, system design, incident scenarios, and CKA/CKAD/CKS exam tips.

---

## Interview Structure (Typical)

```
Round 1: Fundamentals (45 min)
  → Kubernetes concepts, troubleshooting, architecture

Round 2: System Design (60 min)
  → Design a K8s-based platform for X

Round 3: Practical / Live Debugging (45 min)
  → Debug a broken cluster or deployment in real time

Round 4: Incident / Behavioral (45 min)
  → Tell me about an outage you handled
  → How do you handle alert fatigue?
```

---

## Core Concepts Q&A

### Pod & Workloads

**Q: What is the difference between a Deployment and a StatefulSet?**
> Deployments are for stateless apps. They use random Pod name suffixes and share a single PVC. StatefulSets are for stateful apps — they give each Pod a stable network identity (pod-0, pod-1) and a dedicated PVC that survives rescheduling. StatefulSets also guarantee ordered creation/deletion.

**Q: Explain the difference between liveness, readiness, and startup probes.**
> - Startup probe: runs first; disables liveness while starting (prevents killing slow-start apps)
> - Readiness probe: controls whether a Pod is added to Service Endpoints. Failure = no traffic, no restart.
> - Liveness probe: controls whether a container is healthy. Failure = kill + restart.

**Q: What happens when you delete a Pod?**
> 1. Pod is removed from Service Endpoints (stops receiving traffic)
> 2. `preStop` hook runs
> 3. `SIGTERM` sent to container process
> 4. `terminationGracePeriodSeconds` countdown (default 30s)
> 5. `SIGKILL` if process hasn't exited
> If managed by a Deployment/ReplicaSet, a replacement Pod is created immediately.

**Q: What is a QoS class and when does it matter?**
> QoS classes are assigned based on resource requests/limits:
> - Guaranteed (requests == limits): last evicted, lowest OOM score
> - Burstable (requests < limits): middle priority
> - BestEffort (no resources): first evicted
> They matter during node memory pressure — kubelet evicts BestEffort pods first.

### Networking

**Q: How does a Service work internally?**
> A Service gets a ClusterIP. kube-proxy on each node watches Endpoints and programs iptables (or ipvs) DNAT rules. When a Pod sends traffic to the ClusterIP:port, iptables randomly selects a healthy backend Pod IP and rewrites the destination IP before the packet leaves the node.

**Q: A Pod can't reach a Service. Walk me through your debugging.**
```
1. kubectl get endpoints <svc> — is it empty? (label mismatch)
2. kubectl get pod — is the backend pod Running and Ready?
3. kubectl exec debug-pod -- curl http://<clusterip>:<port> — can we reach the ClusterIP?
4. kubectl exec debug-pod -- nslookup <svc-name> — does DNS resolve?
5. kubectl describe networkpolicy — is there a policy blocking traffic?
6. On the node: iptables -t nat -L | grep <clusterip> — are rules present?
```

**Q: What is the difference between ClusterIP, NodePort, and LoadBalancer?**
> - ClusterIP: internal-only virtual IP, reachable only within the cluster
> - NodePort: opens a port on every node (30000–32767), allows external access via NodeIP:NodePort
> - LoadBalancer: provisions a cloud load balancer, gets an external IP; includes NodePort and ClusterIP

### Scheduling

**Q: A Pod is stuck in Pending. What do you check?**
```
kubectl describe pod <name> → Events section
Common causes:
- Insufficient CPU/memory: scale cluster or reduce requests
- Taint/toleration mismatch: check node taints vs pod tolerations
- nodeSelector/affinity mismatch: check node labels
- PVC unbound: check storage class and provisioner
- topologySpreadConstraints unsatisfiable: check available zones
```

**Q: What is the difference between nodeSelector and node affinity?**
> nodeSelector is simple key-value matching (hard requirement). Node affinity supports operators (In, NotIn, Exists, Gt, Lt), preferred (soft) rules with weights, and multiple selector terms combined with OR logic.

### Security

**Q: Walk me through RBAC. How do you give a pod access to list secrets?**
```
1. Create a ServiceAccount
2. Create a Role with rules: [{apiGroups:[""], resources:["secrets"], verbs:["list"]}]
3. Create a RoleBinding linking the Role to the ServiceAccount
4. Set serviceAccountName on the Pod spec
```

**Q: What is Pod Security Standards? What does Restricted enforce?**
> PSS defines three levels (Privileged, Baseline, Restricted). Restricted enforces: runAsNonRoot=true, no allowPrivilegeEscalation, readOnlyRootFilesystem, drop all capabilities, RuntimeDefault seccomp profile.

---

## System Design Questions

### Design a Multi-Region Kubernetes Platform

```
Key areas to cover:
□ Multi-cluster strategy (one per region vs shared)
□ Traffic routing: DNS-based (Route53/Cloud DNS) or Global LB
□ Data replication strategy (RDS Multi-Region, DynamoDB Global Tables)
□ GitOps: ArgoCD with multi-cluster ApplicationSets
□ Observability: centralized Prometheus with federation or Thanos
□ Cluster upgrade strategy (staggered rolling upgrades)
□ Disaster recovery: RTO and RPO targets, failover procedure

Sample answer structure:
- 2 regions (us-east-1, eu-west-1)
- EKS in each, managed by Cluster API
- Route53 health checks + latency routing
- ArgoCD in us-east-1 manages both clusters
- Thanos for cross-cluster metrics
- PDB + zone topology spread on all services
- etcd backup to S3 every hour
```

### Design a CI/CD Platform on Kubernetes

```
Key areas to cover:
□ Build: Tekton or GitHub Actions runners on K8s
□ Image registry: ECR/GCR/Artifact Registry
□ Image scanning: Trivy in CI pipeline
□ Deploy: ArgoCD for GitOps
□ Progressive delivery: Argo Rollouts for canary
□ Policy: Kyverno admission webhooks
□ Secrets: ESO syncing from AWS Secrets Manager
□ Observability: Prometheus + Grafana for pipeline metrics
```

### Design an ML Training Platform

```
□ GPU node pools with Karpenter (scale to zero when idle)
□ Training: Kubeflow Training Operator (PyTorchJob)
□ Experiment tracking: MLflow
□ Pipeline orchestration: Argo Workflows or Kubeflow Pipelines
□ Model serving: KServe with canary support
□ Feature store: Feast
□ Data storage: S3 for datasets and artifacts
□ Monitoring: GPU utilization, training loss, serving latency
```

---

## Incident Scenarios

### "All Pods OOMKilled at 3am"

```
Investigation:
1. Check node memory: kubectl top nodes, kubectl describe node
2. Check OOM events: kubectl get events --field-selector reason=OOMKilling
3. Check memory limits vs actual usage: kubectl top pods
4. Check if a recent deployment changed memory requirements

Root cause (common):
- Memory leak introduced in last release
- Traffic spike + insufficient memory limits
- JVM default heap not tuned for container environment

Fix:
- Immediate: increase memory limits or rollback
- Long-term: set JVM -Xmx, add VPA, add memory usage alert
```

### "The Deployment is stuck at 50% rollout"

```
Investigation:
kubectl rollout status deployment/my-app
kubectl describe deployment my-app   # check rollout strategy
kubectl get pods -l app=my-app       # check pod states
kubectl describe pod <new-pod>       # why is new pod not Ready?

Root cause (common):
- Readiness probe failing on new version
- New version can't connect to database (changed env var)
- PodDisruptionBudget blocking old pod removal
- Resource requests too high (scheduler can't place new pods)

Fix:
kubectl rollout undo deployment/my-app   # immediate rollback
# Then investigate the new version's startup failure
```

### "Service latency increased 10x after deployment"

```
Investigation:
1. Prometheus: check p99 latency, error rate, throughput
2. Was it gradual or immediate? (spike vs trend)
3. kubectl top pods — CPU throttling?
4. Check new version's dependencies (new DB queries, new external calls)
5. Distributed traces in Jaeger/Tempo — where is time being spent?

Root cause (common):
- CPU limits causing throttling (new version more CPU-intensive)
- N+1 query introduced
- New synchronous external API call with high latency
- Connection pool exhaustion

Fix:
- Remove CPU limit (or increase it) for the service
- Rollback and fix the slow query/API call
```

---

## CKA / CKAD / CKS Exam Tips

### CKA (Certified Kubernetes Administrator)

```bash
# Exam is 2 hours, 15–20 tasks, 66% to pass
# 100% kubectl, no MCQ

# Critical aliases (set up immediately)
alias k=kubectl
export do="--dry-run=client -o yaml"
export now="--force --grace-period=0"

# Template command
k run nginx --image=nginx $do > pod.yaml
k create deployment my-app --image=nginx --replicas=3 $do > deploy.yaml

# Exam topics (% of exam):
# 25% Cluster Architecture, Installation, Configuration
# 15% Workloads & Scheduling
# 20% Services & Networking
# 10% Storage
# 30% Troubleshooting

# Must know:
# - kubeadm cluster initialization
# - etcd backup and restore
# - Upgrade a cluster
# - NetworkPolicy
# - RBAC
# - PV/PVC
```

### CKAD (Certified Kubernetes Application Developer)

```bash
# 2 hours, 15-20 tasks, 66% to pass
# Focus: application-level objects

# Key topics:
# - Multi-container pods (sidecar, init)
# - Probes (liveness, readiness, startup)
# - ConfigMaps and Secrets
# - Deployments, rollouts
# - Services and Ingress
# - Jobs and CronJobs
# - Helm (basic usage)
# - Resource limits

# Quick patterns
k set image deploy/my-app app=nginx:1.25
k rollout status deploy/my-app
k rollout undo deploy/my-app
k autoscale deploy my-app --min=2 --max=10 --cpu-percent=70
```

### CKS (Certified Kubernetes Security Specialist)

```bash
# Requires CKA first
# 2 hours, 15-20 tasks, 67% to pass

# Key topics:
# - Pod Security Standards
# - RBAC hardening
# - NetworkPolicy
# - Secrets encryption at rest
# - Image scanning (Trivy)
# - Falco runtime security
# - Audit logging
# - kube-bench

# Quick patterns
k create role pod-reader --verb=get,list,watch --resource=pods
k create rolebinding jane-pod-reader --role=pod-reader --user=jane

# Falco rule quick test
falco -r /etc/falco/falco_rules.yaml --validate /etc/falco/falco_rules.yaml
```

### Practice Resources

```bash
# Killer.sh (official simulator, 2 free sessions with exam)
# https://killer.sh

# KodeKloud labs (best for beginners)
# https://kodekloud.com

# Killercoda (free interactive scenarios)
# https://killercoda.com/kubernetes

# Practice cluster setup
cat << 'EOF' | kind create cluster --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
- role: worker
EOF
```

---

## Behavioral Questions

**"Tell me about an incident you caused."**
> Structure: What happened → What was the impact → What you did to fix it → What you learned → What systemic change prevented recurrence. Never blame others.

**"How do you handle alert fatigue?"**
> - Review alert signal-to-noise ratio monthly
> - Delete or mute alerts that fire more than once without action
> - Convert threshold alerts to SLO-based multi-burn-rate alerts
> - Use inhibition rules to suppress child alerts during parent incidents

**"How do you balance reliability and velocity?"**
> Error budgets make this concrete: if the SLO is being met, spend budget on features. If the error budget is nearly depleted, freeze features and focus on reliability.

**"What's the most complex Kubernetes problem you've solved?"**
> Have a specific story ready: the symptom, your investigation process, the root cause, and the fix. Show systematic thinking, not luck.

---

## Resources

| Type | Link |
|------|------|
| Exam | [CKA](https://training.linuxfoundation.org/certification/certified-kubernetes-administrator-cka/) |
| Exam | [CKAD](https://training.linuxfoundation.org/certification/certified-kubernetes-application-developer-ckad/) |
| Exam | [CKS](https://training.linuxfoundation.org/certification/certified-kubernetes-security-specialist/) |
| Practice | [Killer.sh](https://killer.sh/) |
| Practice | [KodeKloud](https://kodekloud.com/) |
| Practice | [Killercoda](https://killercoda.com/kubernetes) |
| Q&A | [CKAD Exercises (dgkanatsios)](https://github.com/dgkanatsios/CKAD-exercises) |
| Q&A | [CKA Study Guide (David-VTUK)](https://github.com/David-VTUK/CKA-StudyGuide) |
