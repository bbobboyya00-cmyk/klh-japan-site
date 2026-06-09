---
title: "k6とPrometheusを用いたローカルバックエンドの負荷試験とリアルタイム監視パイプラインの構築"
slug: "k6-prometheus-grafana-load-testing"
date: 2026-06-05T12:34:44+09:00
draft: false
image: ""
description: "k6とPrometheus Remote Write、Grafanaを組み合わせ、ローカル環境のバックエンドに対して段階的な負荷試験を実施し、リアルタイムにメトリクスを可視化・検証した実装記録です。"
categories: ["DevOps Logistics"]
tags: ["k6", "prometheus", "grafana", "docker-compose", "load-testing"]
author: "K-Life Hack"
---

本稿では、ローカル開発環境における「Woogongsil」バックエンドサービスを対象とした、段階的な負荷シミュレーションおよびリアルタイム監視環境の構築手順について解説します。本検証は、本番環境への影響を完全に排除したローカルサンドボックス環境にて実施されました。

## 1. 検証の目的とアプローチ

本検証の主な目的は、接続確認レベルのテストから一歩進め、段階的な負荷をバックエンドに与えた際のシステム挙動をリアルタイムに観測することです。具体的には以下のステップを実行します。

💡 <b>段階的な負荷生成</b>: GETリクエストを中心とした負荷を段階的に適用します。

💡 <b>仮想ユーザー（VU）の動的スケーリング</b>: VU数を 10 → 30 → 50 → 20 → 0 の順に増減させます。

💡 <b>時系列データの統合</b>: Prometheus Remote Write機能を利用し、k6が生成するメトリクスをPrometheusへ直接ストリーミングします。

💡 <b>可視化パイプラインの構築</b>: Grafanaを用いて、RPS（Requests Per Second）、VU数、HTTPステータスコード、エンドポイントごとのリクエスト分布、5xxエラー率をリアルタイムに監視します。

💡 <b>システムの安定性検証</b>: ピーク負荷時において、サーバーダウンや内部エラー（500 Internal Server Error）が発生しないことを確認します。

## 2. 技術スタックと検証環境

本検証は、外部サービスへの影響を防ぐため、すべてローカルのDockerコンテナおよび開発環境内で完結させています。

