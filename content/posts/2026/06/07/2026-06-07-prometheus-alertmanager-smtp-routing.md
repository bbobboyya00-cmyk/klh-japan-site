---
title: "PrometheusとAlertmanagerによるアラート制御とSMTP連携の設計"
slug: "prometheus-alertmanager-smtp-routing"
date: 2026-06-07T14:07:56+09:00
draft: false
image: ""
description: "Prometheusによる評価とAlertmanagerによるルーティングの分離、アラートストームを防ぐ制御機構、およびNaver SMTP連携時のPort 465におけるTLS設定の技術的解決策を解説します。"
categories: ["DevOps Logistics"]
tags: ["prometheus", "alertmanager", "smtp-configuration", "alert-routing", "monitoring-infrastructure"]
author: "K-Life Hack"
---

# PrometheusとAlertmanagerによる監視通知基盤の高度化：異常検知と通知制御の分離設計

インフラストラクチャの監視において、異常の検知と通知の制御は明確に分離されるべき設計領域です。本稿では、Prometheusによるアラート評価とAlertmanagerによる通知ルーティングの分離アーキテクチャ、アラートストームを抑制するための制御機能、およびNaver SMTPを利用した通知経路の実装仕様について解説します。

## 1. 評価とルーティングの分離アーキテクチャ

監視パイプラインにおいて、PrometheusとAlertmanagerは以下のように役割を分担します。この分離は、単一責任の原則（Single Responsibility Principle）に基づいています。

| コンポーネント | 役割 | 具体的な処理 | 出力 |
| :--- | :--- | :--- | :--- |
| <b>Prometheus</b> | <b>評価エンジン</b> | `rule_files`で定義されたルールを評価間隔（例: 30秒）ごとに評価する。 | 条件合致時に「firing」状態のアラートを生成し、AlertmanagerへHTTP POSTで送信する。 |
| <b>Alertmanager</b> | <b>ルーティングエンジン</b> | 受信したアラートに対し、グループ化、抑制、サイレンス処理を適用する。 | 外部通知チャネル（Email、Slackなど）へ整理された通知を配信する。 |

💡 <b>分離が必要な理由</b>

1. <b>エンジンの専門化</b>: Prometheusは時系列データベース（TSDB）としての読み書き性能に特化しています。外部ネットワークプロトコル、再試行ロジック、レート制限、状態管理（SMTPやWebhook連携など）を排除することで、コアエンジンの安定性を担保します。
2. <b>高可用性の確保</b>: 複数のPrometheusサーバーから、冗長化されたAlertmanagerクラスターへアラートを集約して送信することが可能になり、通知経路の単一障害点（SPOF）を排除できます。

---

## 2. アラートルールの構成要素と状態遷移

Prometheusにおけるアラートルールは、YAML形式で定義されます。GPUの温度上昇を検知するルールの定義例を以下に示します。

```yaml
- alert: GpuHighTemperature
  expr: gpu_temperature_celsius &gt; 80
  for: 5m
  labels:
    severity: warning
    component: gpu
  annotations:
    summary: "GPU temp on {{ $labels.host }}/{{ $labels.gpu }} = {{ $value }}°C"
    description: |
      GPU {{ $labels.gpu }} on {{ $labels.host }} has been &gt; 80°C for 5 minutes.
      Threshold: 80°C / Critical: 85°C.
      Check: nvidia-smi -q -d TEMPERATURE
```

コアパラメータの機能は以下の通りです。

* <b>`expr`</b>: 評価条件となるPromQL式。この式が結果（時系列データ）を返した場合、アラート条件が満たされたとみなされます。
* <b>`for`</b>: 条件が満たされてから実際にアラートが「firing」状態に移行するまでの待機時間。一時的なスパイクによる誤検知を防ぎます。
* <b>`labels`</b>: アラートに付与されるメタデータ。Alertmanagerでのルーティングやグループ化の基準として使用されます。
* <b>`annotations`</b>: 通知文面に使用されるテンプレート。`{{ $labels.host }}`や`{{ $value }}`などの変数を用いて、動的な情報を埋め込むことが可能です。

アラートの状態遷移ライフサイクルは、`for`パラメータの存在により、以下の3つの状態を遷移します。

```
                  [ expr がデータを返した時 ]
  +------------+  --------------------&gt;  +------------+
  |  inactive  |                         |  pending   |
  +------------+  &lt;--------------------  +------------+
        ^         [ expr の結果が空になった時 ]    |
        |                                      | [ 'for' で指定した時間が経過 ]
        |                                      v
        |                                +------------+
        +--------------------------------|   firing   |
              [ expr の結果が空になった時 ]     +------------+
                (RESOLVED 通知の送信)
```

* <b>`inactive`</b>: 正常状態。PromQLの評価結果が空の状態です。
* <b>`pending`</b>: 異常を検知したものの、`for`で指定した期間を経過していない検証中の状態。この段階では通知は送信されません。
* <b>`firing`</b>: 異常状態が継続し、通知が確定した状態。Alertmanagerへアラートが転送されます。条件が解消されると、自動的に`RESOLVED`通知が送信されます。

---

## 3. アラートストームを抑制する3つの制御機能

大規模な障害が発生した際、大量の通知が同時に送信される「アラートストーム」は、運用担当者の認知負荷を高め、致命的な障害の看過を招きます。Alertmanagerはこれを防ぐために3つの制御機能を提供します。

### ① グループ化 (`group_by`)

