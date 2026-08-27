---
title: "Nginxリバースプロキシ配下におけるHostヘッダー転送とコンテキスト保持の構成検証"
slug: "nginx-proxy-pass-host-header-preservation"
date: 2026-08-27T10:10:06+09:00
draft: false
image: ""
description: "Nginxのproxy_pass使用時にバックエンドWASへ元のHostヘッダーおよびクライアントメタデータを正確に伝達するための設定と問題解決アプローチを解説します。"
categories: ["Linux System Admin"]
tags: ["nginx", "proxy-pass", "proxy-set-header", "http-host-header", "reverse-proxy"]
author: "K-Life Hack"
---

## 1. 建築背景と課題提起

階層型ウェブアプリケーション構造において、NginxはエッジリバースプロキシおよびWebサーバー（WS）として配置され、後続のWebアプリケーションサーバー（WAS：Spring Boot、Tomcatなど）へのトラフィックを中継する役割を担います。

ドメイン `abc.co.kr` に対する外部クライアントからのリクエストは、Nginxを経由して `proxy_pass` ディレクティブにより内部ネットワーク（例: `localhost:8080`）のWASへと転送されます。

```
[ Client Request: http://abc.co.kr ]
                 │
                 ▼
      [ Nginx Reverse Proxy ]
   (Listens on Port 80 / Domain: abc.co.kr)
                 │  proxy_pass http://localhost:8080
                 ▼
         [ Downstream WAS ]
      (e.g., Spring Boot / Tomcat on :8080)
```

この構成において、標準設定のまま `proxy_pass` を使用した場合、WAS層で `request.getRequestURL()` や `HttpServletRequest` のコンテキストを参照すると、クライアントがアクセスしたオリジナルのドメイン（`abc.co.kr`）ではなく、内部ループバックアドレス（`localhost:8080` または `127.0.0.1`）として識別される問題が発生します。

本ドキュメントでは、NginxのHTTPプロキシモジュール（`ngx_http_proxy_module`）におけるヘッダー再構築メカニズムを解析し、オリジナルのリクエストコンテキストを完全に保持・伝送するための設定手順と検証手順を整理します。

## 2. 根本原因の解析 (Root Cause Analysis)

Nginxの `ngx_http_proxy_module` は、バックエンドサーバーへリクエストを転送する際、デフォルトでHTTPリクエストヘッダーの再構築を行います。

1. <b>Hostヘッダーの書き換え</b>: Nginxは `proxy_pass` で指定されたターゲットホスト名（例: `localhost:8080`）を、アップストリームへの `Host` ヘッダー値として自動的にセットします。

2. <b>クライアントメタデータの欠落</b>: `proxy_set_header` を明示的に設定しない限り、接続元クライアントのIPアドレス（`X-Real-IP`）、プロキシ経由チェーン（`X-Forwarded-For`）、および通信プロトコル（`X-Forwarded-Proto`）の情報は破棄または集約されません。

結果として、WAS側は受信した接続をプロキシ経由ではなく、ローカル環境から直接発生したリクエストとして処理するため、絶対URLの生成やSSLオフロード時のリダイレクト制御で不整合が生じます。

## 3. 設定の修正手順

仮想ホスト設定ファイル（`/etc/nginx/nginx.conf` または `/etc/nginx/conf.d/*.conf`）の `location` ブロックを修正します。

### 3.1 従来のデフォルト設定 (AS-IS)

ヘッダー転送ディレクティブが存在しない場合、WASは `Host: localhost:8080` を受信します。

```nginx
server {
    listen 80;
    server_name abc.co.kr;

    location / {
        proxy_pass http://localhost:8080;
    }
}
```

### 3.2 修正後の設定 (TO-BE)

クライアントのコンテキスト変数をプロキシリクエストヘッダーへ明示的にマッピングします。

