---
title: "Design of System Log Aggregation and Periodic Delivery Using Logwatch and Postfix"
slug: "logwatch-postfix-log-monitoring-setup"
date: 2026-10-13T10:14:12+09:00
draft: false
image: ""
description: "Implementation procedure for log monitoring using Logwatch and Postfix in an Ubuntu 24.04 environment. Covers configuration file definitions, cron integration, and Postfix delivery troubleshooting."
categories: ["Linux System Admin"]
tags: ["logwatch", "postfix", "syslog", "cron", "sshd"]
author: "K-Life Hack"
---

As the number of infrastructure nodes increases, manually inspecting authentication logs and packet-drop logs scattered across each node becomes a source of operational errors. As a preliminary stage before implementing a centralized log collection platform, or as an approach to quickly ensure the integrity of individual hosts, automated delivery of periodic reports via a log summarization tool is a standard auditing practice.


This document outlines the procedure for constructing a notification pipeline via Logwatch log analysis and Postfix on an Ubuntu 24.04 LTS environment, along with configuration friction points encountered during operations.



## Architecture and Operational Requirements

Logwatch parses log files for each service (SSH, iptables, Apache, Postfix, cron, sudo, etc.) and generates a text or HTML summary based on a specified time range and granularity (Detail level). The generated data can be output to standard output, saved to a file, or sent externally via a locally resident Mail Transfer Agent (MTA).



```text
+-------------------------------------------------------------+
| Linux Node (Ubuntu 24.04.4 LTS)                             |
|                                                             |
|  /var/log/auth.log ---+                                     |
|  /var/log/syslog   ---+--&gt; [ Logwatch Engine ]              |
|  /var/log/mail.log ---+       |                             |
|                               v                             |
|                      [ /usr/sbin/sendmail ]                 |
|                               |                             |
|                               v                             |
|                       [ Postfix (MTA) ]                     |
|                               |                             |
+-------------------------------|-----------------------------+
                                v (SMTP: Port 25/587)
                     [ Remote Mail Server ]
```

## Package Installation and MTA Configuration

### 1. Installing Logwatch

Update the system package repository and install Logwatch.



```bash
sudo apt update
sudo apt install -y logwatch
logwatch --version
```

### 2. Configuring the Delivery Route with Postfix

Set up Postfix and auxiliary utilities to relay or directly send mail to external destinations.



```bash
sudo apt install -y postfix mailutils
```

If the package configuration dialog is displayed, select one of the following depending on your sending requirements:



- <b>Internet Site</b>: For performing direct SMTP delivery from the host to destination MX records (requires consideration of SPF/DKIM/reverse DNS).
- <b>Internet with smarthost</b>: For delivering via an external relay server.

After configuration is complete, verify source domain resolution.



```bash
sudo postconf mydomain
sudo postconf myhostname
```

## Report Generation Parameters and Configuration File Structure

### Immediate Verification (Standard Output)

To inspect today's summary directly in the terminal, execute with the following flags:



```bash
sudo logwatch --detail high --range today --output stdout
```

When filtering for specific services or specifying a time range, use the `--service` and `--range` options.



```bash
# Extract SSH service only
sudo logwatch --service sshd --range today --output stdout

# Specify range for the past 7 days
sudo logwatch --range 'between -7 days and today' --output stdout
```

### Defining `/etc/logwatch/conf/logwatch.conf`

Default operational parameters are defined in `/etc/logwatch/conf/logwatch.conf`. A deployment example is shown below.



```text
# Logwatch Default Configuration
Output = mail
Format = text
Encode = none
MailTo = admin@example.com
MailFrom = logwatch@yourserver.com
Detail = High
Range = yesterday

# Services to exclude from monitoring
Service = "-cron"
Service = "-ntpd"
```

When configuring threshold-based alerts, override individual service configuration files. To change the disk space warning criteria, create and edit `/etc/logwatch/conf/services/disk_space.conf`.



