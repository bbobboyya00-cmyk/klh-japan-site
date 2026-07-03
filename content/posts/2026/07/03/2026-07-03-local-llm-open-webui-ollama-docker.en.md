---
title: "Construction of a Local LLM Infrastructure Using Open WebUI and Ollama in a Docker Environment"
slug: "local-llm-open-webui-ollama-docker"
date: 2026-07-03T10:52:55+09:00
draft: false
image: ""
description: "An implementation note explaining the integration procedures for Open WebUI and Ollama using Docker, GPU optimization, and troubleshooting inter-container communication."
categories: ["DevOps Logistics"]
tags: ["ollama", "open-webui", "docker-container", "gpu-acceleration", "llm-infrastructure"]
author: "K-Life Hack"
---

## Local LLM Infrastructure: Integrating Ollama and Open WebUI via Docker

In the operation of Large Language Models (LLMs) within local environments, direct library installation on the host OS presents a high risk of dependency conflicts and GPU driver inconsistencies. Environment isolation and reproducibility are critical during research and development phases involving multiple models. This technical log details the methodology for integrating the Ollama inference engine with Open WebUI using Docker containers to establish a secure, portable private AI infrastructure.



## Rationality of Configuration and Significance of Containerization

Deploying Open WebUI via Docker is a standard practice in infrastructure management rather than a mere convenience. Containerization facilitates the management of persistent data volumes and secure access to inference endpoints through the host gateway without compromising the host-side network stack or file system. This approach ensures a scalable interface while preventing configuration errors that might necessitate OS reinstallation.



## Deployment Workflow

### 1. Preparation of Docker Runtime and Verification of Virtualization

Verify the correct operation of the container runtime. In Windows environments, the WSL2 (Windows Subsystem for Linux) backend is mandatory.



*   💡 <b>Enabling Virtualization:</b> Ensure Virtualization Technology (VT-x or AMD-V) is enabled in BIOS/UEFI settings. Docker Engine initialization will fail if this is disabled.
*   🛠️ <b>Binary Verification:</b> Execute terminal commands to confirm path configurations.

```bash
docker --version
```

### 2. Running the Open WebUI Container

With the Ollama service active on the host machine, initiate Open WebUI. Network flags for host-to-container communication are essential for establishing the API bridge.



```bash
docker run -d -p 3000:8080 \
  --add-host=host.docker.internal:host-gateway \
  -v open-webui:/app/backend/data \
  --name open-webui \
  --restart always \
  ghcr.io/open-webui/open-webui:main
```

<b>Technical Explanation of Key Parameters:</b>

*   <b>-p 3000:8080:</b> Maps host port 3000 to container port 8080.
*   <b>--add-host=host.docker.internal:host-gateway:</b> Establishes a bridge to access the host-side Ollama API from within the container environment.
*   <b>-v open-webui:/app/backend/data:</b> Defines a named volume for persistent chat history and user settings, ensuring data survival across container lifecycles.
*   <b>--restart always:</b> Ensures automatic container recovery upon system reboot or unexpected process termination.

## Integration with Ollama and Model Management

Access port 3000 via a web browser and configure an administrator account. Data is stored locally in SQLite or PostgreSQL, ensuring no external leakage of sensitive prompts.



*   <b>Connection Verification:</b> Validate the Ollama connection status in the settings menu via the host.docker.internal endpoint.
*   <b>Pulling Models:</b> Download required models (e.g., llama3:8b) through the UI. The Llama 3 8B model requires approximately 4.7GB of storage.

## Troubleshooting

Common operational friction points and their respective technical solutions:



*   ⚠️ <b>Port Conflict (Port 3000):</b> If port 3000 is occupied by another service, modify the host-side port mapping (e.g., -p 3001:8080).
*   ⚠️ <b>Connection Refused:</b> If Open WebUI cannot reach Ollama, ensure the host-side Ollama service allows external connections by setting the environment variable OLLAMA_HOST=0.0.0.0.
*   ⚠️ <b>GPU Offload Failure:</b> Low inference speeds (1-2 tokens/s) indicate insufficient VRAM or CPU-only operation. Verify "Dedicated GPU Memory" in Task Manager. An 8B model is recommended for 8GB VRAM; 70B models require 16GB or more for stable performance.

## Verification of Operational Status

Confirm container integrity and network connectivity to ensure the infrastructure is ready for inference tasks.



```text
# Check container status
$ docker ps --filter "name=open-webui"
CONTAINER ID   IMAGE                                COMMAND                  STATUS          PORTS                    NAMES
7f8e9d0c1b2a   ghcr.io/open-webui/open-webui:main   "/app/backend/start.…"   Up 15 minutes   0.0.0.0:3000-&gt;8080/tcp   open-webui

# Check host port listening status
$ ss -tulpn | grep :3000
tcp   LISTEN 0      4096            0.0.0.0:3000       0.0.0.0:*    users:(("docker-proxy",pid=1234,fd=4))

# Verify connectivity to the API endpoint
$ curl -I http://localhost:3000
HTTP/1.1 200 OK
Content-Type: text/html; charset=utf-8
Content-Length: 1234
```

## Operational Notes

Building a local LLM environment provides significant security advantages, enabling the processing of confidential code and internal documents offline while eliminating subscription costs. Docker provides an abstraction layer that simplifies future hardware upgrades and migrations. In environments with 16GB+ VRAM, Llama 3 70B class models can operate at practical speeds for advanced inference tasks, fully contained within the private network.