```nginx
server {
    listen 80;
    server_name abc.co.kr;

    location / {
        proxy_pass http://localhost:8080;

        # オリジナルのHostヘッダーを保持
        proxy_set_header Host $host;

        # クライアントの実際のIPアドレスを転送
        proxy_set_header X-Real-IP $remote_addr;

        # プロキシチェーンを経由したIPアドレスリストを保持
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        # 元のリクエストプロトコル (http または https) を転送
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

## 4. 各ディレクティブの機能明細

| ディレクティブ | 使用変数 | 技術的役割および機能概要 |
| :--- | :--- | :--- |
| `proxy_set_header Host` | `$host` | クライアントが要求したオリジナルのホスト名を保持します。`$host` にはリクエストラインのホスト名、または `Host` ヘッダーフィールドのホスト名が含まれます。 |
| `proxy_set_header X-Real-IP` | `$remote_addr` | Nginxに直接接続したクライアントの物理IPアドレスを渡します。 |
| `proxy_set_header X-Forwarded-For` | `$proxy_add_x_forwarded_for` | 既存の `X-Forwarded-For` ヘッダー値の末尾にクライアントの `$remote_addr` を追加し、多段プロキシ環境におけるトレーサビリティを確保します。 |
| `proxy_set_header X-Forwarded-Proto` | `$scheme` | クライアントとNginx間の転送プロトコル（`http` または `https`）を渡します。WAS側でのリダイレクトループ防止やSecure Cookie発行時に不可欠です。 |

## 5. Apache HTTP Serverにおける同等設定

Nginxに限らず、Apache HTTP Server（`httpd`）を `mod_proxy` 経由でリバースプロキシとして運用する場合も同様の動作が発生します。

Apacheではデフォルトで `Host` ヘッダーがバックエンドのアドレスに書き換えられるため、以下の通り `ProxyPreserveHost On` ディレクティブを仮想ホスト内に明記する必要があります。

```apache
<virtualhost *:80="">
    ServerName abc.co.kr

    ProxyPreserveHost On
    ProxyPass / http://localhost:8080/
    ProxyPassReverse / http://localhost:8080/
</virtualhost>
```

## 6. トラブルシューティングおよび動作検証

設定適用時の代表的なトラブルシューティング手順と、検証ログの例を示します。

### ⚠️ 摩擦点 (Friction Points)

- <b>無限リダイレクトループ</b>: SSLオフロード（NginxでHTTPSを受け、WASへHTTPで転送）を行う際、`X-Forwarded-Proto` が欠落していると、WASがHTTPSへの再リダイレクト（301/302）を応答し続け、リダイレクトループが発生します。

- <b>マルチプロキシ時のIP偽装</b>: 上流にロードバランサーが存在する場合、`$remote_addr` のみを参照するとロードバランサーのプライベートIPが記録されるため、`set_real_ip_from` および `real_ip_header` の適切な組み合わせ検討が必要です。

### 🛠️ 動作検証ログ

Nginx設定構文チェックおよびリクエストヘッダー透過の検証コマンド実行ログです。

```text
# nginx -t
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful

# systemctl reload nginx

# curl -Iv -H "Host: abc.co.kr" http://127.0.0.1/
*   Trying 127.0.0.1:80...
* Connected to 127.0.0.1 (127.0.0.1) port 80 (#0)
&gt; GET / HTTP/1.1
&gt; Host: abc.co.kr
&gt; User-Agent: curl/7.81.0
&gt; Accept: */*
&gt; 
&lt; HTTP/1.1 200 OK
&lt; Server: nginx/1.24.0
&lt; Date: Thu, 27 Aug 2026 09:15:00 GMT
&lt; Content-Type: text/html;charset=UTF-8
&lt; Connection: keep-alive
&lt;
```

WAS側ログにおけるヘッダー認識確認:

```text
2026-08-27 09:15:00.102 [http-nio-8080-exec-1] DEBUG o.s.web.servlet.DispatcherServlet - GET "/", parameters={}
[Header Trace]
Host: abc.co.kr
X-Real-IP: 203.0.113.195
X-Forwarded-For: 203.0.113.195
X-Forwarded-Proto: http
Request URL Resolved: http://abc.co.kr/
```

## 7. Lessons Learned

1. `proxy_pass` 使用時は、単にパスを転送するだけでなく、アップストリームに必要なコンテキストヘッダー（`Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`）を明示的にセットすることが運用上の標準ルールとなります。

2. バックエンドフレームワーク（Spring Boot等）側で `ForwardedHeaderFilter` や `server.forward-headers-strategy` を適切に有効化し、プロキシヘッダーを信頼する設定と対で運用する必要があります。