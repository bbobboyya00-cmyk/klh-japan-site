---
title: "Implementation of Resource Isolation and Migration Using Docker Compose in Multi-tenant Web Hosting"
slug: "docker-multi-tenant-resource-isolation"
date: 2026-06-08T10:02:31+09:00
draft: false
image: ""
description: "Explains the implementation steps for container migration and resource limits using Docker Compose and Nginx reverse proxy to solve the \"Noisy Neighbor\" problem when operating multiple sites on a single VM."
categories: ["Linux System Admin"]
tags: ["docker-compose", "nginx-reverse-proxy", "resource-limits", "multi-tenancy", "container-migration"]
author: "K-Life Hack"
---

# Improving Resource Isolation and Operational Stability in Multi-tenant Environments through Docker Containerization

In traditional single-server virtual machine (VM) environments where multiple web services share resources, the "Noisy Neighbor" problem—where a traffic spike on a specific site degrades the performance of the entire server—frequently occurs. This article describes the migration procedure to an independent Docker-based container infrastructure to eliminate this operational risk and improve service stability and visibility.



## Challenges of the Traditional Environment and Background of the Migration

In the traditional VM environment, 10 different websites were operating within a single VM. This configuration contained the following technical debt:



- <b>Single Point of Failure (SPOF) Risk</b>: If CPU usage reaches 100% due to a DDoS attack or spam bot activity on one site, the remaining nine sites simultaneously suffer downtime or severe latency.
- <b>Delayed Incident Response</b>: Since all sites share the same OS and process space, it was difficult to quickly identify which site was the root cause when a failure occurred.

By migrating to containerization using Docker Compose, each site is isolated as a lightweight container with physical resource limits (CPU/memory) imposed, creating a "sandbox" environment where the load of a specific site does not propagate to others.



## Technical Implementation Steps

### 1. Docker Engine Setup

Install the Docker Engine and Compose plugin on the host system. This establishes the foundation for container orchestration.



```bash
# Docker Installation for Ubuntu/Debian
sudo apt-get update
sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

### 2. Preparation of Directory Structure and Storage

Construct a directory hierarchy to manage data for the proxy and each site. Here, storage mounted at `/data` is used to ensure persistence and backup efficiency.



```bash
mkdir -p /data/docker-web/proxy/conf.d
mkdir -p /data/docker-web/site1/html
mkdir -p /data/docker-web/site1/logs
mkdir -p /data/docker-web/site2/html
mkdir -p /data/docker-web/site2/logs
```

### 3. Defining Resource Limits with Docker Compose

In `docker-compose.yml`, use the `deploy.resources.limits` attribute to prevent each container from consuming 100% of the host's resources.



```yaml
version: '3.8'

services:
  site1:
    image: nginx:alpine
    container_name: web-site1
    volumes:
      - /data/docker-web/site1/html:/usr/share/nginx/html
      - /data/docker-web/site1/logs:/var/log/nginx
    deploy:
      resources:
        limits:
          cpus: '0.50'
          memory: 512M
    networks:
      - web-network

networks:
  web-network:
    driver: bridge
```

### 4. Nginx Reverse Proxy Configuration

Use `nginx.conf` to route requests to the appropriate container based on `server_name`. Within the Docker bridge network, the service name functions as the hostname.



```nginx
server {
    listen 80;
    server_name site1.example.com;

    location / {
        proxy_pass http://site1:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

## Operational Verification and Logic of Resource Isolation

Deployment is executed with the following command:



```bash
docker compose up -d
```

With this configuration, even if traffic spikes on `site1`, the container is physically restricted within the configured <b>0.5 CPU cores</b> and <b>512MB RAM</b>. This prevents the exhaustion of the entire host's computational resources, allowing other services from `site2` to `site10` to continue operating unaffected.


Additionally, since logs for each site are output separately to `/data/docker-web/siteX/logs`, identifying the site where an anomaly occurred and performing root cause analysis is accelerated.



## Configuration Notes

- <b>Docker Compose V2 Specification</b>: The `version` specification is optional in the current specification, but it is retained for compatibility.
- <b>Tuning Resource Limits</b>: Numerical values such as `cpus: '0.5'` need to be adjusted based on the actual baseline load of the service. This configuration is a reference model for ensuring minimum stability in a multi-tenant environment.
- <b>Network Isolation</b>: By using the `web-network` bridge driver, direct external access is limited to going through the proxy, clarifying the security boundary.