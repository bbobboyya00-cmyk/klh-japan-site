---
title: "Integration and Control Methods for Apache HTTP Server and Tomcat Using mod_proxy"
slug: "apache-tomcat-mod-proxy-integration"
date: 2026-09-23T10:20:39+09:00
draft: false
image: ""
description: "This article explains the steps to build a reverse proxy configuration that integrates Apache HTTP Server and Apache Tomcat using the mod_proxy module to separate static and dynamic processing, along with systemd management and troubleshooting."
categories: ["Linux System Admin"]
tags: ["apache-httpd", "apache-tomcat", "mod-proxy", "reverse-proxy", "systemd"]
author: "K-Life Hack"
---

In the design of multi-tier Web architectures, separating the processing of static content and dynamic application logic is a standard approach to improve overall system availability and resource efficiency. A configuration where Tomcat alone processes static files (HTML, CSS, JavaScript, images, etc.) increases JVM garbage collection (GC) overhead and unnecessarily consumes the thread pool.


This article explains the steps to build an integration infrastructure that deploys Apache HTTP Server (hereinafter referred to as Apache) as a front-end Web server and reverse proxy, and forwards dynamic requests to Apache Tomcat (hereinafter referred to as Tomcat), which is the back-end Web application server (WAS). For the integration module, we adopt <code>mod_proxy_http</code>, which has a simpler configuration and more easily maintains standard HTTP/1.1 semantics compared to the binary protocol AJP (mod_jk).



## System Topology and Verification Environment

This configuration assumes a colocation model where Apache and Tomcat coexist on the same host. When expanding to a multi-node configuration, change the proxy forwarding destination address to the IP address of the target WAS as appropriate.



* <b>OS</b>: Ubuntu 24.04 LTS
* <b>Front-end</b>: Apache HTTP Server (Port 80)
* <b>Back-end</b>: Apache Tomcat 10.1.59 (Port 8080 / localhost)

---

## Installation and Initial Configuration of Apache HTTP Server

First, install Apache, which will act as the reverse proxy, and the utility packages used for load testing and other purposes.



```bash
# Update the package index
sudo apt update

# Install Apache2 and utility tools
sudo apt install apache2 apache2-utils -y

# Enable and start the service
sudo systemctl enable --now apache2
```

After the installation is complete, verify that Apache is successfully listening on port 80 using a browser or the <code>curl</code> command.



---

## Installation and Service Configuration of Apache Tomcat

Tomcat 10 requires Java 11 or higher as its runtime environment. To ensure security, we will create a non-privileged system user dedicated to Tomcat before deploying the binaries.



### 1. Installing Java Runtime Environment (JDK)

```bash
sudo apt install openjdk-11-jdk -y
```

### 2. Creating the System User and Directory

Create a system account without shell login privileges to isolate the process execution privileges.



```bash
# Create the installation directory
sudo mkdir -p /opt/tomcat

# Create the tomcat user with a disabled login shell
sudo useradd -r -s /bin/false -d /opt/tomcat tomcat
```

### 3. Downloading Binaries and Configuring Permissions

```bash
cd /tmp
wget https://dlcdn.apache.org/tomcat/tomcat-10/v10.1.59/bin/apache-tomcat-10.1.59.tar.gz

# Extract the archive, removing the top-level directory wrapper
sudo tar xzvf apache-tomcat-10.1.59.tar.gz -C /opt/tomcat --strip-components=1

# Change ownership to the tomcat user
sudo chown -R tomcat:tomcat /opt/tomcat
sudo chmod +x /opt/tomcat/bin/*.sh
```

### 4. Defining the systemd Service Unit

To place the Tomcat lifecycle under the service management of the OS, create <code>/etc/systemd/system/tomcat.service</code>.



```ini
[Unit]
Description=Tomcat 10 servlet container
After=network.target

[Service]
Type=forking
User=tomcat
Group=tomcat
Environment="JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64"
Environment="CATALINA_HOME=/opt/tomcat"
Environment="CATALINA_BASE=/opt/tomcat"
ExecStart=/opt/tomcat/bin/startup.sh
ExecStop=/opt/tomcat/bin/shutdown.sh

[Install]
WantedBy=multi-user.target
```

