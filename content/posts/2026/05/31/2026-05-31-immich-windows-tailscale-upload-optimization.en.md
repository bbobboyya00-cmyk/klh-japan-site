---
title: "Deploying Immich on Windows 11 with Tailscale and Upload Optimization"
slug: "immich-windows-tailscale-upload-optimization"
date: 2026-05-21T17:43:23+09:00
draft: false
image: ""
description: "Technical deployment of Immich on Windows 11 using WSL2, Tailscale for secure mesh networking, and a proxy-based upload optimizer for storage efficiency."
categories: ["Linux System Admin"]
tags: ["immich", "wsl2", "tailscale", "docker-compose", "self-hosting"]
author: "K-Life Hack"
---

## Initializing WSL2 and Docker Desktop Backend for Immich

The deployment of Immich within a Windows 11 environment necessitates a sophisticated virtualization strategy to bridge the gap between Windows-native operations and Linux-centric containerized binaries. The Windows Subsystem for Linux (WSL2) serves as this critical infrastructure, providing a genuine Linux kernel interface that allows Docker containers to achieve near-native execution speeds. Unlike traditional Hyper-V implementations that incur significant overhead, WSL2 utilizes a lightweight utility virtual machine that dynamically shares hardware resources with the host operating system. This architecture is particularly advantageous for resource-constrained hardware such as the Intel N100-based Mini PC, where efficient CPU scheduling and memory management are paramount for maintaining system responsiveness.

Furthermore, the integration of Docker Desktop with the WSL2 backend requires precise configuration to ensure the Docker daemon operates within a specialized Linux distribution. This setup optimizes file system performance, which is often a bottleneck in cross-platform virtualization. Verification of the environment is conducted via the command line interface using `wsl --list --verbose`. If the distribution is not utilizing version 2, immediate remediation is required through the `wsl --update` command. This process ensures the latest kernel patches from Microsoft are applied, followed by a `wsl --shutdown` to force a clean initialization of the virtualized environment.

Quantitatively speaking, memory management represents one of the most significant challenges when running WSL2 on a host with limited RAM. By default, WSL2 can consume a substantial portion of the host's physical memory due to its dynamic allocation logic, potentially leading to "Out of Memory" (OOM) errors in the Windows host environment. To mitigate this, a `.wslconfig` file must be implemented in the user's home directory. For a system equipped with 16GB of RAM, restricting the WSL2 instance to 8GB provides a balanced allocation, ensuring that Immich’s machine learning models and transcoding tasks have sufficient resources without starving the host OS. This proactive resource capping is essential for maintaining 24/7 uptime in a production-grade self-hosted environment.

## Implementing Tailscale Mesh VPN for Secure Remote Access

Establishing secure remote access for Immich without the inherent risks of public port forwarding is achieved through the implementation of Tailscale. This mesh VPN solution leverages the WireGuard protocol to construct an encrypted overlay network, known as a tailnet, which connects disparate devices regardless of their physical location. Each node within the tailnet is assigned a stable, private IP address, typically within the 100.64.0.0/10 range. Consequently, the need for complex Dynamic DNS (DDNS) configurations or vulnerable firewall exceptions is eliminated, as Tailscale facilitates NAT traversal through its coordination server and global DERP (Detour Entrusting Reliable Proxy) relay network.

In addition to simplified connectivity, Tailscale provides a robust security layer by ensuring the Immich API and web interface are only reachable by authenticated devices. The Windows 11 host, acting as the server node, is assigned a static internal address such as <b><mark>100.XX.XX.XX</mark></b>. This address serves as the primary endpoint for mobile clients globally. By utilizing Tailscale’s Access Control Lists (ACLs), administrators can further restrict traffic to the specific Immich service port, effectively minimizing the attack surface and providing a granular security posture that traditional VPNs often lack. This architecture ensures that family members can synchronize media from any cellular or Wi-Fi network without compromising the integrity of the home network.

## Orchestrating Immich Services via Docker Compose

The orchestration of Immich’s microservices architecture is managed through a comprehensive Docker Compose configuration. This stack includes the core server, a microservices worker for background processing, a machine learning engine for image analysis, and a high-performance PostgreSQL database equipped with the `pgvecto-rs` extension. A critical aspect of this deployment on Windows is the translation of file paths. To ensure compatibility with the WSL2 Docker engine, the `.env` file must utilize forward slashes for all directory mappings, such as `C:/immich-server/library`. Failure to adhere to this syntax will result in volume mounting errors and container initialization failures within the Docker daemon.

