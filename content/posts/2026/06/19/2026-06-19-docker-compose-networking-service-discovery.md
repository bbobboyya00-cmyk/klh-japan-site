---
title: "Docker Composeにおけるサービスディスカバリとネットワーク分離の設計実装"
slug: "docker-compose-networking-service-discovery"
date: 2026-06-19T10:16:43+09:00
draft: false
image: ""
description: "Docker Composeを用いたWeb・DB間のセキュアな通信設計、内部DNSによるサービスディスカバリ、および起動順序制御に伴うトラブルシューティング手法を解説します。"
categories: ["DevOps Logistics"]
tags: ["docker-compose", "service-discovery", "container-networking", "mysql", "nginx", "healthcheck"]
author: "K-Life Hack"
---

マイクロサービスアーキテクチャや多層構造のアプリケーションにおいて、コンテナ間の通信管理を静的なIPアドレスに依存することは、スケーラビリティと保守性の観点から大きなリスクを伴います。Docker Composeを利用した環境構築では、内部DNSによるサービスディスカバリとネットワーク分離を適切に設計することで、ホストマシンのポート競合を回避しつつ、セキュアなバックエンド通信を実現することが求められます。

### 内部DNSとサービスディスカバリのメカニズム

Docker Composeで定義されたサービス群は、デフォルトで単一のブリッジネットワークに割り当てられます。このネットワーク内では、各コンテナはサービス名をホスト名として相互に解決可能です。例えば、データベースサービスを<b>db_server</b>として定義した場合、Webアプリケーションコンテナからはlocalhostではなく<b>db_server:3306</b>というエンドポイントで接続が可能になります。これにより、コンテナ再起動時に内部IPが変動しても、アプリケーション側の設定を変更する必要がなくなります。

### 実装構成案：NginxとMySQLの統合

以下の構成では、外部に公開するWebサーバーと、内部ネットワークに隠蔽するデータベースを分離し、データの永続化とヘルスチェックによる依存関係制御を実装しています。

```yaml
version: '3.8'

services:
  web_app:
    image: nginx:1.25-alpine
    container_name: web_service
    ports:
      - "8080:80"
    depends_on:
      db_service:
        condition: service_healthy
    networks:
      - backend_net
    volumes:
      - ./html:/usr/share/nginx/html:ro

  db_service:
    image: mysql:8.0.36
    container_name: db_instance
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_PASSWORD}
      MYSQL_DATABASE: app_db
    networks:
      - backend_net
    volumes:
      - db_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p$${DB_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s

networks:
  backend_net:
    driver: bridge

volumes:
  db_data:
    driver: local
```

### ネットワーク分離とポートフォワーディングの原則

本構成において、<b>db_service</b>にはports定義が存在しません。これは、データベースへのアクセスを同一ネットワーク内の<b>web_app</b>のみに制限し、ホストマシン経由の外部攻撃ベクトルを遮断するためです。外部ユーザーはホストの8080番ポートを通じてNginxにアクセスしますが、NginxからMySQLへの通信はDocker内部の<b>backend_net</b>を通り、3306番ポートで直接行われます。

## Troubleshooting

運用環境で最も頻繁に遭遇する問題は、コンテナの起動順序とアプリケーションの接続試行のタイミングの乖離による<b>Connection Refused</b>エラーです。

💡 <b>データベース初期化の遅延</b>: depends_onはコンテナの「開始」のみを保証し、内部プロセス（MySQLエンジン）の「準備完了」は保証しません。これを解決するために、上述のYAMLのようにhealthcheckとcondition: service_healthyを組み合わせる必要があります。

⚠️ <b>名前解決の失敗</b>: サービス名が正しく解決されない場合、コンテナが同一のnetworksブロックに属しているかを確認してください。異なるネットワークに属するコンテナ間では、明示的に接続設定を追加しない限り通信は遮断されます。

🛠️ <b>環境変数の不一致</b>: MYSQL_ROOT_PASSWORDなどの認証情報が、Webアプリ側の接続文字列と一致しているか、.envファイルの読み込み状況を確認してください。

### 接続整合性の検証ログ

デプロイ後、以下のコマンドを使用してネットワークの疎通とサービスの状態を確認します。

```text
# コンテナのステータスおよびヘルスチェック状態の確認
$ docker compose ps
NAME                IMAGE               COMMAND                  SERVICE             STATUS              PORTS
db_instance         mysql:8.0.36        "docker-entrypoint.s…"   db_service          healthy             3306/tcp, 33060/tcp
web_service         nginx:1.25-alpine   "/docker-entrypoint.…"   web_app             running             0.0.0.0:8080-&gt;80/tcp

# WebコンテナからDBサービスへの名前解決テスト
$ docker exec -it web_service ping -c 3 db_service
PING db_service (172.21.0.2): 56 data bytes
64 bytes from 172.21.0.2: seq=0 ttl=64 time=0.082 ms
64 bytes from 172.21.0.2: seq=1 ttl=64 time=0.124 ms

# リアルタイムログによる接続エラーの監視
$ docker compose logs -f web_app
```

## Lessons Learned

Docker Composeを用いたインフラ構成において、単なるコンテナの羅列ではなく、ネットワーク分離とヘルスチェックを組み込むことは、システムの堅牢性を高める上で不可欠です。特に、データベースの初期化時間を考慮した起動制御（Healthcheck）の実装は、デプロイ自動化におけるConnection Refused起因のパイプライン失敗を抑制する極めて有効な手段となります。また、永続ボリュームの適切なマッピングにより、コンテナのライフサイクルに依存しないデータ管理を徹底することが、プロダクション環境への移行における最低条件となります。