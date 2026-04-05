# 11 — Observability

You can't manage what you can't measure. This section covers the three pillars of observability — metrics, logs, and traces — and how to build SLO-based alerting.

---

## The Three Pillars

| Pillar | Question it answers | Tool |
|--------|---------------------|------|
| **Metrics** | What is the system doing? | Prometheus + Grafana |
| **Logs** | What happened and when? | Loki / Fluentd / Fluent Bit |
| **Traces** | Why is this request slow? | Jaeger / Tempo + OpenTelemetry |

---

## Metrics with Prometheus

### Architecture

```
App (exposes /metrics)
      │
      ▼
Prometheus (scrapes every 15–30s)
      │
      ├── Rules Engine (recording + alerting rules)
      │
      ├── Alertmanager (routing, grouping, silencing)
      │
      └── Grafana (visualization)
```

### Install kube-prometheus-stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.adminPassword=admin \
  --set alertmanager.enabled=true \
  --set prometheus.prometheusSpec.retention=15d \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=fast-ssd \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=50Gi

kubectl get pods -n monitoring
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

### Key Kubernetes Metrics

```bash
# kube-state-metrics — cluster state
kube_pod_status_phase{phase="Running"}
kube_deployment_status_replicas_unavailable
kube_node_status_condition{condition="Ready", status="true"}
kube_pod_container_resource_requests{resource="cpu"}

# node-exporter — node-level
node_cpu_seconds_total
node_memory_MemAvailable_bytes
node_disk_read_bytes_total
node_network_receive_bytes_total

# kubelet / cadvisor — container metrics
container_cpu_usage_seconds_total
container_memory_working_set_bytes
container_cpu_cfs_throttled_periods_total

# Kubernetes API server
apiserver_request_duration_seconds
apiserver_request_total
etcd_request_duration_seconds
```

### PromQL Essentials

```promql
# Rate of requests (per second over 5m window)
rate(http_requests_total[5m])

# Error rate %
rate(http_requests_total{status=~"5.."}[5m]) /
rate(http_requests_total[5m]) * 100

# 99th percentile latency
histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))

# CPU usage by pod
sum(rate(container_cpu_usage_seconds_total[5m])) by (pod)

# Memory by container
sum(container_memory_working_set_bytes) by (pod, container)

# Node CPU usage %
1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) by (instance)

# Pods not running
kube_pod_status_phase{phase!~"Running|Succeeded"} == 1
```

### Recording Rules

Pre-compute expensive queries for faster dashboards:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: app-recording-rules
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
  - name: app.recording
    interval: 1m
    rules:
    - record: job:http_requests:rate5m
      expr: sum(rate(http_requests_total[5m])) by (job)

    - record: job:http_error_rate:rate5m
      expr: |
        sum(rate(http_requests_total{status=~"5.."}[5m])) by (job)
        /
        sum(rate(http_requests_total[5m])) by (job)
```

---

## SLO-Based Alerting

### Define SLIs and SLOs

```
SLI (Service Level Indicator): measurable quantity
  e.g., "fraction of requests served in < 200ms"

SLO (Service Level Objective): target for SLI
  e.g., "99.9% of requests served in < 200ms over 30 days"

Error Budget: 1 - SLO = how much unreliability you can afford
  99.9% SLO → 0.1% error budget → 43.8 min/month
```

### Multi-Window Multi-Burn-Rate Alerts

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: slo-alerts
  namespace: monitoring
spec:
  groups:
  - name: slo.availability
    rules:
    # Fast burn: consuming budget 14x faster than sustainable → page immediately
    - alert: HighErrorBudgetBurn
      expr: |
        (
          job:http_error_rate:rate1h{job="my-app"} > (14 * 0.001)
          and
          job:http_error_rate:rate5m{job="my-app"} > (14 * 0.001)
        )
      for: 2m
      labels:
        severity: critical
        slo: availability
      annotations:
        summary: "High error budget burn rate for my-app"
        description: "Error rate {{ $value | humanizePercentage }} is burning budget 14x fast"

    # Slow burn: consuming budget 6x faster → ticket, no page
    - alert: MediumErrorBudgetBurn
      expr: |
        (
          job:http_error_rate:rate6h{job="my-app"} > (6 * 0.001)
          and
          job:http_error_rate:rate30m{job="my-app"} > (6 * 0.001)
        )
      for: 15m
      labels:
        severity: warning
        slo: availability
```

