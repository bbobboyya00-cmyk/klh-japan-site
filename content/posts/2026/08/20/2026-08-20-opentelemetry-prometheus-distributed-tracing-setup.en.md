---
title: "Implementation of Distributed Tracing and Metrics Visualization using OpenTelemetry and Prometheus"
slug: "opentelemetry-prometheus-distributed-tracing-setup"
date: 2026-08-20T12:43:36+09:00
draft: false
image: ""
description: "Summarizes the deployment of OpenTelemetry Collector, instrumentation methods, and steps for building an observability platform integrated with Prometheus and Grafana Exemplars in a microservices environment."
categories: ["DevOps Logistics"]
tags: ["opentelemetry", "opentelemetry-collector", "prometheus", "grafana", "distributed-tracing"]
author: "K-Life Hack"
---

## Observability Challenges and Architectural Background in Distributed Systems

With the spread of microservices architecture, backend systems have evolved into forms where multiple independent services communicate asynchronously or via RPC calls. While traditional monolithic architectures allowed failure detection through single-process logs and server-level resource monitoring, distributed environments make it difficult to locate failure points and trace the root cause of latency degradation because requests cross numerous nodes.


When logs, metrics, and traces are collected using separate protocols or agents, context correlation is lost, leading to increased MTTR (Mean Time to Restore). OpenTelemetry (OTel) is a vendor-neutral standard driven by the CNCF that provides a foundation for unified collection, processing, and exporting of various telemetry data via the OpenTelemetry Protocol (OTLP). This article documents the implementation steps for deploying the OpenTelemetry Collector, instrumenting applications, and establishing a visualization pipeline using Prometheus and Grafana Exemplars.



---

## OpenTelemetry Collector Configuration and Deployment

The OpenTelemetry Collector is a proxy component that receives, processes (batching, memory limiting, sampling), and exports telemetry data sent from applications to external backends. By inserting the Collector, a loosely coupled architecture is achieved where applications point only to the OTLP endpoint without directly depending on specific monitoring tool SDKs.



### Kubernetes Manifest Definition (`opentelemetry-collector.yaml`)

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: otel-collector
  namespace: observability
spec:
  mode: deployment
  image: otel/opentelemetry-collector-contrib:0.94.0
  config:
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    processors:
      batch:
        send_batch_size: 100
        timeout: 10s
      memory_limiter:
        check_interval: 1s
        limit_percentage: 75
        spike_limit_percentage: 20
    exporters:
      prometheus:
        endpoint: 0.0.0.0:8889
      otlp/jaeger:
        endpoint: jaeger-collector.observability.svc.cluster.local:4317
        tls:
          insecure: true
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [otlp/jaeger]
        metrics:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [prometheus]
```

### 🛠️ Pipeline Control Highlights

- <b>memory_limiter</b>: Controls memory usage thresholds before batch processing to prevent the Collector process from being OOMKilled due to sudden traffic spikes.
- <b>batch</b>: Groups individual HTTP/gRPC requests before sending them to the backend, reducing network overhead.
- <b>exporters</b>: Exports trace data to Jaeger's OTLP receiver and exposes metrics externally as an endpoint (port 8889) scrapeable by Prometheus.

---

## Application-Layer Instrumentation

### 1. Automatic and Manual Instrumentation in Python (Flask)

In a Python environment, implementation is done by combining <code>opentelemetry-sdk</code> with instrumentation libraries for various frameworks.



```python
from flask import Flask, request
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor

# Configure resource metadata
resource = Resource.create({
    "service.name": "order-api",
    "service.version": "1.0.0",
    "deployment.environment": "production"
})

# Initialize TracerProvider and register BatchSpanProcessor
provider = TracerProvider(resource=resource)
exporter = OTLPSpanExporter(
    endpoint="otel-collector.observability.svc.cluster.local:4317",
    insecure=True
)
processor = BatchSpanProcessor(exporter)
provider.add_span_processor(processor)
trace.set_tracer_provider(provider)

app = Flask(__name__)

# Enable auto-instrumentation
FlaskInstrumentor().instrument_app(app)
RequestsInstrumentor().instrument()

@app.route("/checkout", methods=["POST"])
def checkout():
    tracer = trace.get_tracer(__name__)
    # Visualize business logic by creating a manual span
    with tracer.start_as_current_span("process_payment") as span:
        user_id = request.headers.get("X-User-ID", "anonymous")
        span.set_attribute("app.user_id", user_id)
        span.set_attribute("app.payment_method", "credit_card")
        
        # Simulate internal processing
        return {"status": "success", "order_id": "ORD-9482"}, 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
