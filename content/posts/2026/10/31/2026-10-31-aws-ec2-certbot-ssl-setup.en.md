---
title: "SSL Certificate Automation and Infrastructure Maintenance Protocol Using a Single EC2 and Certbot in an AWS Environment"
slug: "aws-ec2-certbot-ssl-setup"
date: 2026-10-31T10:59:12+09:00
draft: false
image: ""
description: "This document describes VPC and security group configuration, automated SSL/TLS certificate renewal using Certbot, and automated S3 backup architecture when running Web and DB on a standalone EC2 instance in an AWS environment."
categories: ["Linux System Admin"]
tags: ["let's-encrypt-ssl-인증서-자동-갱신"]
author: "K-Life Hack"
---

In standalone configurations prior to introducing an Application Load Balancer (ALB) to handle high-volume application traffic, or in AWS infrastructure setups aimed at minimizing initial build costs, manual certificate renewals and ambiguous network designs directly cause service outages. Particularly in configurations where a web server and a database coexist on a single EC2 instance, strict implementation is required for security group definitions conforming to the principle of least privilege, an automated SSL/TLS certificate renewal pipeline via Certbot, and a periodic backup mechanism.


This document systematically organizes the concrete procedures ranging from network perimeter design in AWS, EC2 instance initialization, automated certificate renewal using Certbot, to automated DB dump transfers to an S3 bucket, alongside technical troubleshooting for issues that may arise in production operations.



## 1. Network Perimeter and Security Group Configuration

Proper segregation of Virtual Private Clouds (VPCs) and subnets forms the foundation of cloud infrastructure security. This configuration applies a `10.0.0.0/16` CIDR block, clearly separating the boundary between public and private subnets.



### 🛠️ Security Group (Stateful) Configuration Requirements

* <b>Web Server Security Group (`sg-web`)</b>:
* HTTP (Port 80): Source `0.0.0.0/0`
* HTTPS (Port 443): Source `0.0.0.0/0`
* SSH (Port 22): Source `<admin ip="">/32` (Fully open to `0.0.0.0/0` is strictly prohibited)
* <b>Database Security Group (`sg-db`)</b>:
* MySQL (Port 3306) or PostgreSQL (Port 5432): Associate with the security group ID of `sg-web` rather than specifying source IP addresses directly

## 2. EC2 Instance Provisioning and Initialization

After launching an Ubuntu LTS-based EC2 instance, modify the permissions of the key pair for remote access, optimize the system time zone, and create a swap space to avoid OOM panics caused by memory exhaustion.



```bash
chmod 400 my-key.pem
ssh -i my-key.pem ubuntu@<ec2_public_ip>

# Set the timezone
sudo timedatectl set-timezone Asia/Tokyo

# Create swap space (2GB)
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile swap swap defaults 0 0' | sudo tee -a /etc/fstab
```

## 3. SSL/TLS Certificate Issuance and Automated Renewal via Certbot

Because AWS Certificate Manager (ACM) requires integration with an ALB, a single-EC2 configuration applies Let's Encrypt (Certbot) to terminate the SSL/TLS handshake directly on Nginx.



### 💡 Certbot Setup Procedure

```bash
sudo apt update
sudo apt install certbot python3-certbot-nginx -y

# Certificate issuance and automatic Nginx configuration
sudo certbot --nginx -d example.com -d www.example.com
```

The validity period of a Let's Encrypt certificate is 90 days. When the Certbot package is installed, a `systemd` timer (`certbot.timer`) is automatically registered, executing renewal checks twice daily. To perform manual operational verification, execute the following dry-run command.



```bash
sudo certbot renew --dry-run
```

## 4. Automation of Database Backups and S3 Synchronization

To mitigate the risk of data loss resulting from a Single Point of Failure (SPOF), construct a backup script that automatically transfers DB dumps generated inside the EC2 instance to an S3 bucket via the AWS CLI.



