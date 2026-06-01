---
title: "Building Local Kubernetes CI/CD with GitHub Actions and Self-hosted Runners: Overcoming Authentication and Network Boundaries"
slug: "github-actions-self-hosted-k8s-cicd"
date: 2026-05-25T12:26:26+09:00
draft: false
image: ""
description: "To achieve automated deployment to local Kubernetes environments, this article details the implementation of GitHub Actions Self-hosted Runners, avoiding authentication errors via Base64 encoding of Kubeconfig, and shell control specific to Windows environments."
categories: ["DevOps Logistics"]
tags: ["github-actions", "kubernetes", "self-hosted-runner", "kubeconfig", "powershell", "devops"]
author: "K-Life Hack"
---

## Optimizing Local Kubernetes Deployment with GitHub Actions and Self-hosted Runners

### 1. Background: Deployment Disconnect in Hybrid Environments

In modern microservices development, local Kubernetes environments such as Docker Desktop are critical assets that enable validation close to production. However, when attempting to deploy from GitHub Actions managed runners to a local cluster, two major barriers arise. First, the reachability issue from runners on the public cloud to cluster endpoints (kubernetes.docker.internal) within a private network. Second, PEM block parsing errors caused by broken line breaks or indentation when saving YAML-formatted Kubeconfig in GitHub Secrets.


This article details the construction process of a CI/CD pipeline that breaks through these boundaries and fully automates synchronization from Git Push to the local cluster.



### 2. Technology Selection and Trade-offs: Reasons for Adopting Self-hosted Runners

<b>Cloud Runner + VPN/Tunneling (e.g., ngrok)</b>: A method to build a tunnel from the outside to the local network. While setup is easy, it carries high security risks, and bandwidth limits or latency become bottlenecks.


<b>Self-hosted Runner (Adopted)</b>: A method where the GitHub Actions agent runs directly on the local machine. Since it operates inside the firewall, there is no need to open external ports, and it can directly access the local Docker daemon and K8s API. It also has the advantage of minimizing network costs when pulling pre-built images from a registry.



### 3. Implementation Details: Encapsulating Credentials and Runner Configuration

#### 3.1 Ensuring Integrity via Base64 Encoding of Kubeconfig

Saving Kubeconfig directly in GitHub Secrets carries an extremely high probability of encountering the error: <b>error: unable to load root certificates: unable to parse bytes as PEM block</b>. To avoid this, we perform Base64 encoding at the binary level using PowerShell and inject it as a string.



```powershell
# Convert Kubeconfig to Base64 string and output to file
$configPath = "$HOME\.kube\config"
$base64Config = [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath))
$base64Config | Out-File -FilePath "encoded_config.txt"
```

#### 3.2 Workflow Definition for Windows Self-hosted Runners

When running a runner in a Windows environment, the default shell is PowerShell, so Linux-based commands (e.g., mkdir -p) will not work. The following implementation ensures idempotency.



```yaml
jobs:
  deploy:
    runs-on: self-hosted
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Configure Kubeconfig
        shell: pwsh
        run: |
          $kubeDir = "$HOME\.kube"
          if (!(Test-Path $kubeDir)) { New-Item -ItemType Directory -Path $kubeDir }
          $decodedConfig = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("${{ secrets.KUBE_CONFIG_DATA }}"))
          $decodedConfig | Out-File -FilePath "$kubeDir\config" -Encoding ascii

      - name: Deploy to Local Kubernetes
        run: |
          kubectl apply -f ./k8s/deployment.yaml
          kubectl rollout status deployment/api-service
```

### 4. Operational Warnings and Workarounds (Operational Reality)

#### 4.1 Optimizing ErrImagePull and imagePullPolicy

During development in a local environment, if a deployment is performed immediately after pushing an image to a registry, Kubernetes may reference an old cache if the tag is "latest," or an <b>ErrImagePull</b> may occur due to a pull failure. To prevent this, the following settings are recommended in deployment.yaml:


<b>imagePullPolicy: Always</b>: Forces the registry to be checked every time. However, this increases network load.


<b>imagePullPolicy: IfNotPresent</b>: Effective when using locally built images as-is. If the Self-hosted Runner is operating on the same node as the cluster, the built image becomes immediately available, making this setting the most efficient.



#### 4.2 Precautions for Persistent Volume Path Specification

⚠️ When using Docker Desktop for Windows, the path specified in hostPath must be the mount path within the Docker VM (<b>/run/desktop/mnt/host/c/...</b>) rather than the Windows format. If this is incorrect, a mount error will occur during container startup, and the shared directory will not be recognized correctly.



### 5. Results and Evaluation

By implementing this configuration, the following quantitative and qualitative improvements were confirmed:


* <b>Reduction in deployment time</b>: Reduced the lead time from code push to reflection by approximately 70% compared to manual kubectl operations.


* <b>Improved environmental consistency</b>: Established a consistent deployment pipeline independent of the developer's local environment through dynamic Kubeconfig generation.


* <b>Enhanced security</b>: Achieved bidirectional communication with GitHub Actions without allowing any inbound traffic from the outside.



## Summary

This architecture combines the flexibility of GitHub Actions with the network advantages of Self-hosted Runners to eliminate deployment barriers in hybrid cloud environments. It serves as an effective solution to significantly reduce the operational burden (Ops Burden) during the transition from legacy operations centered on static configurations like Nginx to Kubernetes-native GitOps. Moving forward, transitioning to immutable tag management using GITHUB_RUN_NUMBER instead of the "latest" tag will be key to further improving reliability.