```

### 2. Agent Application in Java (Spring Boot)

In Java applications, using a Java Agent that dynamically instruments bytecode allows instrumentation without modifying the source code.



```properties
# Configure in application.properties or environment variables
otel.exporter.otlp.endpoint=http://otel-collector.observability.svc.cluster.local:4317
otel.service.name=payment-service
otel.traces.sampler=always_on
```

JVM startup parameters:



```bash
java -javaagent:/path/to/opentelemetry-javaagent.jar -jar app.jar
```

---

## Integration of Prometheus and Grafana Exemplars

To connect time-series metric data with distributed traces, use Grafana's Exemplars feature. This makes it possible to jump directly from a spiked single data point on a latency graph to the corresponding trace ID.



### Prometheus Scrape Configuration (`prometheus.yml`)

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'otel-collector'
    static_configs:
      - targets: ['otel-collector.observability.svc.cluster.local:8889']
```

### PromQL and Exemplar Definition in Grafana Panels

Enable Exemplars in the panel definition of the Grafana dashboard.



```json
{
  "datasource": {
    "type": "prometheus",
    "uid": "prometheus-ds"
  },
  "fieldConfig": {
    "defaults": {
      "custom": {
        "drawStyle": "line",
        "lineInterpolation": "linear"
      }
    }
  },
  "targets": [
    {
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus-ds"
      },
      "editorMode": "code",
      "exemplar": true,
      "expr": "histogram_quantile(0.99, sum(rate(http_server_duration_milliseconds_bucket[5m])) by (le))",
      "legendFormat": "p99 Latency",
      "refId": "A"
    }
  ],
  "title": "HTTP Request Duration (p99) with Exemplars",
  "type": "timeseries"
}
```

---

## 💡 Tail-based Sampling Strategy

Persisting 100% of traces rapidly increases storage costs and network load. Because head-based sampling (random sampling at request start) risks missing critical error traces, tail-based sampling is introduced to make sampling decisions on the Collector side after the request completes.



```yaml
processors:
  tail_sampling:
    decision_wait: 10s
    num_traces: 10000
    expected_new_traces_per_sec: 2000
    policies:
      - name: status_code_policy
        type: status_code
        status_code: { status_codes: [ERROR] }
      - name: latency_policy
        type: latency
        latency: { threshold_ms: 1000 }
      - name: probabilistic_policy
        type: probabilistic
        probabilistic: { sampling_percentage: 5.0 }
```

With the above configuration, traces containing error statuses such as HTTP 5xx and latency spans exceeding 1000ms are retained at 100%, while successful requests are downsampled to 5%.



---

## ⚠️ Troubleshooting

### 1. Broken Traces Due to Missing W3C Context Propagation

- <b>Symptom</b>: In calls from Service A to Service B, traces are not connected as a single trace in Jaeger, generating separate Trace IDs.
- <b>Cause</b>: The <code>traceparent</code> header is not propagated to downstream services in asynchronous workers or custom HTTP client implementations.
- <b>Solution</b>: Perform explicit context injection before sending HTTP requests.

```python
from opentelemetry.propagate import inject
import requests

headers = {}
inject(headers)
response = requests.get("http://downstream-service/api", headers=headers)
```

### 2. Port Unreachable and Name Resolution Errors

- <b>Symptom</b>: <code>Failed to export spans: StatusCode.UNAVAILABLE</code> is logged in application logs.
- <b>Verification Steps</b>: Verify connectivity to the Collector endpoint from inside the container.

```text
$ kubectl exec -it deploy/order-api -n default -- nc -zv otel-collector.observability.svc.cluster.local 4317
Connection to otel-collector.observability.svc.cluster.local (10.96.120.45) 4317 port [tcp/*] succeeded!

$ kubectl logs -l app.kubernetes.io/name=opentelemetry-collector -n observability --tail=20
2026-08-20T04:12:01.892Z	info	service/telemetry.go:84	Everything is ready. Begin running and processing data.
2026-08-20T04:12:05.104Z	info	TracesExporter	{"kind": "exporter", "data_type": "traces", "name": "otlp/jaeger", "exported_spans": 42}
```

### 3. Increased TSDB Load Due to High Cardinality Metrics

- <b>Symptom</b>: Prometheus memory usage spikes rapidly, causing scrape timeouts.
- <b>Cause</b>: Unique identifiers such as <code>user_id</code> or <code>transaction_id</code> are included as metric labels during instrumentation.
- <b>Solution</b>: Modify operations to exclude highly unique values from metric labels and attach them exclusively to trace span attributes or span events.

---

## Operational Notes

- <b>Strict Resource Limits</b>: When deploying OpenTelemetry Collector to Kubernetes, always set <code>resources.limits</code> and set the <code>memory_limiter</code> processor threshold to around 70–80% of the container limit to prevent forced termination due to OOM.
- <b>Network Security</b>: Even for intra-cluster communication, use network policies to properly restrict source Pods accessing ports <code>4317</code> (gRPC) and <code>4318</code> (HTTP).
- <b>Schema Standardization</b>: Adopt keys adhering to OpenTelemetry Semantic Conventions (such as <code>http.status_code</code>, <code>db.system</code>) for span attribute namespaces to eliminate discrepancies in data interpretation across teams.