---
title: "AnsibleによるNginxリバースプロキシ構築とLet's Encrypt自動化"
slug: "ansible-nginx-reverse-proxy-letsencrypt"
date: 2026-09-29T10:18:30+09:00
draft: false
image: ""
description: "Ansibleを使用してNginxリバースプロキシの構築、Let's EncryptによるSSL証明書の自動発行・更新、およびHTTPSリダイレクト設定を自動化する手順とトラブルシューティング。"
categories: ["Linux System Admin"]
tags: ["ansible", "nginx", "letsencrypt", "certbot", "reverse-proxy"]
author: "K-Life Hack"
---

インフラストラクチャのスケールアウトにおいて、手動によるVirtualHostの設定やファイアウォールルールの適用、SSL/TLS証明書の更新作業は、ノード数の増加に伴いヒューマンエラーを誘発する大きな要因となります。特にマルチテナント環境や複数のマイクロサービスを運用する場合、証明書のライフサイクル管理の遅延はサービス停止に直結する致命的なリスクです。本稿では、Ansibleを用いてNginxリバースプロキシの構築から、Let's EncryptによるHTTP-01チャレンジを用いたSSL/TLS証明書の自動発行、およびcronによる自動更新処理までを一貫して自動化する宣言的アプローチについて解説します。

## アーキテクチャ設計とアプローチ

本構成では、以下のフェーズに分けてインフラストラクチャのプロビジョニングを実行します。

1. <b>ブートストラップフェーズ</b>: NginxおよびCertbot、必要な依存パッケージのインストール。
2. <b>HTTP-01 チャレンジ用ルートの確保</b>: ポート80番で一時的なNginx設定をデプロイし、`/.well-known/acme-challenge/` へのリクエストを特定のWebrootディレクトリ（`/var/www/letsencrypt`）にマッピング。
3. <b>証明書の発行</b>: Certbotを非対話モード（Non-interactive）で実行し、Let's EncryptからX.509証明書を取得。
4. <b>TLS終端とリバースプロキシ設定</b>: ポート443番でのTLS終端（TLS v1.2 / TLS v1.3限定）を有効化し、ポート80番へのアクセスをHTTPSへ恒久的にリダイレクト（301 Moved Permanently）する設定へ移行。
5. <b>自動更新のスケジュール化</b>: 毎日指定時刻に証明書の更新チェックを行い、更新成功時にNginxをリロードするcronジョブを登録。

---

## Ansible プレイブックの実装

以下に、リバースプロキシの構築とSSL証明書のライフサイクル管理を自動化する完全なAnsibleプレイブックを示します。

### プレイブックファイル: `reverse_proxy_ssl.yml

