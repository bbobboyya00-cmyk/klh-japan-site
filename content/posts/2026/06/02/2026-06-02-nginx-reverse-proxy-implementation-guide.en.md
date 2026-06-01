---
title: "Implementation Methods for NGINX Reverse Proxy: Nginx Proxy Manager and Manual Configuration"
slug: "nginx-reverse-proxy-implementation-guide"
date: 2026-06-02T07:52:01+09:00
draft: false
image: ""
description: "Procedures for constructing a reverse proxy using GUI management via Nginx Proxy Manager and direct editing of nginx.conf. Covers Docker environment preparation, proxy_pass settings, and firewall control."
categories: ["Linux System Admin"]
tags: ["nginx", "reverse-proxy", "nginx-proxy-manager", "docker-compose", "proxy-pass", "linux-administration"]
author: "K-Life Hack"
---

This document details the procedures for constructing an NGINX reverse proxy environment to route external traffic from a public IP address to a backend application (Apache Tomcat) on a private network. Two implementation approaches are explained: the introduction of <b>Nginx Proxy Manager (NPM)</b>, a Docker-based GUI management tool, and <b>manual configuration</b> via the command line.

## 1. Implementation via Nginx Proxy Manager (NPM)

Nginx Proxy Manager is a solution that allows centralized management of reverse proxies, SSL certificate management, and access list control from a web interface.



### 1.1 Avoiding Conflicts with Existing Services

Since NPM occupies ports 80 and 443, if an NGINX service is running natively on the host OS, it must be stopped and disabled.



```bash
# Stop service
systemctl stop nginx

# Disable auto-start
systemctl disable nginx
```

### 1.2 Preparing the Docker Environment

As NPM runs as a container, the installation of Docker Engine and Docker Compose is mandatory.



1. <b>Repository Configuration</b>: Install `yum-utils` and add the official Docker repository.
```bash
dnf install -y yum-utils
```
2. <b>Enabling the Service</b>: Start the Docker daemon and configure it to run automatically on system reboot.
```bash
systemctl start docker
systemctl enable docker
```

### 1.3 Container Orchestration

Create a dedicated directory to manage NPM configuration files and define `docker-compose.yml`.



```bash
mkdir ~/npm
cd ~/npm
vi docker-compose.yml
```

In `docker-compose.yml`, specify the official image, database parameters, and volume mappings for persistence. After the definition is complete, start the container in the background using the following command.



```bash
docker compose up -d
```

### 1.4 Proxy Configuration via Web UI

After the container starts, access the management dashboard (default port: 81) to perform settings.



1. <b>Initial Authentication</b>: Access `http://[Public_IP]:81` and log in with the initial credentials (`admin@example.com` / `changeme`). A password change is required upon the first login.
2. <b>Adding a Proxy Host</b>: Select "Add Proxy Host" and enter the following parameters.
- <b>Domain Names</b>: The domain or IP address to be published
- <b>Scheme</b>: http
- <b>Forward Hostname / IP</b>: 10.101.0.28 (Private IP of the backend Tomcat)
- <b>Forward Port</b>: 8080
3. <b>Connectivity Verification</b>: Access the public IP from a browser and confirm that the response from Tomcat is returned.

## 2. Implementation via Manual NGINX Configuration

In environments where a GUI is not required or where a more lightweight configuration is desired, perform pass-through settings by directly operating the NGINX package.



### 2.1 NGINX Installation and Initialization

Install NGINX using the DNF package manager. After installation, execute `curl -I http://localhost` to verify that the web server responds normally.



```bash
dnf install nginx -y
systemctl start nginx
systemctl enable nginx
```

### 2.2 Network Security Settings

To allow external traffic, open port 80 in the OS firewall (iptables).



```bash
iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT
```

### 2.3 Configuring the proxy_pass Directive

Define the core logic of the reverse proxy in `nginx.conf`. Open `/etc/nginx/nginx.conf` and modify the `location /` block within the `server` context.



```nginx
location / {
    # Forward traffic to backend Tomcat server (port 8080)
    proxy_pass http://127.0.0.1:8080;
    
    # Add header information as needed (optional)
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

### 2.4 Validation and Application of Settings

Perform a syntax check on the configuration file, and after confirming there are no errors, reload the service. By using `reload`, settings can be applied while maintaining existing connections.



```bash
# Syntax check
nginx -t

# Reload configuration
systemctl reload nginx
```

## 3. Operational Considerations

<b>Port Conflict Management</b>: When running multiple web services on the same host, it is necessary to clarify which process is assigned the binding rights for ports 80/443.


<b>Security</b>: When using NPM, it is recommended to restrict access to the management port (81) at the network layer so that it is only allowed from specific IP addresses.


<b>Persistence</b>: When configuring Docker, ensure that volume mappings are correctly set to guarantee that configuration data is not lost if the container is destroyed.



## Summary

This document presented two methods for constructing a reverse proxy using NGINX. Nginx Proxy Manager enables intuitive operation, while manual configuration provides system transparency and customizability. Select the appropriate method based on requirements to achieve secure and efficient traffic routing to the backend server.

