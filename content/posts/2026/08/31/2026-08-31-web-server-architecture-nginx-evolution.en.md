---
title: "Evolution of Web Server Architecture and Design Comparison in Separation of Concerns"
slug: "web-server-architecture-nginx-evolution"
date: 2026-08-31T10:11:19+09:00
draft: false
image: ""
description: "A technical analysis and explanation of the background behind migrating from Apache to Nginx, differences between process-driven and event-driven I/O multiplexing models, and design patterns for separation of concerns in cloud-native environments."
categories: ["Backend Architecture"]
tags: ["nginx", "apache", "reverse-proxy", "epoll", "c10k-problem"]
author: "K-Life Hack"
---

In infrastructure scaling, traditional monolithic configurations where dynamic script execution, TLS termination, and static file delivery were all consolidated and handled on a single web server led to resource exhaustion and bloated configurations as concurrent connections surged. In particular, with the response to the C10k problem and the transition to container-based microservice architectures, the web server layer is required to minimize connection handling footprints and clearly separate responsibilities.


This article outlines the differences in concurrency models between Apache HTTP Server and Nginx, analyzing from a technical perspective how web server responsibilities have been distributed and reallocated in cloud-native environments.



## Comparison of Concurrency Architectures and I/O Multiplexing

The fundamental difference in design philosophy between both servers lies in their approach to I/O multiplexing and client connection lifecycle management.



### Apache HTTP Server: Process/Thread-Driven Model

Apache has traditionally adopted Multi-Processing Modules (MPM) such as <code>prefork</code> and <code>worker</code>.



* <b>Mechanism</b>: An OS-level process or thread is allocated per client connection (<code>1 Client → 1 Worker</code>).
* <b>Challenges</b>: As concurrent connections increase, context switching overhead and thread stack memory consumption grow linearly. In particular, while Keep-Alive connections or slow clients maintain open connections, worker threads remain dedicated, tending to block the processing of new requests.

### Nginx: Event-Driven, Asynchronous Non-Blocking Model

Nginx was designed from scratch to solve the C10k problem.



* <b>Mechanism</b>: It operates with a single master process and a small number of fixed worker processes scaled to the number of CPU cores. Each worker runs an asynchronous event loop utilizing Linux's <code>epoll</code> or BSD-based <code>kqueue</code>.
* <b>Characteristics</b>: A single worker process monitors thousands to tens of thousands of connections concurrently. Even when waiting for disk I/O or upstream responses occurs, the worker is not blocked and continues processing other active connection events.

Although modern Apache has significantly improved scalability through the introduction of <code>event MPM</code>, which decouples Keep-Alive processing, Nginx's event-driven model is widely adopted for its connection aggregation efficiency as a reverse proxy.



## Separation of Concerns in Cloud-Native Environments

In modern infrastructure, functions once handled by a single web server are distributed across specialized infrastructure layers.



```text
[Traditional Monolithic Architecture]
Client ──► [ Apache HTTP Server ]
              ├── Static File Serving (Local Disk)
              ├── Dynamic Runtime Execution (mod_php / mod_python)
              ├── SSL/TLS Termination (mod_ssl)
              └── Routing / Rewriting (mod_rewrite)

[Modern Separation of Concerns Architecture]
Client ──► [ CloudFront / CDN ] ──► (Static Assets S3)
              │
              ▼
           [ ALB / Layer 7 LB ] ──► (TLS Termination / Path-Based Routing)
              │
              ▼
           [ Nginx (Ingress/Proxy) ] ──► (Reverse Proxy / Buffering)
              │
              ▼
           [ Application (FastAPI/Spring Boot/Node.js) ]
```

### Internalization of Application Runtimes

With the evolution of web application frameworks, the dominant pattern has shifted toward applications handling requests directly via embedded HTTP servers or dedicated interfaces, rather than through web server modules (such as <code>mod_php</code>).



