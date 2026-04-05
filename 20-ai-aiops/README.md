# 20 — AI & AIOps

AIOps applies AI/ML to automate and enhance SRE workflows — from anomaly detection to LLM-powered root cause analysis.

---

## AIOps Overview

```
Traditional SRE:
  Alert fires → SRE investigates → SRE fixes → SRE documents

AIOps-enhanced SRE:
  Alert fires → AI triages + summarizes → SRE reviews + approves fix
                                         OR auto-remediates low-risk issues
```

Key capabilities:
- **Anomaly detection** — catch issues before users notice
- **Alert correlation** — group related alerts into incidents
- **Root cause analysis** — identify the likely cause automatically
- **Runbook automation** — execute known fixes automatically
- **Predictive scaling** — scale before traffic spikes, not after

---

## K8sGPT — AI-Powered Cluster Analysis

K8sGPT analyzes your cluster for problems and explains them in plain English.

```bash
# Install
brew tap k8sgpt-ai/k8sgpt
brew install k8sgpt

# Configure LLM backend
k8sgpt auth add --backend openai --model gpt-4 --password $OPENAI_API_KEY

# Also supports: localai, ollama, anthropic, google, azure

# Analyze cluster
k8sgpt analyze

# Example output:
# Error: 0/3 nodes are available
# Error message: Pending Pod default/my-app-6d7b9c8f7-xk2m4
# Solution: The pod is pending because there are insufficient resources
# on any of the 3 nodes. Consider:
# 1. Adding more nodes with kubectl scale
# 2. Reducing resource requests for the pod
# 3. Checking for taints that might prevent scheduling

# Deploy as an operator in-cluster
k8sgpt operator install
```

```yaml
# K8sGPT Operator custom resource
apiVersion: core.k8sgpt.ai/v1alpha1
kind: K8sGPT
metadata:
  name: k8sgpt-sample
  namespace: k8sgpt-operator-system
spec:
  ai:
    enabled: true
    model: gpt-4
    backend: openai
    secret:
      name: k8sgpt-sample-secret
      key: openai-api-key
  noCache: false
  filters: []
  sink:
    type: slack
    webhook: https://hooks.slack.com/services/xxx/yyy/zzz
  anonymize: true    # anonymize cluster names/namespaces before sending to AI
  version: v0.3.41
```

---

## Robusta Holmes — AI Incident Investigation

```bash
helm install robusta robusta/robusta \
  --namespace robusta --create-namespace \
  --set ai.enabled=true \
  --set ai.openai.apiKey=$OPENAI_API_KEY
```

```yaml
# playbook.yaml — define automated investigation triggers
triggers:
- on_prometheus_alert:
    alert_name: KubePodCrashLooping
actions:
- holmes_investigate:
    ask: |
      Why is this pod crash looping?
      What is the root cause?
      What should be done to fix it?
```

---

## Building an LLM-Powered Alert Pipeline

```python
# alert_pipeline.py — Prometheus alert → LLM analysis → Slack notification
import anthropic
import json
import requests
from flask import Flask, request

app = Flask(__name__)
client = anthropic.Anthropic()  # uses ANTHROPIC_API_KEY env var

def get_cluster_context(pod_name: str, namespace: str) -> str:
    """Gather relevant kubectl output for context."""
    import subprocess

    cmds = [
        f"kubectl describe pod {pod_name} -n {namespace}",
        f"kubectl logs {pod_name} -n {namespace} --previous --tail=50",
        f"kubectl get events -n {namespace} --field-selector involvedObject.name={pod_name}",
    ]
    context = ""
    for cmd in cmds:
        result = subprocess.run(cmd.split(), capture_output=True, text=True, timeout=30)
        context += f"\n\n--- {cmd} ---\n{result.stdout}"
    return context


def analyze_alert(alert: dict) -> str:
    """Use Claude to analyze a Kubernetes alert."""
    pod_name = alert.get("labels", {}).get("pod", "unknown")
    namespace = alert.get("labels", {}).get("namespace", "default")
    alert_name = alert.get("labels", {}).get("alertname", "unknown")

    context = get_cluster_context(pod_name, namespace)

    message = client.messages.create(
        model="claude-opus-4-6",
        max_tokens=1024,
        messages=[
            {
                "role": "user",
                "content": f"""You are an SRE expert. Analyze this Kubernetes alert and provide:
1. Root cause (1-2 sentences)
2. Immediate action (what to do now)
3. Long-term fix (prevent recurrence)

Alert: {alert_name}
Pod: {pod_name}
Namespace: {namespace}

Cluster context:
{context}

Be concise and actionable.""",
            }
        ],
    )
    return message.content[0].text


def send_to_slack(alert_name: str, analysis: str, webhook_url: str):
    payload = {
        "blocks": [
            {
                "type": "header",
                "text": {"type": "plain_text", "text": f"Alert: {alert_name}"},
            },
            {
                "type": "section",
                "text": {"type": "mrkdwn", "text": f"*AI Analysis:*\n{analysis}"},
            },
        ]
    }
    requests.post(webhook_url, json=payload)


@app.route("/webhook", methods=["POST"])
def alertmanager_webhook():
    data = request.json
    for alert in data.get("alerts", []):
        analysis = analyze_alert(alert)
        send_to_slack(
            alert["labels"].get("alertname"),
            analysis,
            "https://hooks.slack.com/services/xxx",
        )
    return {"status": "ok"}, 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
```