Specifying <code>Type=forking</code> here is extremely critical. The Tomcat startup script (<code>startup.sh</code>) internally forks the Java process to run in the background. If <code>Type=simple</code> is specified, systemd will misinterpret the termination of the startup script as the service stopping and will force-terminate the process.



```bash
# Reload systemd configuration and start the service
sudo systemctl daemon-reload
sudo systemctl enable --now tomcat
```

---

## Creating a JSP Artifact for Verification

To verify dynamic script execution via the proxy, place a JSP file that outputs the system time in the Tomcat document root.



```bash
sudo nano /opt/tomcat/webapps/ROOT/test.jsp

```jsp

&lt;%@ page contentType="text/html; charset=UTF-8" %&gt;
&lt;%@ page import="java.util.Date" %&gt;
<html>
<head><title>Integration Test</title></head>
<body>
<h1>Apache &amp; Tomcat Integration Test</h1>
<h3>Current Time: &lt;%= new Date() %&gt;</h3>
Request URI: &lt;%= request.getRequestURI() %&gt;


</body>
</html>

```

---

## mod_proxyによる連携設定

Apacheでリバースプロキシ機能を有効化するには、<code>proxy</code>モジュールおよびHTTPプロトコルを処理する<code>proxy_http</code>モジュールを有効化する必要があります。

```bash

sudo a2enmod proxy proxy_http

```

次に、<code>/etc/apache2/sites-available/000-default.conf</code>を編集し、プロキシ転送ルールを定義します。要件に応じて以下のいずれかの戦略を選択します。

### パターンA：グローバルリバースプロキシ（全リクエストを転送）

すべてのクライアントリクエストをバックエンドのTomcatへ透過的に転送する構成です。

```apache

<virtualhost *:80="">
ProxyPreserveHost On
ProxyPass / http://localhost:8080/
ProxyPassReverse / http://localhost:8080/
</virtualhost>

```

<b>`ProxyPreserveHost On`</b>: クライアントが送信したオリジナルの`Host`ヘッダーをバックエンドのTomcatに引き渡します。これにより、Tomcat側でのバーチャルホスト判定やURL生成が正しく機能します。
* <b>`ProxyPass`</b>: 特定のパスに対するリクエストを、指定したバックエンドサーバーへマッピングします。
* <b>`ProxyPassReverse`</b>: Tomcatが返却するリダイレクト応答（`Location`ヘッダーなど）に含まれるスキーマやホスト名を、Apache側の公開アドレスに書き換えます。これにより、クライアントが直接ポート8080にリダイレクトされるのを防ぎます。

### パターンB：セレクティブルーティング（JSPのみを転送）

静的コンテンツはApacheが直接高速に処理し、<code>.jsp</code>拡張子を持つ動的リクエストのみをTomcatへルーティングする高効率な構成です。

```apache

<virtualhost *:80="">
ProxyRequests Off
ProxyPreserveHost On

<locationmatch "\.jsp$"="">
ProxyPass http://localhost:8080
ProxyPassReverse http://localhost:8080
</locationmatch>
</virtualhost>

```

<b>`ProxyRequests Off`</b>: オープンプロキシ（フォワードプロキシ）としての動作を明示的に無効化し、セキュリティ脆弱性を排除します。
* <b>`<locationmatch "\.jsp$"="">`</locationmatch></b>: 正規表現を用いて、末尾が`.jsp`で終わるURIのみをプロキシ転送の対象とします。

設定変更後、構文チェックを実行し、Apacheを再起動します。

```bash

# Syntax check of configuration files
sudo apache2ctl configtest

# Restart service
sudo systemctl restart apache2

