---
title: "Implementing SSL Offloading with Nginx Reverse Proxy and Apache mod_remoteip Integration"
slug: "nginx-ssl-offload-apache-mod-remoteip"
date: 2026-10-11T10:07:10+09:00
draft: false
image: ""
description: "Technical note documenting client real IP restoration procedures and configuration verification logs using mod_remoteip when terminating SSL at Nginx and forwarding traffic to backend Apache."
categories: ["Linux System Admin"]
tags: ["nginx", "apache", "mod_remoteip", "ssl-offloading", "reverse-proxy"]
author: "K-Life Hack"
---

As infrastructure scales, designing a system where SSL/TLS certificates are managed and renewed individually on each backend node, consuming CPU resources for cryptographic handshakes, introduces risks of operational renewal oversights and resource contention. To eliminate this cryptographic overhead and operational cost, an architecture is commonly adopted where a reverse proxy is deployed at the edge layer to centralize SSL termination (SSL Offloading) and route traffic to the backend via plain HTTP at high speeds.


However, in this configuration, because the proxy server establishes a new TCP session to the backend, an issue arises where the source IP address is masked by the proxy's internal IP in backend web server (Apache) access logs and internal application layers. This document outlines the setup and verification procedures for a client IP restoration pipeline using `mod_remoteip` on Apache running on CentOS 7, coupled with TLS 1.2/1.3 termination via Nginx on Rocky Linux 9.



## System Topology and Design Specifications

The edge proxy and backend web server communicate within the same private segment (`192.168.20.0/24`).



- <b>Edge Proxy Node</b>
- OS: Rocky Linux 9
- Internal IP: `192.168.20.11`
- Role: Port 80/443 listener, TLS termination, HTTP/2 negotiation, header rewriting
- <b>Backend Node</b>
- OS: CentOS 7
- Internal IP: `192.168.20.12`
- Role: Apache (`httpd`), PHP runtime, request processing over plain HTTP (Port 80)
- <b>Domain Resolution</b>: The target FQDN (`tech.viahost.co.kr`) resolves to the edge proxy's IP.

## Backend Web Server Baseline Configuration (CentOS 7)

On the backend node (`192.168.20.12`), direct external HTTPS connections are blocked, accepting only internal forwarded traffic from Nginx.



```bash
# Install packages and deploy verification script
yum install -y httpd php
echo "<?php phpinfo(); ?>" &gt; /var/www/html/phpinfo.php

# Enable and start the service
systemctl enable httpd
systemctl start httpd
```

## Edge Reverse Proxy and SSL Termination Configuration (Rocky Linux 9)

Install Nginx on the Rocky Linux 9 node (`192.168.20.11`) and configure encryption processing, TLS protocol restrictions, request size limits, and reverse proxy parameters to the backend.



```bash
dnf install -y nginx
```

Create the VirtualHost configuration file (`/etc/nginx/conf.d/tech.viahost.co.kr.conf`) and define the following directives:



```nginx
# HTTP listener - Canonical redirect to HTTPS
server {
    listen 80;
    server_name tech.viahost.co.kr;
    return 301 https://$host$request_uri;
}

# HTTPS listener - SSL termination and proxy forwarding
server {
    listen 443 ssl http2;
    server_name tech.viahost.co.kr;

    # SSL certificate paths
    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    # Cipher suites and protocol restrictions
    ssl_protocols       TLSv1.2 TLSv1.3;

    # Increase payload limit (raised from default 1MB to prevent HTTP 413)
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

Perform a configuration syntax check and reload the daemon:



```bash
nginx -t
systemctl enable nginx
systemctl start nginx
```

### Directive Design Intent

- `ssl_protocols TLSv1.2 TLSv1.3;`: Explicitly disables SSLv3, TLS 1.0, and TLS 1.1 with known vulnerabilities, maintaining Forward Secrecy.
- `client_max_body_size 50m;`: Relaxes buffer restrictions to prevent `HTTP 413 Request Entity Too Large` errors caused by the default value (1MB) during file uploads.
- `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`: Appends the client's original source IP address to the HTTP header chain, passing it transparently downstream.

## Restoring Real IP Addresses with mod_remoteip (Apache)

In traffic routed through a reverse proxy, the source IP recorded in Apache access logs becomes the address of the proxy server (`192.168.20.11`). To ensure accuracy in access analysis and audit logs, extract and apply the real IP address using Apache's `mod_remoteip` module.



### 1. Verifying Module Loading

In Apache 2.4 on CentOS 7, `mod_remoteip` is bundled by default. Verify whether it is loaded in the configuration files.



```apache
LoadModule remoteip_module modules/mod_remoteip.so
```

### 2. Modifying httpd.conf Configuration

Add proxy trust configurations and adjust the log format in `/etc/httpd/conf/httpd.conf`.



```apache
# -------------------------------------------------------------
# Remote IP Configuration
# -------------------------------------------------------------
RemoteIPHeader X-Forwarded-For
RemoteIPInternalProxy 192.168.20.11

