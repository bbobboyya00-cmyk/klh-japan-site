---
title: "Self-Hosting Dify with Docker and Caddy: Setup and Security Hardening Design"
slug: "dify-self-hosting-docker-caddy-hardening"
date: 2026-10-03T10:14:29+09:00
draft: false
image: ""
description: "A technical note detailing self-hosting procedures for Dify Community Edition using Docker and Caddy, bypassing UFW and Docker network conflicts, automatic SSL renewal, and security hardening measures."
categories: ["Linux System Admin"]
tags: ["dify", "docker-compose", "caddy", "ufw-bypass", "reverse-proxy"]
author: "K-Life Hack"
---

The demand for self-hosting Dify, an LLM orchestration tool, is rapidly growing to bypass functional limitations of the public cloud version (such as constraints on the number of applications that can be created and knowledge pipelines). However, operating in a local environment introduces availability challenges such as machine sleep, dynamic IPs, and firewall traversal. Establishing a practical production environment can be achieved by deploying Dify using Docker on a 24/7 Linux VPS, along with automated HTTPS and security hardening via Caddy.


This note explains the infrastructure design and concrete implementation procedures based on Dify <code>v1.17.x</code> and Caddy <code>v2.11.x</code> to securely expose the application to the outside world via a reverse proxy while ensuring host machine security.



---

## 1. System Architecture Design

The network and container deployment topology in this environment is as follows:



```
[ External Client / Webhook Source ]
                 │
                 │  https://dify.<domain> (Port 443)
                 ▼
┌────────────────────────────────── VPS Host ──────────────────────────────────┐
│                                                                              │
│  Caddy Reverse Proxy (Auto ACME SSL Management, Ports 80 / 443)              │
│     │                                                                        │
│     │ reverse_proxy (via local loopback)                                     │
│     ▼                                                                        │
│  127.0.0.1:8080                                                              │
│     │                                                                        │
│     │ Docker Port Mapping                                                    │
│     ▼                                                                        │
│  dify-nginx (Container Port :80)                                             │
│     ├─ web / api / worker / worker_beat                                      │
│     ├─ db_postgres / redis / weaviate                                        │
│     └─ plugin_daemon (127.0.0.1:5003)                                        │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
Exposed External Ports: 80/tcp, 443/tcp, 443/udp (Caddy), SSH (Custom Port)
```

As a paramount security design decision, the containers comprising Dify (Nginx, PostgreSQL, Redis, Plugin Daemon, etc.) do not bind to the host's global network interface (<code>0.0.0.0</code>) at all, but bind exclusively to the loopback address (<code>127.0.0.1</code>). The Caddy reverse proxy receives all incoming external traffic, terminates SSL/TLS, and forwards it internally.



---

## 2. Provisioning Host Infrastructure

### 2-1. Updating System Packages and Installing Dependencies

Update packages on the host OS (assuming Ubuntu 22.04 LTS / 24.04 LTS) and install the required utility tools.



```bash
sudo apt update &amp;&amp; sudo apt upgrade -y
sudo apt install -y git curl jq acl
```

### 2-2. Installing and Verifying Docker Engine

If Docker Engine is not installed, install it using the official script. Verify that the Docker Compose version is <code>v2.24.0</code> or higher (required for supporting the <code>!override</code> syntax described later).



```bash
docker --version 2&gt;/dev/null || curl -fsSL https://get.docker.com | sudo sh
docker compose version
systemctl is-enabled docker
```

### 2-3. Creating a Dedicated System User and Setting Permissions

To ensure security, avoid running containers as the <code>root</code> user and create a dedicated <code>dify</code> user for operation.



```bash
sudo adduser dify
sudo usermod -aG docker dify
sudo usermod -aG sudo dify
```

### 2-4. Allocating Swap Space (4GB)

Dify runs multiple microservices (over 10 containers) simultaneously in the backend, consuming 3–5 GB of memory even when idle. To prevent kernel OOM (Out of Memory) killer invocation due to insufficient memory, explicitly allocate 4 GB of swap space.