```

---

## ライフサイクルとゼロダウンタイムへの配慮

本番環境においてTomcatのローリングアップデートやコンテナの再配置を行う際、単純にTomcatプロセスを停止すると、Apache側で一時的に<code>503 Service Unavailable</code>が発生します。これを回避するためには、以下の設計を考慮する必要があります。

1. <b>接続プーリングとタイムアウトの最適化</b>: `ProxyPass`ディレクティブに`connectiontimeout`や`timeout`パラメータを明示的に設定し、バックエンドの無応答時に迅速にフェイルオーバーさせます。
2. <b>ドレイン（Draining）状態の活用</b>: ロードバランサー配下に複数のTomcatノードを配置している場合、対象ノードへの新規セッション割り当てを停止（ドレイン）し、既存セッションが終了した段階で安全にアップデートを実施します。

---

## Troubleshooting

### 1. ポート競合によるTomcatの起動失敗
すでに他のプロセスがポート8080を占有している場合、Tomcatは起動に失敗します。この場合、<code>/opt/tomcat/conf/server.xml</code>を開き、<code><connector></connector></code>要素の<code>port</code>属性を競合しないポート（例: 8081）に変更してください。

```xml

<connector connectiontimeout="20000" port="8081" protocol="HTTP/1.1" redirectport="8443"></connector>

```

### 2. パーミッションエラーによるアクセス拒否

Tomcatの実行ユーザー（<code>tomcat</code>）に、<code>/opt/tomcat</code>配下のファイル読み込み・実行権限が正しく付与されていない場合、起動スクリプトがエラーを吐き出します。ディレクトリの所有権が<code>tomcat:tomcat</code>になっているか再確認してください。

```bash

sudo chown -R tomcat:tomcat /opt/tomcat

```

### 3. SELinux / AppArmorによる接続拒否

セキュリティモジュールが有効な環境では、Apacheからローカルポートへのアウトバウンド通信がブロックされることがあります。SELinux環境下でプロキシ通信を許可するには、以下のブール値を有効化します。

```bash

sudo setsebool -P httpd_can_network_connect 1

```

---

## 稼働状態の検証ログ

システムが正常に動作している場合の各種コマンドの出力プロトコル例を以下に示します。

### ポートバインド状況の確認 (`ss -tulpn`)

```text

Netid State  Recv-Q Send-Q  Local Address:Port  Peer Address:Port Process
tcp   LISTEN 0      511           0.0.0.0:80         0.0.0.0:*     users:(("apache2",pid=1024,fd=4))
tcp   LISTEN 0      100         127.0.0.1:8005       0.0.0.0:*     users:(("java",pid=2048,fd=15))
tcp   LISTEN 0      100                 *:8080             *:*     users:(("java",pid=2048,fd=12))

```

### Tomcatサービスステータスの確認 (`systemctl status tomcat`)

```text

● tomcat.service - Tomcat 10 servlet container
Loaded: loaded (/etc/systemd/system/tomcat.service; enabled; preset: enabled)
Active: active (running) since Wed 2026-09-23 10:00:00 UTC; 5m ago
Process: 2040 ExecStart=/opt/tomcat/bin/startup.sh (code=exited, status=0/SUCCESS)
Main PID: 2048 (java)
Tasks: 32 (limit: 4615)
Memory: 142.5M
CPU: 1.82s
CGroup: /system.slice/tomcat.service
└─2048 /usr/lib/jvm/java-11-openjdk-amd64/bin/java -Djava.util.logging.config.file=/opt/tomcat/conf/logging.properties ...

```

### HTTPレスポンスヘッダーの検証 (`curl -I`)

```text

HTTP/1.1 200 OK
Date: Wed, 23 Sep 2026 10:05:00 GMT
Server: Apache/2.4.58 (Ubuntu)
Content-Type: text/html;charset=UTF-8
Content-Length: 245
Connection: keep-alive

```

⚠️ <b>注意</b>: <code>Server</code>ヘッダーに<code>Apache</code>が表示されつつ、<code>Content-Type</code>にTomcat側で処理された<code>charset=UTF-8</code>が返却されていることから、プロキシ連携が正常に機能していることが実証されます。

---

## Operational Notes

* <b>本番環境におけるテストファイルの削除</b>: 本番環境へのデプロイ前に、システム情報やパス構造を露呈させるリスクのある`test.jsp`などの検証用スクリプトは必ず削除してください。
* <b>タイムアウト値のチューニング</b>: クライアントとApache間、およびApacheとTomcat間のタイムアウト値（`KeepAliveTimeout`, `ProxyTimeout`）を整合させることで、不要なゾンビコネクションの滞留を防ぎ、リソースの枯渇を防止できます。