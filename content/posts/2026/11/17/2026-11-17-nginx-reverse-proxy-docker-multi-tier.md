---
title: "Next.js・NestJSマルチコンテナ構成におけるNginxリバースプロキシの設計とポートバインディング"
slug: "nginx-reverse-proxy-docker-multi-tier"
date: 2026-11-17T10:47:43+09:00
draft: false
image: ""
description: "Next.jsとNestJS、MySQLで構成されるマルチコンテナ環境において、Nginxリバースプロキシを用いたL7ルーティングとDockerブリッジネットワークのポートバインディング構造を解説します。"
categories: ["Linux System Admin"]
tags: ["nginx", "docker-compose", "reverse-proxy", "nextjs", "nestjs"]
author: "K-Life Hack"
---

単一のアプリケーションサーバーにフロントエンドとバックエンドの役割を同居させ、パブリックポートを個別に開放する構成は、コンポーネントのスケールアウトやセキュリティの維持においてボトルネックとなります。特にマイクロサービス構成やフロント・バック分離アーキテクチャでは、エンドポイントの一元化と内部ネットワークの隔離が必須となります。本稿では、フロントエンド（Next.js）、バックエンド（NestJS）、データベース（MySQL）を分離し、Nginxをイングラストラフィックの統一エントリポイントとして統合した多層コンテナ構成の設計と検証手順を整理します。

## ネットワーク構成とコンテナトポロジー

本構成では、外部からのリクエストをすべてNginxリバースプロキシ（Port 80）で受け取り、URIパスに基づいて内部Dockerブリッジネットワーク上の適切なサービスへとルーティングします。各アプリケーションコンテナは直接ホストのネットワークポートをパブリックにバインドせず、Docker内部DNSによるサービス名解決を利用して通信します。

```
Docker Network (Bridge Interface)
│
├── nginx (Ingress / Routing Layer)
├── frontend (Next.js Application)
├── backend (NestJS API Engine)
└── database (MySQL Instance)
```

### コンテナ構成ファイル (docker-compose.yml)

サービス定義では、`ports` セクションをNginxのみに限定し、他コンテナは `app-network` 内部でのみ通信可能な状態にします。

```yaml
version: '3.8'

networks:
  app-network:
    driver: bridge

services:
  database:
    image: mysql:8.0
    container_name: database
    environment:
      MYSQL_ROOT_PASSWORD: rootpassword
      MYSQL_DATABASE: app_db
    networks:
      - app-network

  backend:
    build:
      context: ./backend
      dockerfile: Dockerfile
    container_name: backend
    environment:
      DATABASE_HOST: database
      DATABASE_PORT: 3306
      PORT: 4000
    depends_on:
      - database
    networks:
      - app-network

  frontend:
    build:
      context: ./frontend
      dockerfile: Dockerfile
    container_name: frontend
    environment:
      PORT: 3000
    networks:
      - app-network

  nginx:
    image: nginx:alpine
    container_name: nginx
    ports:
      - "80:80"
    volumes:
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - frontend
      - backend
    networks:
      - app-network
```

## Nginx リバースプロキシの設定詳細

Nginxでは、`/api/` プレフィックスの付いたリクエストをバックエンドコンテナ（`backend:4000`）へ、それ以外のルートリクエスト（`/`）をフロントエンドコンテナ（`frontend:3000`）へ転送します。

```nginx
upstream frontend {
    server frontend:3000;
}

upstream backend {
    server backend:4000;
}

server {
    listen 80;
    server_name localhost;

    location /api/ {
        proxy_pass http://backend/api/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location / {
        proxy_pass http://frontend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

## ポートバインディングにおける内部状態の区別

コンテナネットワークを構築する際、コンテナ内部ポートの開放状態（Exposed）とホストインターフェースへの公開状態（Published）の違いを正確に把握する必要があります。

* <b>未公開の内部状態 (`80/tcp`):</b> ソケットはコンテナ内部のネットワークスタックでのみLISTENしています。Dockerネットワーク外部（ホストOSやクライアント）からの直接接続は拒否されます。
* <b>公開された外部状態 (`0.0.0.0:80-&gt;80/tcp`):</b> ホストOSの全ネットワークインターフェース（`0.0.0.0`）のポート80がコンテナ内部のポート80へ転送されます。これにより、AWS EC2などのパブリックIPまたはALB経由のトラフィックが正しくインフラ内部へと転送されます。

## 稼働検証とステータス確認

デプロイ後、コンテナの稼働状態およびHTTPレスポンスの完全性をターミナル上で確認します。

```text
$ docker compose ps
NAME        IMAGE          COMMAND                  SERVICE     CREATED         STATUS         PORTS
backend     app-backend    "docker-entrypoint.s…"   backend     5 minutes ago   Up 5 minutes   4000/tcp
database    mysql:8.0      "docker-entrypoint.s…"   database    5 minutes ago   Up 5 minutes   3306/tcp, 33060/tcp
frontend    app-frontend   "docker-entrypoint.s…"   frontend    5 minutes ago   Up 5 minutes   3000/tcp
nginx       nginx:alpine   "/docker-entrypoint.…"   nginx       5 minutes ago   Up 5 minutes   0.0.0.0:80-&gt;80/tcp, :::80-&gt;80/tcp

$ curl -i http://localhost/api/posts
HTTP/1.1 200 OK
Server: nginx/1.25.3
Date: Mon, 17 Nov 2026 10:00:00 GMT
Content-Type: application/json; charset=utf-8
Content-Length: 124
Connection: keep-alive
X-Powered-By: Express
```

## Troubleshooting

### 1. ⚠️ Nginx起動時の502 Bad Gatewayエラー

Nginxコンテナ起動時にアップストリームとなるバックエンドまたはフロントエンドコンテナのアプリケーション初期化が完了していない場合、Nginxは名前解決または接続確立に失敗し `502 Bad Gateway` を返します。

* <b>原因:</b> コンテナの起動順序（`depends_on`）は制御できても、アプリケーション層のReady状態まではDockerエンジン単体で保証されないためです。
* <b>対策:</b> Nginxの `upstream` ブロックにダイナミックリゾルバを設定するか、ヘルスチェックロジックを統合して依存関係の成立を確認後にプロキシトラフィックの通過を許可します。

### 2. ⚠️ URI末尾スラッシュによるプロキシパスのミスマッチ

`proxy_pass` ディレクティブの末尾スラッシュ指定有無により、転送先へのパス付与動作が変化します。

* `proxy_pass http://backend/api/;`（末尾スラッシュあり）: マッチした `location /api/` 部分が置換され、`http://backend/api/posts` へ転送されます。
* `proxy_pass http://backend;`（末尾スラッシュなし）: 元のリクエストURI全体がそのまま付加されます。

設定ミスによりバックエンド側で `404 Not Found` が発生する場合は、`proxy_pass` の末尾スラッシュと NestJS 側のグローバルプレフィックス設定の一致を確認してください。

## Configuration Notes

* 🛠️ <b>基盤健全性の検証基準:</b> 単にコンテナが `Up` 状態であることだけを確認するのではなく、ALBターゲットグループのヘルスチェックエンドポイントおよびプロキシ経由のL7レスポンスコード（`HTTP 200 OK`）を監視指標として定義する必要があります。
* 🛠️ <b>最小権限のポート公開方針:</b> ホスト側でポートを開放するコンテナはNginx（プロキシ層）のみに制限し、バックエンドおよびデータベースコンテナは内部ブリッジネットワークに限定配置することで、攻撃表面積を最小化できます。