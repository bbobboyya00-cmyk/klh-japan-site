---
title: "Implementation of Connecting Apache on a Docker Container to PHP-FPM on the Host OS via FastCGI Proxy"
slug: "docker-apache-host-php-fpm-proxy"
date: 2026-06-01T13:49:50+09:00
draft: false
image: ""
description: "This article explains the implementation steps and configuration details for a hybrid setup that links an Apache web server in a Docker container with PHP-FPM on the host OS via a FastCGI proxy to separate dynamic content processing."
categories: ["Linux System Admin"]
tags: ["docker", "apache-httpd", "php-fpm", "mod-proxy-fcgi", "fastcgi", "hybrid-infrastructure"]
author: "K-Life Hack"
---

# Building a PHP Execution Environment with a Hybrid Configuration of Docker Container (Apache) and Host OS (PHP-FPM)

## 1. Architecture Overview and Selection Rationale

This article details the implementation process of a hybrid configuration that links the Apache HTTP Server running inside a Docker container with PHP-FPM (FastCGI Process Manager) running directly on the host OS. While it is common in Docker environments to run PHP within the same container or in a sidecar configuration, this setup physically and logically separates the presentation layer (Apache) from the application processing layer (PHP).



### 1.1 Current Issues

In the containerized Apache (container name: <b>web2</b>), while static content (HTML) delivery was functioning normally, it was observed that PHP file requests were not being parsed, resulting in the source code being exposed or the browser attempting to download the file. This is caused by the absence of a PHP interpreter within the container or Apache's inability to properly handle PHP requests.



### 1.2 Adopted Solution: Hybrid Proxy Model

After considering the following two options, Option 2 was adopted.



1. <b>Container Rebuild</b>: Create a new image containing both Apache and PHP.
2. <b>Hybrid Proxy Model</b>: Connect the existing Apache container and the PHP-FPM on the host OS via a network bridge.

By adopting Option 2, it is possible to utilize the host OS's native hardware resources for PHP processing while preventing container image bloat. Furthermore, operational flexibility is improved because the management of PHP extension modules and configuration changes can be completed on the host side.



## 2. Host OS Configuration: Building PHP-FPM

Prepare the environment on the host OS side to accept FastCGI requests from the container.



### 2.1 Package Installation

Use the host OS package manager (dnf) to install the PHP core and major modules.



```bash
dnf install -y php-fpm php-mysqlnd php-opcache php-mbstring
```

* <b>php-fpm</b>: A FastCGI manager that processes requests from the web server.
* <b>php-mysqlnd</b>: Driver for database connections.
* <b>php-opcache</b>: Improves execution speed by keeping compiled bytecode in shared memory.
* <b>php-mbstring</b>: Essential for proper handling of multi-byte strings.

### 2.2 Modifying PHP-FPM Configuration (www.conf)

By default, PHP-FPM listens on a Unix domain socket or 127.0.0.1:9000, and access from the outside (container) is denied. Change this to accept requests over the network.



```bash
vi /etc/php-fpm.d/www.conf
```

Configuration adjustments:



```ini
; Port setting to allow requests from outside
listen = 8080

; Restriction of clients allowed to access
listen.allowed_clients = 127.0.0.1, 192.168.159.10
```

After changing the settings, start and enable the service.



```bash
systemctl start php-fpm
systemctl enable php-fpm
```

## 3. Docker Container Configuration: Apache FastCGI Proxy

Next, configure the Apache container (<b>web2</b>) to forward PHP requests to port 8080 of the host OS.



### 3.1 Editing the Apache Configuration File

Enter the container's shell and edit httpd.conf.



```bash
docker exec -it web2 /bin/bash
vi /usr/local/apache2/conf/httpd.conf
```

#### 3.1.1 Enabling Proxy Modules

Uncomment the following lines to enable the FastCGI proxy functionality.



```apache
LoadModule proxy_module modules/mod_proxy.so
LoadModule proxy_fcgi_module modules/mod_proxy_fcgi.so
```

#### 3.1.2 Handler Configuration

Add the proxy settings for PHP files to the end of the file. Here, assume the host OS IP address is 192.168.159.10.



```apache
ProxyPassMatch ^/(.*\.php(/.*)?)$ fcgi://192.168.159.10:8080/var/www/html/$1
```

With this configuration, all requests with a .php extension will be forwarded to the specified FastCGI endpoint.



## 4. Integration Testing and Verification

After completing the configuration, verify that communication between the container and the host is functioning correctly.



### 4.1 Verification Flow

1. <b>Entry Point</b>: Access index.php (HTML form) on the container.
2. <b>Data Transmission</b>: Send data from the form to login.php using the POST method.
3. <b>Proxy Processing</b>: Apache detects the request to login.php and forwards it to 192.168.159.10:8080 on the host OS.
4. <b>PHP Execution</b>: PHP-FPM on the host OS executes the script and returns the result to Apache.
5. <b>Response</b>: Confirm that the execution result is displayed in the browser.

If the PHP code is not displayed as-is and the result processed on the server side is returned as expected, the proxy integration is successful.



## Operational Notes

* ⚠️ <b>Network Reachability</b>: Ensure that port 8080 is open from the container to the host OS IP address in the firewall settings (e.g., firewalld).
* 🛠️ <b>File Path Consistency</b>: The document root seen by Apache and the script path referenced by PHP-FPM must match. If they do not match, a `File not found` error will occur.
* 💡 <b>Performance</b>: Since this is a proxy over the network, overhead may occur compared to Unix domain sockets in high-traffic environments. Consider tuning php-opcache as necessary.