```bash
#!/bin/bash
# /usr/local/bin/db-backup.sh
SET_DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/tmp/db_backups"
FILE_NAME="db_backup_${SET_DATE}.sql.gz"
S3_BUCKET="s3://my-db-backup-bucket-prod"

mkdir -p ${BACKUP_DIR}

# Generate database dump
mysqldump -u root -p'DB_PASSWORD_HERE' --all-databases | gzip &gt; ${BACKUP_DIR}/${FILE_NAME}

# Transfer to S3
aws s3 cp ${BACKUP_DIR}/${FILE_NAME} ${S3_BUCKET}/${FILE_NAME}

# Delete local temporary file
rm -f ${BACKUP_DIR}/${FILE_NAME}
```

Grant execution permissions to the created script and register it in `crontab` for scheduled execution.



```cron
0 3 * * * /usr/local/bin/db-backup.sh &gt; /dev/null 2&gt;&amp;1
```

Configure a lifecycle rule on the S3 bucket to automatically delete objects 30 days after creation, thereby optimizing storage costs.



## Troubleshooting

### ⚠️ 1. Certbot Renewal Challenge Failure (HTTP-01 Challenge Failure)
* <b>Symptom</b>: `Timeout during connect (HTTP)` or `404 Not Found` errors are returned when running `certbot renew`.
* <b>Cause</b>: Inbound traffic on Port 80 is not open in the security group, or routing configuration for `.well-known/acme-challenge/` in Nginx is incorrect.
* <b>Resolution</b>: Verify that Port 80 is open in the security group inbound rules. Re-verify static file path references in the Nginx configuration file (`/etc/nginx/sites-available/default`) and restore the configuration for the `certbot --nginx` plugin.

### ⚠️ 2. AWS CLI Transfer Failure via cron

* <b>Symptom</b>: Files upload successfully to S3 during manual script execution, but uploads are skipped during automated execution by cron.
* <b>Cause</b>: The environment variable `PATH` and the path to `AWS_CONFIG_FILE` are not properly resolved within the cron execution environment.
* <b>Resolution</b>: Use full-path notation such as `/usr/local/bin/aws` within the script, or explicitly declare `export PATH=$PATH:/usr/local/bin` and `export AWS_SHARED_CREDENTIALS_FILE=/home/ubuntu/.aws/credentials` at the beginning of the script.

### ⚠️ 3. OOM Crash During Package Updates

* <b>Symptom</b>: The console hangs during the execution of `apt update &amp;&amp; apt upgrade`.
* <b>Cause</b>: Physical memory is exhausted on small instances such as t3.micro, triggering the Linux kernel's OOM Killer.
* <b>Resolution</b>: Prior to executing updates, use the `swapon --show` command to verify that swap space is properly allocated.

## Verification Protocols

After completing the setup of each component, verify the operational status of services and automated renewal timers using the following verification commands.



```text
$ systemctl status certbot.timer
● certbot.timer - Run certbot twice daily
     Active: active (waiting) since Sun 2026-10-25 09:00:12 KST; 6 days ago
    Trigger: Sat 2026-10-31 18:42:11 KST; 4h 12min left
   Triggers: ● certbot.service

$ ss -tulpn | grep -E ':(80|443)'
tcp   LISTEN 0      512          0.0.0.0:80        0.0.0.0:*    users:(("nginx",pid=1234,fd=6))
tcp   LISTEN 0      512          0.0.0.0:443       0.0.0.0:*    users:(("nginx",pid=1234,fd=7))

$ swapon --show
NAME      TYPE BASE_SIZE USED PRIO
/swapfile file       2G 128M   -2

$ curl -I https://example.com
HTTP/2 200
server: nginx/1.18.0 (Ubuntu)
date: Sat, 31 Oct 2026 14:30:00 GMT
content-type: text/html
strict-transport-security: max-age=31536000; includeSubDomains
```

## Operational Notes

* <b>OS Patch Management</b>: Batch updates for all packages (`apt upgrade -y`) carry the risk of breaking existing dependency libraries. Maintain an operational policy restricted to security patch applications (`dnf update --security` or `unattended-upgrades`).
* <b>Certificate Expiration Monitoring</b>: Even when the automated renewal timer operates properly, scenarios exist where renewal processing fails due to domain DNS configuration changes or external network restrictions. Integrating external monitoring (such as Prometheus Blackbox Exporter) that triggers an alert when certificate validity falls below 30 days is strongly recommended.</ec2_public_ip></admin>