---
title: "Nginx Reverse Proxy Construction and Let's Encrypt Automation with Ansible"
slug: "ansible-nginx-reverse-proxy-letsencrypt"
date: 2026-09-29T10:18:31+09:00
draft: false
image: ""
description: "Procedures and troubleshooting for automating Nginx reverse proxy setup, SSL certificate auto-issuance/renewal via Let's Encrypt, and HTTPS redirect configurations using Ansible."
categories: ["Linux System Admin"]
tags: ["ansible", "nginx", "letsencrypt", "certbot", "reverse-proxy"]
author: "K-Life Hack"
---

In infrastructure scale-out, manual configuration of VirtualHosts, application of firewall rules, and renewal of SSL/TLS certificates become major factors that induce human error as the number of nodes increases. Especially when operating multi-tenant environments or multiple microservices, delays in certificate lifecycle management pose a critical risk directly leading to service downtime. This article explains a declarative approach to consistently automate everything from building an Nginx reverse proxy using Ansible to automatically issuing SSL/TLS certificates via Let's Encrypt using the HTTP-01 challenge and setting up automated renewal processing via cron.



## Architecture Design and Approach

In this architecture, infrastructure provisioning is executed across the following phases:



1. <b>Bootstrap Phase</b>: Installation of Nginx, Certbot, and required dependency packages.
2. <b>Securing the Route for HTTP-01 Challenge</b>: Deploy temporary Nginx configurations on port 80 and map requests to `/.well-known/acme-challenge/` to a specific webroot directory (`/var/www/letsencrypt`).
3. <b>Certificate Issuance</b>: Run Certbot in non-interactive mode to obtain X.509 certificates from Let's Encrypt.
4. <b>TLS Termination and Reverse Proxy Configuration</b>: Enable TLS termination on port 443 (restricted to TLS v1.2 / TLS v1.3) and transition to a configuration that permanently redirects (301 Moved Permanently) access on port 80 to HTTPS.
5. <b>Scheduling Automated Renewals</b>: Register a cron job that checks for certificate renewals daily at a specified time and reloads Nginx upon successful renewal.

---

## Ansible Playbook Implementation

The following is a complete Ansible playbook that automates reverse proxy construction and SSL certificate lifecycle management.



### Playbook File: `reverse_proxy_ssl.yml

```yaml
- name: Setup Nginx Reverse Proxy + Let's Encrypt SSL
  hosts: reverse_proxy
  become: yes

  vars:
    domain_name: "example.com"        # Target domain name
    backend_server: "http://127.0.0.1:8080"   # Target backend server
    email_for_ssl: "admin@example.com" # Admin email address for Certbot notifications

  tasks:
    - name: Update apt cache
      apt:
        update_cache: yes
        cache_valid_time: 3600

    # ----------------------------------------
    # 1) Install and configure Nginx startup
    # ----------------------------------------
    - name: Install Nginx
      apt:
        name: nginx
        state: present

    - name: Ensure nginx running
      service:
        name: nginx
        state: started
        enabled: yes

    # ----------------------------------------
    # 2) Install Certbot and dependencies
    # ----------------------------------------
    - name: Install Certbot and Nginx plugin
      apt:
        name:
          - certbot
          - python3-certbot-nginx
        state: present

    # ----------------------------------------
    # 3) Initial reverse proxy configuration (Port 80)
    # ----------------------------------------
    - name: Create Nginx reverse proxy config
      copy:
        dest: /etc/nginx/sites-available/reverse_proxy.conf
        content: |
          server {
              listen 80;
              server_name {{ domain_name }};
              
              # Path for Let's Encrypt ACME HTTP-01 challenge
              location /.well-known/acme-challenge/ {
                  root /var/www/letsencrypt;
              }

              location / {
                  proxy_pass {{ backend_server }};
                  proxy_set_header Host $host;
                  proxy_set_header X-Real-IP $remote_addr;
                  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                  proxy_set_header X-Forwarded-Proto $scheme;
              }
          }
      notify: Reload Nginx

    - name: Ensure webroot folder for certbot exists
      file:
        path: /var/www/letsencrypt
        state: directory
        owner: www-data
        group: www-data
        mode: '0755'

    - name: Enable reverse proxy site
      file:
        src: /etc/nginx/sites-available/reverse_proxy.conf
        dest: /etc/nginx/sites-enabled/reverse_proxy.conf
        state: link
        force: yes
      notify: Reload Nginx

    - name: Remove default nginx site
      file:
        path: /etc/nginx/sites-enabled/default
        state: absent
      notify: Reload Nginx

    # ----------------------------------------
    # 4) Obtain Let's Encrypt SSL certificate (HTTP-01)
    # ----------------------------------------
    - name: Obtain Let's Encrypt SSL certificate
      command: &gt;
        certbot certonly --webroot
        -w /var/www/letsencrypt
        -d {{ domain_name }}
        --email {{ email_for_ssl }}
        --agree-tos
        --no-eff-email
      args:
        creates: "/etc/letsencrypt/live/{{ domain_name }}/fullchain.pem"

    # ----------------------------------------
    # 5) TLS termination setup and HTTPS redirection (Port 443)
    # ----------------------------------------
    - name: Create SSL-enabled Nginx config
      copy:
        dest: /etc/nginx/sites-available/ssl_reverse_proxy.conf
        content: |
          server {
              listen 443 ssl;
              server_name {{ domain_name }};

              ssl_certificate /etc/letsencrypt/live/{{ domain_name }}/fullchain.pem;
              ssl_certificate_key /etc/letsencrypt/live/{{ domain_name }}/privkey.pem;
              ssl_protocols TLSv1.2 TLSv1.3;

              location / {
                  proxy_pass {{ backend_server }};
                  proxy_set_header Host $host;
                  proxy_set_header X-Real-IP $remote_addr;
                  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                  proxy_set_header X-Forwarded-Proto https;
              }
          }

          # 301 redirect from HTTP to HTTPS
          server {
              listen 80;
              server_name {{ domain_name }};
              return 301 https://$host$request_uri;
          }
      notify: Reload Nginx

    - name: Enable SSL reverse proxy config
      file:
        src: /etc/nginx/sites-available/ssl_reverse_proxy.conf
        dest: /etc/nginx/sites-enabled/ssl_reverse_proxy.conf
        state: link
        force: yes
      notify: Reload Nginx

    # ----------------------------------------
    # 6) Schedule Certbot automatic renewal
    # ----------------------------------------
    - name: Ensure certbot renew cron job exists
      cron:
        name: "Certbot auto renew"
        job: "certbot renew --quiet --deploy-hook 'systemctl reload nginx'"
        minute: "0"
        hour: "3"

  handlers:
    - name: Reload Nginx
      service:
        name: nginx
        state: restarted
```

