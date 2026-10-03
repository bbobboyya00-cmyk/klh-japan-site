---
title: "DockerとCaddyによるDifyセルフホスト環境の構築とセキュリティ硬化設計"
slug: "dify-self-hosting-docker-caddy-hardening"
date: 2026-10-03T10:14:28+09:00
draft: false
image: ""
description: "DockerとCaddyを使用したDify Community Editionのセルフホスト手順、UFWとDockerのネットワーク競合回避、SSL自動更新、セキュリティ硬化策を解説する技術ノート。"
categories: ["Linux System Admin"]
tags: ["dify", "docker-compose", "caddy", "ufw-bypass", "reverse-proxy"]
author: "K-Life Hack"
---

LLMオーケストレーションツールであるDifyをセルフホストする要求は、パブリッククラウド版の機能制限（作成可能なアプリケーション数やナレッジパイプラインの制約）を回避するために急速に高まっています。しかし、ローカル環境での運用は、マシンのスリープや動的IP、ファイアウォール越えといった可用性の課題を伴います。24時間稼働するLinux VPS上にDockerを用いてDifyを構築し、Caddyによる自動HTTPS化とセキュリティ硬化を施すことで、実用的な運用環境を確立できます。

本稿では、Dify <code>v1.17.x</code> および Caddy <code>v2.11.x</code> をベースに、ホストマシンのセキュリティを担保しつつ、リバースプロキシを介して安全に外部公開するためのインフラ設計と具体的な実装手順を解説します。

---

## 1. システムアーキテクチャ設計

本環境におけるネットワークおよびコンテナの配置トポロジーは以下の通りです。

```
[ 外部クライアント / Webhook 送信元 ]
                 │
                 │  https://dify.<domain> (Port 443)
                 ▼
┌───────────────────────────────── VPS ホスト ─────────────────────────────────┐
│                                                                              │
│  Caddy リバースプロキシ (ACME SSL自動管理, Ports 80 / 443)                    │
│     │                                                                        │
│     │ reverse_proxy (ローカルループバック経由)                                │
│     ▼                                                                        │
│  127.0.0.1:8080                                                              │
│     │                                                                        │
│     │ Docker ポートマッピング                                                 │
│     ▼                                                                        │
│  dify-nginx (コンテナポート :80)                                             │
│     ├─ web / api / worker / worker_beat                                      │
│     ├─ db_postgres / redis / weaviate                                        │
│     └─ plugin_daemon (127.0.0.1:5003)                                        │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
外部公開ポート: 80/tcp, 443/tcp, 443/udp (Caddy), SSH (カスタムポート)
```

セキュリティ上の最重要設計として、Difyを構成するコンテナ群（Nginx、PostgreSQL、Redis、Plugin Daemon等）は、ホストのグローバルネットワークインターフェース（<code>0.0.0.0</code>）には一切バインドせず、ループバックアドレス（<code>127.0.0.1</code>）にのみバインドします。外部からのトラフィックは、Caddyリバースプロキシがすべて受信し、SSL/TLSを終端した上で内部転送します。

---

## 2. ホストインフラのプロビジョニング

### 2-1. システムパッケージの更新と依存関係の導入
ホストOS（Ubuntu 22.04 LTS / 24.04 LTSを想定）のパッケージを最新化し、必要なツール群を導入します。

```bash
sudo apt update &amp;&amp; sudo apt upgrade -y
sudo apt install -y git curl jq acl
```

### 2-2. Docker Engineの導入と検証

Docker Engineが未導入の場合は、公式のスクリプトを用いて導入します。Docker Composeのバージョンが <code>v2.24.0</code> 以上であることを確認してください（後述の <code>!override</code> 構文のサポートに必要です）。

```bash
docker --version 2&gt;/dev/null || curl -fsSL https://get.docker.com | sudo sh
docker compose version
systemctl is-enabled docker
```

### 2-3. 専用システムユーザーの作成と権限設定

セキュリティ確保のため、<code>root</code> ユーザーでのコンテナ実行を避け、専用の <code>dify</code> ユーザーを作成して運用します。

```bash
sudo adduser dify
sudo usermod -aG docker dify
sudo usermod -aG sudo dify
```

### 2-4. スワップ領域（4GB）の確保

Difyはバックエンドで複数のマイクロサービス（10以上のコンテナ）を同時に起動するため、アイドル時でも3〜5GBのメモリを消費します。メモリ不足によるカーネルのOOM（Out of Memory）キラーの作動を防ぐため、4GBのスワップ領域を明示的に確保します。

