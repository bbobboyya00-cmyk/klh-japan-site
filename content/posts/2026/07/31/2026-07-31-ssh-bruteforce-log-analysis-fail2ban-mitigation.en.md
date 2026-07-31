---
title: "SSH Brute-Force Attack Log Analysis and Building Dynamic Defense with Fail2ban in Linux Environments"
slug: "ssh-bruteforce-log-analysis-fail2ban-mitigation"
date: 2026-07-31T10:03:38+09:00
draft: false
image: ""
description: "Explains the construction of a Linux authentication log analysis pipeline, the implementation of an automated IP blocking mechanism using Fail2ban, and SSH hardening techniques."
categories: ["Linux System Admin"]
tags: ["fail2ban"]
author: "K-Life Hack"
---

The default SSH port (TCP 22) of Linux servers exposed to the internet is constantly subjected to dictionary attacks and brute-force attacks by automated botnets. In infrastructure operations where the number of nodes increases, manually updating firewall rules to block attacking IPs leads to human error and reaches its limit in terms of response speed.


This article outlines the configuration steps for building an authentication log analysis pipeline recorded in <code>/var/log/auth.log</code> and deploying an Intrusion Prevention System (IPS) that leverages Fail2ban to dynamically inject packet drop rules into netfilter (iptables).



## Authentication Log Structure and Text Analysis Pipeline

In Debian/Ubuntu-based distributions, SSH authentication events are output to <code>/var/log/auth.log</code> (or <code>/var/log/secure</code> in RHEL/CentOS-based systems).



### Attack Log Sample Trace

```syslog
May 20 14:21:05 server-node sshd[4102]: Failed password for invalid user admin from 192.168.56.120 port 54321 ssh2
May 20 14:21:07 server-node sshd[4105]: Failed password for invalid user root from 192.168.56.120 port 54322 ssh2
May 20 14:21:09 server-node sshd[4108]: Failed password for root from 192.168.56.120 port 54323 ssh2
May 20 14:21:11 server-node sshd[4111]: Accepted password for deployer from 192.168.56.10 port 51100 ssh2
```

The <code>Failed password</code> pattern in the log indicates an authentication failure. When <code>invalid user</code> is included, it denotes an attempt using a username that does not exist in the local <code>/etc/passwd</code>; when it is not included, it signifies an attack against an existing account.



### Extracting Attacking IPs via CLI Commands

To quickly identify top IP addresses with high attack frequencies from large log volumes, execute a pipeline combining standard Linux utilities.



```bash
grep "Failed password" /var/log/auth.log | awk '{for(i=1;i&lt;=NF;i++) if($i=="from") print $(i+1)}' | sort | uniq -c | sort -nr | head -n 10
```

Through <code>awk</code> loop processing, the field immediately following the <code>from</code> token is reliably extracted even when column positions vary depending on the presence of <code>invalid user</code>.



## Automated Defense Configuration Using Fail2ban

Based on threat indicators detected via log analysis, dynamic blocking rules are applied using Fail2ban. To protect package default configuration files, create <code>/etc/fail2ban/jail.local</code> to override definitions.



```ini
[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 5
findtime = 10m
bantime  = 1h
```

💡 <b>Key Parameter Definitions:</b>


・<b>maxretry</b>: The maximum number of failed attempts permitted within the specified timeframe.


・<b>findtime</b>: The time window for counting failed attempts (10 minutes in the configuration above).


・<b>bantime</b>: The duration for blocking packets once conditions are met (1 hour in the configuration above).



## Defense-in-Depth Configuration for SSH Service

In addition to deploying an IPS, optimize the configuration of the SSH daemon itself (<code>/etc/ssh/sshd_config</code>) to reduce the attack surface.



1. <b>Change Port Number</b>: Change from the default port 22 to a high-numbered port (e.g., <code>22022</code>) to reduce exposure to wide-area scanners.

2. <b>Disable Direct Root Login</b>: Set <code>PermitRootLogin no</code> to block direct access attempts as a privileged user.

3. <b>Disable Password Authentication</b>: Set <code>PasswordAuthentication no</code> to allow only public key authentication, eliminating dictionary attacks.

## Troubleshooting

Common troubleshooting scenarios and countermeasures encountered when deploying Fail2ban.



### 1. Log Path Identification Issues in systemd Environments

In environments such as Ubuntu 22.04 and later or systems where rsyslog is disabled by default, <code>/var/log/auth.log</code> may not be generated, causing Fail2ban startup to fail.


⚠️ <b>Symptom</b>: The error <code>Have not found any log file for sshd jail</code> occurs upon starting <code>fail2ban.service</code>.


🛠️ <b>Solution</b>: Explicitly specify <code>backend = systemd</code> in the <code>[sshd]</code> section of <code>/etc/fail2ban/jail.local</code> to configure Fail2ban to read logs directly from journald.



### 2. iptables/nftables Backend Conflicts

Depending on the OS kernel version, the packet filter backend (iptables-legacy vs nftables) may differ, causing BAN rules to fail to inject correctly.


🛠️ <b>Solution</b>: Execute <code>fail2ban-client status sshd</code>. If traffic still passes despite the IP being listed in <code>Banned IP list</code>, switch <code>banaction</code> in <code>/etc/fail2ban/jail.conf</code> from <code>iptables-multiport</code> to <code>nftables</code> or <code>nftables-multiport</code>.



## Configuration Notes

Example terminal execution logs for verifying system operating status and BAN rule application status.



```text
# systemctl status fail2ban.service
● fail2ban.service - Fail2ban Service
     Loaded: loaded (/lib/systemd/system/fail2ban.service; enabled; vendor preset: enabled)
     Active: active (running) since Fri 2026-07-31 09:00:00 UTC; 1h 15m ago
   Main PID: 1234 (fail2ban-server)
      Tasks: 5 (limit: 4677)
     Memory: 14.5M
     CGroup: /system.slice/fail2ban.service
             └─1234 /usr/bin/python3 /usr/bin/fail2ban-server -xf start

# fail2ban-client status sshd
Status for the jail: sshd
|- Filter
|  |- Currently failed: 2
|  |- Total failed:     28
|  `- File list:        /var/log/auth.log
`- Actions
   |- Currently banned: 1
   |- Total banned:     3
   `- Banned IP list:   192.168.56.120

# iptables -L f2b-sshd -n -v
Chain f2b-sshd (1 references)
 pkts bytes target     prot opt in     out     source               destination         
    6   360 REJECT     all  --  *      *       192.168.56.120       0.0.0.0/0            reject-with icmp-port-unreachable
 1250 82000 RETURN     all  --  *      *       0.0.0.0/0            0.0.0.0/0
```