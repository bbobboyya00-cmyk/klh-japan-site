---
title: "NginxリバースプロキシによるSSLオフロードとApache mod_remoteip連携の実践"
slug: "nginx-ssl-offload-apache-mod-remoteip"
date: 2026-10-11T10:07:10+09:00
draft: false
image: ""
description: "NginxでのSSL終端とバックエンドApacheへのトラフィック転送時における、mod_remoteipを用いたクライアント実IP復元手順と設定検証ログを記録した技術ノート。"
categories: ["Linux System Admin"]
tags: ["nginx", "apache", "mod_remoteip", "ssl-offloading", "reverse-proxy"]
author: "K-Life Hack"
---

インフラストラクチャの規模が拡大する過程において、各バックエンドノードで個別にSSL/TLS証明書を管理・更新し、暗号化ハンドシェイクのCPUリソースを消費させる設計は、証明書更新の運用漏れやリソース競合を招く要因となります。こうした暗号処理のオーバーヘッドと運用コストを排除するため、エッジ層にリバースプロキシを配置してSSL終端（SSL Offloading）を集約し、バックエンドには平文HTTPで高速にルーティングするアーキテクチャが一般的に採用されます。

しかし、この構成ではプロキシサーバがバックエンドに対して新しいTCPセッションを確立するため、バックエンドのWebサーバ側（Apache）のアクセスログや内部アプリケーション層において、接続元IPアドレスがプロキシの内部IPでマスクされてしまう問題が生じます。本稿では、Rocky Linux 9上のNginxによるTLS 1.2/1.3終端と、CentOS 7上のApacheにおける<code>mod_remoteip</code>を用いたクライアントIP復元パイプラインの構築・検証手順を整理します。

## システムトポロジと設計仕様

エッジプロキシとバックエンドWebサーバは同一のプライベートセグメント（<code>192.168.20.0/24</code>）内で通信を行います。

- <b>エッジプロキシノード</b>
- OS: Rocky Linux 9
- 内部IP: `192.168.20.11`
- 役割: Port 80/443リスナー、TLS終端、HTTP/2ネゴシエーション、ヘッダー書き換え
- <b>バックエンドノード</b>
- OS: CentOS 7
- 内部IP: `192.168.20.12`
- 役割: Apache (`httpd`)、PHPランタイム、平文HTTP（Port 80）でのリクエスト処理
- <b>ドメイン解決</b>: 対象FQDN（`tech.viahost.co.kr`）はエッジプロキシのIPに紐付けられます。

## バックエンドWebサーバのベースライン構築 (CentOS 7)

バックエンドノード（<code>192.168.20.12</code>）では、外部からの直接HTTPS接続は遮断し、Nginxからの内部転送のみを受け付けます。

```bash
# パッケージ導入と動作確認用スクリプトの配置
yum install -y httpd php
echo "<?php phpinfo(); ?>" &gt; /var/www/html/phpinfo.php

# サービスの有効化と起動
systemctl enable httpd
systemctl start httpd
```

## エッジリバースプロキシおよびSSL終端設定 (Rocky Linux 9)

Rocky Linux 9ノード（<code>192.168.20.11</code>）にNginxを導入し、暗号化処理、TLSプロトコル制限、リクエストサイズ制約、バックエンドへのリバースプロキシパラメータを構成します。

```bash
dnf install -y nginx
```

VirtualHost設定ファイル（<code>/etc/nginx/conf.d/tech.viahost.co.kr.conf</code>）を作成し、以下のディレクティブを定義します。

```nginx
# HTTP リスナー - HTTPSへの正規化リダイレクト
server {
    listen 80;
    server_name tech.viahost.co.kr;
    return 301 https://$host$request_uri;
}

# HTTPS リスナー - SSL終端およびプロキシ転送
server {
    listen 443 ssl http2;
    server_name tech.viahost.co.kr;

    # SSL証明書パス
    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    # 暗号化スイート・プロトコル制限
    ssl_protocols       TLSv1.2 TLSv1.3;

    # ペイロード制限の拡張（デフォルト1MBから引き上げ、HTTP 413を防止）
    client_max_body_size 50m;

    location / {
        proxy_pass http://192.168.20.12:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

設定の構文チェックを実行後、デーモンを再読み込みします。

```bash
nginx -t
systemctl enable nginx
systemctl start nginx
```

### ディレクティブ設計の意図

- `ssl_protocols TLSv1.2 TLSv1.3;`: 既知の脆弱性を持つSSLv3、TLS 1.0、TLS 1.1を明示的に無効化し、前方秘匿性（Forward Secrecy）を維持します。
- `client_max_body_size 50m;`: ファイルアップロード時にデフォルト値（1MB）による`HTTP 413 Request Entity Too Large`が発生することを防ぐためのバッファ制限緩和です。
- `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`: クライアント本来の接続元IPアドレスをHTTPヘッダーチェーンへ追記し、ダウンストリームへ透過させます。

## mod_remoteipによる実IPアドレスの復元 (Apache)

リバースプロキシを介した通信では、Apacheのアクセスログに記録される接続元IPがプロキシサーバ（<code>192.168.20.11</code>）のアドレスになってしまいます。アクセス解析や監査ログの正確性を担保するため、Apacheの<code>mod_remoteip</code>モジュールを使用して実IPアドレスを抽出・適用します。

### 1. モジュールの読み込み確認

CentOS 7のApache 2.4系では、<code>mod_remoteip</code>が標準で同梱されています。設定ファイル内で読み込まれているか確認します。

```apache
LoadModule remoteip_module modules/mod_remoteip.so
```

### 2. httpd.confの設定変更

<code>/etc/httpd/conf/httpd.conf</code>にプロキシの信頼設定およびログフォーマットの調整を追加します。

```apache
# -------------------------------------------------------------
# Remote IP Configuration
# -------------------------------------------------------------
RemoteIPHeader X-Forwarded-For
RemoteIPInternalProxy 192.168.20.11