```yaml
version: "3.8"
services:
  immich-server:
    container_name: immich_server
    image: ghcr.io/immich-app/immich-server:v1.105.1
    volumes:
      - ${UPLOAD_LOCATION}:/usr/src/app/upload
      - /etc/localtime:/etc/localtime:ro
    env_file:
      - .env
    ports:
      - "2283:2283"
    depends_on:
      - redis
      - database
    restart: always

  database:
    container_name: immich_postgres
    image: tensorchord/pgvecto-rs:pg16-v0.2.0
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_USER: ${DB_USERNAME}
      POSTGRES_DB: ${DB_DATABASE_NAME}
    volumes:
      - ${DB_DATA_LOCATION}:/var/lib/postgresql/data
    restart: always
```

The inclusion of the `pgvecto-rs` image is vital for the semantic search and facial recognition features that define the Immich experience. During the initial execution of `docker compose up -d`, the system pulls the necessary images and executes database migrations. Monitoring these logs via `docker compose logs -f` is a mandatory verification step. Any interruption during the database schema initialization will prevent the server from binding to port <b><mark>2283</mark></b>, leading to service unavailability. Furthermore, the Intel N100’s hardware acceleration can be utilized by the machine learning and transcoding services by passing the `/dev/dri` device into the relevant containers, significantly reducing CPU load during heavy processing tasks.

## Integrating Upload Optimizer for Storage Constraint Management

Managing storage constraints on a 1TB SSD requires the integration of an upload optimizer to prevent rapid volume saturation. The `immich-upload-optimizer` functions as a specialized reverse proxy that intercepts incoming media uploads. By analyzing the metadata and file size of incoming multipart/form-data requests, the optimizer can transcode high-bitrate 4K videos or massive RAW images into more efficient formats before they reach the Immich server. This process is handled transparently, ensuring that the mobile user experience remains seamless while significantly extending the longevity of the server's storage hardware.

```yaml
immich-upload-optimizer:
  image: ghcr.io/miguelangel-nubla/immich-upload-optimizer:latest
  ports:
    - "2283:2283"
  environment:
    - IUO_UPSTREAM=http://immich-server:2283
    - IUO_TASKS_IMAGE_MAX_SIZE=4MB
    - IUO_TASKS_VIDEO_MAX_SIZE=40MB
  depends_on:
    - immich-server
  restart: always
```

In this optimized configuration, the direct port mapping for the `immich-server` is removed, and the optimizer assumes control of port 2283. The `IUO_UPSTREAM` variable facilitates internal communication within the Docker network. By leveraging the Intel N100’s QuickSync capabilities, the optimizer can perform hardware-accelerated transcoding using FFmpeg, which minimizes the latency introduced during the upload phase. This architectural choice is particularly effective for multi-user environments where simultaneous uploads from modern smartphones could otherwise overwhelm the server's processing and storage capacity.

## Resolving Environment Variable Syntax and Image Pull Failures

Operational stability in a Windows-based Docker environment often hinges on the precise syntax of environment variables. Docker Compose V2 is notoriously sensitive to formatting within the `.env` file; common errors such as "key cannot contain a space" usually stem from trailing spaces or inline comments. To ensure a successful deployment, the `.env` file must be strictly sanitized to follow the `KEY=VALUE` format. Additionally, network timeouts during the image pull phase can occur due to DNS resolution issues within WSL2. This can be resolved by manually configuring DNS servers in `/etc/wsl.conf` or restarting the Docker Desktop service to refresh the virtual network bridge.

Finally, the portability of the Immich stack is one of its primary advantages. Since all persistent data, including the database and the library, is stored within the `C:\immich-server` directory, disaster recovery is straightforward. Regular backups of this directory allow for rapid migration to new hardware. By simply transferring the folder and executing the Docker Compose commands on a new host, the entire service can be restored with minimal downtime, ensuring that the personal media archive remains secure and accessible over the long term. Verification of the final stack is performed by accessing the Tailscale IP from a remote device, confirming that the network routing and backend services are correctly aligned.