```yaml
---
- name: Setup Nginx Reverse Proxy + Let's Encrypt SSL
  hosts: reverse_proxy
  become: yes

  vars:
    domain_name: "example.com"        # 対象となるドメイン名
    backend_server: "http://127.0.0.1:8080"   # 転送先バックエンドサーバー
    email_for_ssl: "admin@example.com" # Certbot通知用管理者メールアドレス

  tasks:
    - name: Update apt cache
      apt:
        update_cache: yes
        cache_valid_time: 3600

    # ----------------------------------------
    # 1) Nginxのインストールと起動設定
    # ----------------------------------------
    - name: Install Nginx
      apt:
        name: nginx
        state: present

    - name: Ensure nginx running
      service:
        name: nginx
        state: started
        enabled: yes

    # ----------------------------------------
    # 2) Certbotおよび依存パッケージのインストール
    # ----------------------------------------
    - name: Install Certbot and Nginx plugin
      apt:
        name:
          - certbot
          - python3-certbot-nginx
        state: present

    # ----------------------------------------
    # 3) リバースプロキシ初期設定 (Port 80)
    # ----------------------------------------
    - name: Create Nginx reverse proxy config
      copy:
        dest: /etc/nginx/sites-available/reverse_proxy.conf
        content: |
          server {
              listen 80;
              server_name {{ domain_name }};
              
              # Let's Encrypt ACME HTTP-01 チャレンジ用パス
              location /.well-known/acme-challenge/ {
                  root /var/www/letsencrypt;
              }

              location / {
                  proxy_pass {{ backend_server }};
                  proxy_set_header Host $host;
                  proxy_set_header X-Real-IP $remote_addr;
                  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                  proxy_set_header X-Forwarded-Proto $scheme;
              }
          }
      notify: Reload Nginx

    - name: Ensure webroot folder for certbot exists
      file:
        path: /var/www/letsencrypt
        state: directory
        owner: www-data
        group: www-data
        mode: '0755'

    - name: Enable reverse proxy site
      file:
        src: /etc/nginx/sites-available/reverse_proxy.conf
        dest: /etc/nginx/sites-enabled/reverse_proxy.conf
        state: link
        force: yes
      notify: Reload Nginx

    - name: Remove default nginx site
      file:
        path: /etc/nginx/sites-enabled/default
        state: absent
      notify: Reload Nginx

    # ----------------------------------------
    # 4) Let's Encrypt SSL証明書の取得 (HTTP-01)
    # ----------------------------------------
    - name: Obtain Let's Encrypt SSL certificate
      command: &gt;
        certbot certonly --webroot
        -w /var/www/letsencrypt
        -d {{ domain_name }}
        --email {{ email_for_ssl }}
        --agree-tos
        --no-eff-email
      args:
        creates: "/etc/letsencrypt/live/{{ domain_name }}/fullchain.pem"

    # ----------------------------------------
    # 5) TLS終端設定およびHTTPSリダイレクト (Port 443)
    # ----------------------------------------
    - name: Create SSL-enabled Nginx config
      copy:
        dest: /etc/nginx/sites-available/ssl_reverse_proxy.conf
        content: |
          server {
              listen 443 ssl;
              server_name {{ domain_name }};

              ssl_certificate /etc/letsencrypt/live/{{ domain_name }}/fullchain.pem;
              ssl_certificate_key /etc/letsencrypt/live/{{ domain_name }}/privkey.pem;
              ssl_protocols TLSv1.2 TLSv1.3;

              location / {
                  proxy_pass {{ backend_server }};
                  proxy_set_header Host $host;
                  proxy_set_header X-Real-IP $remote_addr;
                  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                  proxy_set_header X-Forwarded-Proto https;
              }
          }

          # HTTPからHTTPSへの301リダイレクト
          server {
              listen 80;
              server_name {{ domain_name }};
              return 301 https://$host$request_uri;
          }
      notify: Reload Nginx

    - name: Enable SSL reverse proxy config
      file:
        src: /etc/nginx/sites-available/ssl_reverse_proxy.conf
        dest: /etc/nginx/sites-enabled/ssl_reverse_proxy.conf
        state: link
        force: yes
      notify: Reload Nginx

    # ----------------------------------------
    # 6) Certbot自動更新のスケジュール設定
    # ----------------------------------------
    - name: Ensure certbot renew cron job exists
      cron:
        name: "Certbot auto renew"
        job: "certbot renew --quiet --deploy-hook 'systemctl reload nginx'"
        minute: "0"
        hour: "3"

  handlers:
    - name: Reload Nginx
      service:
        name: nginx
        state: restarted
```

### インベントリファイル: `inventory.ini

```ini
[reverse_proxy]
203.0.113.50 ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/id_ansible
```

---

## 実行手順

対象ノードに対してプレイブックを実行するには、以下のコマンドを使用します。

```bash
ansible-playbook reverse_proxy_ssl.yml -i inventory.ini
```

このコマンドを実行すると、システムパッケージの更新からNginxのセットアップ、一時的なHTTP-01チャレンジ用ルーティングを介した証明書取得、そして最終的なTLS終端設定の適用までが自動的に進行します。

---

## Troubleshooting

本構成を本番環境にデプロイする際、ネットワークや権限の不整合により発生しやすい代表的なエラーと、その解決ワークフローを以下に示します。

