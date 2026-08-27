---
title: "Configuration Verification of Host Header Forwarding and Context Preservation Under Nginx Reverse Proxy"
slug: "nginx-proxy-pass-host-header-preservation"
date: 2026-08-27T10:10:07+09:00
draft: false
image: ""
description: "Explains configuration and troubleshooting approaches for accurately passing the original Host header and client metadata to backend WAS when using Nginx proxy_pass."
categories: ["Linux System Admin"]
tags: ["nginx", "proxy-pass", "proxy-set-header", "http-host-header", "reverse-proxy"]
author: "K-Life Hack"
---

## 1. Architectural Background and Problem Statement

In a multi-tier web application architecture, Nginx is deployed as an edge reverse proxy and Web Server (WS), serving to relay traffic to downstream Web Application Servers (WAS: Spring Boot, Tomcat, etc.).


Requests from external clients for the domain <b>abc.co.kr</b> are forwarded via Nginx to the WAS on the internal network (e.g., <b>localhost:8080</b>) using the <b>proxy_pass</b> directive.



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

In this configuration, when using <b>proxy_pass</b> with default settings, referencing <b>request.getRequestURL()</b> or the <b>HttpServletRequest</b> context in the WAS layer identifies the request not by the original domain accessed by the client (<b>abc.co.kr</b>), but as the internal loopback address (<b>localhost:8080</b> or <b>127.0.0.1</b>).


This document analyzes the header reconstruction mechanism in the Nginx HTTP proxy module (<b>ngx_http_proxy_module</b>) and details the configuration and verification procedures required to fully preserve and transmit the original request context.



## 2. Root Cause Analysis

When forwarding requests to backend servers, Nginx's <b>ngx_http_proxy_module</b> reconstructs HTTP request headers by default.


1. <b>Host Header Rewriting</b>: Nginx automatically sets the target hostname specified in <b>proxy_pass</b> (e.g., <b>localhost:8080</b>) as the value of the <b>Host</b> header sent upstream.


2. <b>Loss of Client Metadata</b>: Unless explicitly configured via <b>proxy_set_header</b>, information regarding the source client's IP address (<b>X-Real-IP</b>), the proxy transit chain (<b>X-Forwarded-For</b>), and the communication protocol (<b>X-Forwarded-Proto</b>) is either discarded or not aggregated.


As a result, the WAS processes the incoming connection as a request originating directly from the local environment rather than through a proxy, causing inconsistencies in absolute URL generation and redirect handling during SSL offloading.



## 3. Configuration Modification Procedure

Modify the location block within the virtual host configuration file (<b>/etc/nginx/nginx.conf</b> or <b>/etc/nginx/conf.d/*.conf</b>).



### 3.1 Default Configuration (AS-IS)

In the absence of header forwarding directives, the WAS receives <b>Host: localhost:8080</b>.



```nginx
server {
    listen 80;
    server_name abc.co.kr;

    location / {
        proxy_pass http://localhost:8080;
    }
}
```

### 3.2 Modified Configuration (TO-BE)

Explicitly map client context variables to proxy request headers.



```nginx
server {
    listen 80;
    server_name abc.co.kr;

    location / {
        proxy_pass http://localhost:8080;

        # Preserve the original Host header
        proxy_set_header Host $host;

        # Forward the client's actual IP address
        proxy_set_header X-Real-IP $remote_addr;

        # Maintain the list of IP addresses traversed through the proxy chain
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        # Forward the original request protocol (http or https)
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

## 4. Directive Functional Specifications

| Directive | Variable Used | Technical Role and Functional Overview |
| :--- | :--- | :--- |
| `proxy_set_header Host` | `$host` | Preserves the original host name requested by the client. `$host` contains the host name from the request line or the host name from the `Host` header field. |
| `proxy_set_header X-Real-IP` | `$remote_addr` | Passes the physical IP address of the client directly connected to Nginx. |
| `proxy_set_header X-Forwarded-For` | `$proxy_add_x_forwarded_for` | Appends the client's `$remote_addr` to the end of the existing `X-Forwarded-For` header value, ensuring traceability across multi-tier proxy environments. |
| `proxy_set_header X-Forwarded-Proto` | `$scheme` | Passes the transmission protocol (`http` or `https`) used between the client and Nginx. Essential for preventing redirect loops and issuing Secure cookies on the WAS side. |

## 5. Equivalent Configuration in Apache HTTP Server

This behavior is not limited to Nginx; it also occurs when operating Apache HTTP Server (<b>httpd</b>) as a reverse proxy via <b>mod_proxy</b>.


Because Apache rewrites the <b>Host</b> header to the backend address by default, the <b>ProxyPreserveHost On</b> directive must be explicitly defined within the virtual host as follows:



```apache
<virtualhost *:80="">
    ServerName abc.co.kr

    ProxyPreserveHost On
    ProxyPass / http://localhost:8080/
    ProxyPassReverse / http://localhost:8080/
</virtualhost>
```

## 6. Troubleshooting and Operational Verification

Typical troubleshooting procedures and verification log examples when applying the configuration are shown below.



### ⚠️ Friction Points

- <b>Infinite Redirect Loops</b>: During SSL offloading (receiving HTTPS at Nginx and forwarding as HTTP to WAS), if <b>X-Forwarded-Proto</b> is missing, the WAS continuously responds with redirects to HTTPS (301/302), resulting in a redirect loop.


- <b>IP Spoofing in Multi-Proxy Environments</b>: When an upstream load balancer exists, referencing only <b>$remote_addr</b> records the private IP of the load balancer; therefore, an appropriate combination of <b>set_real_ip_from</b> and <b>real_ip_header</b> must be considered.



### 🛠️ Operational Verification Logs

Execution log for Nginx configuration syntax check and request header transparency verification commands:



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

Header recognition confirmation in the WAS-side logs:



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

1. When using <b>proxy_pass</b>, it is an operational best practice not merely to forward the path, but to explicitly set the context headers (<b>Host</b>, <b>X-Real-IP</b>, <b>X-Forwarded-For</b>, <b>X-Forwarded-Proto</b>) required by the upstream.


2. On the backend framework side (such as Spring Boot), configurations to trust proxy headers—such as properly enabling <b>ForwardedHeaderFilter</b> or <b>server.forward-headers-strategy</b>—must be operated in tandem with the reverse proxy configuration.

