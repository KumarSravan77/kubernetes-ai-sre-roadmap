# 16 — Autoscaling & Cost Optimization

Autoscaling keeps your cluster right-sized under variable load. Cost optimization ensures you're not paying for resources you don't use.

---

## Horizontal Pod Autoscaler (HPA)

HPA scales the number of Pod replicas based on metrics.

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-app-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  minReplicas: 2
  maxReplicas: 20
  metrics:
  # CPU-based scaling
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70   # scale when avg CPU > 70% of requests

  # Memory-based scaling
  - type: Resource
    resource:
      name: memory
      target:
        type: AverageValue
        averageValue: 500Mi

  # Custom metric (from Prometheus adapter)
  - type: Pods
    pods:
      metric:
        name: http_requests_per_second
      target:
        type: AverageValue
        averageValue: 100

  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0    # scale up immediately
      policies:
      - type: Percent
        value: 100                      # double replicas at most per step
        periodSeconds: 15
    scaleDown:
      stabilizationWindowSeconds: 300  # wait 5m before scaling down
      policies:
      - type: Pods
        value: 1                        # remove at most 1 pod per minute
        periodSeconds: 60
```

```bash
kubectl get hpa
kubectl describe hpa my-app-hpa
# Shows: current metrics, target, min/max replicas, last scale event
```

---

## KEDA — Kubernetes Event-Driven Autoscaling

KEDA extends HPA with 50+ scalers: Kafka, SQS, Redis, Prometheus, Cron, etc. Can scale to zero.

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm install keda kedacore/keda --namespace keda --create-namespace
```

### ScaledObject Examples

```yaml
# Scale based on Kafka consumer lag
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: kafka-consumer-scaler
spec:
  scaleTargetRef:
    name: kafka-consumer
  minReplicaCount: 0   # can scale to zero!
  maxReplicaCount: 50
  cooldownPeriod: 60
  triggers:
  - type: kafka
    metadata:
      bootstrapServers: kafka.default.svc:9092
      consumerGroup: my-consumer-group
      topic: orders
      lagThreshold: "100"   # scale up when lag > 100 messages
      offsetResetPolicy: latest
---
# Scale based on SQS queue depth
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: sqs-worker-scaler
spec:
  scaleTargetRef:
    name: sqs-worker
  minReplicaCount: 0
  maxReplicaCount: 30
  triggers:
  - type: aws-sqs-queue
    authenticationRef:
      name: keda-aws-credentials
    metadata:
      queueURL: https://sqs.us-east-1.amazonaws.com/123456789/my-queue
      queueLength: "10"    # one worker per 10 messages
      awsRegion: us-east-1
---
# Scale based on Prometheus metric
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: prometheus-scaler
spec:
  scaleTargetRef:
    name: my-app
  minReplicaCount: 1
  maxReplicaCount: 20
  triggers:
  - type: prometheus
    metadata:
      serverAddress: http://prometheus.monitoring.svc:9090
      metricName: http_requests_rate
      query: |
        sum(rate(http_requests_total{job="my-app"}[2m]))
      threshold: "100"
---
# Cron-based scaling (scale down overnight)
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: cron-scaler
spec:
  scaleTargetRef:
    name: my-app
  triggers:
  - type: cron
    metadata:
      timezone: America/New_York
      start: 0 8 * * 1-5    # 8am weekdays: scale up
      end: 0 20 * * 1-5     # 8pm weekdays: scale down
      desiredReplicas: "10"
```

### ScaledJob (for batch workloads)

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledJob
metadata:
  name: image-processor
spec:
  jobTargetRef:
    template:
      spec:
        containers:
        - name: processor
          image: myorg/processor:latest
        restartPolicy: Never
  minReplicaCount: 0
  maxReplicaCount: 100
  pollingInterval: 10
  successfulJobsHistoryLimit: 5
  failedJobsHistoryLimit: 5
  triggers:
  - type: aws-sqs-queue
    metadata:
      queueURL: https://sqs.us-east-1.amazonaws.com/123/image-jobs
      queueLength: "1"   # one job per message
```

---

## Cluster Autoscaler

CA adds/removes nodes based on pending Pods and node utilization.

```bash
# Install on EKS
helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --set autoDiscovery.clusterName=production \
  --set awsRegion=us-east-1 \
  --set rbac.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::ACCOUNT:role/ClusterAutoscalerRole
```

### Important annotations

```yaml
# Prevent CA from evicting a Pod (e.g., stateful apps)
metadata:
  annotations:
    cluster-autoscaler.kubernetes.io/safe-to-evict: "false"

# Opt in a node group for CA (if not using autodiscovery)
metadata:
  labels:
    k8s.io/cluster-autoscaler/enabled: "true"
    k8s.io/cluster-autoscaler/production: "owned"
```

```bash
# CA logs
kubectl logs -n kube-system -l app=cluster-autoscaler | tail -100

# Check scale-down candidates
kubectl get nodes -l node-role.kubernetes.io/worker \
  -o custom-columns='NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory'

# Force scale-up (create a pending pod)
kubectl run scale-test --image=nginx --requests=cpu=2 --replicas=10
```

---

## Karpenter

Karpenter is a next-generation node provisioner that's faster and more flexible than Cluster Autoscaler.

```bash
helm install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version 0.35.0 \
  --namespace karpenter --create-namespace \
  --set settings.clusterName=production \
  --set settings.interruptionQueue=karpenter-production