# -------------------------------------------------------------
# Log Format Adjustments (Change from %h to %a)
# -------------------------------------------------------------
LogFormat "%a %l %u %t \"%r\" %&gt;s %b \"%{Referer}i\" \"%{User-Agent}i\"" combined
LogFormat "%a %l %u %t \"%r\" %&gt;s %b" common
```

By explicitly registering the edge proxy's internal IP (`192.168.20.11`) in `RemoteIPInternalProxy`, only the `X-Forwarded-For` header forwarded by that proxy is trusted, discarding malicious external header spoofing (IP Spoofing). Additionally, change the LogFormat directive from `%h`, which represents the direct TCP connection source, to `%a`, which indicates the resolved client IP.


After applying the configuration, restart the Apache service:



```bash
systemctl restart httpd
```

## Troubleshooting

Common friction points during the initial deployment of a reverse proxy configuration and verification procedures:



### 1. HTTP 502 Bad Gateway Is Returned

- <b>Cause</b>: Outbound network connections from Nginx may be denied by SELinux policies on the edge proxy (Rocky 9), or the port may not be listening on the backend (`192.168.20.12:80`).
- <b>Verification Procedure</b>:

  ```bash
  # SELinuxによるHTTPネットワーク接続許可フラグの確認
  getsebool httpd_can_network_connect
  # 無効（off）の場合は有効化
  setsebool -P httpd_can_network_connect 1
  ```

### 2. Real IP Is Not Reflected on Apache, Proxy IP Continues to Be Displayed

- <b>Cause</b>: Incorrect IP definition in `RemoteIPInternalProxy`, or intermediate header name mismatch with `X-Forwarded-For`.
- <b>Verification Procedure</b>: Verify via browser or `curl` using PHP environment variable output (`phpinfo.php`) whether the value of `$_SERVER['HTTP_X_FORWARDED_FOR']` accurately reaches the backend.

## System Operation Verification Logs

Protocol verification logs with all services operational:



### Listener and Forwarding Test on Proxy Node

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

### Access Log Verification on Backend Node

Output of `/var/log/httpd/access_log` when accessed from a client (e.g., public IP `203.0.113.45`):



```text
[root@backend-node ~]# tail -n 1 /var/log/httpd/access_log
203.0.113.45 - - [11/Oct/2026:13:12:05 +0900] "GET /phpinfo.php HTTP/1.0" 200 45124 "-" "curl/7.88.1"
```

It can be confirmed that the client's real source IP address (`203.0.113.45`) is properly recorded in the leading field (`%a`).



## Configuration Notes

- <b>Scaling to a Backend Cluster</b>: When transitioning from single-host forwarding to a redundant configuration, define an `upstream` block in Nginx and configure health checks and balancing algorithms.

  ```nginx
  upstream backend_cluster {
      server 192.168.20.12:80 max_fails=3 fail_timeout=10s;
      # 追加のバックエンドノードを順次定義
  }
  ```

- <b>Integrating Security Layers</b>: By integrating a WAF (Web Application Firewall) into the edge proxy layer, the architecture can evolve to inspect and block malicious request parameters and injection attacks before reaching the backend.