### Alertmanager Config

```yaml
# alertmanager-config.yaml
global:
  resolve_timeout: 5m
  slack_api_url: <webhook-url>

route:
  group_by: [alertname, cluster, namespace]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  receiver: default

  routes:
  - matchers:
    - severity=critical
    receiver: pagerduty
    repeat_interval: 1h

  - matchers:
    - severity=warning
    receiver: slack-warnings

receivers:
- name: default
  slack_configs:
  - channel: "#alerts"
    text: "{{ range .Alerts }}{{ .Annotations.description }}\n{{ end }}"

- name: pagerduty
  pagerduty_configs:
  - service_key: <service-key>

- name: slack-warnings
  slack_configs:
  - channel: "#sre-warnings"

inhibit_rules:
- source_matchers:
  - severity=critical
  target_matchers:
  - severity=warning
  equal: [alertname, cluster, namespace]
```

---

## ServiceMonitor (Prometheus Operator)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-app
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app: my-app
  namespaceSelector:
    matchNames:
    - production
  endpoints:
  - port: metrics        # named port on the Service
    interval: 15s
    path: /metrics
    scheme: http
    tlsConfig:
      insecureSkipVerify: false
```

---

## Logging with Loki + Fluent Bit

### Architecture

```
Pod stdout/stderr
      │
      ▼
Fluent Bit (DaemonSet) — tail /var/log/pods/**/*.log
      │   enriches with k8s metadata (namespace, pod, container)
      ▼
Loki (log aggregation, label-based indexing)
      │
      ▼
Grafana (LogQL queries)
```

### Install Loki Stack

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm install loki-stack grafana/loki-stack \
  --namespace monitoring \
  --set grafana.enabled=false \
  --set loki.persistence.enabled=true \
  --set loki.persistence.storageClassName=fast-ssd \
  --set loki.persistence.size=50Gi \
  --set fluent-bit.enabled=true
```

### LogQL Queries

```logql
# All logs from a namespace
{namespace="production"}

# Error logs for a specific app
{namespace="production", app="my-app"} |= "ERROR"

# JSON parsing + filter
{app="api"} | json | status_code >= 500

# Rate of error logs
rate({app="api"} |= "ERROR" [5m])

# Extract a field and aggregate
{app="api"} | json | line_format "{{.method}} {{.path}} {{.duration_ms}}"

# Top 10 slowest requests
topk(10, sum by (path) (
  rate({app="api"} | json | unwrap duration_ms [5m])
))
```

### Fluent Bit DaemonSet Config

```yaml
# Key config snippet
[INPUT]
    Name tail
    Path /var/log/pods/*/*/*.log
    Parser cri
    Tag kube.*
    Refresh_Interval 5
    Mem_Buf_Limit 50MB

[FILTER]
    Name kubernetes
    Match kube.*
    Kube_URL https://kubernetes.default.svc:443
    Merge_Log On
    Keep_Log Off
    K8S-Logging.Parser On

[OUTPUT]
    Name loki
    Match kube.*
    Host loki.monitoring.svc.cluster.local
    Port 3100
    Labels job=fluent-bit, namespace=$kubernetes['namespace_name']
```

---

## Distributed Tracing with OpenTelemetry