```

```yaml
# NodePool — defines what nodes Karpenter can provision
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      nodeClassRef:
        name: default
      requirements:
      - key: karpenter.sh/capacity-type
        operator: In
        values: [spot, on-demand]
      - key: node.kubernetes.io/instance-type
        operator: In
        values: [m5.large, m5.xlarge, m5.2xlarge, m5.4xlarge]
      - key: topology.kubernetes.io/zone
        operator: In
        values: [us-east-1a, us-east-1b, us-east-1c]
  disruption:
    consolidationPolicy: WhenUnderutilized
    consolidateAfter: 30s
  limits:
    cpu: 1000
    memory: 4000Gi
---
# NodeClass — AWS-specific node configuration
apiVersion: karpenter.k8s.aws/v1beta1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2
  role: KarpenterNodeRole-production
  subnetSelectorTerms:
  - tags:
      karpenter.sh/discovery: production
  securityGroupSelectorTerms:
  - tags:
      karpenter.sh/discovery: production
  blockDeviceMappings:
  - deviceName: /dev/xvda
    ebs:
      volumeSize: 100Gi
      volumeType: gp3
      encrypted: true
```

### Karpenter vs Cluster Autoscaler

| | Cluster Autoscaler | Karpenter |
|-|--------------------|-----------|
| **Launch speed** | 3–5 minutes | 30–60 seconds |
| **Bin packing** | Poor | Excellent |
| **Instance diversity** | Node group level | Per-Pod level |
| **Spot handling** | Manual diversification | Automatic |
| **Consolidation** | Manual | Automatic |
| **Cloud support** | All clouds | AWS, Azure (preview) |

---

## Spot/Preemptible Instances

```yaml
# Karpenter: prefer spot, fall back to on-demand
requirements:
- key: karpenter.sh/capacity-type
  operator: In
  values: [spot, on-demand]

# HPA behavior: scale out fast on spot-heavy clusters
# (spots can disappear; need headroom)
behavior:
  scaleUp:
    stabilizationWindowSeconds: 0
    policies:
    - type: Percent
      value: 100
      periodSeconds: 15
```

```yaml
# AWS Node Termination Handler (2-minute warning for spots)
helm install aws-node-termination-handler eks/aws-node-termination-handler \
  --namespace kube-system \
  --set enableSpotInterruptionDraining=true
```

---

## Cost Optimization

### Kubecost

```bash
helm install kubecost cost-analyzer \
  --repo https://kubecost.github.io/cost-analyzer/ \
  --namespace kubecost --create-namespace \
  --set kubecostToken=<token>

kubectl port-forward svc/kubecost-cost-analyzer -n kubecost 9090:9090
```

### OpenCost (open-source Kubecost)

```bash
helm install opencost opencost/opencost --namespace opencost --create-namespace
```

### Key Cost Metrics

```promql
# Cost by namespace (requires cost exporter)
sum(node_total_hourly_cost) by (node) * on(node) group_left(namespace)
  sum(container_memory_allocation_bytes) by (node, namespace) /
  sum(node_memory_MemTotal_bytes) by (node)

# Idle CPU cost
(1 - sum(rate(container_cpu_usage_seconds_total[1h])) by (node) /
  sum(kube_node_status_allocatable{resource="cpu"}) by (node)) *
  sum(node_total_hourly_cost) by (node)
```

### Cost Reduction Strategies

```bash
# 1. Right-size with Goldilocks (VPA recommendations UI)
helm install goldilocks fairwinds-stable/goldilocks --namespace goldilocks
kubectl label namespace production goldilocks.fairwinds.com/enabled=true
kubectl port-forward svc/goldilocks-dashboard -n goldilocks 8080:80

# 2. Scale non-prod to zero overnight
helm install kube-downscaler hjacobs/kube-downscaler \
  --namespace kube-system

# Annotate a namespace to downscale nights + weekends
kubectl annotate namespace staging \
  downscaler/uptime="Mon-Fri 08:00-20:00 US/Eastern"

# 3. Use spot for stateless workloads
# Already covered in Karpenter NodePool above

# 4. Delete idle PVCs
kubectl get pvc -A | grep Released

# 5. Remove unused images from nodes (containerd)
crictl rmi --prune
```

---

## VPA + HPA Together

```yaml
# Use VPA for memory (avoid OOMKills) + KEDA for replicas (avoid conflicting on CPU)
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: my-app-vpa
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  updatePolicy:
    updateMode: "Auto"
  resourcePolicy:
    containerPolicies:
    - containerName: app
      controlledResources: [memory]   # VPA controls memory only
      controlledValues: RequestsOnly  # don't set limits
```

---

## SRE Lens

- **Scale to zero** with KEDA reduces costs dramatically for intermittent workloads. Batch workers that are idle 20 hours/day should scale to zero.
- **Karpenter consolidation** automatically removes underutilized nodes. Set `consolidateAfter: 30s` for aggressive cost reduction.
- **Spot instances need PDBs** — if a spot node is reclaimed, the workload must be schedulable elsewhere immediately.
- **Right-size before scaling** — autoscaling an oversized app wastes money. Use VPA recommendations first, then enable HPA.
- **Set namespace cost budgets** — notify teams when they exceed their monthly allocation.

---

## Resources

| Type | Link |
|------|------|
| Official Docs | [HPA](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/) |
| Official Docs | [Cluster Autoscaler](https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler) |
| Official Docs | [KEDA](https://keda.sh/docs/) |
| Official Docs | [Karpenter](https://karpenter.sh/docs/) |
| Tool | [Kubecost](https://www.kubecost.com/) |
| Tool | [OpenCost](https://www.opencost.io/) |
| Tool | [Goldilocks](https://goldilocks.docs.fairwinds.com/) |
| Tool | [kube-downscaler](https://codeberg.org/hjacobs/kube-downscaler) |
