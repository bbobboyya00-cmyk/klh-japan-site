---
title: "Implementation Specifications for Linux Firewall Management Tools: firewalld, UFW, iptables, nftables"
slug: "linux-firewall-management-implementation-note"
date: 2026-06-06T18:07:48+09:00
draft: false
image: ""
description: "This article explains the specific configuration procedures and architectural differences of major firewall management tools (firewalld, UFW, iptables, nftables) in Rocky Linux and Ubuntu, focusing on practical command structures."
categories: ["Linux System Admin"]
tags: ["firewalld", "ufw", "iptables", "nftables", "linux-security"]
author: "K-Life Hack"
---


This document outlines the implementation specifications of four major tools (firewalld, UFW, iptables, and nftables) for firewall management systems, which form the foundation of network security in Linux operating systems. It describes specific operational procedures and control logic for Rocky Linux and Ubuntu environments.



## 1. firewalld (Rocky Linux)

firewalld is a dynamic firewall management tool standard in RHEL-based distributions. It manages rules using abstracted concepts called "zones" and "services."



### 1.1 Checking Daemon Status and Referencing Rules

As the first step of management, verify the operational status of the background daemon and the current configuration values.



```bash
# Determine the Operational Status of the Daemon
systemctl status firewalld

# View all currently applied rules
firewall-cmd --list-all
```

### 1.2 Service Permission Settings

When allowing specific services such as HTTP traffic, permanent configuration (--permanent) and runtime application (--reload) are required.



```bash
# Permanent addition of HTTP services
firewall-cmd --permanent --add-service=http

# Reload and reflect configuration
firewall-cmd --reload

# confirmation of reflection results
firewall-cmd --list-all
```

### 1.3 Detailed Access Control via Rich Rules

For finer-grained control, such as allowing communication only from specific source IP addresses, "Rich Rules" are used.



```bash
# Allow HTTP access from a specific IP (192.168.0.100)
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.0.100" service name="http" accept'

# Reloading the Configuration
firewall-cmd --reload
```

## 2. UFW (Ubuntu)

UFW (Uncomplicated Firewall) is the default management tool in Ubuntu, designed to simplify iptables operations.



### 2.1 Initial Activation and SSH Protection

When enabling UFW, SSH must be allowed beforehand to prevent remote connections from being cut off.



```bash
# UFW Installation
apt update &amp;&amp; apt install ufw -y

# Allow SSH before enabling
ufw allow ssh
ufw enable
```

### 2.2 Allowing Port and Service Specifications

```bash
# Allow HTTP (port 80)
ufw allow http

# Allowing a Specific TCP Port (8080)
ufw allow 8080/tcp

# Detailed status check
ufw status verbose
```

## 3. iptables

iptables is a low-layer utility that directly manipulates the Linux kernel's netfilter hooks. It filters packets based on the concepts of tables and chains.



### 3.1 Rule Priority and Insertion

By using the -I (Insert) option, specific rules can be inserted at the beginning of existing rules to ensure they are applied with priority.



```bash
# Detailed view of current rules (line numbered)
iptables -L -v -n

# Insert test rule to drop communication to port 8080 first
iptables -I INPUT 1 -p tcp --dport 8080 -j DROP

# Deleting a Test Rule
iptables -D INPUT 1
```

### 3.2 Switching to iptables in Rocky Linux

To avoid conflicts with firewalld, firewalld must be disabled when using iptables directly.



```bash
# Installing Services and Stopping Firewall
dnf install iptables-services -y
systemctl stop firewalld
systemctl disable firewalld

# Verify that SSH (number 22) authorization settings exist in /etc/sysconfig/iptables
# example: -A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT

# Launch Services
systemctl start iptables
systemctl enable iptables
```

### 3.3 Rule Persistence

Since iptables rules are held in memory, a save process is required to maintain them after a reboot.



```bash
# Saving Rules
service iptables save
```

## 4. nftables

nftables was developed as the successor to iptables, featuring more efficient data structures and syntax. It is characterized by a structure where tables and chains are explicitly created.



### 4.1 Defining Basic Structures and Adding Rules

```bash
# Creating a table for the inet family (both IPv4 and IPv6)
nft add table inet filter

# Creating an Input Chain (Defining Hooks and Priorities)
nft add chain inet filter input { type filter hook input priority 0 \; }

# Adding Authorization Rules for Port 80
nft add rule inet filter input tcp dport 80 accept

# Verifying the Rule Set
nft list ruleset
```

### 4.2 Rule Management Using Handles

In nftables, deletion and modification are performed using "handle" numbers assigned to each rule.



```bash
# Show rule set including handle number
nft --handle list ruleset

# Delete a rule by specifying a specific handle number (for example, 5)
nft delete rule inet filter input handle 5
```

## Closing Notes

Linux firewall management must be selected according to the application, ranging from high-abstraction layers like firewalld/UFW to kernel-proximate tools like iptables/nftables. In particular, when operating iptables directly in an existing firewalld environment, care must be taken regarding unintended communication blockages due to service conflicts. In modern system design, migration to nftables, which offers superior performance and scalability, is recommended.

