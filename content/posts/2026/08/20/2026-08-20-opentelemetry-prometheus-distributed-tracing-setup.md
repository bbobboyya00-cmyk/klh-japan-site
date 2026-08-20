---
title: "OpenTelemetryとPrometheusによる分散トレーシングおよびメトリクス可視化の実装"
slug: "opentelemetry-prometheus-distributed-tracing-setup"
date: 2026-08-20T12:43:36+09:00
draft: false
image: ""
description: "マイクロサービス環境におけるOpenTelemetry Collectorの配備、計装手法、PrometheusとGrafana Exemplarsを連携させた観測基盤の構築手順をまとめます。"
categories: ["DevOps Logistics"]
tags: ["opentelemetry", "opentelemetry-collector", "prometheus", "grafana", "distributed-tracing"]
author: "K-Life Hack"
---

## 分散システムにおける観測性の課題とアーキテクチャ背景

マイクロサービスアーキテクチャの普及に伴い、バックエンドシステムは複数の独立したサービスが非同期またはRPC通信を介して連携する形態へと変化しました。従来のモノリシックな構成では単一プロセスのログやサーバー単位のリソース監視で障害検知が可能でしたが、分散環境ではリクエストが多数のノードを横断するため、障害発生箇所の特定やレイテンシ悪化の根本原因追跡が困難になります。

ログ、メトリクス、トレースが個別のプロトコルやエージェントで収集されている場合、コンテキストの紐付けが失われ、MTTR（平均復旧時間）が増大する要因となります。OpenTelemetry（OTel）は、CNCF主導のベンダーニュートラルな標準仕様であり、OpenTelemetry Protocol（OTLP）を通じて各種テレメトリデータを統合的に収集・処理・転送する基盤を提供します。本稿では、OpenTelemetry Collectorの配備からアプリケーション計装、PrometheusおよびGrafana Exemplarsを用いた可視化パイプラインの実装手順を記録します。

---

## OpenTelemetry Collectorの構成と配備

OpenTelemetry Collectorは、アプリケーションから送信されるテレメトリデータを受信、加工（バッチ処理、メモリ制限、サンプリング）、外部バックエンドへ転送するプロキシコンポーネントです。Collectorを挟むことで、アプリケーション側に特定監視ツールのSDKを直接依存させず、OTLPエンドポイントのみを向ける疎結合なアーキテクチャを実現します。

### Kubernetesマニフェスト定義 (`opentelemetry-collector.yaml`)

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

### 🛠️ パイプライン制御のポイント

- <b>memory_limiter</b>: 急激なトラフィック増によるCollectorプロセスのOOMKilledを防止するため、バッチ処理の前にメモリ使用率の閾値を制御します。
- <b>batch</b>: 個別のHTTP/gRPCリクエストをまとめてバックエンドへ送信し、ネットワークオーバーヘッドを低減します。
- <b>exporters</b>: トレースデータはJaegerのOTLPレシーバーへ転送し、メトリクスはPrometheusがスクレイプ可能なエンドポイント（ポート8889）として外部へ公開します。

---

## アプリケーション層の計装 (Instrumentation)

### 1. Python (Flask) による自動・手動計装の実装

Python環境では、<code>opentelemetry-sdk</code> と各種フレームワーク向け計装ライブラリを組み合わせて実装します。

```python
from flask import Flask, request
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor

# リソースメタデータの設定
resource = Resource.create({
    "service.name": "order-api",
    "service.version": "1.0.0",
    "deployment.environment": "production"
})

# TracerProviderの初期化とBatchSpanProcessorの登録
provider = TracerProvider(resource=resource)
exporter = OTLPSpanExporter(
    endpoint="otel-collector.observability.svc.cluster.local:4317",
    insecure=True
)
processor = BatchSpanProcessor(exporter)
provider.add_span_processor(processor)
trace.set_tracer_provider(provider)

app = Flask(__name__)

# 自動計装の有効化
FlaskInstrumentor().instrument_app(app)
RequestsInstrumentor().instrument()

@app.route("/checkout", methods=["POST"])
def checkout():
    tracer = trace.get_tracer(__name__)
    # 手動スパンの生成によるビジネスロジックの可視化
    with tracer.start_as_current_span("process_payment") as span:
        user_id = request.headers.get("X-User-ID", "anonymous")
        span.set_attribute("app.user_id", user_id)
        span.set_attribute("app.payment_method", "credit_card")
        
        # 内部処理のシミュレーション
        return {"status": "success", "order_id": "ORD-9482"}, 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
```

### 2. Java (Spring Boot) におけるエージェント適用