```bash
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
sudo sysctl vm.swappiness=10
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf
free -h
```

---

## 3. Deploying Dify Orchestration

The following tasks should be executed after switching to the newly created <code>dify</code> user.



### 3-1. Cloning the Repository and Configuring Environment Encryption

Dynamically retrieve the latest release version via the GitHub API and clone the repository.



```bash
cd ~
git clone --branch "$(curl -s https://api.github.com/repos/langgenius/dify/releases/latest | jq -r .tag_name)" https://github.com/langgenius/dify.git
cd ~/dify/docker
cp .env.example .env
chmod 600 .env
```

Replace the initial passwords and encryption keys in the <code>.env</code> file with high-entropy random strings. Running with default values (such as <code>difyai123456</code>) is strictly prohibited as it significantly increases the risk of unauthorized external access.



```bash
# Generate key for session token encryption
sed -i "s|^SECRET_KEY=.*|SECRET_KEY=$(openssl rand -base64 42)|" .env

# Generate passwords for PostgreSQL and Redis
DBP=$(openssl rand -hex 24)
RP=$(openssl rand -hex 24)

sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=$DBP|" .env
sed -i "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=$RP|" .env

# Apply Redis password to Celery Broker URL
sed -i "s|^CELERY_BROKER_URL=.*|CELERY_BROKER_URL=redis://:$RP@redis:6379/1|" .env
```

### 3-2. Restricting Port Binding to Loopback

By default in Docker, performing port mappings opens ports across all host interfaces (<code>0.0.0.0</code>), which bypasses host-side firewalls like UFW. To prevent this, explicitly add a <code>127.0.0.1:</code> prefix to the exposed port configurations in <code>.env</code>.



```bash
sed -i 's|^NGINX_PORT=.*|NGINX_PORT=80|' .env
sed -i 's|^NGINX_SSL_PORT=.*|NGINX_SSL_PORT=443|' .env

sed -i 's|^EXPOSE_NGINX_PORT=.*|EXPOSE_NGINX_PORT=127.0.0.1:8080|' .env
sed -i 's|^EXPOSE_NGINX_SSL_PORT=.*|EXPOSE_NGINX_SSL_PORT=127.0.0.1:8443|' .env
sed -i 's|^EXPOSE_PLUGIN_DEBUGGING_PORT=.*|EXPOSE_PLUGIN_DEBUGGING_PORT=5003|' .env
```

### 3-3. Plugin Daemon Binding Restriction (Docker Compose Override)

The <code>plugin_daemon</code> service is configured by default to bind to <code>0.0.0.0:5003</code>. To safely override this, create <code>docker-compose.override.yaml</code> and restrict it to the loopback address.



```yaml
# ~/dify/docker/docker-compose.override.yaml
services:
  plugin_daemon:
    ports: !override
      - "127.0.0.1:5003:5003"
```

### 3-4. Starting Containers and Initial Health Check

Once configured, start the containers in the background.



```bash
docker compose up -d
```

After startup, verify via local loopback whether the API server responds normally.



```bash
sleep 30
curl -s http://127.0.0.1:8080/console/api/setup
```

If operating correctly, it returns a JSON response of <code>{"step":"not_started","setup_at":null}</code>.



---

## 4. Setting Up HTTPS Reverse Proxy with Caddy

Use Caddy to automatically acquire SSL/TLS certificates from Let's Encrypt and terminate HTTPS communication.



### 4-1. Installing Caddy

Add the official repository and install Caddy.



```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update &amp;&amp; sudo apt install -y caddy
```

### 4-2. Configuring Caddyfile

Edit <code>/etc/caddy/Caddyfile</code> to route traffic from the domain to internal <code>127.0.0.1:8080</code>.



```caddy
# /etc/caddy/Caddyfile
dify.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

Note: Replace <code>dify.example.com</code> with your domain configured in DNS to point to the VPS public IP.

Check the configuration file syntax, and if there are no issues, reload the Caddy service.



```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

---

## 5. Troubleshooting

