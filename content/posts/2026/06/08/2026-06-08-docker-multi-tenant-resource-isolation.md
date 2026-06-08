---
title: "マルチテナントWebホスティングにおけるDocker Composeを用いたリソース隔離と移行の実装"
slug: "docker-multi-tenant-resource-isolation"
date: 2026-06-08T10:02:30+09:00
draft: false
image: ""
description: "1台のVMで複数サイトを運用する際の「Noisy Neighbor」問題を解決するため、Docker ComposeとNginxリバースプロキシを用いたコンテナ移行とリソース制限の実装手順を解説します。"
categories: ["Linux System Admin"]
tags: ["docker-compose", "nginx-reverse-proxy", "resource-limits", "multi-tenancy", "container-migration"]
author: "K-Life Hack"
---

# Dockerコンテナ化によるマルチテナント環境のリソース隔離と運用安定性の向上

従来のシングルサーバー仮想マシン（VM）環境において、複数のWebサービスがリソースを共有する構成では、特定のサイトでのトラフィック急増がサーバー全体のパフォーマンスを低下させる「Noisy Neighbor（リソース独占）」問題が頻発します。本稿では、この運用リスクを排除し、サービスの安定性と可視性を向上させるための、Dockerベースの独立したコンテナインフラへの移行手順について記述します。

## 従来環境の課題と移行の背景

従来のVM環境では、10個の異なるWebサイトが単一のVM内で動作していました。この構成には以下の技術的負債が存在していました。

- <b>単一障害点（SPOF）のリスク</b>: 1つのサイトに対するDDoS攻撃やスパムボットの活動によりCPU使用率が100%に達すると、残りの9サイトも同時にダウンタイムまたは深刻なレイテンシに見舞われます。
- <b>インシデント対応の遅延</b>: 全サイトが同一のOSおよびプロセス空間を共有しているため、障害発生時にどのサイトが根本原因であるかを迅速に特定することが困難でした。

Docker Composeを用いたコンテナ化への移行により、各サイトを軽量なコンテナとして分離し、物理的なリソース制限（CPU/メモリ）を課すことで、特定のサイトの負荷が他へ波及しない「サンドボックス」環境を構築します。

## 技術的実装手順

### 1. Docker Engineのセットアップ

ホストシステムにDockerエンジンおよびComposeプラグインをインストールします。これにより、コンテナオーケストレーションの基盤を確立します。

```bash
# Docker Installation for Ubuntu/Debian
sudo apt-get update
sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

### 2. ディレクトリ構造とストレージの準備

プロキシおよび各サイトのデータを管理するためのディレクトリ階層を構築します。ここでは `/data` にマウントされたストレージを使用し、永続性とバックアップの効率性を確保します。

```bash
mkdir -p /data/docker-web/proxy/conf.d
mkdir -p /data/docker-web/site1/html
mkdir -p /data/docker-web/site1/logs
mkdir -p /data/docker-web/site2/html
mkdir -p /data/docker-web/site2/logs
```

### 3. Docker Composeによるリソース制限の定義

`docker-compose.yml` において、`deploy.resources.limits` 属性を使用し、各コンテナがホストのリソースを100%消費することを防止します。

```yaml
version: '3.8'

services:
  site1:
    image: nginx:alpine
    container_name: web-site1
    volumes:
      - /data/docker-web/site1/html:/usr/share/nginx/html
      - /data/docker-web/site1/logs:/var/log/nginx
    deploy:
      resources:
        limits:
          cpus: '0.50'
          memory: 512M
    networks:
      - web-network

networks:
  web-network:
    driver: bridge
```

### 4. Nginxリバースプロキシの設定

`nginx.conf` を使用して、`server_name` に基づきリクエストを適切なコンテナへルーティングします。Dockerブリッジネットワーク内では、サービス名がホスト名として機能します。

```nginx
server {
    listen 80;
    server_name site1.example.com;

    location / {
        proxy_pass http://site1:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

## 運用検証とリソース隔離の論理

デプロイは以下のコマンドで実行します。

```bash
docker compose up -d
```

この構成により、例えば `site1` でトラフィックが急増した場合でも、当該コンテナは設定された <b>0.5 CPUコア</b> および <b>512MB RAM</b> の範囲内に物理的に制限されます。これにより、ホスト全体の計算リソースが枯渇することを防ぎ、`site2` から `site10` までの他サービスは影響を受けずに稼働を継続できます。

また、各サイトのログが `/data/docker-web/siteX/logs` に分離して出力されるため、異常が発生したサイトの特定と原因分析が迅速化されます。

## Configuration Notes

- <b>Docker Compose V2の仕様</b>: `version` 指定は現在の仕様では任意となっていますが、互換性のために残しています。
- <b>リソース制限のチューニング</b>: `cpus: '0.5'` などの数値は、実際のサービスのベースライン負荷に基づいて調整が必要です。本構成は、マルチテナント環境における最小限の安定性を確保するためのリファレンスモデルです。
- <b>ネットワーク分離</b>: `web-network` ブリッジドライバを使用することで、外部からの直接アクセスをプロキシ経由に限定し、セキュリティ境界を明確にしています。