* <b>Java (Spring Boot)</b>: HTTP processing via embedded Tomcat or Undertow
* <b>Python (Django / FastAPI)</b>: Process management via WSGI (Gunicorn) or ASGI (Uvicorn)
* <b>Node.js</b>: Asynchronous event-driven execution via built-in <code>libuv</code>
In this architecture, the primary role required of the web server has shifted from "direct execution of dynamic code" to "high-efficiency reverse proxying, request buffering, and lightweight header rewriting."



## Reverse Proxy Implementation Configuration Example

The following is a representative Nginx reverse proxy configuration that relays requests to a backend application server (e.g., Gunicorn or FastAPI).



```nginx
# /etc/nginx/nginx.conf (Excerpt of key directives)
worker_processes auto;
events {
    worker_connections 1024;
    use epoll;
    multi_accept on;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    upstream backend_app {
        server 127.0.0.1:8000 max_fails=3 fail_timeout=10s;
        keepalive 32;
    }

    server {
        listen 80;
        server_name api.internal.local;

        client_max_body_size 16M;
        client_body_buffer_size 128k;

        location / {
            proxy_pass http://backend_app;
            proxy_http_version 1.1;
            
            proxy_set_header Connection "";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            proxy_connect_timeout 5s;
            proxy_read_timeout 60s;
            proxy_send_timeout 60s;
            
            proxy_buffering on;
            proxy_buffer_size 8k;
            proxy_buffers 8 8k;
        }
    }
}
```

## Troubleshooting

🛠️ Typical issues encountered during reverse proxy deployment and their countermeasures.



### 1. 502 Bad Gateway Caused by HTTP/1.1 Keep-Alive Connection Termination

* <b>Symptom</b>: Sporadic <code>502 Bad Gateway</code> errors occur in communication between Nginx and the backend.
* <b>Cause</b>: By default, Nginx uses HTTP/1.0 for upstream communication, closing connections after each request. Additionally, if the backend's Keep-Alive timeout is shorter than Nginx's, connection closing race conditions occur.
* <b>Countermeasure</b>: Specify the <code>keepalive</code> directive within the <code>upstream</code> block, and explicitly define <code>proxy_http_version 1.1;</code> and <code>proxy_set_header Connection "";</code> inside the <code>location</code> block to clear the header.

### 2. Loss of Client IP Address

* <b>Symptom</b>: Application logs record all client source IPs as the reverse proxy IP (such as <code>127.0.0.1</code>).
* <b>Cause</b>: Because the L7 proxy terminates the TCP connection and regenerates new packets, the source IP in the IP packet header is overwritten.
* <b>Countermeasure</b>: Configure <code>proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;</code> and enable Trusted Proxies settings within the backend framework.

## Verification Command Protocol

Sample verification output for Nginx operational status and port binding after applying configuration.



```text
$ sudo nginx -t
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful

$ sudo systemctl reload nginx

$ ss -tulpn | grep nginx
tcp   LISTEN 0      511          0.0.0.0:80        0.0.0.0:*    users:(("nginx",pid=10421,fd=6),("nginx",pid=10420,fd=6))

$ curl -I -H "Host: api.internal.local" http://127.0.0.1/
HTTP/1.1 200 OK
Server: nginx/1.24.0
Date: Mon, 31 Aug 2026 09:15:20 GMT
Content-Type: application/json
Content-Length: 42
Connection: keep-alive
```

## Findings

💡 The shift from Apache to Nginx in web infrastructure stems not merely from software superiority, but from a paradigm shift in infrastructure design (the transition from single-server centralization to cloud-native separation of concerns).



* <b>Apache Application Scope</b>: Remains a viable choice for shared hosting environments heavily reliant on per-directory configuration (<code>.htaccess</code>) and CMS (e.g., WordPress) runtime environments.
* <b>Nginx Application Scope</b>: Functions as an API Ingress in microservices and as a high-throughput reverse proxy positioned in front of standalone application runtimes.

Selecting an appropriate layer architecture based on system traffic characteristics, containerization status, and static asset delivery pathways is essential.