```bash
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
sudo sysctl vm.swappiness=10
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf
free -h
```

---

## 3. Difyオーケストレーションのデプロイ

ここからの作業は、先ほど作成した <code>dify</code> ユーザーに切り替えて実行します。

### 3-1. リポジトリの取得と環境変数の暗号化設定

最新のリリースバージョンをGitHub API経由で動的に取得し、クローンします。

```bash
cd ~
git clone --branch "$(curl -s https://api.github.com/repos/langgenius/dify/releases/latest | jq -r .tag_name)" https://github.com/langgenius/dify.git
cd ~/dify/docker
cp .env.example .env
chmod 600 .env
```

<code>.env</code> ファイル内の初期パスワードおよび暗号化キーを、高エントロピーなランダム文字列に書き換えます。初期値（<code>difyai123456</code> など）のまま起動することは、外部からの不正アクセスのリスクを極めて高めるため厳禁です。

```bash
# セッショントークン暗号化用のキー生成
sed -i "s|^SECRET_KEY=.*|SECRET_KEY=$(openssl rand -base64 42)|" .env

# PostgreSQLおよびRedis用のパスワード生成
DBP=$(openssl rand -hex 24)
RP=$(openssl rand -hex 24)

sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=$DBP|" .env
sed -i "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=$RP|" .env

# Celery Broker URLへのRedisパスワードの反映
sed -i "s|^CELERY_BROKER_URL=.*|CELERY_BROKER_URL=redis://:$RP@redis:6379/1|" .env
```

### 3-2. ポートバインドのループバック限定化

Dockerのデフォルト設定では、ポートマッピングを行うとホストの全インターフェース（<code>0.0.0.0</code>）でポートが開放され、UFWなどのホスト側ファイアウォールをバイパスしてしまいます。これを防ぐため、<code>.env</code> 内の露出ポート設定に <code>127.0.0.1:</code> プレフィックスを明示的に付与します。

```bash
sed -i 's|^NGINX_PORT=.*|NGINX_PORT=80|' .env
sed -i 's|^NGINX_SSL_PORT=.*|NGINX_SSL_PORT=443|' .env

sed -i 's|^EXPOSE_NGINX_PORT=.*|EXPOSE_NGINX_PORT=127.0.0.1:8080|' .env
sed -i 's|^EXPOSE_NGINX_SSL_PORT=.*|EXPOSE_NGINX_SSL_PORT=127.0.0.1:8443|' .env
sed -i 's|^EXPOSE_PLUGIN_DEBUGGING_PORT=.*|EXPOSE_PLUGIN_DEBUGGING_PORT=5003|' .env
```

### 3-3. Plugin Daemonのバインド制限（Docker Compose Override）

<code>plugin_daemon</code> サービスは、デフォルトで <code>0.0.0.0:5003</code> にバインドされる設定になっています。これを安全に上書きするため、<code>docker-compose.override.yaml</code> を作成し、ループバックアドレスに制限します。

```yaml
# ~/dify/docker/docker-compose.override.yaml
services:
  plugin_daemon:
    ports: !override
      - "127.0.0.1:5003:5003"
```

### 3-4. コンテナの起動と初期ヘルスチェック

設定が完了したら、コンテナ群をバックグラウンドで起動します。

```bash
docker compose up -d
```

起動後、APIサーバーが正常に応答するかローカルループバック経由で確認します。

```bash
sleep 30
curl -s http://127.0.0.1:8080/console/api/setup
```

正常に起動していれば、<code>{"step":"not_started","setup_at":null}</code> というJSONレスポンスが返ります。

---

## 4. CaddyによるHTTPSリバースプロキシの構築

Caddyを使用して、Let's EncryptからSSL/TLS証明書を自動取得し、HTTPS通信を終端します。

### 4-1. Caddyのインストール

公式リポジトリを追加し、Caddyを導入します。

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update &amp;&amp; sudo apt install -y caddy
```

### 4-2. Caddyfileの構成

<code>/etc/caddy/Caddyfile</code> を編集し、ドメインから内部の <code>127.0.0.1:8080</code> へルーティングする設定を行います。

```caddy
# /etc/caddy/Caddyfile
dify.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

※ <code>dify.example.com</code> は、実際にDNSでVPSのパブリックIPを指すように設定したドメインに置き換えてください。

設定ファイルの構文チェックを行い、問題がなければCaddyサービスをリロードします。

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

---

## 5. Troubleshooting

セルフホスト環境の構築および運用フェーズで直面しやすい代表的な摩擦点（Friction Points）と、その解決策を以下に示します。

