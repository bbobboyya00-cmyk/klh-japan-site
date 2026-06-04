---
title: "k6とPrometheus Remote Writeを用いたローカルバックエンドの段階的負荷試験とリアルタイム可観測性パイプラインの構築"
slug: "k6-prometheus-observability-pipeline"
date: 2026-06-04T14:05:29+09:00
draft: false
image: ""
description: "k6のPrometheus Remote Writeプロトコルを活用し、ローカルバックエンドに対する段階的負荷試験を実施。Grafanaによるリアルタイム可観測性パイプラインの構築手順と検証結果を解説します。"
categories: ["DevOps Logistics"]
tags: ["k6", "prometheus-remote-write", "grafana", "docker-compose", "load-testing"]
author: "K-Life Hack"
---

# k6・Prometheus・Grafanaによるリアルタイム可観測性負荷試験パイプラインの構築と検証

本稿では、ローカル開発環境におけるバックエンドサーバーの性能検証を目的とした、k6、Prometheus、およびGrafanaを組み合わせたリアルタイム可観測性（Observability）パイプラインの構築と、段階的な負荷試験の実施手順について解説します。

本検証では、本番環境への影響を完全に排除するため、すべてのコンテナおよびターゲットサーバーをローカル環境内に閉じた状態で実行しています。k6から出力されるメトリクスをPrometheus Remote Writeプロトコル経由でリアルタイムに収集し、Grafana上で可視化するシステムを構築しました。

## 1. 負荷試験の目的

本フェーズにおける負荷試験の主な目的は以下の通りです。

1. <b>段階的なGETリクエスト負荷の適用</b>: ターゲットとなるローカルバックエンドサーバーに対し、構造化されたHTTP GETトラフィックを送信します。

2. <b>仮想ユーザー（VU）の段階的スケーリング</b>: 仮想ユーザー数を 10 → 30 → 50 → 20 → 0 とプログラム制御に基づいて段階的に増減させます。

3. <b>Prometheus Remote Writeの検証</b>: k6の実験的機能である `experimental-prometheus-rw` プロトコルを用いて、メトリクスが遅延なくPrometheus時系列データベースにプッシュされることを確認します。

4. <b>リアルタイム可観測性の確保</b>: Grafanaを用いて、RPS（Requests Per Second）、アクティブVU、HTTPステータスコード、エンドポイント別リクエスト数、5xxエラー率などの主要業績評価指標（KPI）をリアルタイムに監視します。

5. <b>サーバーの安定性評価</b>: ピーク負荷時において、バックエンドサーバーのクラッシュ、リソースリーク、または5xx系エラーが発生しないことを検証します。

## 2. 検証環境の構成

本番環境への不要なトラフィック流入やサービス停止を防ぐため、検証はすべてローカルのDockerネットワーク内に限定して実施しました。

### ターゲットサーバー

* <b>WGSローカルバックエンド</b>: `http://localhost:5000`

### 監視・可観測性インフラ（Dockerコンテナ）

* <b>Grafana</b>: `http://localhost:3001`
* <b>Prometheus</b>: `http://localhost:9090`

### コンポーネント構成

💡 <b>k6</b>: シナリオスクリプトに基づき、並行仮想ユーザー（VU）からターゲットに対してHTTPリクエストを生成する負荷生成エンジンです。

💡 <b>Prometheus</b>: k6からプッシュされた時系列パフォーマンスメトリクスを蓄積するデータストアです。

💡 <b>Grafana</b>: Prometheusをデータソースとしてクエリを投げ、リアルタイムでグラフ描画を行うビジュアライゼーションプラットフォームです。

💡 <b>Docker Compose</b>: Prometheus、Grafana、およびk6を同一の分離されたローカルネットワーク内でオーケストレーションするツールです。

## 3. 事前準備：コンテナ環境の初期化

過去の試験メトリクスがGrafanaの可視化に混入するのを防ぐため、試験開始前にPrometheusおよびGrafanaコンテナを完全に破棄し、再初期化を行います。

