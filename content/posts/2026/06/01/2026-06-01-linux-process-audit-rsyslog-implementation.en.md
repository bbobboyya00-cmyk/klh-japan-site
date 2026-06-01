---
title: "Implementing Process Auditing and Log Forwarding Using auditd and rsyslog"
slug: "linux-process-audit-rsyslog-implementation"
date: 2026-06-01T10:21:24+09:00
draft: false
image: ""
description: "Explains the implementation steps for kernel-level process monitoring rule definitions using auditd and tampering prevention measures via remote log forwarding using rsyslog."
categories: ["Linux System Admin"]
tags: ["auditd", "rsyslog", "linux-security", "syslog", "process-monitoring"]
author: "K-Life Hack"
---

# Building an Audit Log Management Infrastructure in Linux Systems: Secure System Call Monitoring and External Forwarding with auditd and rsyslog

## 1. Challenges and Background in Auditing and Log Management

In Linux systems, monitoring process execution states and system calls is fundamental to ensuring security. However, relying solely on standard application-level log output (such as syslog) introduces several serious challenges.


⚠️ <b>Risk of Log Tampering:</b> If an attacker gains root privileges, locally stored plaintext log files (such as /var/log/auth.log) can be easily cleared or tampered with.


⚠️ <b>Lack of System Call-Level Visibility:</b> Standard syslog relies on logs self-reported by applications, making it impossible to forcibly capture system calls (such as file modification or privilege escalation) executed directly by unauthorized binaries.


To address these challenges, we define the implementation steps for an auditing infrastructure that combines auditd, which intercepts system calls at the kernel level, and rsyslog, which forwards logs externally over a highly reliable TCP connection.



## 2. Technology Selection and Trade-offs

In the design of system auditing and log management, the following trade-offs were considered.


<b>Comparison of syslog and auditd:</b> syslog is suitable for recording application-layer events but cannot forcibly track process behavior. On the other hand, auditd captures system calls at the kernel boundary, preventing processes from taking evasive actions. However, depending on the rule configuration, a large volume of logs may be generated, creating a trade-off that strains disk I/O and storage capacity.


<b>Comparison of UDP Forwarding and TCP Forwarding:</b> In remote forwarding via rsyslog, UDP (@) is fast but carries a risk of packet loss. TCP (@@) is connection-oriented and performs retransmission control even during temporary network disconnections, so TCP is adopted for forwarding security audit logs.



## 3. Implementation Steps

### 3.1 Installing and Enabling auditd

In a Debian/Ubuntu environment, run the following commands to install auditd and enable the service.



```bash
sudo apt-get update
sudo apt-get install -y auditd audispd-plugins
sudo systemctl enable --now auditd
```

### 3.2 Defining Audit Rules

Add custom rules to /etc/audit/rules.d/audit.rules to monitor access to critical files and directories.



```text
-w /etc/shadow -p wa -k shadow_watch
-w /etc/sudoers -p wa -k sudoers_watch
```

Reload the audit rules to apply the configuration.



```bash
sudo auigenrules --load
```

### 3.3 Remote TCP Forwarding Configuration via rsyslog

To prevent local log tampering, add a remote forwarding rule to /etc/rsyslog.conf (or a configuration file under /etc/rsyslog.d/).



```text
*.* @@remote-log-server:514
```

After modifying the configuration, restart the rsyslog service.



```bash
sudo systemctl restart rsyslog
```

## 4. Operational Verification and Log Analysis Pipeline

### 4.1 Searching Audit Logs (ausearch)

Search for events matching the defined key (shadow_watch) and display them with numeric values converted to a human-readable format.



```bash
sudo ausearch -k shadow_watch -i
```

### 4.2 Detecting Deleted Executable Binaries

💡 Identify suspicious processes that are running in memory but have been deleted from the disk.



```bash
sudo ls -l /proc/*/exe | grep "deleted"
```

### 4.3 Aggregating SSH Brute-Force Attacks

Extract IP addresses with a high number of failed login attempts from /var/log/auth.log and sort them in descending order.



```bash
grep "Failed password" /var/log/auth.log | awk '{print $(NF-3)}' | sort | uniq -c | sort -nr
```

## 5. Deployment Benefits

With the deployment of this configuration, the following benefits have been verified.


💡 <b>Improved Audit Comprehensiveness:</b> Modifications to /etc/shadow and /etc/sudoers are now reliably recorded at the kernel level along with the executing user ID (auid).


💡 <b>Ensured Log Integrity:</b> Thanks to rsyslog's TCP forwarding configuration, even if local logs are cleared, the event history remains traceable on the remote log server.

