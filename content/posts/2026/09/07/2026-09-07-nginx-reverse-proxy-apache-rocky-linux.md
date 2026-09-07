---
title: "Rocky Linux 9におけるNginxリバースプロキシ構成とApacheポート移行手順"
slug: "nginx-reverse-proxy-apache-rocky-linux"
date: 2026-09-07T10:03:58+09:00
draft: false
image: ""
description: "Rocky Linux 9環境でNginxをリバースプロキシとして導入し、既存Apacheのポート80競合解消からSELinuxネットワークリレー設定、502エラー対策までを整理します。"
categories: ["Linux System Admin"]
tags: ["nginx", "httpd", "rocky-linux-9", "reverse-proxy", "selinux"]
author: "K-Life Hack"
---

Webシステムのトラフィック増大に伴い、従来のプロセス／スレッド駆動型Webサーバー（Apache HTTP Server等）では、クライアント接続数の増加に比例してメモリ消費およびコンテキストスイッチのオーバーヘッドが顕在化します。これに対し、非同期イベント駆動アーキテクチャを採用したNginxをネットワークエッジに配置し、リバースプロキシとしてリクエストを受け付ける構成は、接続管理の集約とバックエンド保護における有効なアプローチとなります。

本稿では、Rocky Linux 9環境を対象に、既存のApache HTTP Server（httpd）をバックエンド（ポート8080）へ移行し、フロントエンドにNginx（ポート80）をリバースプロキシとして導入・連携するアーキテクチャの構築手順および運用時の注意点を整理します。

```
                  +----------------------------------------------+
                  |               Rocky Linux 9                  |
                  |                                              |
[ Client ] ------&gt;| [ Port 80: Nginx ]                           |
 (Browser)   HTTP |        |                                     |
                  |        | proxy_pass (Internal Forwarding)    |
                  |        v                                     |
                  | [ Port 8080: Apache HTTP Server ]            |
                  |        |                                     |
                  |        +--&gt; VirtualHost: site-a.com          |
                  +----------------------------------------------+
```

---

## 1. Apache ポート移行（TCP 80 -&gt; 8080）

デフォルト状態でNginxとApacheを同一OSインスタンス上で稼働させる場合、標準HTTPポート（TCP 80）のバインド競合（`EADDRINUSE: Address already in use`）が発生します。外部トラフィックをNginxで終端するため、Apache側のリッスンポートを8080へ変更します。

### 1.1 グローバルリッスン設定の変更

Apacheのメイン設定ファイル `/etc/httpd/conf/httpd.conf` を編集します。

```apache
# /etc/httpd/conf/httpd.conf

# 変更前: Listen 80
Listen 8080
```

### 1.2 バーチャルホスト設定の同期

既存のVirtualHost定義（例: `/etc/httpd/conf.d/site-a.conf`）もポート8080を明示的に指定するように更新します。

```apache
# /etc/httpd/conf.d/site-a.conf
<virtualhost *:8080="">
    ServerName site-a.com
    ServerAlias www.site-a.com
    DocumentRoot /var/www/site-a

    <directory site-a="" var="" www="">
        AllowOverride All
        Require all granted
    </directory>

    ErrorLog logs/site-a_error.log
    CustomLog logs/site-a_access.log combined
</virtualhost>
```

### 1.3 サービス再起動とポートバインド検証

設定反映のため `httpd` サービスを再起動し、ポート8080でリッスンしていることを確認します。

```bash
sudo systemctl restart httpd
sudo ss -tulpn | grep httpd
```

出力例:

```text
tcp   LISTEN 0      511          *:8080            *:*    users:(("httpd",pid=1234,fd=4))
```

---

## 2. Nginxのインストールとリバースプロキシ設定

### 2.1 パッケージ導入と自動起動設定
Rocky Linux 9の公式リポジトリよりNginxをインストールします。

```bash
sudo dnf install -y nginx
sudo systemctl start nginx
sudo systemctl enable nginx
```

### 2.2 リバースプロキシブロックの構築

Nginx設定ディレクトリ配下にプロキシ設定ファイル `/etc/nginx/conf.d/proxy.conf` を作成します。