PowerShell等のターミナル環境において、コンテナの初期化コマンドを実行します。

```bash
```powershell
# プロジェクトディレクトリへ移動
cd "C:\python-src\WebDevelop_project\wgs_loadtest_lab"

# 既存の監視コンテナおよびネットワークの破棄
docker compose -f docker-compose.monitor.yml down

# PrometheusとGrafanaをバックグラウンドで再起動
docker compose -f docker-compose.monitor.yml up -d prometheus grafana

# 起動ステータスの確認
docker ps --filter "name=wgs-"
```
```

これにより、過去のテストデータがクリアされたクリーンな状態から計測を開始できます。

## 4. バックエンドサーバーの稼働確認

負荷試験を開始する前に、ターゲットとなるローカルバックエンドサーバーが正常に応答可能な状態にあるかを確認します。

```bash
```powershell
curl.exe -I http://localhost:5000
```
```

### 期待されるレスポンスヘッダー

```http
```http
HTTP/1.1 200 OK
```
```

上記のように `200 OK` が返却されれば、バックエンドが正常に起動しており、負荷試験を受け入れ可能であると判断できます。

## 5. k6負荷試験シナリオの設計

負荷試験シナリオスクリプトである `06_final_recording_public_get.js` の実装構成を定義します。

```javascript
```javascript
import http from "k6/http";
import { check, sleep } from "k6";

// 200〜499のステータスコードを正常なアプリケーション応答として定義
http.setResponseCallback(
http.expectedStatuses({ min: 200, max: 499 })
);

export const options = {
stages: [
{ duration: "30s", target: 10 }, // 30秒で10 VUまでランプアップ
{ duration: "30s", target: 30 }, // 30秒で30 VUまでランプアップ
{ duration: "30s", target: 50 }, // 30秒で50 VUまでランプアップ（ピーク負荷）
{ duration: "30s", target: 20 }, // 30秒で20 VUまでランプダウン
{ duration: "30s", target: 0 }   // 30秒で0 VUまでランプダウン
],
thresholds: {
http_req_duration: ["p(95)&lt;2000"], // 95%のリクエストが2000ms以内に完了すること
http_req_failed: ["rate&lt;0.01"]     // エラー率（5xx等）を1%未満に抑えること
},
summaryTrendStats: ["avg", "min", "med", "max", "p(90)", "p(95)", "p(99)"]
};

// Dockerコンテナ内からホストマシンのlocalhostを参照するためのベースURL設定
const BASE_URL = __ENV.BASE_URL || "http://host.docker.internal:5000";

// 負荷検証対象のエンドポイント定義
const endpoints = [
{ name: "home-root", path: "/" },
{ name: "screen-settings", path: "/api/screen-settings" },
{ name: "class-schedules", path: "/api/class-schedules" },
{ name: "mealmap-places", path: "/api/mealmap/places" },
{ name: "exam-catalogs", path: "/api/exam-catalogs" },
{ name: "ipep-catalog", path: "/api/ipep/exam-catalog" },
{ name: "ipep-random", path: "/api/ipep/random-question" },
{ name: "ranking", path: "/api/ranking" },
{ name: "notices", path: "/api/notices" },
{ name: "posts", path: "/api/posts" }
];

export default function () {
// ターミナルログの流量を抑えるため、5イテレーションごとにログを出力
if (__ITER % 5 === 0) {
console.log(`[WGS LOAD TEST] VU=${__VU}, ITER=${__ITER}, target=${BASE_URL}`);
}

// 定義されたエンドポイントを順次実行
for (const item of endpoints) {
const res = http.get(`${BASE_URL}${item.path}`, {
tags: {
endpoint: item.name // Grafanaでのフィルタリング用にタグを付与
}
});

// サーバーがクラッシュせず、何らかの応答を返していることを検証
check(res, {
[`${item.name} no server crash`]: (r) =&gt; r.status &gt; 0 &amp;&amp; r.status &lt; 500
});

// リクエスト間に100msのウェイトを挿入
sleep(0.1);
}
}
```
```

