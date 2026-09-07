---
title: "Nginx Reverse Proxy Configuration and Apache Port Migration Procedure on Rocky Linux 9"
slug: "nginx-reverse-proxy-apache-rocky-linux"
date: 2026-09-07T10:03:59+09:00
draft: false
image: ""
description: "Covers introducing Nginx as a reverse proxy on Rocky Linux 9, from resolving port 80 conflicts with existing Apache to SELinux network relay configuration and 502 error troubleshooting."
categories: ["Linux System Admin"]
tags: ["nginx", "httpd", "rocky-linux-9", "reverse-proxy", "selinux"]
author: "K-Life Hack"
---

As Web system traffic increases, conventional process/thread-driven Web servers (such as Apache HTTP Server) experience apparent memory consumption and context switch overhead proportional to the number of client connections. In contrast, deploying Nginx—which adopts an asynchronous event-driven architecture—at the network edge to accept requests as a reverse proxy serves as an effective approach for consolidating connection management and protecting the backend.


This article outlines the configuration procedure and operational considerations for an architecture targeting a Rocky Linux 9 environment, where an existing Apache HTTP Server (httpd) is migrated to the backend (port 8080) and Nginx (port 80) is introduced and integrated at the frontend as a reverse proxy.



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

## 1. Apache Port Migration (TCP 80 -&gt; 8080)

When running Nginx and Apache on the same OS instance under default configurations, a bind conflict on the standard HTTP port (TCP 80) (`EADDRINUSE: Address already in use`) occurs. To terminate external traffic with Nginx, change the listening port on the Apache side to 8080.



### 1.1 Changing the Global Listen Configuration

Edit the Apache main configuration file `/etc/httpd/conf/httpd.conf`.



```apache
# /etc/httpd/conf/httpd.conf

# Before change: Listen 80
Listen 8080
```

### 1.2 Synchronizing VirtualHost Configuration

Update existing VirtualHost definitions (e.g., `/etc/httpd/conf.d/site-a.conf`) to explicitly specify port 8080 as well.



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

### 1.3 Service Restart and Port Bind Verification

Restart the `httpd` service to apply the configuration and verify that it is listening on port 8080.



```bash
sudo systemctl restart httpd
sudo ss -tulpn | grep httpd
```

Example output:



```text
tcp   LISTEN 0      511          *:8080            *:*    users:(("httpd",pid=1234,fd=4))
```

---

## 2. Installing Nginx and Configuring the Reverse Proxy

### 2.1 Package Installation and Automatic Start Configuration

Install Nginx from the official Rocky Linux 9 repository.



```bash
sudo dnf install -y nginx
sudo systemctl start nginx
sudo systemctl enable nginx
```

### 2.2 Constructing the Reverse Proxy Block

Create the proxy configuration file `/etc/nginx/conf.d/proxy.conf` under the Nginx configuration directory.



```nginx
# /etc/nginx/conf.d/proxy.conf
server {
    listen 80;
    server_name site-a.com www.site-a.com;

    location / {
        proxy_pass http://127.0.0.1:8080;

        # Forward client information
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Role of each directive:



* `proxy_pass http://127.0.0.1:8080;`: Relays received requests to the local Apache instance (port 8080).
* `proxy_set_header Host $host;`: Preserves the original Host header requested by the client, allowing Apache VirtualHost resolution to function properly.
* `proxy_set_header X-Real-IP $remote_addr;`: Explicitly transmits the client source IP address to the backend.
* `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`: Appends the client IP address list routed through the proxy.
* `proxy_set_header X-Forwarded-Proto $scheme;`: Propagates the original request protocol (http or https).

---

## 3. Adjusting SELinux Policies and Applying Configuration

In Rocky Linux 9, SELinux is enabled (Enforcing) by default, restricting outbound communication from web server processes to external and internal network sockets. If this restriction is not lifted, communication from Nginx to Apache will be blocked, resulting in a `502 Bad Gateway` error.



### 3.1 Persistently Allowing Network Relays

💡 Enable `httpd_can_network_connect` using the `setsebool` command.



```bash
sudo setsebool -P httpd_can_network_connect 1
```

### 3.2 Syntax Check and Service Reload

Verify configuration file syntax, then reload the service.



```bash
sudo nginx -t
sudo systemctl reload nginx
```

---

## 4. Operational Verification Protocol

Check port bindings and HTTP header responses to confirm that the proxy functions properly.



### 4.1 Checking Port Bind Status

```bash
sudo ss -tulpn | grep -E '80|8080'
```

Example output:



```text
tcp   LISTEN 0      511    0.0.0.0:80        0.0.0.0:*    users:(("nginx",pid=5678,fd=6))
tcp   LISTEN 0      511          *:8080            *:*    users:(("httpd",pid=1234,fd=4))
```

### 4.2 Verifying HTTP Response Connectivity

```bash
curl -I -H "Host: site-a.com" http://127.0.0.1
```

Example output:



```text
HTTP/1.1 200 OK
Server: nginx/1.20.1
Date: Mon, 07 Sep 2026 09:00:00 GMT
Content-Type: text/html; charset=UTF-8
Connection: keep-alive
```

---

## 5. Troubleshooting

### 5.1 Nginx Startup Failure (`Job for nginx.service failed`)

* ⚠️ <b>Cause</b>: Occurs when Nginx is started while Apache is still occupying port 80.
* <b>Verification and Recovery Procedure</b>:

  ```bash
  # 80番ポートを占有しているプロセスの特定
  sudo ss -tulpn | grep :80

  # httpdの設定を確認後、再起動して80番を解放
  sudo systemctl restart httpd
  sudo systemctl start nginx
  ```

### 5.2 502 Bad Gateway Error

* ⚠️ <b>Cause 1</b>: The backend Apache server is stopped or not responding on the specified port (8080).
* ⚠️ <b>Cause 2</b>: Connection from Nginx to the internal port is denied by SELinux.
* <b>Verification and Recovery Procedure</b>:

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

* 🛠️ <b>Preserving Header Transparency</b>: In a proxied architecture, consider implementing `remoteip_module` (`RemoteIPHeader X-Forwarded-For`) on the Apache side to prevent client IPs logged in Apache access logs from being replaced with `127.0.0.1`.
* 🛠️ <b>Architectural Scalability</b>: Consolidating the frontend with Nginx allows for easy future expansion, such as TLS termination (integration with Let's Encrypt / Certbot), direct serving of static content, and rate limiting configurations.