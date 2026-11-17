---
title: "Nginx Reverse Proxy Design and Port Binding in a Next.js / NestJS Multi-Container Architecture"
slug: "nginx-reverse-proxy-docker-multi-tier"
date: 2026-11-17T10:47:44+09:00
draft: false
image: ""
description: "Explains L7 routing using an Nginx reverse proxy and Docker bridge network port binding architecture in a multi-container environment comprising Next.js, NestJS, and MySQL."
categories: ["Linux System Admin"]
tags: ["nginx", "docker-compose", "reverse-proxy", "nextjs", "nestjs"]
author: "K-Life Hack"
---

Co-locating frontend and backend roles on a single application server and individually exposing public ports introduces bottlenecks in scaling out components and maintaining security. Particularly in microservice architectures and decoupled frontend/backend architectures, centralizing endpoints and isolating internal networks are essential. This document outlines the design and verification procedures for a multi-tier container architecture that decouples the frontend (Next.js), backend (NestJS), and database (MySQL), integrating Nginx as a unified entry point for ingress traffic.



## Network Configuration and Container Topology

In this configuration, all external requests are received by the Nginx reverse proxy (Port 80) and routed to the appropriate service on the internal Docker bridge network based on the URI path. Application containers do not bind directly to the host's public network ports; instead, they communicate using service name resolution provided by Docker's internal DNS.



```
Docker Network (Bridge Interface)
│
├── nginx (Ingress / Routing Layer)
├── frontend (Next.js Application)
├── backend (NestJS API Engine)
└── database (MySQL Instance)
```

### Container Configuration File (docker-compose.yml)

In the service definitions, the `ports` section is restricted exclusively to Nginx, allowing other containers to communicate only within `app-network`.



```yaml
version: '3.8'

networks:
  app-network:
    driver: bridge

services:
  database:
    image: mysql:8.0
    container_name: database
    environment:
      MYSQL_ROOT_PASSWORD: rootpassword
      MYSQL_DATABASE: app_db
    networks:
      - app-network

  backend:
    build:
      context: ./backend
      dockerfile: Dockerfile
    container_name: backend
    environment:
      DATABASE_HOST: database
      DATABASE_PORT: 3306
      PORT: 4000
    depends_on:
      - database
    networks:
      - app-network

  frontend:
    build:
      context: ./frontend
      dockerfile: Dockerfile
    container_name: frontend
    environment:
      PORT: 3000
    networks:
      - app-network

  nginx:
    image: nginx:alpine
    container_name: nginx
    ports:
      - "80:80"
    volumes:
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - frontend
      - backend
    networks:
      - app-network
```

## Nginx Reverse Proxy Configuration Details

In Nginx, requests with the `/api/` prefix are forwarded to the backend container (`backend:4000`), and all other root requests (`/`) are forwarded to the frontend container (`frontend:3000`).



```nginx
upstream frontend {
    server frontend:3000;
}

upstream backend {
    server backend:4000;
}

server {
    listen 80;
    server_name localhost;

    location /api/ {
        proxy_pass http://backend/api/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location / {
        proxy_pass http://frontend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

## Distinguishing Internal States in Port Binding

When architecting container networks, it is critical to accurately distinguish between a container port's exposed state (Exposed) and its published state to host interfaces (Published).



* <b>Unpublished Internal State (`80/tcp`):</b> The socket is LISTENing only on the container's internal network stack. Direct connections from outside the Docker network (the host OS or external clients) are rejected.
* <b>Published External State (`0.0.0.0:80-&gt;80/tcp`):</b> Port 80 on all network interfaces of the host OS (`0.0.0.0`) is forwarded to port 80 inside the container. This enables traffic arriving via public IPs, such as on AWS EC2 or through an ALB, to be correctly forwarded into the infrastructure.

## Operational Verification and Status Checks

Following deployment, verify the container run states and the integrity of HTTP responses from the terminal.



```text
$ docker compose ps
NAME        IMAGE          COMMAND                  SERVICE     CREATED         STATUS         PORTS
backend     app-backend    "docker-entrypoint.s…"   backend     5 minutes ago   Up 5 minutes   4000/tcp
database    mysql:8.0      "docker-entrypoint.s…"   database    5 minutes ago   Up 5 minutes   3306/tcp, 33060/tcp
frontend    app-frontend   "docker-entrypoint.s…"   frontend    5 minutes ago   Up 5 minutes   3000/tcp
nginx       nginx:alpine   "/docker-entrypoint.…"   nginx       5 minutes ago   Up 5 minutes   0.0.0.0:80-&gt;80/tcp, :::80-&gt;80/tcp

$ curl -i http://localhost/api/posts
HTTP/1.1 200 OK
Server: nginx/1.25.3
Date: Mon, 17 Nov 2026 10:00:00 GMT
Content-Type: application/json; charset=utf-8
Content-Length: 124
Connection: keep-alive
X-Powered-By: Express
```

## Troubleshooting

### 1. ⚠️ 502 Bad Gateway Error During Nginx Startup

If the application initialization of the upstream backend or frontend containers is not complete when the Nginx container starts, Nginx will fail name resolution or connection establishment and return a `502 Bad Gateway`.



* <b>Cause:</b> While container startup order can be managed via `depends_on`, the Docker engine alone does not guarantee readiness at the application layer.
* <b>Resolution:</b> Configure a dynamic resolver in the Nginx `upstream` block, or integrate health check logic to allow proxy traffic only after dependencies are verified as healthy.

### 2. ⚠️ Proxy Pass Mismatch Due to Trailing Slash in URI

The presence or absence of a trailing slash in the `proxy_pass` directive changes the URI path forwarding behavior.



* `proxy_pass http://backend/api/;` (with trailing slash): The matched `location /api/` portion is replaced, forwarding to `http://backend/api/posts`.
* `proxy_pass http://backend;` (without trailing slash): The original request URI is appended in its entirety.

If a misconfiguration results in a `404 Not Found` on the backend, verify consistency between the trailing slash in `proxy_pass` and the NestJS global prefix configuration.



## Configuration Notes

* 🛠️ <b>Infrastructure Health Verification Criteria:</b> Rather than merely checking that containers are in the `Up` state, define ALB target group health check endpoints and L7 response codes (`HTTP 200 OK`) routed through the proxy as monitoring metrics.
* 🛠️ <b>Least-Privilege Port Publishing Policy:</b> Restrict host port exposure exclusively to Nginx (the proxy tier) and isolate backend and database containers strictly within the internal bridge network to minimize the attack surface.