### 実装のポイント

🛠️ <b>http.expectedStatuses({ min: 200, max: 499 })</b>: `401 Unauthorized` や `404 Not Found` などのクライアントエラーは、アプリケーションロジックが正常に稼働している証拠であるため、テストフレームワーク側で「失敗」としてカウントしないよう除外します。一方、`5xx`系エラーはサーバー側のクラッシュや過負荷を示すため、厳格に失敗として検知します。

🛠️ <b>stages</b>: 総計測時間は2分30秒（150秒）であり、段階的に負荷を増減させることで、コンテナのオートスケーリングやリソース限界点をシミュレートしやすい構成にしています。

🛠️ <b>tags: { endpoint: item.name }</b>: 各HTTPリクエストにメタデータを付与することで、Grafana側で特定のエンドポイントにボトルネックがないかをドリルダウンして分析可能にします。

## 6. Grafana可観測性ダッシュボードとPromQL設計

Prometheusに蓄積されたメトリクスを可視化するため、GrafanaのExploreインターフェースおよびダッシュボードにおいてPromQLクエリを設定します。

### A. RPS (Requests Per Second)

```promql
```promql
sum(rate(k6_http_reqs_total[10s]))
```
```

直近10秒間のスライディングウィンドウにおける、秒間平均HTTPリクエスト数を算出します。

### B. アクティブ仮想ユーザー数 (VUs)

```promql
```promql
max_over_time(k6_vus[10s])
```
```

k6が生成している現在の同時実行仮想ユーザー数をリアルタイムに追跡します。

### C. HTTPステータスコード別リクエスト数

```promql
```promql
sum by (status) (increase(k6_http_reqs_total[2m]))
```
```

直近2分間で発生したリクエストをステータスコード（200, 401, 404等）ごとにグルーピングして累積表示します。

### D. エンドポイント別リクエスト数

```promql
```promql
sum by (endpoint) (increase(k6_http_reqs_total[2m]))
```
```

スクリプト内で付与した `endpoint` タグを基に、どのAPIにトラフィックが集中しているかを可視化します。

### E. 5xx系サーバーエラー検出

```promql
```promql
sum(increase(k6_http_reqs_total{status=~"5.."}[2m]))
```
```

サーバー内部エラー（HTTP 500〜599）の発生件数を監視し、システムの不安定化を即座に検知します。

⚠️ <b>トラブルシューティング注意点</b>: 初期検証時、Grafanaのグラフがリアルタイムに更新されない事象が発生しました。原因はGrafanaの自動更新間隔（Auto-Refresh Interval）がデフォルトのままになっていたことでした。これを `5s` に明示的に設定することで、k6からPrometheus Remote Write経由で送られてくる1秒間隔のメトリクスが遅延なく画面上に描画されるようになりました。

## 7. 負荷試験の実行

PowerShellからDocker Composeを呼び出し、k6コンテナを起動して負荷試験を実行します。

