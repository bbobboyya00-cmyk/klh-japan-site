---
title: "Resolution Methods for 502 Bad Gateway and Permission Boundaries in Nginx-Gunicorn Integration for Django Applications"
slug: "nginx-gunicorn-django-troubleshooting"
date: 2026-07-07T10:33:06+09:00
draft: false
image: ""
description: "Explains the causes of socket communication errors (502 Bad Gateway, 403 Forbidden) between Nginx and Gunicorn in Django deployments on EC2, along with solutions involving permission settings, systemd, and Docker environments."
categories: ["Linux System Admin"]
tags: ["nginx", "gunicorn", "django", "502-bad-gateway", "systemd"]
author: "K-Life Hack"
---

# Three-Tier Deployment Architecture and Troubleshooting in Django Production Environments

When scaling up infrastructure or migrating to a production environment, exposing the Django development server (runserver) directly to the internet is not recommended due to security and concurrency performance concerns. In production, it is common to build a three-tier architecture consisting of a reverse proxy (Nginx), a WSGI application server (Gunicorn), and the application logic (Django). However, this configuration increases the number of communication paths between components, frequently leading to errors such as "502 Bad Gateway" or "403 Forbidden" due to socket permission misconfigurations or abnormal process terminations. This article explains the system design and troubleshooting procedures to prevent these errors and to quickly identify and resolve them when they occur.



## Basic Design of the Three-Tier Deployment Architecture

To achieve efficient traffic control and static file delivery in a production environment, the stack is configured with the following roles:


1. <b>Nginx (Port 80/443)</b>: Acts as the reverse proxy that first receives requests from clients. It directly serves static files (CSS/JS/media files) and forwards only dynamic requests to the downstream Gunicorn.


2. <b>Gunicorn (WSGI Server)</b>: Communicates with Nginx via a Unix domain socket and executes the Python process. It is managed as a daemon by systemd to ensure process persistence.


3. <b>Django</b>: Processes business logic and interfaces with the database (such as AWS RDS).



### Gunicorn systemd Service Definition

To ensure stable operation of the Gunicorn process, define `/etc/systemd/system/gunicorn.service`. The design of the socket file location and ownership is the key to preventing permission errors.



```ini
[Unit]
Description=gunicorn daemon
After=network.target

[Service]
User=ubuntu
Group=www-data
WorkingDirectory=/home/ubuntu/myproject
ExecStart=/home/ubuntu/myproject/venv/bin/gunicorn \
    --access-logfile - \
    --workers 3 \
    --bind unix:/run/gunicorn.sock \
    myproject.wsgi:application

[Install]
WantedBy=multi-user.target
```

### Nginx Virtual Host Configuration

Configure `/etc/nginx/sites-available/django` to proxy requests to the Unix domain socket `/run/gunicorn.sock`.



```nginx
server {
    listen 80;
    server_name _;

    location = /favicon.ico { access_log off; log_not_found off; }

    location /static/ {
        alias /home/ubuntu/myproject/static/;
    }

    location / {
        include proxy_params;
        proxy_pass http://unix:/run/gunicorn.sock;
    }
}
```

---

## Troubleshooting

The following are typical error patterns encountered during production operations and their resolution workflows.



### 1. 502 Bad Gateway

Occurs when Nginx cannot connect to the Gunicorn socket file, or when the socket file itself does not exist.


💡 <b>Cause A</b>: The Gunicorn service is not running. Check the status with `systemctl status gunicorn`; if it is stopped, start it with `systemctl start gunicorn`. Check error logs using `journalctl -u gunicorn`.


💡 <b>Cause B</b>: Socket file path mismatch. Verify that the path specified in Nginx's `proxy_pass` exactly matches the path specified in Gunicorn's `--bind`.



### 2. 403 Forbidden

Occurs when the Nginx execution user (usually `www-data`) does not have access permissions to the socket file or the static file directory.


⚠️ <b>Cause A</b>: Permission restrictions on the `/home/ubuntu` directory. In default Ubuntu settings, the permissions for `/home/ubuntu` may be set to `700` (read/write/execute for the owner only). In this case, Nginx cannot access the sockets or static files located beneath it. Change the directory permissions to `755` or change the socket file creation location to a shared directory such as `/run/`.



        ```bash
        chmod 755 /home/ubuntu
        ```