```yaml
# Deploy the alert pipeline
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ai-alert-pipeline
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: pipeline
        image: myorg/ai-alert-pipeline:latest
        env:
        - name: ANTHROPIC_API_KEY
          valueFrom:
            secretKeyRef:
              name: ai-credentials
              key: anthropic-api-key
---
# Add to Alertmanager config
receivers:
- name: ai-pipeline
  webhook_configs:
  - url: http://ai-alert-pipeline.default.svc:8080/webhook
    send_resolved: false
```

---

## Anomaly Detection on Metrics

### Prometheus + Alerting Rules (statistical)

```yaml
# Alert when a metric deviates significantly from its historical baseline
groups:
- name: anomaly-detection
  rules:
  # Error rate anomaly: current rate is 5x the 1-week average
  - alert: ErrorRateAnomaly
    expr: |
      (
        rate(http_requests_total{status=~"5.."}[5m]) /
        rate(http_requests_total[5m])
      )
      >
      5 * (
        avg_over_time(
          (rate(http_requests_total{status=~"5.."}[5m]) /
           rate(http_requests_total[5m]))[7d:5m]
        )
      )
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "Error rate is 5x higher than last week's average"

  # Latency anomaly: p99 is 3x the daily average
  - alert: LatencyAnomaly
    expr: |
      histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))
      >
      3 * avg_over_time(
        histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))[1d:5m]
      )
    for: 10m
```

### Machine Learning-Based Anomaly Detection

```python
# anomaly_detector.py — Prophet-based forecasting
from prophet import Prophet
import pandas as pd
from prometheus_api_client import PrometheusConnect

prom = PrometheusConnect(url="http://prometheus.monitoring.svc:9090")

# Fetch historical data
metric_data = prom.get_metric_range_data(
    metric_name='http_requests_total',
    label_config={'job': 'my-app'},
    start_time='2024-01-01T00:00:00Z',
    end_time='2024-01-07T23:59:59Z',
)

# Train Prophet model
df = pd.DataFrame({
    'ds': [point[0] for point in metric_data[0]['values']],
    'y': [float(point[1]) for point in metric_data[0]['values']],
})
df['ds'] = pd.to_datetime(df['ds'], unit='s')

model = Prophet(
    changepoint_prior_scale=0.05,
    seasonality_prior_scale=10,
    daily_seasonality=True,
    weekly_seasonality=True,
)
model.fit(df)

# Predict next hour
future = model.make_future_dataframe(periods=12, freq='5T')
forecast = model.predict(future)

# Alert if current value is outside prediction interval
current_value = float(prom.get_current_metric_value('http_requests_total{job="my-app"}')[0]['value'][1])
latest_forecast = forecast.iloc[-1]

if current_value > latest_forecast['yhat_upper'] * 1.5:
    # Fire anomaly alert
    print(f"ANOMALY: {current_value} >> expected max {latest_forecast['yhat_upper']}")
```

---

## Auto-Remediation with Argo Events

```yaml
# EventSource — watch Prometheus alerts
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: prometheus-alerts
spec:
  webhook:
    prometheus:
      port: "12000"
      endpoint: /alerts
      method: POST
---
# Sensor — trigger remediation workflow
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: pod-restart-remediator
spec:
  dependencies:
  - name: prometheus-alert
    eventSourceName: prometheus-alerts
    eventName: prometheus
    filters:
      data:
      - path: body.alerts.0.labels.alertname
        type: string
        value: KubePodCrashLooping
  triggers:
  - template:
      name: restart-pod
      argoWorkflow:
        operation: submit
        source:
          resource:
            apiVersion: argoproj.io/v1alpha1
            kind: Workflow
            metadata:
              generateName: restart-crashing-pod-
            spec:
              entrypoint: restart
              templates:
              - name: restart
                steps:
                - - name: ai-check
                    template: check-with-ai
                - - name: restart-if-approved
                    template: restart-pod
                    when: "{{steps.ai-check.outputs.result}} == approved"

              - name: check-with-ai
                script:
                  image: python:3.11
                  command: [python]
                  source: |
                    import subprocess, anthropic
                    # Get pod status and ask AI if it's safe to restart
                    # Returns "approved" or "escalate"
                    print("approved")

              - name: restart-pod
                container:
                  image: bitnami/kubectl:latest
                  command: [kubectl, rollout, restart, "deployment/{{workflow.parameters.deployment}}"]
```

---

## LLM Agent for SRE Tasks