```bash
```powershell
# k6コンテナによる負荷試験の実行
docker compose -f docker-compose.monitor.yml --profile test run --rm `
-e BASE_URL=http://host.docker.internal:5000 `
-e K6_PROMETHEUS_RW_PUSH_INTERVAL=1s `
k6 run -o experimental-prometheus-rw /scripts/06_final_recording_public_get.js
```
```

### コマンドオプションの解説

🛠️ <b>--profile test</b>: Composeファイル内の `test` プロファイルに属するk6サービスを有効化します。

🛠️ <b>run --rm</b>: 試験終了後、不要になった一時コンテナを自動的に削除し、ホストのリソースを解放します。

🛠️ <b>-e K6_PROMETHEUS_RW_PUSH_INTERVAL=1s</b>: デフォルトのプッシュ間隔を1秒に短縮し、Grafana上でのリアルタイムなグラフ追従性を極限まで高めます。

🛠️ <b>-o experimental-prometheus-rw</b>: メトリクス出力先としてPrometheus Remote Writeプロトコルを指定します。

## 8. 試験結果の分析

負荷試験完了後、k6から出力された最終サマリーレポートの測定結果です。

| メトリクス項目 | 測定値 |
| :--- | :--- |
| <b>総HTTPリクエスト数</b> | 32,200 |
| <b>完了イテレーション数</b> | 3,220 |
| <b>ピーク仮想ユーザー数 (VUs)</b> | 50 |
| <b>中断されたイテレーション数</b> | 0 |
| <b>HTTP失敗率 (Error Rate)</b> | 0.00% |
| <b>アサーションクリア率 (Checks)</b> | 100.00% |
| <b>平均応答時間 (Average Latency)</b> | 2.73 ms |
| <b>95パーセンタイル (p95) 応答時間</b> | 5.88 ms |
| <b>99パーセンタイル (p99) 応答時間</b> | 15.26 ms |
| <b>最大応答時間 (Max Latency)</b> | 57.09 ms |
| <b>平均スループット</b> | ~213.75 reqs/sec |

### 性能評価

🛠️ <b>極めて低いレイテンシ</b>: 95%のリクエストが5.88ms以内に処理されており、目標値である2000ms（2.0秒）を大幅に下回る極めて良好な応答性能を示しました。

🛠️ <b>エラーフリーの達成</b>: 総リクエスト32,200件のうち、5xx系エラーおよび接続エラーは0件（0.00%）であり、アサーションクリア率は100.00%を達成しました。ローカル環境のシングルプロセス構成においても、50 VUの同時接続に対してバックエンドが安定してソケットを処理しきれていることが実証されました。

## 9. 可観測性データの可視化分析

Grafanaダッシュボードのリアルタイム監視から、以下の挙動が確認されました。

1. <b>RPSとVUの相関性</b>: 仮想ユーザー数（VU）の段階的な増減（10 → 30 → 50 → 20 → 0）に完全に比例して、RPSのグラフが綺麗な階段状の放物線を描きました。これは、k6の負荷生成エンジンおよびPrometheusへのデータ転送パイプラインがボトルネックなく機能していることを示します。

2. <b>HTTPステータスコードの分布</b>: 期待通り、認証不要なエンドポイントへの `200 OK` と、保護されたエンドポイントへの `401 Unauthorized` のみが記録され、不予期な `404` や `500` などのエラーは一切発生しませんでした。

3. <b>エンドポイントの均等分散</b>: 10個のエンドポイントに対するリクエスト数が完全に均等に推移しており、特定の重いクエリを処理するAPIに偏ることなく、シナリオ通りにラウンドロビンでリクエストが分散されていることが確認されました。

## Lessons Learned

本検証を通じて得られた知見および今後の改善点は以下の通りです。

💡 <b>リアルタイム可視化における更新間隔の重要性</b>: Prometheus Remote Writeを使用する場合、k6側のプッシュ間隔（`K6_PROMETHEUS_RW_PUSH_INTERVAL`）だけでなく、Grafana側のダッシュボード自動更新間隔（Auto-Refresh）の双方を同期させなければ、データが不連続に見える、あるいは描画が遅延する原因になります。

💡 <b>コンテナ間名前解決の考慮</b>: Dockerブリッジネットワーク内で実行されるk6からホストマシンのローカルポートにアクセスする際、`localhost` ではなく `host.docker.internal` を適切に解決させる環境変数設計が必須となります。

💡 <b>ホストリソース監視の欠如</b>: 現在の構成では、k6側から見たアプリケーションの応答性能（外形監視）は取得できていますが、バックエンドプロセスが稼働しているコンテナ自体のCPU使用率やメモリ消費量（内部監視）が統合されていません。今後は、Node.jsバックエンドに `prom-client` などのライブラリを組み込み、`/metrics` エンドポイント経由で内部リソースメトリクスをPrometheusにプルさせる構成への拡張が推奨されます。