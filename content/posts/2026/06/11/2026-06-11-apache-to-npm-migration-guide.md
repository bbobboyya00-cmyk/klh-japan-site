---
title: "Apache mod_proxyからNginx Proxy Managerへのリバースプロキシ移行手順"
slug: "apache-to-npm-migration-guide"
date: 2026-06-11T14:17:26+09:00
draft: false
image: ""
description: "Rocky Linux環境におけるApache mod_proxyのセットアップと、Dockerを利用したNginx Proxy Managerへの移行プロセスを詳述します。SELinux設定やポート競合の回避策を含みます。"
categories: ["Linux System Admin"]
tags: ["apache-httpd", "nginx-proxy-manager", "rocky-linux", "selinux", "docker-compose", "reverse-proxy"]
author: "K-Life Hack"
---

# Rocky LinuxにおけるApache mod_proxyからNginx Proxy Managerへの移行実装ガイド

Rocky Linux環境において、従来のApache <b>mod_proxy</b>を利用した構成から、GUIベースの管理が可能なNginx Proxy Manager (NPM) へ移行する際の実装手順をまとめます。本稿では、初期のApache構成からコンテナベースの運用への転換プロセスを扱います。

## Apache mod_proxyによる初期リバースプロキシ構成

まず、バックエンドで動作するTomcatアプリケーションサーバーへのゲートウェイとして、Apache HTTP Server (httpd) を構成します。

### パッケージのインストールとサービス有効化

DNFパッケージマネージャーを使用してhttpdを導入し、システムの起動時に自動的に開始されるよう設定します。

```bash
dnf install -y httpd
systemctl start httpd
systemctl enable httpd
```

### プロキシ設定の定義

/etc/httpd/conf.d/tomcat.confを作成し、特定のトラフィックをTomcatサーバー（ポート8080）へ転送するディレクティブを記述します。

```apache
<virtualhost *:80="">
    ProxyPreserveHost On
    ProxyPass / http://10.101.0.28:8080/
    ProxyPassReverse / http://10.101.0.28:8080/
</virtualhost>
```

### SELinuxセキュリティポリシーの調整

Rocky Linuxのデフォルトのセキュリティポリシーでは、Apacheプロセスによる外部ネットワーク接続が制限されています。リバースプロキシとして機能させるには、以下のブール値を変更する必要があります。

```bash
setsebool -P httpd_can_network_connect 1
```

<b>-P</b>フラグを付与することで、OSの再起動後もこの設定が永続化されます。設定反映後、systemctl restart httpdを実行して接続を確認します。

## Nginx Proxy Manager (NPM) への移行プロセス

運用管理の柔軟性を高めるため、Dockerコンテナ上で動作するNginx Proxy Managerへ環境を移行します。

### 既存サービスの停止とポートの解放

NPMは標準でポート80および443を使用するため、既存のApacheサービスと競合します。移行前にApacheを停止し、自動起動を無効化します。⚠️ 既存サービスの停止を忘れると、コンテナのバインドエラーが発生します。

```bash
systemctl stop httpd
systemctl disable httpd
```

### NPMコンテナのデプロイ

Docker Composeを使用してNPM環境を立ち上げます。作業ディレクトリに移動し、デタッチモードでコンテナを起動します。

```bash
cd ~/npm
docker compose up -d
```

### 管理インターフェースでのプロキシ設定

NPMの管理コンソール（デフォルトポート: 81）にアクセスし、新しいProxy Hostを登録します。設定値は以下の通りです。

*   <b>Domain Names</b>: 公開IPアドレスまたはドメイン名
*   <b>Scheme</b>: http
*   <b>Forward Hostname / IP</b>: 10.101.0.28 (バックエンドTomcatの内部IP)
*   <b>Forward Port</b>: 8080
*   <b>Security</b>: 「Block Common Exploits」を有効化し、SQLインジェクションやXSSなどの一般的な攻撃に対するフィルタリングを適用します。

## Findings

Apache <b>mod_proxy</b>からNginx Proxy Managerへの移行により、設定ファイルベースの管理からGUIによる直感的なホスト管理へと転換されました。特に、SELinuxのコンテキスト調整が必要な従来の構成と比較して、コンテナ化されたNPMはホストOSの依存関係を最小限に抑えつつ、セキュリティフィルタリング機能を容易に適用できる利点があります。🛠️ 移行の際は、ポート80/443の占有状況を事前に確認し、既存サービスを完全に停止させることが不可欠です。