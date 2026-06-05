---
title: "Exposing Local Services Behind NAT and Implementing STCP Secure Tunneling Using FRP"
slug: "frp-reverse-proxy-stcp-setup"
date: 2026-06-05T14:14:35+09:00
draft: false
image: ""
description: "This article explains how to deploy FRP (Fast Reverse Proxy) to safely expose local services behind NAT or firewalls, daemonize it using systemd, and configure secure connections using STCP."
categories: ["Linux System Admin"]
tags: ["frp", "reverse-proxy", "stcp", "systemd", "network-security"]
author: "K-Life Hack"
---

### 1. Introduction

During software development and testing phases, it often becomes necessary to make local server services operating under private IP addresses accessible from external networks. To address this challenge, <b>FRP (Fast Reverse Proxy)</b> provides an easy-to-configure, high-performance reverse proxy solution.


FRP features a built-in web-based dashboard for real-time monitoring of active tunnel connections, traffic statistics, and system health. Configuration details and system architecture for FRP deployment:



---

### 2. FRP Overview

#### 2.1 Definition
FRP is a reverse proxy application designed to securely expose local servers behind NAT (Network Address Translation) or restrictive firewalls to the public internet. It acts as a relay for external user access to local services on machines that do not have a public static IP address.



#### 2.2 Core Components

FRP client-server architecture binaries:



* <b>`frps` (FRP Server):</b> Runs on a cloud server or similar host with a public IP address. It functions as a listener waiting for connection requests from clients and external users.
* <b>`frpc` (FRP Client):</b> Runs on the local server within the private network where the actual target services (SSH, web server, database, etc.) are running. It establishes an outbound connection to `frps` to build a secure tunnel.

```text
+------------------+                  +------------------+                  +------------------+
|  Local Server    |                  |  Public Server   |                  |   External User  |
|  (FRP Client)    | --[Outbound]--&gt;  |  (FRP Server)    | &lt;---[Inbound]--- |   (SSH/Browser)  |
|  [frpc]          |                  |  [frps]          |                  |                  |
+------------------+                  +------------------+                  +------------------+
```

#### 2.3 Operating Principle and Workflow

Traffic routing steps via FRP:



1. <b>Connection Establishment:</b> `frpc` within the private network initiates an outbound connection to `frps` on the public cloud. Because it is an outbound connection, it can bypass most inbound firewall rules and NAT restrictions.
2. <b>Port Binding:</b> Upon receiving the connection, `frps` binds the specified port (e.g., port `3500`) and prepares to forward inbound traffic to that port to `frpc` via the active tunnel.
3. <b>Data Transfer:</b> When an external user attempts to connect to `CLOUD_PUBLIC_IP:3500` on the public server, `frps` intercepts the traffic and forwards it to `frpc` through the established tunnel.
4. <b>Response Return:</b> `frpc` receives the forwarded data and passes it to the local service (such as an SSH daemon on port `22`). It collects the response from the service, sends it back to `frps` through the tunnel, and it is ultimately delivered to the external user.

#### 2.4 Key Features

* <b>Multi-protocol Support:</b> Supports TCP, UDP, HTTP, HTTPS, and domain-based virtual host routing.
* <b>P2P Connection (`xtcp`):</b> Supports a peer-to-peer communication mode directly between clients without going through a relay server after the initial handshake, saving bandwidth.
* <b>Security Features:</b> Supports in-tunnel encryption, data compression, and token-based authentication.
* <b>Management Dashboard:</b> Provides a Web UI to visualize tunnel status and bandwidth usage.

---

### 3. Installation

Obtain the release package corresponding to the target system's architecture from the official repository.