⚠️ <b>Cause B</b>: Ownership inconsistency in the static files directory. Change the owner of the static files directory so that Nginx can read it.



        ```bash
        sudo chown -R www-data:www-data /home/ubuntu/myproject/static/
        ```

### 3. Port Conflict (Address already in use)

Occurs when a port is already in use during Docker container startup or when attempting to manually start the Django test server.



        ```bash
        sudo lsof -i :8000

        ```bash

kill -15 &lt;PID&gt;



        ```bash
        kill -9 <pid>
        ```

---

## Django Network Design in Docker Environments

When running Django in a containerized environment, attention must be paid to network binding settings. If Django is bound to `localhost` (127.0.0.1) inside the container, it cannot accept access via port mapping from the host machine or other containers (such as Nginx). To receive traffic from outside the container, it must be bound to `0.0.0.0`, which represents all network interfaces.



```bash
# Not recommended (inaccessible from outside the container)
python manage.py runserver 127.0.0.1:8000

# Recommended (allows access from outside the container)
python manage.py runserver 0.0.0.0:8000
```

Furthermore, to accommodate the ephemeral nature of containers, the design must synchronize (volume mount) static files, media files, and database data with directories on the host machine.



```bash
docker run -d \
  -p 8000:8000 \
  -v /home/ubuntu/myproject/media:/app/media \
  --name django-app my-django-image
```

---

## Verification Logs

The following are verification commands and examples of expected output logs to confirm that each component is operating normally after system construction.



### Verifying Gunicorn Operational Status

```text
$ systemctl status gunicorn
● gunicorn.service - gunicorn daemon
     Loaded: loaded (/etc/systemd/system/gunicorn.service; enabled; vendor preset: enabled)
     Active: active (running) since Tue 2026-07-07 10:00:00 UTC; 5min ago
   Main PID: 12345 (gunicorn)
      Tasks: 4 (limit: 1143)
     Memory: 48.2M
        CPU: 120ms
     CGroup: /system.slice/gunicorn.service
             ├─12345 /home/ubuntu/myproject/venv/bin/python3 /home/ubuntu/myproject/venv/bin/gunicorn --access-logfile - --workers 3 --bind unix:/run/gunicorn.sock myproject.wsgi:application
             ├─12346 /home/ubuntu/myproject/venv/bin/python3 /home/ubuntu/myproject/venv/bin/gunicorn --access-logfile - --workers 3 --bind unix:/run/gunicorn.sock myproject.wsgi:application
             └─12347 /home/ubuntu/myproject/venv/bin/python3 /home/ubuntu/myproject/venv/bin/gunicorn --access-logfile - --workers 3 --bind unix:/run/gunicorn.sock myproject.wsgi:application
```

### Verifying Socket File Existence and Permissions

```text
$ ls -la /run/gunicorn.sock
srwxrwxrwx 1 ubuntu www-data 0 Jul  7 10:00 /run/gunicorn.sock
```

### Verifying HTTP Responses via Nginx

```text
$ curl -I http://localhost
HTTP/1.1 200 OK
Server: nginx/1.18.0 (Ubuntu)
Date: Tue, 07 Jul 2026 10:05:00 GMT
Content-Type: text/html; charset=utf-8
Connection: keep-alive
X-Frame-Options: DENY
X-Content-Type-Options: nosniff
Referrer-Policy: same-origin
```

---

## Operational Notes

In production environment operations, regularly check the following checklist to maintain configuration consistency.


🛠️ <b>Principle of Least Privilege for Security Groups</b>: Restrict SSH (Port 22) and development ports (8000) to specific administrative source IP addresses only, and avoid opening them to `0.0.0.0/0`. If the IP address changes, update the security group inbound rules immediately.


🛠️ <b>Separation of Environment Variables</b>: Sensitive information such as database connection details and the Django `SECRET_KEY` should not be hard-coded in the codebase. Inject them using `.env` files or services like AWS Systems Manager Parameter Store, and exclude them from version control system (Git) tracking.


🛠️ <b>Aggregation of Static Files</b>: When updating the application, always execute `python manage.py collectstatic` to update the static file directory referenced by Nginx to the latest state.

</pid>