### 5-1. DockerによるUFW（ファイアウォール）バイパス問題

* <b>事象</b>: ホスト側で <code>sudo ufw deny 8080/tcp</code> を設定しているにもかかわらず、外部から <code>http://&lt;VPS_IP&gt;:8080</code> に直接アクセスできてしまう。
* <b>原因</b>: Dockerはホストの <code>iptables</code>（Netfilter）ルールを直接操作してコンテナへのルーティングを行うため、UFWのフィルタリングルールよりも優先してパケットがコンテナに到達します。
* <b>解決策</b>: <code>.env</code> 内の <code>EXPOSE_NGINX_PORT</code> に必ず <code>127.0.0.1:8080</code> のようにIPアドレスを明示的に指定します。これにより、コンテナはループバックインターフェースにのみバインドされ、外部からの直接アクセスは物理的に遮断されます。

### 5-2. 初回起動後のデータベース認証エラー

* <b>事象</b>: 運用開始後に <code>.env</code> の <code>DB_PASSWORD</code> を変更したところ、<code>api</code> コンテナが <code>FATAL: password authentication failed for user "postgres"</code> を出力してクラッシュループに陥る。
* <b>原因</b>: PostgreSQLコンテナは、初回起動時（ボリュームが空の状態）にのみ <code>.env</code> のパスワードを使用してデータベース初期化を行います。起動後に <code>.env</code> の値を変更しても、コンテナ内のデータベースに保存されたパスワードは自動更新されないため、不一致が発生します。
* <b>解決策</b>: パスワードを変更する場合は、PostgreSQLコンテナ内で直接 <code>ALTER USER</code> 構文を実行してデータベース側のパスワードを更新するか、データを破棄して再初期化（※データは全消失します）する必要があります。

### 5-3. 非同期タスク（Celery）の接続拒否

* <b>事象</b>: ナレッジ（RAG）へのドキュメントアップロードやインデックス作成タスクが「進行中」のまま停止する。
* <b>原因</b>: Redisのパスワード（<code>REDIS_PASSWORD</code>）を変更した際、<code>CELERY_BROKER_URL</code> に含まれる接続パスワードの同期を忘れたため、非同期ワーカーがキューを取得できなくなっています。
* <b>解決策</b>: <code>.env</code> 内の <code>CELERY_BROKER_URL</code> が <code>redis://:&lt;REDIS_PASSWORD&gt;@redis:6379/1</code> の形式になっており、現在の <code>REDIS_PASSWORD</code> と完全に一致しているか確認し、コンテナを再起動します。

### 5-4. Nginxコンテナによる「502 Bad Gateway」のキャッシュ

* <b>事象</b>: <code>api</code> コンテナの再起動中、またはアップデート直後に、Caddyは正常であるにもかかわらずブラウザに <code>502 Bad Gateway</code> が表示され続ける。
* <b>原因</b>: DifyのフロントエンドNginxコンテナが、上流の <code>api</code> コンテナの古いIPアドレスをキャッシュしている、または <code>api</code> の起動完了前に名前解決に失敗してルーティングを停止しているケースがあります。
* <b>解決策</b>: <code>api</code> コンテナが完全に起動したことを確認した上で、Nginxコンテナのみを単独で再起動します。

  ```bash
  docker compose restart nginx
  ```

---

## 6. 稼働状態の検証（Operational Verification）

デプロイ完了後、以下の検証コマンドを実行して、システムが設計通りにセキュアに稼働しているか確認します。

### 6-1. コンテナ稼働ステータスの確認

すべてのコンテナが <code>Up</code>（または <code>Up (healthy)</code>）ステータスであることを確認します。

```text
$ docker compose ps
NAME                IMAGE                               COMMAND                  SERVICE             CREATED             STATUS                    PORTS
dify-api-1          langgenius/dify-api:0.15.3          "/bin/sh -c './entry…"   api                 2 hours ago         Up 2 hours (healthy)      
dify-db-1           postgres:15-alpine                  "docker-entrypoint.s…"   db                  2 hours ago         Up 2 hours (healthy)      5432/tcp
dify-nginx-1        nginx:1.25-alpine                   "/docker-entrypoint.…"   nginx               2 hours ago         Up 2 hours                127.0.0.1:8080-&gt;80/tcp, 127.0.0.1:8443-&gt;443/tcp
dify-plugin_daemon  langgenius/dify-plugin-daemon:0.15  "/entrypoint.sh"         plugin_daemon       2 hours ago         Up 2 hours (healthy)      127.0.0.1:5003-&gt;5003/tcp
dify-redis-1        redis:7.2-alpine                    "docker-entrypoint.s…"   redis               2 hours ago         Up 2 hours (healthy)      6379/tcp
dify-sandbox-1      langgenius/dify-sandbox:0.5.2       "/main"                  sandbox             2 hours ago         Up 2 hours (healthy)      
dify-web-1          langgenius/dify-web:0.15.3          "/bin/sh -c './entry…"   web                 2 hours ago         Up 2 hours (healthy)      
dify-weaviate-1     semitechnologies/weaviate:1.19.0    "/bin/weaviate --hos…"   weaviate            2 hours ago         Up 2 hours (healthy)      
dify-worker-1       langgenius/dify-api:0.15.3          "/bin/sh -c './entry…"   worker              2 hours ago         Up 2 hours (healthy)      
```

