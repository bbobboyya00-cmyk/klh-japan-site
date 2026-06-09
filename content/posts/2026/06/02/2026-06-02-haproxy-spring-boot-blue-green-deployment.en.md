---
title: "Configuration and Health Check Optimization for Blue/Green Deployment Using HAProxy and Spring Boot Actuator"
slug: "haproxy-spring-boot-blue-green-deployment"
date: 2026-05-29T17:40:32+09:00
draft: false
image: ""
description: "Explains implementation methods for Blue/Green deployment combining HAProxy and Spring Boot Actuator. Details health check behavior, Docker container replacement, and multi-layer proxy configuration including SSL termination via NPM."
categories: ["Linux System Admin"]
tags: ["haproxy"]
author: "K-Life Hack"
---

# High Availability Infrastructure and Blue/Green Deployment Optimization with HAProxy and Spring Boot Actuator

This article analyzes the construction of high-availability infrastructure based on HAProxy and Spring Boot Actuator, along with implementation details for Blue/Green deployment strategies. Specifically, it focuses on traffic control for zero downtime and the role of health checks in application lifecycle management to verify a robust system configuration.



## 1. Security Protocols in Deployment Environments

To ensure session management security on cloud platforms such as AWS or Vercel, strict attribute settings for cookie-based authentication are required. To mitigate the risks of Cross-Site Scripting (XSS) and Cross-Site Request Forgery (CSRF), implementation of the following attributes is essential:



- <b>SameSite</b>: Restricts the scope of cookie transmission in cross-site requests to block unintended requests.
- <b>HttpOnly</b>: Prohibits access to cookies by client-side scripts to prevent token leakage.
- <b>Secure</b>: Forces cookies to be sent only during encrypted communication via the HTTPS protocol.

These settings must be appropriately handled at the load balancer or application proxy layer.



## 2. Monitoring and Health Management with Spring Boot Actuator

Spring Boot Actuator provides endpoints for exposing the operational status of an application to the outside. In infrastructure orchestration, the following endpoints are particularly important:



- <b>/actuator/health</b>: Returns the application's operational status (UP/DOWN). This is the primary target when load balancers like HAProxy perform backend liveness checks.
- <b>/actuator/metrics</b>: Provides telemetry data such as JVM memory usage, CPU load, and HTTP request statistics to assist in resource optimization.
- <b>/actuator/env</b>: Displays the configuration information of environment variables applied to the application, helping to identify configuration inconsistencies during deployment.

## 3. Multi-domain Mapping and Load Balancing with HAProxy

Configure HAProxy as a reverse proxy and load balancer to integrate multiple Spring Boot applications into a single domain. Precise traffic control is enabled through routing using ACLs (Access Control Lists) and health check configurations utilizing Actuator.



```haproxy
defaults
    mode http
    timeout connect 5s
    timeout client 60s
    timeout server 60s
    
frontend http_front
    bind *:80
    # Definition of ACL based on host header
    acl host_app1 hdr_beg(host) -i app1-127-0-0-1.nip.io

    # Routing to backend if conditions are met
    use_backend http_back_1 if host_app1

backend http_back_1
    balance roundrobin
    # Health check configuration: Use Actuator endpoint instead of root path
    option httpchk GET /actuator/health
    
    # Check parameters: 2s interval, UP after 1 success, DOWN after 1 failure
    default-server inter 2s rise 1 fall 1
    
    # Setting to retry requests to other servers on failure
    option redispatch

    # Definition of backend servers
    server app_server_1_1 app1_1:8080 check
    server app_server_1_2 app1_2:8080 check
```

## 4. Blue/Green Deployment Execution Workflow

Blue/Green deployment is a method that eliminates downtime by running old and new environments in parallel and switching traffic between them. This configuration combines Docker container replacement with Readiness Probes implemented via shell scripts.



### Step 1: Stopping the Old Container (Green)

First, stop and remove the <b>app1_2</b> container. HAProxy detects the health check failure and automatically consolidates traffic to the running <b>app1_1</b> (Blue).



### Step 2: Starting and Verifying the New Container

Start the container using the new image and wait until the application is fully initialized. It is critical to hold the deletion of the old container until the Actuator <b>/health</b> endpoint returns <b>UP</b>.



```bash
# Start new container
docker run -d --network common -p 8081:8080 --name app1_2 chasaem/app260601:1.0

# Readiness Probe script
START_TIME=$(date +%s);
while true; do
    CONTENT=$(curl -s http://localhost:8081/actuator/health);
    
    if [[ "$CONTENT" == *'"status":"UP"'* ]]; then
        echo "Server is UP!";
        break;
    fi
    
    CURRENT_TIME=$(date +%s);
    ELAPSED_TIME=$((CURRENT_TIME - START_TIME));
    
    if [[ $ELAPSED_TIME -ge 60 ]]; then
        echo "Error: Server did not start within 60 seconds." >&amp;2;
        exit 1;
    fi
    
    sleep 5;
done

# Delete old container after startup confirmation
docker rm -f app1_1 2> /dev/null
```

## 5. Multi-layer Proxy Architecture: Integration of NPM and HAProxy

To streamline SSL/TLS termination and certificate management, a configuration is adopted where Nginx Proxy Manager (NPM) is placed at the front end. HTTPS requests from clients are decrypted by NPM and forwarded to HAProxy (port 80) through the internal network. This multi-layer structure allows for the separation of application-layer load balancing and security management.



## 6. HAProxy Health Check Mechanism Details

By fine-tuning HAProxy health check parameters, the balance between fault detection sensitivity and system stability can be optimized.



- <b>inter 2s</b>: Executes a health check every 2 seconds to capture state changes quickly.
- <b>rise 1</b>: The number of consecutive successful checks required for a server to transition from a DOWN state to an UP state. Setting this to 1 speeds up traffic injection immediately after startup.
- <b>fall 1</b>: The number of consecutive failed checks required to judge a server as DOWN. Setting this to 1 ensures traffic is cut off immediately when an anomaly occurs.
- <b>option redispatch</b>: If a selected server goes down while processing a request, the request is resent to another healthy server. This reduces the error rate on the client side.

## 7. Provisioning via Infrastructure as Code (IaC)

Terraform is used to build AWS EC2 instances. By codifying infrastructure through <b>terraform apply</b> and managing A records with external DNS services like DNSZI, the operational complexity associated with IP address changes is resolved. On the constructed EC2 environment, the aforementioned HAProxy and Docker-based Blue/Green deployment logic is executed to verify operations in a cloud environment.



## Summary

This configuration realizes a robust Blue/Green deployment environment combining precise status monitoring via Spring Boot Actuator with flexible traffic control via HAProxy. In particular, by incorporating Readiness Probes into automation scripts, the risk of traffic flowing in before application initialization is complete is eliminated, confirming that true zero-downtime deployment can be achieved.

