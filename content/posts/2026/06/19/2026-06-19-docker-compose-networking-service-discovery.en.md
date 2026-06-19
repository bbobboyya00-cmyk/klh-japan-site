---
title: "Design and Implementation of Service Discovery and Network Isolation in Docker Compose"
slug: "docker-compose-networking-service-discovery"
date: 2026-06-19T10:16:44+09:00
draft: false
image: ""
description: "Explains secure communication design between Web and DB using Docker Compose, service discovery via internal DNS, and troubleshooting methods for startup order control."
categories: ["DevOps Logistics"]
tags: ["docker-compose", "service-discovery", "container-networking", "mysql", "nginx", "healthcheck"]
author: "K-Life Hack"
---

# Docker Compose Network Architecture and Service Discovery Implementation

In microservice architectures and multi-tier applications, relying on static IP addresses for communication management between containers carries significant risks from the perspectives of scalability and maintainability. In environment construction using Docker Compose, it is required to achieve secure backend communication while avoiding host machine port conflicts by appropriately designing service discovery via internal DNS and network isolation.



### Mechanisms of Internal DNS and Service Discovery

Services defined in Docker Compose are assigned to a single bridge network by default. Within this network, each container can resolve others using the service name as the hostname. For example, if a database service is defined as <b>db_server</b>, the web application container can connect using the endpoint <b>db_server:3306</b> instead of localhost. This eliminates the need to change application-side settings even if internal IPs fluctuate during container restarts.



### Implementation Configuration Proposal: Integration of Nginx and MySQL

The implementation separates the externally exposed web server from the database hidden within the internal network, implementing data persistence and dependency control via health checks.



```yaml
version: '3.8'

services:
  web_app:
    image: nginx:1.25-alpine
    container_name: web_service
    ports:
      - "8080:80"
    depends_on:
      db_service:
        condition: service_healthy
    networks:
      - backend_net
    volumes:
      - ./html:/usr/share/nginx/html:ro

  db_service:
    image: mysql:8.0.36
    container_name: db_instance
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_PASSWORD}
      MYSQL_DATABASE: app_db
    networks:
      - backend_net
    volumes:
      - db_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p$${DB_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s

networks:
  backend_net:
    driver: bridge

volumes:
  db_data:
    driver: local
```

### Principles of Network Isolation and Port Forwarding

In this configuration, <b>db_service</b> does not have a ports definition. This is to restrict database access only to the <b>web_app</b> within the same network, blocking external attack vectors via the host machine. External users access Nginx through port 8080 of the host, but communication from Nginx to MySQL occurs directly on port 3306 through the Docker-internal <b>backend_net</b>.



## Troubleshooting

The most frequent problem encountered in production environments is the <b>Connection Refused</b> error caused by the discrepancy between container startup order and the timing of application connection attempts.


💡 <b>Database Initialization Delay</b>: depends_on only guarantees the "start" of the container and does not guarantee that the internal process (MySQL engine) is "ready." To resolve this, it is necessary to combine healthcheck with condition: service_healthy.


⚠️ <b>Name Resolution Failure</b>: If a service name is not resolved correctly, check if the containers belong to the same networks block. Communication is blocked between containers belonging to different networks unless connection settings are explicitly added.


🛠️ <b>Environment Variable Mismatch</b>: Verify whether authentication information such as MYSQL_ROOT_PASSWORD matches the connection string on the web app side, and check the loading status of the .env file.



### Connection Integrity Verification Logs

Post-deployment verification involves checking network connectivity and service status via specific command execution.



```text
# Check container status and health check results
$ docker compose ps
NAME                IMAGE               COMMAND                  SERVICE             STATUS              PORTS
db_instance         mysql:8.0.36        "docker-entrypoint.s…"   db_service          healthy             3306/tcp, 33060/tcp
web_service         nginx:1.25-alpine   "/docker-entrypoint.…"   web_app             running             0.0.0.0:8080-&gt;80/tcp

# Test name resolution from the web container to the DB service
$ docker exec -it web_service ping -c 3 db_service
PING db_service (172.21.0.2): 56 data bytes
64 bytes from 172.21.0.2: seq=0 ttl=64 time=0.082 ms
64 bytes from 172.21.0.2: seq=1 ttl=64 time=0.124 ms

# Monitor connection errors using real-time logs
$ docker compose logs -f web_app
```

## Lessons Learned

In infrastructure configuration using Docker Compose, incorporating network isolation and health checks rather than just listing containers is essential for increasing system robustness. In particular, implementing startup control (Healthcheck) that accounts for database initialization time is an extremely effective means of suppressing pipeline failures caused by Connection Refused in deployment automation. Furthermore, ensuring data management that does not depend on the container lifecycle through appropriate mapping of persistent volumes is a minimum requirement for transitioning to production environments.

