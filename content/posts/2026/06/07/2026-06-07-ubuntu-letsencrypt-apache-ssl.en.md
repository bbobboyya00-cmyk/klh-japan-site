---
title: "Let's Encrypt Installation and Auto-Renewal Configuration for Apache and Nginx on Ubuntu 22.04 LTS"
slug: "ubuntu-letsencrypt-apache-ssl"
date: 2026-06-07T10:06:30+09:00
draft: false
image: ""
description: "This guide explains the steps to install and auto-renew Let's Encrypt SSL/TLS certificates using Certbot for Apache/Nginx on Ubuntu 22.04 LTS, along with troubleshooting during migration."
categories: ["Linux System Admin"]
tags: ["letsencrypt", "certbot", "ubuntu-22-04", "apache", "nginx"]
author: "K-Life Hack"
---

Physical server migrations or network line switchovers can sometimes cause temporary omissions in SSL/TLS configurations. Continuing operations over unencrypted HTTP (port 80) triggers "Not Secure" warnings in browsers, risking a loss of user trust, lower search engine rankings, and a significant drop in traffic.


This article explains the procedures for installing Let's Encrypt SSL/TLS certificates using Certbot, configuring auto-renewal, and troubleshooting for Apache 2.4 and Nginx web servers on Ubuntu 22.04 LTS.



## 1. Prerequisites and Network Requirements

Before starting the certificate issuance process, the target environment must meet the following requirements.



1. <b>Administrative Privileges</b>: SSH access to the server and sudo execution privileges.
2. <b>DNS Settings</b>: Registered domain names (A or AAAA records) must correctly point to the public IP address of the target server.
3. <b>Firewall Settings</b>: Ports 80 (HTTP) and 443 (HTTPS) must be open to the outside, with traffic routed to the web server.

⚠️ In cloud environments such as AWS, you must explicitly allow these ports in the security group inbound rules. Omitting this configuration is a common cause of certificate validation errors.



## 2. Installing Certbot and Issuing Certificates

This section covers the installation steps on Ubuntu 22.04 LTS. Install the appropriate plugin depending on your Apache or Nginx environment.



### 2.1. Updating System Packages

Update the local package index to prevent dependency conflicts.



```bash
sudo apt update
```

### 2.2. Installing Certbot and Plugins

Select and install the appropriate package for the web server you are using.


For Apache environments:



```bash
sudo apt install certbot python3-certbot-apache -y
```

For Nginx environments:



```bash
sudo apt install certbot python3-certbot-nginx -y
```

### 2.3. Running the Certificate Issuance Command

Run Certbot to obtain the certificate and automatically apply it to the web server. Specifying both the root domain and the www subdomain prevents certificate errors based on the access path.


For Apache environments:



```bash
sudo certbot --apache -d yourdomain.com -d www.yourdomain.com
```

For Nginx environments:



```bash
sudo certbot --nginx -d yourdomain.com -d www.yourdomain.com
```

💡 The interactive prompt during execution will request the following inputs:



1. <b>Enter Email Address</b>: Enter an address to receive certificate expiration notices and important announcements from Let's Encrypt.
2. <b>Agree to Terms of Service (ToS)</b>: You will be asked to agree, so accept by following the on-screen instructions.
3. <b>Newsletter Subscription</b>: Choose whether to receive information updates from the Electronic Frontier Foundation (EFF) (optional).

## 3. Configuring Auto-Renewal and Zero-Downtime Reload

Let's Encrypt certificates are valid for 90 days. Configure auto-renewal to prevent service disruptions due to expiration.



### 3.1. Testing the Renewal Process (Dry Run)

Verify that the validation process functions correctly without actually reissuing the certificate.



```bash
sudo certbot renew --dry-run
```

### 3.2. Scheduling Auto-Renewal with Cron

Add a task to the root user's crontab to execute the renewal process periodically.


Open the crontab editor.



```bash
sudo crontab -e
```

Append the following configuration line to the end of the file.



```cron
0 3 * * * certbot renew --post-hook "systemctl reload apache2" --quiet
```

💡 This job runs daily at 3:00 AM. The `--quiet` flag ensures logs are output only when an error occurs. Using `--post-hook` (or `--deploy-hook`) reloads the web server only when the certificate is actually renewed, applying the new certificate without disconnecting active connections (for Nginx, specify `systemctl reload nginx`).



## 4. Troubleshooting

If you access `https://yourdomain.com` in a browser after applying the certificate and the lock icon does not appear, or if a connection error occurs, check the following items.



### 4.1. Port 443 (HTTPS) Traffic Blocked

⚠️ If a timeout occurs during an HTTPS connection, check the host-side firewall (such as UFW) or the cloud infrastructure security settings.



```bash
sudo ufw status
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

### 4.2. Domain Name Mismatch

⚠️ If `Common Name Invalid` or `SSL_ERROR_BAD_CERT_DOMAIN` is displayed in the browser, double-check that the domain name specified when running Certbot exactly matches the domain registered in the DNS A record.



### 4.3. Virtual Host Configuration Conflicts

⚠️ If the web server fails to start, or if the default unencrypted page is displayed during HTTPS access, the automatic rewriting by Certbot may be conflicting with existing configurations. Open the configuration file (`/etc/apache2/sites-enabled/` or `/etc/nginx/sites-enabled/`) and verify that the certificate paths are correctly specified.


Configuration example in Apache:



```apache
<virtualhost *:443="">
    ServerName yourdomain.com
    ServerAlias www.yourdomain.com

    DocumentRoot /var/www/html

    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/yourdomain.com/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/yourdomain.com/privkey.pem
</virtualhost>
```

Configuration example in Nginx:



```nginx
server {
    listen 443 ssl;
    server_name yourdomain.com www.yourdomain.com;

    ssl_certificate /etc/letsencrypt/live/yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/yourdomain.com/privkey.pem;

    location / {
        try_files $uri $uri/ =404;
    }
}
```

## 5. Configuring Multi-Domain (SAN) Certificates

When operating multiple subdomains or different domains on the same server, you can issue a "Subject Alternative Name (SAN)" certificate that consolidates multiple hostnames into a single certificate.


Run the command using additional `-d` flags.



```bash
sudo certbot --expand -d yourdomain.com -d www.yourdomain.com -d otherdomain.com
```

### Operational Considerations

⚠️ Although Let's Encrypt supports up to 100 names per certificate, it is recommended to limit the number of domains in a single certificate to 10 or fewer to avoid complex validation processes and risks during DNS issues.



## Configuration Notes

The following is a summary of the key configuration parameters and recommended actions for this setup.



| Item / Task | Specification / Recommended Action |
| :--- | :--- |
| <b>Target OS</b> | Ubuntu 22.04 LTS |
| <b>Web Server</b> | Apache 2.4 or Nginx |
| <b>Certificate Validity Period</b> | 90 days |
| <b>Auto-Renewal Threshold</b> | When less than 30 days remain until expiration |
| <b>Auto-Renewal Schedule</b> | Cron execution daily at 3:00 AM (`0 3 * * *`) |
| <b>Reload Process</b> | Zero-downtime reload execution via `--post-hook` |
| <b>Multi-Domain Limit</b> | 10 domains or fewer per certificate recommended |
| <b>Required Ports</b> | Port 80 (for HTTP validation) and Port 443 (for HTTPS traffic) |