The following section details representative friction points frequently encountered during the self-hosted environment setup and operational phases, along with their resolutions.



### 5-1. UFW (Firewall) Bypass Issue by Docker

* <b>Symptom</b>: External direct access to <code>http://&lt;VPS_IP&gt;:8080</code> remains possible despite configuring <code>sudo ufw deny 8080/tcp</code> on the host.
* <b>Cause</b>: Docker directly manipulates host <code>iptables</code> (Netfilter) rules for container routing, causing packets to reach containers with higher priority than UFW filtering rules.
* <b>Resolution</b>: Explicitly specify the IP address in <code>EXPOSE_NGINX_PORT</code> within <code>.env</code>, such as <code>127.0.0.1:8080</code>. This ensures containers bind only to the loopback interface, physically blocking direct external access.

### 5-2. Database Authentication Error After Initial Launch

* <b>Symptom</b>: After changing <code>DB_PASSWORD</code> in <code>.env</code> post-deployment, the <code>api</code> container enters a crash loop outputting <code>FATAL: password authentication failed for user "postgres"</code>.
* <b>Cause</b>: The PostgreSQL container initializes the database using the password from <code>.env</code> only on initial startup (when the volume is empty). Changing the value in <code>.env</code> after startup does not update the password stored within the database inside the container, causing a mismatch.
* <b>Resolution</b>: To change the password, execute an <code>ALTER USER</code> statement directly inside the PostgreSQL container to update the database-side password, or destroy the data and reinitialize (note: all data will be lost).

### 5-3. Connection Refusal for Asynchronous Tasks (Celery)

* <b>Symptom</b>: Document upload or indexing tasks to Knowledge (RAG) remain stuck in the 'in progress' state.
* <b>Cause</b>: When changing the Redis password (<code>REDIS_PASSWORD</code>), the connection password contained in <code>CELERY_BROKER_URL</code> was not synchronized, preventing asynchronous workers from fetching jobs from the queue.
* <b>Resolution</b>: Ensure that <code>CELERY_BROKER_URL</code> in <code>.env</code> matches the format <code>redis://:&lt;REDIS_PASSWORD&gt;@redis:6379/1</code> and exactly aligns with the current <code>REDIS_PASSWORD</code>, then restart the containers.

### 5-4. "502 Bad Gateway" Caching by Nginx Container

* <b>Symptom</b>: During <code>api</code> container restart or immediately after an update, <code>502 Bad Gateway</code> continues to display in the browser despite Caddy functioning properly.
* <b>Cause</b>: The Dify frontend Nginx container may be caching an old IP address of the upstream <code>api</code> container, or name resolution failed before <code>api</code> finished starting up, halting routing.
* <b>Resolution</b>: Confirm that the <code>api</code> container is fully operational, then restart only the Nginx container independently.

  ```bash
  docker compose restart nginx
  ```

---

## 6. Operational Verification

After deployment is complete, execute the following verification commands to confirm that the system is operating securely as designed.



### 6-1. Checking Container Operational Status

Verify that all containers are in the <code>Up</code> (or <code>Up (healthy)</code>) status.



```text
$ docker compose ps
NAME                IMAGE                               COMMAND                  SERVICE             CREATED             STATUS                    PORTS
dify-api-1          langgenius/dify-api:0.15.3          "/bin/sh -c './entry…"   api                 2 hours ago         Up 2 hours (healthy)      
dify-db-1           postgres:15-alpine                  "docker-entrypoint.s…"   db                  2 hours ago         Up 2 hours (healthy)      5432/tcp
dify-nginx-1        nginx:1.25-alpine                   "/docker-entrypoint.…"   nginx               2 hours ago         Up 2 hours                127.0.0.1:8080-&gt;80/tcp, 127.0.0.1:8443-&gt;443/tcp
dify-plugin_daemon  langgenius/dify-plugin-daemon:0.15  "/entrypoint.sh"         plugin_daemon       2 hours ago         Up 2 hours (healthy)      127.0.0.1:5003-&gt;5003/tcp
dify-redis-1        redis:7.2-alpine                    "docker-entrypoint.s…"   redis               2 hours ago         Up 2 hours (healthy)      6379/tcp
dify-sandbox-1      langgenius/dify-sandbox:0.5.2       "/main"                  sandbox             2 hours ago         Up 2 hours (healthy)      
dify-web-1          langgenius/dify-web:0.15.3          "/bin/sh -c './entry…"   web                 2 hours ago         Up 2 hours (healthy)      
dify-weaviate-1     semitechnologies/weaviate:1.19.0    "/bin/weaviate --hos…"   weaviate            2 hours ago         Up 2 hours (healthy)      
dify-worker-1       langgenius/dify-api:0.15.3          "/bin/sh -c './entry…"   worker              2 hours ago         Up 2 hours (healthy)
```