```python
# sre_agent.py — Claude-powered SRE agent
import anthropic
import subprocess
import json

client = anthropic.Anthropic()

# Define tools the agent can use
tools = [
    {
        "name": "kubectl",
        "description": "Run a kubectl command to inspect or modify the cluster",
        "input_schema": {
            "type": "object",
            "properties": {
                "command": {
                    "type": "string",
                    "description": "The kubectl command to run (without the 'kubectl' prefix)",
                }
            },
            "required": ["command"],
        },
    },
    {
        "name": "prometheus_query",
        "description": "Query Prometheus for metrics",
        "input_schema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "PromQL query"}
            },
            "required": ["query"],
        },
    },
]

def run_kubectl(command: str) -> str:
    """Execute a kubectl command (read-only in this example)."""
    # Safety: only allow read operations
    allowed_verbs = ["get", "describe", "logs", "top", "explain"]
    verb = command.strip().split()[0]
    if verb not in allowed_verbs:
        return f"Error: Only read operations are allowed. Verb '{verb}' is not permitted."

    result = subprocess.run(
        ["kubectl"] + command.split(),
        capture_output=True, text=True, timeout=30
    )
    return result.stdout or result.stderr


def query_prometheus(query: str) -> str:
    import requests
    resp = requests.get(
        "http://prometheus.monitoring.svc:9090/api/v1/query",
        params={"query": query}
    )
    return json.dumps(resp.json()["data"]["result"][:5], indent=2)


def investigate(user_query: str) -> str:
    """Run the SRE agent loop."""
    messages = [{"role": "user", "content": user_query}]

    while True:
        response = client.messages.create(
            model="claude-opus-4-6",
            max_tokens=4096,
            tools=tools,
            messages=messages,
            system="You are an expert SRE. Investigate Kubernetes issues by querying the cluster. Be methodical: gather facts, form a hypothesis, verify it, then provide a clear diagnosis and recommended fix.",
        )

        messages.append({"role": "assistant", "content": response.content})

        if response.stop_reason == "end_turn":
            # Extract text response
            for block in response.content:
                if hasattr(block, "text"):
                    return block.text
            break

        # Handle tool calls
        tool_results = []
        for block in response.content:
            if block.type == "tool_use":
                if block.name == "kubectl":
                    result = run_kubectl(block.input["command"])
                elif block.name == "prometheus_query":
                    result = query_prometheus(block.input["query"])
                else:
                    result = "Unknown tool"

                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": block.id,
                    "content": result,
                })

        messages.append({"role": "user", "content": tool_results})


# Example usage
if __name__ == "__main__":
    diagnosis = investigate(
        "The frontend service is returning 503 errors. "
        "Investigate what's wrong and tell me how to fix it."
    )
    print(diagnosis)
```

---

## Log Intelligence

```python
# log_clustering.py — cluster log lines to find patterns
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.cluster import DBSCAN
import numpy as np

def cluster_logs(log_lines: list[str], eps: float = 0.3) -> dict:
    """Group similar log lines to reduce noise."""
    # Normalize: remove timestamps, IPs, UUIDs
    import re
    normalized = [
        re.sub(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}', 'TIMESTAMP', line)
        for line in log_lines
    ]
    normalized = [
        re.sub(r'\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b', 'UUID', line)
        for line in normalized
    ]

    vectorizer = TfidfVectorizer(analyzer='word', max_features=100)
    X = vectorizer.fit_transform(normalized).toarray()

    clustering = DBSCAN(eps=eps, min_samples=2, metric='cosine')
    labels = clustering.fit_predict(X)

    clusters = {}
    for i, label in enumerate(labels):
        clusters.setdefault(label, []).append(log_lines[i])

    # Return representative line + count for each cluster
    return {
        label: {"count": len(lines), "representative": lines[0]}
        for label, lines in clusters.items()
    }
```

---

## SRE Lens

- **Human-in-the-loop for destructive actions** — auto-remediation should be limited to safe, reversible actions (pod restarts, scaling). Always require human approval for deletions and schema changes.
- **Anonymize before sending to LLMs** — customer data, internal hostnames, and secrets should be stripped before sending cluster context to external APIs.
- **False positives erode trust** — tune anomaly detection carefully. Too many false alerts make engineers ignore AI recommendations.
- **Start with analysis, not automation** — begin by having AI explain problems. Add automation only after the explanations are consistently accurate.

---

## Resources

| Type | Link |
|------|------|
| Tool | [K8sGPT](https://k8sgpt.ai/) |
| Tool | [Robusta Holmes](https://home.robusta.dev/holmes/) |
| Tool | [Argo Events](https://argoproj.github.io/argo-events/) |
| Official Docs | [Anthropic API](https://docs.anthropic.com/) |
| Official Docs | [OpenAI API](https://platform.openai.com/docs/) |
| Framework | [LangChain](https://python.langchain.com/docs/) |
| Blog | [AIOps at CNCF](https://www.cncf.io/blog/2023/11/14/aiops-in-the-cloud-native-ecosystem/) |
| Paper | [Prometheus Anomaly Detection](https://arxiv.org/abs/2009.10923) |