### OpenTelemetry Collector

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: otel-collector
spec:
  mode: DaemonSet
  config: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
      prometheus:
        config:
          scrape_configs:
          - job_name: 'otel-collector'
            scrape_interval: 10s

    processors:
      batch:
        send_batch_size: 1000
        timeout: 10s
      memory_limiter:
        limit_mib: 400
        spike_limit_mib: 100
      resource:
        attributes:
        - key: k8s.cluster.name
          value: production
          action: insert

    exporters:
      otlp:
        endpoint: tempo.monitoring.svc.cluster.local:4317
        tls:
          insecure: true
      prometheus:
        endpoint: "0.0.0.0:8889"
      loki:
        endpoint: http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push

    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch, resource]
          exporters: [otlp]
        metrics:
          receivers: [prometheus]
          processors: [batch]
          exporters: [prometheus]
```

### Instrument a Go App

```go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    "go.opentelemetry.io/otel/sdk/trace"
)

func initTracer(ctx context.Context) (*trace.TracerProvider, error) {
    exporter, err := otlptracegrpc.New(ctx,
        otlptracegrpc.WithEndpoint("otel-collector:4317"),
        otlptracegrpc.WithInsecure(),
    )
    tp := trace.NewTracerProvider(
        trace.WithBatcher(exporter),
        trace.WithResource(resource.NewWithAttributes(
            semconv.SchemaURL,
            semconv.ServiceName("my-service"),
        )),
    )
    otel.SetTracerProvider(tp)
    return tp, nil
}

// In handler:
tracer := otel.Tracer("my-service")
ctx, span := tracer.Start(ctx, "process-order")
defer span.End()
span.SetAttributes(attribute.String("order.id", orderID))
```

---

## Grafana Dashboards

```bash
# Access Grafana
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

# Import community dashboards
# Kubernetes Cluster Overview: dashboard ID 7249
# Node Exporter Full: dashboard ID 1860
# Kubernetes Pods: dashboard ID 6417
```

### Essential Dashboard Panels

```promql
# Cluster CPU utilization
sum(rate(container_cpu_usage_seconds_total{container!=""}[5m])) /
sum(kube_node_status_allocatable{resource="cpu"}) * 100

# Memory utilization
sum(container_memory_working_set_bytes{container!=""}) /
sum(kube_node_status_allocatable{resource="memory"}) * 100

# Pod restart rate
sum(increase(kube_pod_container_status_restarts_total[1h])) by (pod, namespace)

# Request success rate
sum(rate(http_requests_total{status!~"5.."}[5m])) /
sum(rate(http_requests_total[5m])) * 100

# P99 latency
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, job))
```

---

## Continuous Profiling

```bash
# Pyroscope — continuous profiling
helm install pyroscope grafana/pyroscope -n monitoring

# Parca — continuous profiling
kubectl apply -f https://github.com/parca-dev/parca/releases/latest/download/kubernetes-manifest.yaml
```

---

## SRE Lens

- **Alert on symptoms, not causes** — alert on "high error rate" not "CPU high". Users care about errors and latency.
- **Error budget alerts beat threshold alerts** — multi-burn-rate SLO alerts tell you urgency (fast burn = page now, slow burn = ticket).
- **Structured logs** — JSON logs are queryable. `{"level":"error","msg":"db timeout","duration_ms":5000}` beats `ERROR: db timeout after 5s`.
- **Keep traces, metrics, and logs correlated** — put `trace_id` in log lines so you can jump from logs to traces.

---

## Resources

| Type | Link |
|------|------|
| Official Docs | [Prometheus](https://prometheus.io/docs/) |
| Official Docs | [OpenTelemetry](https://opentelemetry.io/docs/) |
| Official Docs | [Grafana](https://grafana.com/docs/) |
| Official Docs | [Loki](https://grafana.com/docs/loki/latest/) |
| Tool | [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) |
| Tool | [Grafana Tempo](https://grafana.com/docs/tempo/latest/) |
| Tool | [Pyroscope](https://pyroscope.io/docs/) |
| Book | *Site Reliability Engineering* (Google, free online) |
| Blog | [SLO Alerting Deep Dive](https://sre.google/workbook/alerting-on-slos/) |