```nginx
# /etc/nginx/conf.d/proxy.conf
server {
    listen 80;
    server_name site-a.com www.site-a.com;

    location / {
        proxy_pass http://127.0.0.1:8080;

        # クライアント情報の伝搬
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

各ディレクティブの役割:
* `proxy_pass http://127.0.0.1:8080;`: 受信したリクエストをローカルのApache（ポート8080）へ中継します。
* `proxy_set_header Host $host;`: クライアントが要求したオリジナルのHostヘッダーを維持し、Apache側のVirtualHost判定を正しく機能させます。
* `proxy_set_header X-Real-IP $remote_addr;`: クライアントの送信元IPアドレスをバックエンドへ明示的に伝達します。
* `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`: プロキシ経由のクライアントIPアドレスリストを追記します。
* `proxy_set_header X-Forwarded-Proto $scheme;`: 元のリクエストプロトコル（httpまたはhttps）を伝搬します。

---

## 3. SELinuxポリシー調整と設定適用

Rocky Linux 9ではSELinuxがデフォルトで有効化（Enforcing）されており、Webサーバープロセスから外部・内部ネットワークソケットへのアウトバウンド通信が制限されています。この制限を解除しない場合、NginxからApacheへの通信が遮断され `502 Bad Gateway` が発生します。

### 3.1 ネットワークリレーの永続的許可

💡 `setsebool` コマンドで `httpd_can_network_connect` を有効化します。

```bash
sudo setsebool -P httpd_can_network_connect 1
```

### 3.2 構文チェックとサービスリロード

設定ファイルの文法を確認後、サービスをリロードします。

```bash
sudo nginx -t
sudo systemctl reload nginx
```

---

## 4. 動作検証プロトコル

正常にプロキシが機能しているか、ポートバインドおよびHTTPヘッダーレスポンスを確認します。

### 4.1 ポートバインド状態の確認

```bash
sudo ss -tulpn | grep -E '80|8080'
```

出力例:

```text
tcp   LISTEN 0      511    0.0.0.0:80        0.0.0.0:*    users:(("nginx",pid=5678,fd=6))
tcp   LISTEN 0      511          *:8080            *:*    users:(("httpd",pid=1234,fd=4))
```

### 4.2 HTTPレスポンスの疎通確認

```bash
curl -I -H "Host: site-a.com" http://127.0.0.1
```

出力例:

```text
HTTP/1.1 200 OK
Server: nginx/1.20.1
Date: Mon, 07 Sep 2026 09:00:00 GMT
Content-Type: text/html; charset=UTF-8
Connection: keep-alive
```

---

## 5. Troubleshooting

### 5.1 Nginx起動失敗 (`Job for nginx.service failed`)
* ⚠️ <b>原因</b>: Apacheがポート80を占有したままNginxを起動した場合に発生。
* <b>確認・復旧手順</b>:

  ```bash
  # 80番ポートを占有しているプロセスの特定
  sudo ss -tulpn | grep :80

  # httpdの設定を確認後、再起動して80番を解放
  sudo systemctl restart httpd
  sudo systemctl start nginx
  ```

### 5.2 502 Bad Gateway エラー

* ⚠️ <b>原因1</b>: バックエンドのApacheが停止している、または指定ポート（8080）で応答していない。
* ⚠️ <b>原因2</b>: SELinuxによってNginxから内部ポートへの接続が拒否されている。
* <b>確認・復旧手順</b>:

  ```bash
  # Apacheの稼働確認
  sudo systemctl status httpd

  # SELinux Boolean状態の確認
  sudo getsebool httpd_can_network_connect
  # off の場合は以下を実行
  sudo setsebool -P httpd_can_network_connect 1

  # Nginxエラーログの詳細確認
  sudo tail -n 20 /var/log/nginx/error.log
  ```

---

## 6. Operational Notes

* 🛠️ <b>ヘッダー透過性の維持</b>: プロキシを挟む構成では、Apache側のアクセスログに記録されるIPが `127.0.0.1` に置き換わらないよう、Apache側で `remoteip_module`（`RemoteIPHeader X-Forwarded-For`）の導入を検討してください。
* 🛠️ <b>構成の拡張性</b>: Nginxをフロントエンドに集約することで、将来的なTLS終端（Let's Encrypt / Certbot連携）や静的コンテンツの直接配信、Rate Limiting設定を容易に拡張できます。