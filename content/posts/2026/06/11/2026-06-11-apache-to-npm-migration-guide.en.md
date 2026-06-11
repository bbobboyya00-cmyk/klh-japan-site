---
title: "Reverse Proxy Migration Procedure from Apache mod_proxy to Nginx Proxy Manager"
slug: "apache-to-npm-migration-guide"
date: 2026-06-11T14:17:27+09:00
draft: false
image: ""
description: "Details the setup of Apache mod_proxy in a Rocky Linux environment and the migration process to Nginx Proxy Manager using Docker. Includes SELinux configurations and workarounds for port conflicts."
categories: ["Linux System Admin"]
tags: ["apache-httpd", "nginx-proxy-manager", "rocky-linux", "selinux", "docker-compose", "reverse-proxy"]
author: "K-Life Hack"
---

# Implementation Guide for Migrating from Apache mod_proxy to Nginx Proxy Manager on Rocky Linux

This guide outlines the implementation steps for migrating from a traditional configuration using Apache <b>mod_proxy</b> to Nginx Proxy Manager (NPM) in a Rocky Linux environment. This process covers the transition from initial Apache configuration to container-based operations.



## Initial Reverse Proxy Configuration with Apache mod_proxy

Configure Apache HTTP Server (httpd) as a gateway to the Tomcat application server running in the backend.



### Package Installation and Service Activation

Install httpd using the DNF package manager and configure it to start automatically at system boot.



```bash
dnf install -y httpd
systemctl start httpd
systemctl enable httpd
```

### Defining Proxy Settings

Create /etc/httpd/conf.d/tomcat.conf and write directives to forward specific traffic to the Tomcat server on port 8080.



```apache
<virtualhost *:80="">
    ProxyPreserveHost On
    ProxyPass / http://10.101.0.28:8080/
    ProxyPassReverse / http://10.101.0.28:8080/
</virtualhost>
```

### Adjusting SELinux Security Policies

In the default security policy of Rocky Linux, external network connections by the Apache process are restricted. To function as a reverse proxy, the following boolean value must be modified.



```bash
setsebool -P httpd_can_network_connect 1
```

By providing the <b>-P</b> flag, this setting is persisted across OS reboots. After applying the settings, execute systemctl restart httpd to verify the connection.



## Migration Process to Nginx Proxy Manager (NPM)

Migrate the environment to Nginx Proxy Manager running on a Docker container to increase operational management flexibility.



### Stopping Existing Services and Releasing Ports

Since NPM uses ports 80 and 443 by default, it conflicts with the existing Apache service. Stop Apache and disable its automatic startup before migration. Failure to stop existing services results in container binding errors.



```bash
systemctl stop httpd
systemctl disable httpd
```

### Deploying the NPM Container

Set up the NPM environment using Docker Compose. Navigate to the working directory and start the container in detached mode.



```bash
cd ~/npm
docker compose up -d
```

### Proxy Settings in the Management Interface

Access the NPM management console via the default port 81 and register a new Proxy Host. The configuration values are as follows:



*   <b>Domain Names</b>: Public IP address or domain name
*   <b>Scheme</b>: http
*   <b>Forward Hostname / IP</b>: 10.101.0.28 (Internal IP of the backend Tomcat)
*   <b>Forward Port</b>: 8080
*   <b>Security</b>: Enable "Block Common Exploits" to apply filtering against common attacks such as SQL injection and XSS.

## Findings

The migration from Apache <b>mod_proxy</b> to Nginx Proxy Manager transitions management from configuration file-based workflows to intuitive GUI-based host management. Compared to traditional configurations requiring SELinux context adjustments, containerized NPM minimizes host OS dependencies while providing integrated security filtering features. During migration, verify the occupancy status of ports 80/443 and ensure existing services are completely stopped.

