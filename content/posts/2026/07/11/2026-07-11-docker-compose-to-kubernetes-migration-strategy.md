---
title: "Docker ComposeからKubernetesへの移行におけるアーキテクチャ設計とNode.jsランタイムの最適化"
slug: "docker-compose-to-kubernetes-migration-strategy"
date: 2026-07-11T10:06:06+09:00
draft: false
image: ""
description: "Docker ComposeからKubernetesへの移行期における、Node.jsランタイムの選定、ヘルスチェックの実装、およびグレースフルシャットダウンの設計指針を解説します。"
categories: ["DevOps Logistics"]
tags: ["kubernetes", "docker-compose", "node-js-lts", "health-check", "graceful-shutdown"]
author: "K-Life Hack"
---

# Node.js環境におけるDocker ComposeからKubernetesへの移行：スケーラビリティ確保のための技術設計

インフラストラクチャのスケーリングにおいて、Docker Composeによる単一ノード管理からKubernetes（K8s）によるオーケストレーションへの移行は、単なるツールの変更ではなく、運用パラダイムの根本的な転換を意味します。手動でのコンテナ管理や静的なポート割り当ては、ノード数が増加するにつれてヒューマンエラーを誘発し、ダウンタイムのリスクを増大させます。本稿では、Node.js環境をモデルケースとし、開発環境（Compose）から本番環境（K8s）への移行を成功させるための技術的要件と、実務上の摩擦を回避するための設計指針を詳述します。

## Node.jsランタイム戦略とバージョン管理

運用安定性の基盤はランタイムの選定にあります。2026年7月現在のロードマップに基づき、本番環境ではLTS（Long Term Support）版であるNode.js v22.22.3（Codename: Jod）の採用を推奨します。最新機能を備えたv26系も存在しますが、検証コストとサードパーティ製ライブラリの互換性を考慮すると、LTSが最も堅実な選択肢となります。ビルドの再現性を確保するため、node:latestタグの使用を避け、OSディストリビューションまで明示したタグを使用します。

```dockerfile
FROM node:22-bookworm-slim

# セキュリティの観点から非ルートユーザーでの実行を推奨
WORKDIR /app

# 依存関係の解決（package-lock.jsonを優先）
COPY package*.json ./
RUN npm ci --omit=dev

COPY . .

# アプリケーションの実行
USER node
CMD ["node", "server.js"]
```

## ヘルスチェックの実装：ReadinessとLivenessの分離

コンテナが「実行中」であることは、サービスが「正常」であることを保証しません。Kubernetesへの移行を見据える場合、プロセスの死活監視（Liveness）と、トラフィックを受け入れ可能かどうかの判定（Readiness）を明確に分離する必要があります。💡

### Node.jsによる実装例

```javascript
'use strict';
const http = require('node:http');
const os = require('node:os');

const state = {
  isReady: false,
  isShuttingDown: false
};

// 起動時の初期化処理（DB接続確認など）をシミュレート
setTimeout(() =&gt; {
  state.isReady = true;
  console.log('Application is ready to serve traffic');
}, 5000);

const server = http.createServer((req, res) =&gt; {
  // Liveness Probe: プロセスが生存しているか
  if (req.url === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ status: 'ok' }));
  }

  // Readiness Probe: トラフィックをルーティングして良いか
  if (req.url === '/readyz') {
    if (state.isReady &amp;&amp; !state.isShuttingDown) {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ status: 'ready' }));
    }
    res.writeHead(503, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ status: 'not ready' }));
  }

  res.writeHead(200);
  res.end(`Processed by ${os.hostname()}`);
});

server.listen(3000);
```

### Docker Composeでの定義

Node.js 18以降で標準搭載されたfetch APIを利用することで、コンテナ内にcurlをインストールすることなくヘルスチェックが可能です。これにより、イメージの軽量化とセキュリティの向上が図れます。

```yaml
services:
  api:
    build: .
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:3000/healthz').then(r=&gt;process.exit(r.ok?0:1)).catch(()=&gt;process.exit(1))"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 10s
```

## グレースフルシャットダウンとステートレス設計

Kubernetes環境では、ローリングアップデートやノードの再スケジューリングにより、コンテナの破棄が頻繁に発生します。SIGTERMシグナルを適切にハンドリングし、仕掛かり中のリクエストを完了させてから終了する「グレースフルシャットダウン」の実装が不可欠です。⚠️

```javascript
const shutdown = (signal) =&gt; {
  console.log(`${signal} received. Starting graceful shutdown...`);
  state.isShuttingDown = true;

  server.close(() =&gt; {
    console.log('Http server closed.');
    // DB接続のクローズなどをここに記述
    process.exit(0);
  });

  // 強制終了タイマー（K8sのterminationGracePeriodSecondsに合わせる）
  setTimeout(() =&gt; {
    console.error('Could not close connections in time, forcefully shutting down');
    process.exit(1);
  }, 25000);
};

process.on('SIGTERM', () =&gt; shutdown('SIGTERM'));
process.on('SIGINT', () =&gt; shutdown('SIGINT'));
```

## Troubleshooting: 移行時に直面する典型的な課題

移行プロセスにおいて、以下の3点は特に頻出するボトルネックとなります。🛠️

1. <b>DB接続プールの枯渇</b>: Docker Compose（単一ノード）では問題にならなかった接続数が、KubernetesでPodを水平スケーリングさせた瞬間にDB側の最大接続数（max_connections）を超過するケースがあります。Podあたりのプールサイズを制限し、必要に応じてPgBouncerなどのプロキシを導入する必要があります。

2. <b>ゾンビプロセスの発生</b>: DockerfileのENTRYPOINTにシェル形式（CMD node server.js）を使用すると、シェルがSIGTERMをトラップしてしまい、Node.jsプロセスにシグナルが届かないことがあります。必ずJSON配列形式（CMD ["node", "server.js"]）を使用してください。

3. <b>非決定的なビルド</b>: npm installをビルド時に実行すると、package.jsonの範囲指定により環境間でライブラリバージョンが乖離することがあります。必ずnpm ciを使用し、package-lock.jsonに基づいた厳密なビルドを行ってください。

## 運用整合性の検証

デプロイ後、コンテナが期待通りにシグナルを処理し、ヘルスチェックに応答しているかを以下のコマンドで確認します。

```text
# コンテナのステータスとヘルスチェック結果の確認
$ docker ps --format "table {{.Names}}	{{.Status}}	{{.Ports}}"
NAMES               STATUS                     PORTS
app-v22-jod         Up 5 minutes (healthy)     0.0.0.0:3000-&gt;3000/tcp

# ヘルスチェックエンドポイントへのリクエスト検証
$ curl -i http://localhost:3000/readyz
HTTP/1.1 200 OK
Content-Type: application/json
Date: Sat, 11 Jul 2026 10:00:00 GMT
Connection: keep-alive
Keep-Alive: timeout=5
Transfer-Encoding: chunked

{"status":"ready"}

# ログ出力の構造化確認 (JSON形式)
$ docker logs app-v22-jod | head -n 5
{"level":"info","message":"Server listening on port 3000","timestamp":"2026-07-11T10:00:05Z"}
{"level":"info","message":"Application is ready to serve traffic","timestamp":"2026-07-11T10:00:10Z"}
```

## Operational Notes

Docker Composeは、再現可能な運用ユニットを定義するための「訓練場」です。ここでヘルスチェック、ログの標準出力化、シグナルハンドリングを徹底することで、Kubernetesへの移行コストは大幅に削減されます。技術選定は単なる好みの問題ではなく、障害発生時の回復コストとデリバリー速度のバランスを考慮した経営判断であるべきです。