### 🛠️ 1. HTTP-01 チャレンジの検証失敗 (Unauthorized / Connection Refused)

* <b>原因</b>: Let's EncryptのACME検証サーバーが、対象ドメインのポート80番にアクセスできない場合に発生します。DNSレコード（Aレコード）の反映遅延、またはセキュリティグループやファイアウォール（ufw、iptables）でポート80番が閉じていることが主な原因です。
* <b>対策</b>: 
1. 外部から対象ドメインへの名前解決が正しく行われているか確認します。
2. ファイアウォール設定を確認し、ポート80および443へのインバウンドトラフィックを許可します。

### 🛠️ 2. Nginxのデフォルト設定との競合

* <b>原因</b>: Ubuntuなどのディストリビューションでは、Nginxインストール時に `/etc/nginx/sites-enabled/default` が自動的に有効化されます。これが残っていると、ポート80番へのリクエストがデフォルトのサーバーブロックに奪われ、ACMEチャレンジ用のパス（`/.well-known/acme-challenge/`）に到達しないことがあります。
* <b>対策</b>: プレイブック内の `Remove default nginx site` タスクが正常に実行され、シンボリックリンクが削除されていることを確認してください。

### 🛠️ 3. Webrootディレクトリの権限不足

* <b>原因</b>: `/var/www/letsencrypt` ディレクトリに対する書き込み権限が不足していると、Certbotが検証用ファイルを配置できずエラーになります。
* <b>対策</b>: ディレクトリの所有者が `www-data:www-data` であり、パーミッションが `0755` に設定されていることを確認します。

---

## 稼働検証とステータス確認

デプロイ完了後、対象サーバーにSSH接続し、以下のコマンドを用いてシステムの状態とトラフィックの挙動を確認します。

### Nginx サービスステータスの確認

```text
$ systemctl status nginx
● nginx.service - A high performance web server and a reverse proxy server
     Loaded: loaded (/lib/systemd/system/nginx.service; enabled; vendor preset: enabled)
     Active: active (running) since Tue 2026-09-29 10:00:00 UTC; 5min ago
   Main PID: 12345 (nginx)
      Tasks: 2 (limit: 1151)
     Memory: 8.5M
        CPU: 45ms
     CGroup: /system.slice/nginx.service
             ├─12345 nginx: master process /usr/sbin/nginx -g daemon on; master_process on;
             └─12346 nginx: worker process
```

### リッスンポートの確認

```text
$ ss -tulpn | grep -E '80|443'
tcp   LISTEN 0      511          0.0.0.0:80        0.0.0.0:*    users:(("nginx",pid=12345,fd=6))
tcp   LISTEN 0      511          0.0.0.0:443       0.0.0.0:*    users:(("nginx",pid=12345,fd=7))
```

### HTTPからHTTPSへのリダイレクト検証

```text
$ curl -I http://example.com
HTTP/1.1 301 Moved Permanently
Server: nginx
Date: Tue, 29 Sep 2026 10:05:00 GMT
Content-Type: text/html
Content-Length: 166
Connection: keep-alive
Location: https://example.com/
```

---

## Key Takeaways

* 💡 <b>冪等性の担保</b>: `creates` オプションを使用することで、すでに有効な証明書が存在する場合はCertbotの実行をスキップし、不要なAPIコールとレートリミット到達を防止します。
* 💡 <b>セキュアな通信プロトコル</b>: 脆弱性のある古いプロトコル（SSLv3、TLSv1.0、TLSv1.1）を排除し、`TLSv1.2` および `TLSv1.3` のみを有効化することで、セキュリティ基準に適合した通信経路を確立します。
* 💡 <b>運用の自動化</b>: 毎日午前3時に実行されるcronジョブにより、有効期限が30日未満になった証明書が自動的に更新され、`--deploy-hook` によってNginxが安全にリロードされます。これにより、手動介入ゼロでの継続的な運用が可能になります。