🛠️ <b>検証対象バックエンド</b>: Woogongsil Local Backend (http://localhost:5000)

🛠️ <b>可視化ツール</b>: Grafana (http://localhost:3001)

🛠️ <b>時系列データベース</b>: Prometheus (http://localhost:9090)

🛠️ <b>負荷生成ツール</b>: k6

🛠️ <b>オーケストレーション</b>: Docker Compose

## 3. コンテナ環境の初期化と事前検証

過去のテスト実行によるメトリクスの混入を防ぐため、測定開始前に監視スタックの初期化を行います。

```bash
```powershell
# 既存のコンテナおよびネットワークの停止
docker compose -f docker-compose.monitor.yml down

# PrometheusとGrafanaのバックグラウンド起動
docker compose -f docker-compose.monitor.yml up -d prometheus grafana

# コンテナの起動状態確認
docker ps --filter "name=wgs-"
```
```

コンテナ wgs-prometheus および wgs-grafana が正常に起動していることを確認後、ターゲットとなるバックエンドのヘルスチェックを行います。

```bash
```powershell
curl.exe -I http://localhost:5000
```
```

HTTPヘッダーの返却値として HTTP/1.1 200 OK が確認できれば、負荷試験の準備は完了です。

## 4. k6負荷試験スクリプトの実装

負荷シミュレーションには、以下のJavaScriptシナリオ（06_final_recording_public_get.js）を使用します。

```javascript
```javascript
import http from "k6/http";
import { check, sleep } from "k6";

// 200〜499のステータスコードを許容範囲として定義
http.setResponseCallback(
http.expectedStatuses({ min: 200, max: 499 })
);

export const options = {
stages: [
{ duration: "30s", target: 10 }, // 10 VUまでランプアップ
{ duration: "30s", target: 30 }, // 30 VUまでランプアップ
{ duration: "30s", target: 50 }, // 50 VUでピーク負荷維持
{ duration: "30s", target: 20 }, // 20 VUまでランプダウン
{ duration: "30s", target: 0 }   // 0 VUまでクールダウン
],
thresholds: {
http_req_duration: ["p(95)<2000"], // 95%のリクエストが2秒以内に完了すること
http_req_failed: ["rate<0.01"]     // エラー率が1%未満であること
},
summaryTrendStats: ["avg", "min", "med", "max", "p(90)", "p(95)", "p(99)"]
};

const BASE_URL = __ENV.BASE_URL || "http://host.docker.internal:5000";

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
if (__ITER % 5 === 0) {
console.log(`[WGS LOAD TEST] VU=${__VU}, ITER=${__ITER}, target=${BASE_URL}`);
}

for (const item of endpoints) {
const res = http.get(`${BASE_URL}${item.path}`, {
tags: { endpoint: item.name } // Grafanaでの集計用タグ
});

check(res, { 
[`${item.name} no server crash`]: (r) => r.status > 0 &amp;&amp; r.status < 500
});

sleep(0.1); // ローカルソケットの枯渇を防ぐためのウェイト
}
}
```
```

### 実装上の注意点

⚠️ <b>host.docker.internal</b>: k6コンテナ内からホストマシンの localhost（ポート5000）へ通信するために必要なホスト名定義です。

⚠️ <b>タグ付け (tags)</b>: 各HTTPリクエストにエンドポイント名を付与することで、Grafana上でルートごとのレイテンシやエラー率を個別に集計可能にしています。

## 5. 負荷試験の実行とPrometheus連携

以下のコマンドを実行し、Prometheus Remote Writeを有効化した状態でk6を起動します。

```bash
```powershell
docker compose -f docker-compose.monitor.yml --profile test run --rm `
-e BASE_URL=http://host.docker.internal:5000 `
-e K6_PROMETHEUS_RW_PUSH_INTERVAL=1s `
k6 run -o experimental-prometheus-rw /scripts/06_final_recording_public_get.js
```
```

🛠️ <b>--profile test</b>: Docker Composeファイル内のk6サービス定義を有効化します。

🛠️ <b>K6_PROMETHEUS_RW_PUSH_INTERVAL=1s</b>: リアルタイム監視のグラフ描画を滑らかにするため、メトリクスのプッシュ間隔を1秒に設定しています。

## 6. 測定結果とメトリクス分析

約2分30秒の試験実行によって得られた主要メトリクスは以下の通りです。

| メトリクス項目 | 測定値 |
| :--- | :--- |
| <b>総HTTPリクエスト数</b> | 32,200 回 |
| <b>総イテレーション数</b> | 3,220 回 |
| <b>最大仮想ユーザー数 (VU)</b> | 50 VU |
| <b>HTTPリクエスト失敗率</b> | 0.00% |
| <b>チェック成功率</b> | 100.00% |
| <b>平均レスポンス時間</b> | 2.73ms |
| <b>p95 レスポンス時間</b> | 5.88ms |
| <b>p99 レスポンス時間</b> | 15.26ms |
| <b>最大レスポンス時間</b> | 57.09ms |
| <b>スループット</b> | 約 213.75 reqs/sec |

### リアルタイム監視による分析結果

💡 <b>RPSとVUの相関関係</b>: VU数の増減（10 → 30 → 50 → 20 → 0）に追従して、RPSのグラフが綺麗な山型のカーブを描き、スケールアップ・ダウンが意図通りに機能していることを確認しました。

💡 <b>ステータスコードの分布</b>: 大半のリクエストは 200 OK でしたが、一部の保護されたAPIにおいて 401 Unauthorized が記録されました。これは認証セッションなしでアクセスしたことによる期待通りの挙動であり、サーバーエラー（5xx）は一切発生していません。

💡 <b>エンドポイント別の負荷分散</b>: スクリプト内のループ処理により、定義した10個のエンドポイントに対して均等にトラフィックが分散されていることが確認できました。

## 7. Lessons Learned

⚠️ <b>リアルタイム監視における更新頻度の重要性</b>: 初期検証時、Grafanaのデータ更新頻度がデフォルトのままであったため、グラフが静的に見える問題が発生しました。更新間隔を5秒（5s）に明示的に設定することで、負荷の増減をリアルタイムに追従できるようになりました。

⚠️ <b>テスト実行IDの識別</b>: Prometheus上で複数のテスト実行結果が混在するのを防ぐため、今後は実行ごとに一意の run_id などのカスタムラベルを付与する設計が推奨されます。

⚠️ <b>サーバーサイドリソースの可視化不足</b>: 今回はクライアント（k6）側から見たメトリクス収集に留まったため、サーバー側のCPUやメモリ使用率の推移が追いきれませんでした。今後はNode.jsバックエンドに prom-client を組み込み、/metrics エンドポイント経由で内部リソース情報を統合するアプローチを検討します。