Javaアプリケーションでは、バイトコードを動的に計装するJava Agentを利用することで、ソースコードの変更なしに計装が可能です。

```properties
# application.properties または環境変数で設定
otel.exporter.otlp.endpoint=http://otel-collector.observability.svc.cluster.local:4317
otel.service.name=payment-service
otel.traces.sampler=always_on
```

JVM起動パラメータ:

```bash
java -javaagent:/path/to/opentelemetry-javaagent.jar -jar app.jar
```

---

## PrometheusとGrafana Exemplarsの連携

メトリクスの時系列データと分散トレースを接続するために、GrafanaのExemplars機能を利用します。これにより、レイテンシグラフ上のスパイクした単一データポイントから、直接対応するトレースIDへジャンプすることが可能になります。

### Prometheusスクレイプ設定 (`prometheus.yml`)

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'otel-collector'
    static_configs:
      - targets: ['otel-collector.observability.svc.cluster.local:8889']
```

### GrafanaパネルのPromQLとExemplar定義

Grafanaダッシュボードのパネル定義でExemplarを有効化します。

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

## 💡 テイルサンプリング (Tail-based Sampling) 戦略

全量トレースの永続化はストレージコストとネットワーク負荷を急増させます。ヘッドベースサンプリング（リクエスト開始時のランダム抽出）では重要なエラートレースが欠落するリスクがあるため、Collector側でリクエスト完了後にサンプリング判定を行うテイルサンプリングを導入します。

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

上記設定により、HTTP 5xx等のエラーステータスを含むトレース、および1000msを超過したレイテンシスパンは100%保持し、正常系リクエストのみ5%にダウンサンプリングします。

---

## ⚠️ Troubleshooting

### 1. W3Cコンテキスト伝播の欠落によるトレース断絶

- <b>現象</b>: サービスAからサービスBへの呼び出しにおいて、Jaeger上で単一のトレースとして繋がらず、別々のTrace IDが生成される。
- <b>原因</b>: 非同期ワーカーや独自HTTPクライアント実装において、<code>traceparent</code> ヘッダーが下流サービスへ伝播されていない。
- <b>解決策</b>: HTTPリクエスト送信前に明示的なインジェクション処理を実施する。

```python
from opentelemetry.propagate import inject
import requests

headers = {}
inject(headers)
response = requests.get("http://downstream-service/api", headers=headers)
```

### 2. ポート到達不能および名前解決エラー

- <b>現象</b>: アプリケーションログに <code>Failed to export spans: StatusCode.UNAVAILABLE</code> が記録される。
- <b>検証手順</b>: コンテナ内部からCollectorエンドポイントへの疎通を確認。

```text
$ kubectl exec -it deploy/order-api -n default -- nc -zv otel-collector.observability.svc.cluster.local 4317
Connection to otel-collector.observability.svc.cluster.local (10.96.120.45) 4317 port [tcp/*] succeeded!

$ kubectl logs -l app.kubernetes.io/name=opentelemetry-collector -n observability --tail=20
2026-08-20T04:12:01.892Z	info	service/telemetry.go:84	Everything is ready. Begin running and processing data.
2026-08-20T04:12:05.104Z	info	TracesExporter	{"kind": "exporter", "data_type": "traces", "name": "otlp/jaeger", "exported_spans": 42}
```

### 3. 高カーディナリティメトリクスによるTSDB負荷増大

- <b>現象</b>: Prometheusのメモリ使用率が急増し、スクレイプタイムアウトが発生。
- <b>原因</b>: <code>user_id</code> や <code>transaction_id</code> などの一意な識別子をメトリクスラベルに含めて計装している。
- <b>解決策</b>: 一意性の高い値はメトリクスラベルから除外し、トレースのスパン属性（Span Attributes）またはスパンイベントに限定して付与する運用へ修正します。

---

## Operational Notes

- <b>リソース制限の厳密化</b>: OpenTelemetry CollectorをKubernetesに配備する際は、必ず <code>resources.limits</code> を設定し、<code>memory_limiter</code> プロセッサの閾値をコンテナ制限値の70〜80%程度に設定してOOMによる強制終了を防ぎます。
- <b>ネットワークセキュリティ</b>: クラスター内部の通信であっても、ネットワークポリシーを用いてポート <code>4317</code> (gRPC) および <code>4318</code> (HTTP) へのアクセス元Podを適切に制限します。
- <b>スキーマの標準化</b>: スパン属性の名前空間にはOpenTelemetry Semantic Conventions（<code>http.status_code</code>, <code>db.system</code> など）に準拠したキーを採用し、チーム間でのデータ解釈の齟齬を排除します。