### 6-2. ホストのリスニングポート監査

外部公開されているポートが、設計通り SSH（例: <code>2022</code>）および Caddy（<code>80</code>, <code>443</code>）のみに制限されているか検証します。

```text
$ sudo ss -tulnp | grep -vE '127\.0\.0\.|::1|%lo'
Netid State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
tcp   LISTEN 0      4096         0.0.0.0:80         0.0.0.0:*     users:(("caddy",pid=1024,fd=6))
tcp   LISTEN 0      4096         0.0.0.0:443        0.0.0.0:*     users:(("caddy",pid=1024,fd=7))
tcp   LISTEN 0      128          0.0.0.0:2022       0.0.0.0:*     users:(("sshd",pid=821,fd=3))
udp   UNCONN 0      0            0.0.0.0:443        0.0.0.0:*     users:(("caddy",pid=1024,fd=8))
```

※ <code>8080</code> や <code>5003</code>、<code>5432</code> などのポートが <code>0.0.0.0</code> に露出していないことを確認します。

### 6-3. エンドツーエンドのHTTPS接続検証

外部のクライアントマシンから、Caddyを介したHTTPS通信が正常に終端され、Difyのセットアップエンドポイントに到達できるかテストします。

```text
$ curl -I https://dify.example.com/console/api/setup
HTTP/2 200 
alt-svc: h3=":443"; ma=2592000
content-type: application/json; charset=utf-8
date: Sat, 03 Oct 2026 14:22:15 GMT
server: Caddy
server: nginx
```

レスポンスヘッダーに <code>server: Caddy</code> および <code>server: nginx</code> が順に出現し、ステータスコード <code>200</code> が返れば、リバースプロキシチェーンは正常に機能しています。

---

## 7. ライフサイクルダイナミクスとコンテナ更新

Difyのバージョンアップや設定変更に伴うコンテナの再作成時には、一時的なサービスダウンタイムが発生します。Caddyはバックエンド（<code>127.0.0.1:8080</code>）への接続が切断された場合、自動的に <code>502 Bad Gateway</code> をクライアントに返します。

ローリングアップデート（ゼロダウンタイムに近い切り替え）を部分的に実現するためには、コンテナの停止前に新しいイメージをプリプル（事前取得）しておくことで、コンテナの再作成および起動にかかる時間を最小限に抑えるアプローチが有効です。

```bash
cd ~/dify/docker
git pull origin main
docker compose pull
docker compose up -d --remove-orphans
```

これにより、イメージのダウンロード時間によるダウンタイムを排除し、コンテナの再起動にかかる数秒〜数十秒程度にサービス停止時間を圧縮できます。

---

## Operational Notes

* 💡 <b>バックアップの自動化</b>: <code>dify-db-1</code>（PostgreSQL）のデータボリュームおよび <code>.env</code> ファイルは、システムの全設定とユーザーデータを保持しています。定期的に <code>pg_dump</code> を実行し、ホスト外のセキュアなストレージにバックアップを退避するジョブを <code>cron</code> に登録することを強く推奨します。
* 🛠️ <b>ログのローテーション</b>: Dockerのデフォルト設定では、コンテナの標準出力ログが無限に肥大化し、ディスク容量を圧迫します。<code>/etc/docker/daemon.json</code> に <code>json-file</code> ドライバの最大サイズ制限（例: <code>max-size: "10m"</code>）を設定してください。
* ⚠️ <b>APIキーのライフサイクル</b>: Dify内で連携する外部LLM（OpenAI、Anthropic等）のAPIキーは、<code>.env</code> 内の <code>SECRET_KEY</code> を用いて暗号化されデータベースに保存されます。このキーを変更すると、既存のすべての外部連携が破損するため、本番稼働後の <code>SECRET_KEY</code> の変更は原則禁止とします。</domain>