* <b>Reference Source:</b> [FRP GitHub Releases](https://github.com/fatedier/frp/releases)
* <b>Verified Version:</b> `0.67.0` (Assuming a Linux 64-bit environment)

Binary extraction commands for server and client:



```bash
# FRPパッケージのダウンロードと展開
wget https://github.com/fatedier/frp/releases/download/v0.67.0/frp_0.67.0_linux_amd64.tar.gz
tar -zxvf frp_0.67.0_linux_amd64.tar.gz
cd frp_0.67.0_linux_amd64
```

---

### 4. Server-Side Configuration

💡 <b>Target Host:</b> Cloud server with a public IP address



#### 4.1 Editing the Configuration File (`frps.toml`)

Server configuration using TOML format (v0.52.0 and later):



```bash
# 設定ファイルの配置ディレクトリ作成と編集
mkdir -p /etc/frp
cp frps.toml /etc/frp/frps.toml
vi /etc/frp/frps.toml
```

Configuration parameters for the server:



```toml
# frps.toml
bindPort = 7000
auth.token = "your_secure_token"

# 管理ダッシュボードの設定
webServer.addr = "0.0.0.0"
webServer.port = 7500
webServer.user = "admin"
webServer.password = "admin_password"
```

#### 4.2 Firewall Configuration

In your cloud provider's security groups and local firewall (`ufw` or `firewalld`), allow inbound traffic to the following ports:



* <b>Port `7000`:</b> Required for the control connection between `frpc` and `frps`.
* <b>Port `7500`:</b> Required to access the management dashboard.
* <b>Service Ports:</b> Any ports requested by `frpc` for public exposure (e.g., `6000`, `6500`, etc.).

#### 4.3 Background Execution Configuration with `systemd`

Register as a `systemd` service to enable automatic recovery upon server reboot or abnormal process termination.



```bash
# systemdサービスファイルの作成
sudo vi /etc/systemd/system/frps.service
```

Service definition for systemd:



```ini
[Unit]
Description=FRP Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c /etc/frp/frps.toml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Enable and start the service.



```bash
# バイナリのシステムパスへの配置
sudo cp frps /usr/local/bin/

# サービスの有効化および起動
sudo systemctl daemon-reload
sudo systemctl enable frps
sudo systemctl start frps
sudo systemctl status frps
```

#### 4.4 Verifying the Dashboard

Dashboard access and credential verification:



* <b>URL:</b> `http://CLOUD_PUBLIC_IP:7500`
* <b>Username:</b> `admin`
* <b>Password:</b> `admin_password`

---

### 5. Client-Side Configuration

💡 <b>Target Host:</b> Local server with a private IP address



#### 5.1 Editing the Configuration File (`frpc.toml`)

Client configuration for destination server and local services:



```bash
# 設定ファイルの配置ディレクトリ作成と編集
mkdir -p /etc/frp
cp frpc.toml /etc/frp/frpc.toml
vi /etc/frp/frpc.toml
```

Client configuration parameters:



```toml
# frpc.toml
serverAddr = "CLOUD_PUBLIC_IP"
serverPort = 7000
auth.token = "your_secure_token"

[[proxies]]
name = "ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = 6000
```

#### 5.2 Background Execution Configuration with `systemd`

Systemd service construction for the client:



```bash
# systemdサービスファイルの作成
sudo vi /etc/systemd/system/frpc.service
```

```ini
[Unit]
Description=FRP Client
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frpc -c /etc/frp/frpc.toml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Enable and start the client service.



```bash
# バイナリのシステムパスへの配置
sudo cp frpc /usr/local/bin/

# サービスの有効化および起動
sudo systemctl daemon-reload
sudo systemctl enable frpc
sudo systemctl start frpc
sudo systemctl status frpc
```

---

### 6. Advanced Configuration and Security

#### 6.1 Generating a Secure Authentication Token

To prevent unauthorized access to the FRP control port, it is recommended to use a cryptographically secure random token. Generation of a 24-character Base64 encoded string using OpenSSL:



```bash
# 安全なランダムトークンの生成
openssl rand -base64 24
```

#### 6.2 Exposing Multiple Ports and Services

Definition of multiple `[[proxies]]` blocks in `frpc.toml`:



```toml
# frpc.toml (複数サービス構成例)
serverAddr = "CLOUD_PUBLIC_IP"
serverPort = 7000
auth.token = "your_secure_token"

[[proxies]]
name = "ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = 6000

[[proxies]]
name = "web"
type = "tcp"
localIP = "127.0.0.1"
localPort = 80
remotePort = 6500
```

After changing the configuration, restart the client service.



```bash
# クライアントサービスの再起動
sudo systemctl restart frpc
```

⚠️ <b>Note:</b> You must allow inbound communication for all exposed `remotePort`s (e.g., `6000`, `6500`) on the public server's firewall.



#### 6.3 Specifying Port Ranges in Bulk

Bulk port exposure using ranges or commas:



```toml
# frpc.toml (ポート範囲指定例)
[[proxies]]
name = "range_ports"
type = "tcp"
localIP = "127.0.0.1"
localPort = "8000-8080"
remotePort = "8000-8080"
```

#### 6.4 Restricting Bind Ports on the Server Side

Server-side bind port restrictions:



```toml
# frps.toml (ポート制限設定)
allowPorts = [
    { start = 6000, end = 7000 }
]
```

#### 6.5 Connection Troubleshooting

If you cannot connect despite having no issues with the configuration, packet filtering on the public server side may be the cause.



##### Step 1: Explicitly Allowing Port 7000 with `iptables`

Insertion of a rule at the top of the input chain:



```bash
# ポート7000の通信を許可
sudo iptables -I INPUT -p tcp --dport 7000 -j ACCEPT
```

##### Step 2: Persisting the Rules

Persistence of rules using `iptables-persistent`:



```bash
# ルールの永続化保存
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
sudo netfilter-persistent save
```

##### Step 3: Verifying Connectivity from the Outside

Connectivity verification using `netcat` (`nc`):



```bash
# 外部端末からの疎通テスト
nc -zv CLOUD_PUBLIC_IP 7000
```

---

### 7. STCP (Secure TCP) Configuration

Standard TCP proxies globally expose ports on the public server side, making them susceptible to port scanning and unauthorized access. In an <b>STCP (Secure TCP)</b> configuration, no public ports are exposed on the public server; instead, communication is routed through an encrypted tunnel. The accessing client terminal (Visitor) also runs `frpc` and binds to a local port to relay the traffic.



```text
+------------------+                  +------------------+                  +------------------+
|  Service Host    |                  |  Public Server   |                  |   Visitor Host   |
|  (FRP Client)    | --[STCP Tunnel]-&gt;|  (FRP Server)    | &lt;-[STCP Tunnel]- |   (FRP Client)   |
|  [frpc (service)]|                  |  [frps]          |                  |   [frpc (visitor)]|
+------------------+                  +------------------+                  +------------------+
```

#### 7.1 STCP Architectural Configuration

* <b>Service (Private Server):</b> Runs the target service to be exposed and the `frpc` acting as the STCP provider.
* <b>frps (Relay Server):</b> Runs on a public IP and relays communication without directly exposing ports to the outside.
* <b>Visitor (Accessing Terminal):</b> Runs on the developer's local PC or similar, running `frpc` as an STCP visitor to bind a local port.

#### 7.2 Configuration Files in INI Format

Configuration examples in INI format:



##### 1. Service Provider Configuration (`frpc_service.ini`)

Placed on the private server side.



```ini
# frpc_service.ini
[common]
server_addr = CLOUD_PUBLIC_IP
server_port = 7000
token = your_secure_token

[ssh_stcp]
type = stcp
sk = secret_key_here
local_ip = 127.0.0.1
local_port = 22
```

⚠️ <b>Security Note:</b> The secret key (`sk`) functions as a pre-shared key for the tunnel. Set a unique, complex string for each service.



##### 2. Relay Server Configuration (`frps.ini`)

Placed on the public server side.



```ini
# frps.ini
[common]
bind_port = 7000
token = your_secure_token
```

##### 3. Visitor Configuration (`frpc_visitor.ini`)

Placed on the accessing local PC side.



```ini
# frpc_visitor.ini
[common]
server_addr = CLOUD_PUBLIC_IP
server_port = 7000
token = your_secure_token

[ssh_stcp_visitor]
type = stcp
role = visitor
server_name = ssh_stcp
sk = secret_key_here
bind_addr = 127.0.0.1
bind_port = 6000
```

#### 7.3 Connection Establishment

When the STCP configuration is active, you connect to your own loopback address to access the remote service from the visitor terminal.


Connection address for a remote application on port `4000`:



```bash
# ビジター端末からの接続実行例
ssh -p 6000 user@127.0.0.1
```

(*Please specify an appropriate loopback address, such as `127.0.0.1:6001`, depending on your network environment's bind settings.)



#### 7.4 Binary Startup Sequence

Recommended binary startup sequence:



1. <b>Start the Relay Server (`frps`):</b>

```bash
./frps -c ./frps.ini
```

2. <b>Start the Service Provider Client (`frpc` - Private Server):</b>

```bash
./frpc -c ./frpc_service.ini
```

3. <b>Start the Visitor Client (`frpc` - Local PC):</b>

```bash
./frpc -c ./frpc_visitor.ini
```

4. <b>Run the Local Application:</b> Connection initiation to the local port via SSH client or browser:



---

### 8. Operational Considerations

* <b>Strict Token Management:</b> Since `auth.token` and STCP's `sk` are stored in plain text in the configuration files, restrict the configuration file permissions appropriately (e.g., `chmod 600`) and take measures to prevent accidental commits to repositories.
* <b>Connection Maintenance and Timeouts:</b> Depending on the specifications of routers behind NAT, TCP connections may be disconnected if there is no communication for a certain period. If necessary, add keep-alive settings such as `keepalive_interval` to the `frpc` configuration to maintain the tunnel.
* <b>Log Monitoring:</b> In the event of connection failures, use `systemctl status frps` and `systemctl status frpc` to check for authentication errors (`token is invalid`) or port conflicts (`port already in use`).