```text
disk_space_percent_used_warning = 90
```

## Automation and Cron Scheduling

In Ubuntu, `/etc/cron.daily/00logwatch` is deployed by default. To strictly control execution timing and delivery parameters, disable the standard daily job and explicitly configure the schedule using `crontab`.


First, as a unit test, verify email output via the mail command and Logwatch standalone.



```bash
# Delivery pipeline connectivity test
echo "Test body" | mail -s "MTA Test" admin@example.com

# One-off email sending test via Logwatch
sudo logwatch --output mail --mailto admin@example.com --detail high --range today
```

After verification, register the following in `/etc/cron.d/logwatch` or root's crontab:



```text
# Send yesterday's report every morning at 08:00
0 8 * * * /usr/sbin/logwatch --output mail --mailto admin@example.com --detail high --range yesterday
```

## Troubleshooting

The following sections describe common failure scenarios encountered during Logwatch installation and Postfix integration, along with their diagnostic procedures.



### 1. Mail Does Not Reach External Destinations and Remains in Queue

⚠️ <b>Cause</b>: Outbound Port 25 Blocking (OP25B) enforced by cloud providers or ISPs, or misconfigurations in Postfix DNS resolution or relay settings.


Verification commands:



```bash
mailq
sudo journalctl -u postfix -n 50 --no-pager
```

If `Connection timed out` or `Network is unreachable` is logged in the queue, Port 25 traffic is restricted. In this case, `relayhost` must be defined in `/etc/postfix/main.cf` to route mail via authenticated SMTP (Port 587).



### 2. Log File Permission Denied

⚠️ <b>Cause</b>: Files under `/var/log` are restricted to specific groups (such as `adm` or `systemd-journal`), preventing read access under the cron execution user privileges.


Remediation procedure: Check execution privileges and verify permission groups for the log directory.



```bash
ls -l /var/log/auth.log
```

If the cron job is configured under an unprivileged user, ensure that it is placed in root's crontab (`sudo crontab -e`) or under `/etc/cron.daily/`.



## Operational Verification

🛠️ The inspection protocols for verifying normal operation of each daemon and process, as well as network listeners, are as follows:



```bash
sudo systemctl status postfix --no-pager
sudo ss -tulpn | grep :25

```text

● postfix@-.service - Postfix Mail Transport Agent (instance -)
Loaded: loaded (/usr/lib/systemd/system/postfix@.service; enabled; preset: enabled)
Active: active (running) since Tue 2026-10-13 09:12:44 UTC; 2h 15min ago
Main PID: 12480 (master)
Tasks: 3 (limit: 4613)
Memory: 4.8M (peak: 5.2M)
CPU: 120ms
CGroup: /system.slice/system-postfix.slice/postfix@-.service
├─12480 /usr/lib/postfix/sbin/master -w
├─12482 qmgr -l -t unix -u
└─15210 pickup -l -t unix -u

tcp   LISTEN 0      100        127.0.0.1:25        0.0.0.0:*    users:(("master",pid=12480,fd=13))
tcp   LISTEN 0      100            [::1]:25           [::]:*    users:(("master",pid=12480,fd=14))

```

上記のようにPostfixのマスタープロセスがループバックアドレス（127.0.0.1）でリッスンしており、Logwatch実行時にエラーなくパイプラインが終了していれば、日次の監視基盤は正常に稼働しています。

## Operational Notes

💡 Logwatchは軽量かつ依存関係が少ないため、最小構成のLinuxサーバーにおける基本的なセキュリティ監査および死活状況の把握に適しています。ただし、ホスト数が増加した環境では個別のメールレポートを人が判読する負荷が急激に増大します。サーバ群の規模に応じて、LogwatchのHTML出力を集約スクリプトで統合するか、あるいはSyslogプロトコルを用いた集中ログ基盤（Fluentbit、OpenTelemetry、Vector等）への移行を検討する必要があります。