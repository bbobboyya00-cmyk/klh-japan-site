---
title: "DjangoアプリケーションにおけるNginx・Gunicorn連携時の502 Bad Gatewayおよび権限境界の解決手法"
slug: "nginx-gunicorn-django-troubleshooting"
date: 2026-07-07T10:33:05+09:00
draft: false
image: ""
description: "EC2上のDjangoデプロイにおけるNginxとGunicornのソケット通信エラー（502 Bad Gateway、403 Forbidden）の原因と、権限設定、systemd、Docker環境での解決策を解説します。"
categories: ["Linux System Admin"]
tags: ["nginx", "gunicorn", "django", "502-bad-gateway", "systemd"]
author: "K-Life Hack"
---

# Django本番環境における3層デプロイ構成とトラブルシューティング

インフラストラクチャのスケールアップや本番環境への移行において、Djangoの開発用サーバー（runserver）をそのままインターネットに公開することは、セキュリティおよび並行処理性能の観点から推奨されません。本番環境では、リバースプロキシ（Nginx）、WSGIアプリケーションサーバー（Gunicorn）、そしてアプリケーションロジック（Django）の3層構造を構築することが一般的です。しかし、この構成ではコンポーネント間の通信経路が増えるため、ソケットの権限設定ミスやプロセスの異常終了に伴う「502 Bad Gateway」や「403 Forbidden」といったエラーが頻発します。本稿では、これらのエラーを未然に防ぎ、発生時に迅速に特定・解決するためのシステム設計とトラブルシューティングの手順を解説します。

## 3層デプロイアーキテクチャの基本設計

本番環境におけるトラフィック制御および静的ファイルの効率的な配信を実現するため、以下の役割分担でスタックを構成します。

1. <b>Nginx (ポート 80/443)</b>: クライアントからのリクエストを最初に受け取るリバースプロキシとして動作します。静的ファイル（CSS/JS/メディアファイル）の配信を直接行い、動的リクエストのみを後続のGunicornに転送します。
2. <b>Gunicorn (WSGIサーバー)</b>: Unixドメインソケットを介してNginxと通信し、Pythonプロセスを実行します。systemdによってデーモンとして管理され、プロセスの永続性を担保します。
3. <b>Django</b>: ビジネスロジックを処理し、データベース（AWS RDSなど）と連携します。

### Gunicornのsystemdサービス定義

Gunicornプロセスを安定して稼働させるため、`/etc/systemd/system/gunicorn.service` を以下のように定義します。ソケットファイルの作成場所と所有権の設計が、後述する権限エラーを防ぐ鍵となります。

```ini
[Unit]
Description=gunicorn daemon
After=network.target

[Service]
User=ubuntu
Group=www-data
WorkingDirectory=/home/ubuntu/myproject
ExecStart=/home/ubuntu/myproject/venv/bin/gunicorn \
    --access-logfile - \
    --workers 3 \
    --bind unix:/run/gunicorn.sock \
    myproject.wsgi:application

[Install]
WantedBy=multi-user.target
```

### Nginxのバーチャルホスト設定

Nginxから上記で作成されるUnixドメインソケット `/run/gunicorn.sock` へリクエストをプロキシするように、`/etc/nginx/sites-available/django` を設定します。

```nginx
server {
    listen 80;
    server_name _;

    location = /favicon.ico { access_log off; log_not_found off; }

    location /static/ {
        alias /home/ubuntu/myproject/static/;
    }

    location / {
        include proxy_params;
        proxy_pass http://unix:/run/gunicorn.sock;
    }
}
```

---

## Troubleshooting

本番運用時に発生する代表的なエラーパターンと、その解決ワークフローを以下に示します。

### 1. 502 Bad Gateway

NginxがGunicornのソケットファイルに接続できない、またはソケットファイル自体が存在しない場合に発生します。

💡 <b>原因A</b>: Gunicornサービスが起動していない。`systemctl status gunicorn` でステータスを確認し、停止している場合は `systemctl start gunicorn` で起動します。エラーログは `journalctl -u gunicorn` で確認します。
💡 <b>原因B</b>: ソケットファイルのパス不一致。Nginxの `proxy_pass` に指定したパスと、Gunicornの `--bind` に指定したパスが完全に一致しているか確認します。

### 2. 403 Forbidden

Nginxの実行ユーザー（通常は `www-data`）が、ソケットファイルや静的ファイルディレクトリへのアクセス権限を持っていない場合に発生します。

⚠️ <b>原因A</b>: `/home/ubuntu` ディレクトリの権限制限。Ubuntuのデフォルト設定では、`/home/ubuntu` の権限が `700`（所有者のみ読み書き実行可能）になっていることがあります。この場合、Nginxは配下のソケットや静的ファイルにアクセスできません。ディレクトリの権限を `755` に変更するか、ソケットファイルの作成場所を `/run/` などの共有ディレクトリに変更します。

        ```bash
        chmod 755 /home/ubuntu
        ```