### Inventory File: `inventory.ini

```ini
[reverse_proxy]
203.0.113.50 ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/id_ansible
```

---

## Execution Procedures

To execute the playbook against the target node, use the following command:



```bash
ansible-playbook reverse_proxy_ssl.yml -i inventory.ini
```

Running this command automatically performs tasks from updating system packages and setting up Nginx to acquiring certificates via temporary HTTP-01 challenge routing and applying the final TLS termination configuration.



---

## Troubleshooting

Below are typical errors likely to occur due to network or permission inconsistencies when deploying this configuration to a production environment, along with resolution workflows.



### 🛠️ 1. HTTP-01 Challenge Verification Failure (Unauthorized / Connection Refused)

* <b>Cause</b>: Occurs when Let's Encrypt's ACME verification server cannot access port 80 of the target domain. The primary causes are delays in DNS record (A record) propagation or port 80 being closed by security groups or firewalls (ufw, iptables).
* <b>Solution</b>: 
1. Confirm whether external name resolution to the target domain is operating correctly.
2. Check firewall settings and allow inbound traffic to ports 80 and 443.

### 🛠️ 2. Conflict with Nginx Default Configuration

* <b>Cause</b>: In distributions such as Ubuntu, `/etc/nginx/sites-enabled/default` is automatically enabled during Nginx installation. If left intact, requests to port 80 may be captured by the default server block and fail to reach the path for the ACME challenge (`/.well-known/acme-challenge/`).
* <b>Solution</b>: Verify that the `Remove default nginx site` task in the playbook executed successfully and that the symbolic link has been removed.

### 🛠️ 3. Insufficient Permissions on Webroot Directory

* <b>Cause</b>: Insufficient write permissions for the `/var/www/letsencrypt` directory prevent Certbot from placing verification files, leading to an error.
* <b>Solution</b>: Ensure that the directory owner is `www-data:www-data` and permissions are set to `0755`.

---

## Operational Verification and Status Checks

After deployment completes, SSH into the target server and verify the system state and traffic behavior using the following commands:



### Checking Nginx Service Status

```text
$ systemctl status nginx
● nginx.service - A high performance web server and a reverse proxy server
     Loaded: loaded (/lib/systemd/system/nginx.service; enabled; vendor preset: enabled)
     Active: active (running) since Tue 2026-09-29 10:00:00 UTC; 5min ago
   Main PID: 12345 (nginx)
      Tasks: 2 (limit: 1151)
     Memory: 8.5M
        CPU: 45ms
     CGroup: /system.slice/nginx.service
             ├─12345 nginx: master process /usr/sbin/nginx -g daemon on; master_process on;
             └─12346 nginx: worker process
```

### Checking Listening Ports

```text
$ ss -tulpn | grep -E '80|443'
tcp   LISTEN 0      511          0.0.0.0:80        0.0.0.0:*    users:(("nginx",pid=12345,fd=6))
tcp   LISTEN 0      511          0.0.0.0:443       0.0.0.0:*    users:(("nginx",pid=12345,fd=7))
```

### Verifying HTTP to HTTPS Redirect

```text
$ curl -I http://example.com
HTTP/1.1 301 Moved Permanently
Server: nginx
Date: Tue, 29 Sep 2026 10:05:00 GMT
Content-Type: text/html
Content-Length: 166
Connection: keep-alive
Location: https://example.com/
```

---

## Key Takeaways

* 💡 <b>Ensuring Idempotency</b>: Using the `creates` option skips Certbot execution if a valid certificate already exists, preventing unnecessary API calls and rate-limit exhaustion.
* 💡 <b>Secure Communication Protocols</b>: Eliminating vulnerable legacy protocols (SSLv3, TLSv1.0, TLSv1.1) and enabling only `TLSv1.2` and `TLSv1.3` establishes communication channels compliant with security standards.
* 💡 <b>Operational Automation</b>: A cron job running daily at 3:00 AM automatically renews certificates with less than 30 days of validity remaining, and safely reloads Nginx using `--deploy-hook`. This enables continuous operation with zero manual intervention.