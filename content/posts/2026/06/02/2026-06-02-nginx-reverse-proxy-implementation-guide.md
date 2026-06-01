---
title: "NGINXリバースプロキシ構築におけるNginx Proxy Managerと手動構成の実装手法"
slug: "nginx-reverse-proxy-implementation-guide"
date: 2026-06-02T07:52:01+09:00
draft: false
image: ""
description: "Nginx Proxy ManagerによるGUI管理とnginx.confの直接編集によるリバースプロキシ構築手順。Docker環境の整備からproxy_passの設定、ファイアウォール制御までを網羅。"
categories: ["Linux System Admin"]
tags: ["nginx", "reverse-proxy", "nginx-proxy-manager", "docker-compose", "proxy-pass", "linux-administration"]
author: "K-Life Hack"
---

パブリックIPアドレスからの外部トラフィックを、プライベートネットワーク上のバックエンドアプリケーション（Apache Tomcat）へルーティングするためのNGINXリバースプロキシ環境の構築手順について詳述します。実装アプローチとして、Dockerを利用したGUIベースの管理ツールである「Nginx Proxy Manager (NPM)」の導入と、コマンドラインによる「手動構成」の2つの手法を解説します。

## 1. Nginx Proxy Manager (NPM) による実装

Nginx Proxy Managerは、リバースプロキシ、SSL証明書管理、アクセスリストの制御をWebインターフェースから一元管理できるソリューションです。

### 1.1 既存サービスの競合回避

NPMはポート80および443を占有するため、ホストOS上でネイティブに動作しているNGINXサービスが存在する場合、これを停止および無効化する必要があります。

```bash
# サービスの停止
systemctl stop nginx

# 自動起動の無効化
systemctl disable nginx
```

### 1.2 Docker環境の整備

NPMはコンテナとして動作するため、Docker EngineおよびDocker Composeの導入が必須となります。

1. <b>リポジトリの構成</b>: `yum-utils`をインストールし、公式のDockerリポジトリを追加します。
```bash
   dnf install -y yum-utils
   ```
2. <b>サービスの有効化</b>: Dockerデーモンを起動し、システム再起動時にも自動実行されるよう設定します。
```bash
   systemctl start docker
   systemctl enable docker
   ```

### 1.3 コンテナのオーケストレーション

NPMの構成ファイルを管理するための専用ディレクトリを作成し、`docker-compose.yml`を定義します。

```bash
mkdir ~/npm
cd ~/npm
vi docker-compose.yml
```

`docker-compose.yml`には、公式のイメージ指定、データベースパラメータ、および永続化のためのボリュームマッピングを記述します。定義完了後、以下のコマンドでコンテナをバックグラウンドで起動します。

```bash
docker compose up -d
```

### 1.4 Web UIによるプロキシ設定

コンテナ起動後、管理ダッシュボード（デフォルトポート: 81）にアクセスして設定を行います。

1. <b>初期認証</b>: `http://[Public_IP]:81`にアクセスし、初期クレデンシャル（`admin@example.com` / `changeme`）でログインします。初回ログイン時にメールアドレスとパスワードの変更が強制されます。
2. <b>Proxy Hostの追加</b>: 「Add Proxy Host」を選択し、以下のパラメータを入力します。

・<b>Domain Names</b>: 公開するドメインまたはIPアドレス

・<b>Scheme</b>: http

・<b>Forward Hostname / IP</b>: 10.101.0.28（バックエンドTomcatのプライベートIP）

・<b>Forward Port</b>: 8080
3. <b>疎通確認</b>: ブラウザからパブリックIPにアクセスし、Tomcatのレスポンスが返ることを確認します。

## 2. NGINX手動構成によるリバースプロキシの実装

GUIを必要としない環境や、より軽量な構成を求める場合には、NGINXパッケージを直接操作してパススルー設定を行います。

### 2.1 NGINXのインストールと初期化

DNFパッケージマネージャを使用してNGINXを導入します。インストール後、`curl -I http://localhost`を実行し、Webサーバーが正常に応答することを確認します。

```bash
dnf install nginx -y
systemctl start nginx
systemctl enable nginx
```

### 2.2 ネットワークセキュリティ設定

外部トラフィックを許可するため、OSのファイアウォール（iptables）でポート80を開放します。

```bash
iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT
```

### 2.3 proxy_passディレクティブの構成

リバースプロキシの中核となるロジックを`nginx.conf`に定義します。`/etc/nginx/nginx.conf`を開き、`server`コンテキスト内の`location /`ブロックを修正します。

```nginx
   location / {
       # バックエンドのTomcatサーバー（ポート8080）へトラフィックを転送
       proxy_pass http://127.0.0.1:8080;
       
       # 必要に応じてヘッダー情報を付与（オプション）
       proxy_set_header Host $host;
       proxy_set_header X-Real-IP $remote_addr;
       proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
   }
   ```

### 2.4 設定の検証と反映

設定ファイルの構文チェックを行い、エラーがないことを確認した上でサービスをリロードします。`reload`を使用することで、既存の接続を維持したまま設定を適用可能です。

```bash
# 構文チェック
nginx -t

# 設定の再読み込み
systemctl reload nginx
```

## 3. 運用上の留意事項

💡 <b>ポート競合の管理</b>: 同一ホスト内で複数のWebサービスを稼働させる場合、ポート80/443のバインド権限をどのプロセスに割り当てるかを明確にする必要があります。
⚠️ <b>セキュリティ</b>: NPMを使用する場合、管理ポート（81）へのアクセスは特定のIPアドレスからのみ許可するよう、ネットワーク層での制限を推奨します。
🛠️ <b>永続性</b>: Docker構成時は、ボリュームマッピングが正しく設定されているか確認し、コンテナの破棄によって設定データが消失しないよう担保してください。

## Summary

本ドキュメントでは、NGINXを用いたリバースプロキシ構築の2つの手法を提示しました。Nginx Proxy Managerは直感的な運用を可能にし、手動構成はシステムの透明性とカスタマイズ性を提供します。要件に応じて適切な手法を選択し、バックエンドサーバーへの安全かつ効率的なトラフィックルーティングを実現してください。