### 6-2. Auditing Host Listening Ports

Verify that externally exposed ports are restricted as designed to SSH (e.g., <code>2022</code>) and Caddy (<code>80</code>, <code>443</code>) only.



```text
$ sudo ss -tulnp | grep -vE '127\.0\.0\.|::1|%lo'
Netid State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
tcp   LISTEN 0      4096         0.0.0.0:80         0.0.0.0:*     users:(("caddy",pid=1024,fd=6))
tcp   LISTEN 0      4096         0.0.0.0:443        0.0.0.0:*     users:(("caddy",pid=1024,fd=7))
tcp   LISTEN 0      128          0.0.0.0:2022       0.0.0.0:*     users:(("sshd",pid=821,fd=3))
udp   UNCONN 0      0            0.0.0.0:443        0.0.0.0:*     users:(("caddy",pid=1024,fd=8))
```

Verify that ports such as <code>8080</code>, <code>5003</code>, and <code>5432</code> are not exposed to <code>0.0.0.0</code>.

### 6-3. End-to-End HTTPS Connection Verification

Test from an external client machine whether HTTPS communication via Caddy terminates normally and reaches the Dify setup endpoint.



```text
$ curl -I https://dify.example.com/console/api/setup
HTTP/2 200 
alt-svc: h3=":443"; ma=2592000
content-type: application/json; charset=utf-8
date: Sat, 03 Oct 2026 14:22:15 GMT
server: Caddy
server: nginx
```

If <code>server: Caddy</code> and <code>server: nginx</code> appear sequentially in the response headers and a status code of <code>200</code> is returned, the reverse proxy chain is functioning correctly.



---

## 7. Lifecycle Dynamics and Container Updates

Temporary service downtime occurs when containers are recreated due to Dify version upgrades or configuration changes. When the connection to the backend (<code>127.0.0.1:8080</code>) is disconnected, Caddy automatically returns <code>502 Bad Gateway</code> to the client.


To partially achieve rolling updates (near zero-downtime switching), pre-pulling new images prior to stopping containers is an effective approach to minimize the time required for container recreation and startup.



```bash
cd ~/dify/docker
git pull origin main
docker compose pull
docker compose up -d --remove-orphans
```

This eliminates downtime caused by image download times and compresses service interruption to a few seconds to tens of seconds required for container restarts.



---

## Operational Notes

* 💡 <b>Backup Automation</b>: The <code>dify-db-1</code> (PostgreSQL) data volume and <code>.env</code> file hold all system configurations and user data. Registering a <code>cron</code> job to periodically run <code>pg_dump</code> and offload backups to secure off-host storage is strongly recommended.
* 🛠️ <b>Log Rotation</b>: In Docker default configurations, container standard output logs expand indefinitely, consuming disk space. Configure maximum size limits for the <code>json-file</code> driver in <code>/etc/docker/daemon.json</code> (e.g., <code>max-size: "10m"</code>).
* ⚠️ <b>API Key Lifecycle</b>: API keys for external LLMs (OpenAI, Anthropic, etc.) integrated within Dify are encrypted using <code>SECRET_KEY</code> in <code>.env</code> and stored in the database. Changing this key breaks all existing external integrations; therefore, changing <code>SECRET_KEY</code> after going into production is strictly prohibited.</domain>