# -------------------------------------------------------------
# Log Format Adjustments (%h から %a への変更)
# -------------------------------------------------------------
LogFormat "%a %l %u %t \"%r\" %&gt;s %b \"%{Referer}i\" \"%{User-Agent}i\"" combined
LogFormat "%a %l %u %t \"%r\" %&gt;s %b" common
```

<code>RemoteIPInternalProxy</code>にエッジプロキシの内部IP（<code>192.168.20.11</code>）を明示的に登録することで、当該プロキシから渡された<code>X-Forwarded-For</code>のみを信頼し、外部の悪意あるヘッダー偽装（IP Spoofing）を破棄します。また、LogFormatのディレクティブを直接のTCP接続元である<code>%h</code>から、解決されたクライアントIPを示す<code>%a</code>へ変更します。

設定適用後、Apacheサービスを再起動します。

```bash
systemctl restart httpd
```

## Troubleshooting

リバースプロキシ構成の初期導入時に頻発するフリクションポイントと確認手順です。

### 1. HTTP 502 Bad Gateway が返却される

- <b>原因</b>: エッジプロキシ（Rocky 9）上のSELinuxポリシーにより、Nginxによる外部ネットワーク接続が拒否されている、またはバックエンド（`192.168.20.12:80`）でポートがリッスンされていないケースがあります。
- <b>確認手順</b>:

  ```bash
  # SELinuxによるHTTPネットワーク接続許可フラグの確認
  getsebool httpd_can_network_connect
  # 無効（off）の場合は有効化
  setsebool -P httpd_can_network_connect 1
  ```

### 2. Apache側で実IPが反映されず、プロキシIPが表示され続ける

- <b>原因</b>: `RemoteIPInternalProxy`のIP定義ミス、または中間ヘッダー名が`X-Forwarded-For`と一致していない場合があります。
- <b>確認手順</b>: PHPの環境変数出力（`phpinfo.php`）を通じて、`$_SERVER['HTTP_X_FORWARDED_FOR']`の値がバックエンドへ正確に届いているかをブラウザまたは`curl`で検証します。

## システム動作検証ログ

すべてのサービスが稼働した状態におけるプロトコル検証ログです。

### プロキシノードのリスナーおよび転送テスト

```text
[root@proxy-node ~]# ss -tulpn | grep -E ':(80|443)'
tcp   LISTEN 0      511          0.0.0.0:80        0.0.0.0:*    users:(("nginx",pid=15234,fd=6))
tcp   LISTEN 0      511          0.0.0.0:443       0.0.0.0:*    users:(("nginx",pid=15234,fd=7))

[root@proxy-node ~]# curl -I -k https://tech.viahost.co.kr/phpinfo.php
HTTP/2 200 
server: nginx/1.20.1
date: Sun, 11 Oct 2026 04:12:05 GMT
content-type: text/html; charset=UTF-8
```

### バックエンドノードのアクセスログ検証

クライアント（例: パブリックIP <code>203.0.113.45</code>）からアクセスした際の<code>/var/log/httpd/access_log</code>出力結果です。

```text
[root@backend-node ~]# tail -n 1 /var/log/httpd/access_log
203.0.113.45 - - [11/Oct/2026:13:12:05 +0900] "GET /phpinfo.php HTTP/1.0" 200 45124 "-" "curl/7.88.1"
```

接続元の実IPアドレス（<code>203.0.113.45</code>）が先頭フィールド（<code>%a</code>）に正常に記録されていることが確認できます。

## Configuration Notes

- 🛠️ <b>バックエンドクラスタへの拡張</b>: 単一ホストへの転送から冗長構成へ移行する場合、Nginx側で`upstream`ブロックを定義し、ヘルスチェックおよびバランシングアルゴリズムを設定します。

  ```nginx
  upstream backend_cluster {
      server 192.168.20.12:80 max_fails=3 fail_timeout=10s;
      # 追加のバックエンドノードを順次定義
  }
  ```

- ⚠️ <b>セキュリティレイヤの統合</b>: エッジプロキシ層にWAF（Web Application Firewall）を組み込むことで、バックエンドへの到達前に悪意のあるリクエストパラメータやインジェクション攻撃を走査・遮断する構成への発展が可能です。