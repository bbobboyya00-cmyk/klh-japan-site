---
title: "Implementation of Automated Continuous Deployment Using GitHub Actions and SSH"
slug: "github-actions-ssh-cd-automation"
date: 2026-07-21T10:17:23+09:00
draft: false
image: ""
description: "This guide explains how to build an automated pipeline using GitHub Actions and SSH to eliminate human errors in manual deployment. It provides an implementation guide that balances security and maintainability."
categories: ["DevOps Logistics"]
tags: ["github-actions", "ssh-deploy", "cd-pipeline", "devops", "automation"]
author: "K-Life Hack"
---

# Building an SSH-Based Automated Deployment Pipeline Using GitHub Actions

As infrastructure scales, manual SSH connections and command execution become significant bottlenecks that induce human error. Especially in environments where the number of nodes increases and deployment frequency rises, operational mistakes such as incorrect directory specification, failure to apply environment variables, or forgetting to restart services directly lead to unexpected downtime. This article details a method for building a secure and lightweight SSH-based automated deployment pipeline using GitHub Actions while avoiding the overhead of operating a dedicated CI/CD server.



## 1. Deployment Architecture Design

In remote server deployment, the most versatile and lightweight method is command execution via SSH (Secure Shell). This configuration adopts a structure where the GitHub Actions runner establishes a secure tunnel to the target server and kicks off a pre-defined deployment script.



```text
[Developer Push to 'test' Branch]
               │
               ▼
     [GitHub Actions Runner]
               │
       (SSH Connection)
               │
               ▼
     [Target Remote Server]
               │
     (Executes deploy.sh)
               │
               ▼
     [Deployment Completed]
```

## 2. Server-Side Preparation

Before operating the automated pipeline, configuration is required on the target server side to accept secure connections.



### SSH Authentication Configuration

To allow access from the GitHub Actions runner, generate a key pair using the Ed25519 algorithm and register the public key in the server's ~/.ssh/authorized_keys.



```bash
# Generate key pair
ssh-keygen -t ed25519 -C "github-actions-deploy"

# Register public key (server side)
cat id_ed25519.pub &gt;&gt; ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

### Implementation of the Deployment Script (deploy.sh)

Instead of writing complex logic within the GitHub Actions YAML file, maintainability is improved by placing an execution script on the server side.



```bash
#!/bin/bash
set -e # Exit immediately if an error occurs

PROJECT_DIR="/var/www/my-app"
cd $PROJECT_DIR

echo "Fetching latest changes from origin..."
git fetch origin test
git reset --hard origin/test

echo "Installing dependencies..."
npm install --production

echo "Building application..."
npm run build

echo "Restarting application service..."
pm2 reload my-app || pm2 start dist/index.js --name "my-app"

echo "Deployment successfully completed!"
```

## 3. Managing Sensitive Information with GitHub Secrets

To ensure security, server IP addresses and SSH private keys must not be included in the codebase. Register variables in Settings &gt; Secrets and variables &gt; Actions of the GitHub repository.



| Secret Name | Description |
| :--- | :--- |
| `SSH_HOST` | Target server's public IP or domain |
| `SSH_USERNAME` | Username dedicated to deployment |
| `SSH_KEY` | Full text of the generated SSH private key |
| `SSH_PORT` | SSH connection port (default is 22) |

## 4. Workflow Definition (YAML)

Create .github/workflows/deploy.yml and define a pipeline that executes deployment triggered by a push to a specific branch.



```yaml
name: Continuous Deployment to Test Environment

on:
  push:
    branches:
      - test

jobs:
  deploy:
    name: Execute Remote SSH Deployment
    runs-on: ubuntu-latest

    steps:
      - name: Checkout Repository Code
        uses: actions/checkout@v4

      - name: Execute Remote Commands via SSH
        uses: appleboy/ssh-action@v1.0.3
        with:
          host: ${{ secrets.SSH_HOST }}
          username: ${{ secrets.SSH_USERNAME }}
          key: ${{ secrets.SSH_KEY }}
          port: ${{ secrets.SSH_PORT }}
          script_stop: true
          script: |
            echo "Successfully connected to remote host."
            cd /var/www/my-app
            chmod +x deploy.sh
            ./deploy.sh
```

## 5. Troubleshooting &amp; Verification

After deployment completion, execute verification commands to confirm the system is operating normally. In particular, if SSH connection timeouts or permission errors occur, check log protocols for diagnostic information.



```text
# Check service running status
$ pm2 status

# Check port listening status
$ ss -tulpn | grep :3000

# Check application response
$ curl -I http://localhost:3000
HTTP/1.1 200 OK
X-Powered-By: Express
Content-Type: text/html; charset=utf-8
```

### Common Failure Cases and Countermeasures

<b>Permission Denied</b>: Occurs when the deployment user does not have write permissions for PROJECT_DIR. Set appropriate ownership using the chown command.


<b>SSH Timeout</b>: The server-side firewall (UFW/iptables) may not be allowing the GitHub Actions IP range or the specific port.


<b>Sudo Password Requirement</b>: If sudo is required for service restarts, the pipeline will stop at the password prompt. Avoid this by adding NOPASSWD settings to /etc/sudoers.



```bash
# Configuration example for /etc/sudoers
deploy-user ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart my-app-service
```

## 6. Operational Notes

Three points are recommended as design guidelines when introducing automation.


1. 💡 <b>Principle of Least Privilege (PoLP)</b>: Do not use the root user for deployment; create a dedicated user with limited permissions.


2. 🛠️ <b>Decoupling Scripts</b>: By encapsulating deployment logic in a shell script on the server rather than writing it directly in the YAML, operations become independent of the CI tool.


3. ⚠️ <b>Private Key Rotation</b>: Establish an operational flow to periodically update private keys registered in GitHub Secrets to minimize the risk in the event of a leak.


Implementing SSH deployment via GitHub Actions is an extremely effective approach to improving release reliability while minimizing infrastructure management overhead.