類似するアラートを1つの通知に集約します。例えば、同一ホストで複数のコンポーネントが同時に警告を発した場合、個別に通知するのではなく、ホスト単位でまとめて通知します。

```yaml
route:
  group_by: ['alertname', 'severity']
  group_wait: 30s        # 最初のアラート受信後、バッファリングする時間
  group_interval: 5m     # 同一グループ内の新規アラートを通知するまでの間隔
```

### ② 抑制 (`inhibit_rules`)

特定の「トリガーアラート」が既に発生している場合、それに関連する「依存アラート」の通知を抑制します。例えば、ホスト自体がダウンしている場合（`HostDown`）、そのホスト上の個別プロセスやGPUの監視アラートは不要となるため、通知をカットします。

```yaml
inhibit_rules:
  - source_matchers: [alertname="HostDown"]
    target_matchers: [severity=~"warning|info"]
    equal: ['host']
```

`equal`で指定されたラベル（この場合は`host`）が一致する場合にのみ、抑制ルールが適用されます。

### ③ 再送制御 (`repeat_interval`)

未解決のアラートについて、同じ通知を繰り返す間隔を制御します。頻繁な再送を防ぎつつ、未解決のまま放置されるリスクを低減します。

```yaml
route:
  repeat_interval: 4h    # 解決していないアラートの再送間隔
```

---

## 4. Naver SMTP連携におけるPort 465の挙動と対策

通知経路としてNaver SMTP（`smtp.naver.com`）を利用する場合、プロトコルのネゴシエーションにおける特有の挙動に注意する必要があります。

⚠️ <b>Port 465（Implicit SSL）の接続問題</b>

Naver SMTPはPort 465（暗黙的なSSL/TLS）とPort 587（明示的なSTARTTLS）をサポートしています。Alertmanagerのデフォルト挙動では、接続開始時にSTARTTLSコマンドを送信しようとします。しかし、Port 465は接続の最初からSSLハンドシェイクを要求するため、AlertmanagerがSTARTTLSを送信するとプロトコルの不一致が発生し、接続がハングアップするか、`connection unexpectedly closed`エラーで失敗します。

🛠️ <b>解決策</b>

Alertmanagerの設定において、`smtp_require_tls: false`を明示的に指定します。これにより、STARTTLSの送信がスキップされ、Port 465での暗黙的なSSL接続が正常に確立されます。また、認証には通常のログインパスワードではなく、Naverのセキュリティ設定から生成した16桁の「アプリパスワード」を使用する必要があります。

---

## 5. 実装用設定ファイル (`alertmanager.yml`)

以下は、上記のアラート制御およびNaver SMTP連携を組み込んだ、実用的なAlertmanagerの設定ファイルです。

```yaml
global:
  resolve_timeout: 5m
  smtp_smarthost: 'smtp.naver.com:465'
  smtp_from: 'neogle@naver.com'
  smtp_auth_username: 'neogle@naver.com'
  smtp_auth_password: 'YOUR_16_DIGIT_APP_PASSWORD'
  smtp_require_tls: false

route:
  receiver: 'default-email'
  group_by: ['alertname', 'severity']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

  routes:
    - matchers:
        - severity="critical"
      receiver: 'critical-email'
      repeat_interval: 1h

    - matchers:
        - severity="info"
      repeat_interval: 24h

inhibit_rules:
  - source_matchers: [alertname="HostDown"]
    target_matchers: [severity=~"warning|info"]
    equal: ['host']

  - source_matchers: [alertname="GpuCriticalTemp"]
    target_matchers: [alertname="GpuHighTemperature"]
    equal: ['host', 'gpu']

receivers:
  - name: 'default-email'
    email_configs:
      - to: 'neogle@naver.com'
        send_resolved: true

  - name: 'critical-email'
    email_configs:
      - to: 'neogle@naver.com'
        send_resolved: true
        headers:
          Subject: '🚨 [CRITICAL] {{ .CommonLabels.alertname }} on {{ .CommonLabels.host }}'
```

---

## 6. トラブルシューティングガイド

| 事象 | 想定原因 | 対処方法 |
| :--- | :--- | :--- |
| アラート条件を満たしているが通知されない | `for`で指定した時間が経過していない、または抑制ルール（`inhibit_rules`）に合致している。 | PrometheusのWeb UIで対象アラートが`pending`状態になっていないか確認。また、同一ホストで上位アラート（`HostDown`など）が発報されていないか確認する。 |
| SMTP接続時に`connection unexpectedly closed`が発生する | Port 465に対してSTARTTLSを使用しようとしている。 | `smtp_require_tls: false`が設定されているか確認する。 |
| SMTP認証エラーが発生する | 通常のログインパスワードを使用している、またはアプリパスワードが失効している。 | Naverのメール設定画面からPOP3/SMTP使用設定が有効であることを確認し、新規に16桁のアプリパスワードを再生成して適用する。 |

---

## Configuration Notes

アラート設計において最も重要なのは、「すべてのアラートが、受信者にとって具体的なアクションに結びつくこと」です。アクションの不要な通知は、運用チームの疲弊を招くだけでなく、真に重大な障害の検知を遅らせる要因となります。

本稿で示したグループ化、抑制、および再送制御を適切に組み合わせることで、ノイズを最小限に抑えた、信頼性の高い監視・通知基盤を構築することが可能になります。実環境の要件や運用体制に合わせて、各インターバル値や抑制条件を段階的にチューニングしてください。