⚠️ <b>原因B</b>: 静的ファイルディレクトリの所有権不整合。静的ファイルディレクトリの所有者をNginxが読み込めるように変更します。

        ```bash
        sudo chown -R www-data:www-data /home/ubuntu/myproject/static/
        ```

### 3. Port Conflict (Address already in use)

Dockerコンテナの起動時や、手動でDjangoのテストサーバーを起動しようとした際、ポートがすでに使用されている場合に発生します。

        ```bash
        sudo lsof -i :8000

        ```bash
kill -15 <pid>

        ```bash
        kill -9 <pid>
        ```

---

## Docker環境におけるDjangoネットワーク設計

コンテナ化された環境でDjangoを稼働させる場合、ネットワークのバインド設定に注意が必要です。コンテナ内部の `localhost` (127.0.0.1) にDjangoをバインドすると、ホストマシンや他のコンテナ（Nginxなど）からのポートマッピング経由のアクセスを受け付けることができません。コンテナ外部からのトラフィックを受信するためには、すべてのネットワークインターフェースを指す `0.0.0.0` にバインドする必要があります。

```bash
# 非推奨（コンテナ外からアクセス不可）
python manage.py runserver 127.0.0.1:8000

# 推奨（コンテナ外からのアクセスを許可）
python manage.py runserver 0.0.0.0:8000
```

また、コンテナの使い捨て（Ephemeral）の特性に対応するため、静的ファイルやメディアファイル、データベースのデータはホストマシンのディレクトリと同期（ボリュームマウント）させる設計が必要です。

```bash
docker run -d \
  -p 8000:8000 \
  -v /home/ubuntu/myproject/media:/app/media \
  --name django-app my-django-image
```

---

## Verification Logs

システム構築後、各コンポーネントが正常に稼働しているかを確認するための検証コマンドと、期待される出力ログの例です。

### Gunicornの稼働状態確認

```text
$ systemctl status gunicorn
● gunicorn.service - gunicorn daemon
     Loaded: loaded (/etc/systemd/system/gunicorn.service; enabled; vendor preset: enabled)
     Active: active (running) since Tue 2026-07-07 10:00:00 UTC; 5min ago
   Main PID: 12345 (gunicorn)
      Tasks: 4 (limit: 1143)
     Memory: 48.2M
        CPU: 120ms
     CGroup: /system.slice/gunicorn.service
             ├─12345 /home/ubuntu/myproject/venv/bin/python3 /home/ubuntu/myproject/venv/bin/gunicorn --access-logfile - --workers 3 --bind unix:/run/gunicorn.sock myproject.wsgi:application
             ├─12346 /home/ubuntu/myproject/venv/bin/python3 /home/ubuntu/myproject/venv/bin/gunicorn --access-logfile - --workers 3 --bind unix:/run/gunicorn.sock myproject.wsgi:application
             └─12347 /home/ubuntu/myproject/venv/bin/python3 /home/ubuntu/myproject/venv/bin/gunicorn --access-logfile - --workers 3 --bind unix:/run/gunicorn.sock myproject.wsgi:application
```

### ソケットファイルの存在と権限の確認

```text
$ ls -la /run/gunicorn.sock
srwxrwxrwx 1 ubuntu www-data 0 Jul  7 10:00 /run/gunicorn.sock
```

### Nginx経由のHTTPレスポンス検証

```text
$ curl -I http://localhost
HTTP/1.1 200 OK
Server: nginx/1.18.0 (Ubuntu)
Date: Tue, 07 Jul 2026 10:05:00 GMT
Content-Type: text/html; charset=utf-8
Connection: keep-alive
X-Frame-Options: DENY
X-Content-Type-Options: nosniff
Referrer-Policy: same-origin
```

---

## Operational Notes

本番環境の運用においては、以下のチェックリストを定期的に確認し、構成の整合性を維持してください。

🛠️ <b>セキュリティグループの最小特権原則</b>: SSH（ポート22）および開発用ポート（8000）は、特定の管理元IPアドレスのみに制限し、`0.0.0.0/0`への開放は避けてください。IPアドレスが変更された場合は、セキュリティグループのインバウンドルールを即座に更新します。
🛠️ <b>環境変数の分離</b>: データベース接続情報やDjangoの `SECRET_KEY` などの機密情報は、コードベースにハードコーディングせず、`.env` ファイルやAWS Systems Manager Parameter Store等を利用して注入し、バージョン管理システム（Git）の追跡対象から除外します。
🛠️ <b>静的ファイルの集約</b>: アプリケーションのアップデート時には、必ず `python manage.py collectstatic` を実行し、Nginxが参照する静的ファイルディレクトリを最新の状態に更新してください。</pid></pid>