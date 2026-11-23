---
title: "Migrating to a Self-Hosted Runner on AWS Lightsail and Building an Inbound-Private CD Pipeline"
slug: "aws-lightsail-github-actions-selfhosted-runner-cd"
date: 2026-11-23T11:26:45+09:00
draft: false
image: ""
description: "Records the migration procedure and verification results for closing inbound Port 22 and establishing a secure CD pipeline using a GitHub Actions Self-Hosted Runner in an AWS Lightsail environment."
categories: ["DevOps Logistics"]
tags: ["github-actions-self-hosted-runner-proxy"]
author: "K-Life Hack"
---

In infrastructure scaling and operational automation, decoupling the update cycles of application code and machine learning models, as well as minimizing inbound access permissions during deployment, are critical design elements. In conventional configurations where application code and model binaries are packaged together in the same Docker image, rebuilds occur even during model-only updates, creating a problem of increased container image delivery costs.


Furthermore, in architectures where deployments are executed from a CI/CD pipeline to a production server via SSH, the SSH port (Port 22) must be fully opened (0.0.0.0/0) to accommodate managed runners with dynamically changing IP addresses, incurring significant security risks.


This article records the version decoupling design between code and model, the migration procedure from external SSH connection deployment (Stage 1) to outbound-only deployment using a Self-Hosted Runner (Stage 2), and the troubleshooting logs encountered for the <code>eta-mini</code> service running on AWS Lightsail.



## 1. Code and Model Decoupling Architecture

The retraining cycle of machine learning models occurs at a higher frequency than application logic modifications. To address this asymmetry in lifecycles, a decoupled design is adopted to completely sever the dependency between container images and model binaries.



* <b>Application Code Version (`v1.x`)</b>: Triggered by pushing a Git semantic tag, a container image is built and pushed to GHCR (GitHub Container Registry).
* <b>Model Version (`m<yyyymmdd>-<seq>`)</seq></yyyymmdd></b>: Model files are not baked into the container image; instead, they are placed in persistent storage on the host server (`/srv/eta/models/`) and volume-mounted as read-only (`:ro`) upon container startup.

The container exposes a <code>/health</code> endpoint structured to dynamically return the consistency of the currently loaded application version and model version.



```json
{
  "status": "ok",
  "model": "onnx",
  "app_version": "v1.0",
  "model_version": "baked"
}
```

When <code>model_version</code> in the response indicates <code>baked</code>, it means the default initial model embedded in the image is applied.



## 2. Stage 1: Limitations of SSH Connection Deployment

In the initial operational phase (Stage 1), a push-based configuration was used where GitHub-hosted runners connected via SSH to an instance on AWS Lightsail to execute deployment scripts.



### Stage 1 Deployment Script (`server.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="/srv/eta"
ENV_FILE="${TARGET_DIR}/.env"

COMMAND="${1:-}"
TAG_NAME="${2:-}"

if [ "${COMMAND}" = "image" ]; then
  if [ -z "${TAG_NAME}" ]; then
    echo "Error: Tag name is required."
    exit 1
  fi

  PREV_TAG=$(grep -E '^TAG=' "${ENV_FILE}" | cut -d'=' -f2 || true)
  echo "Updating TAG to ${TAG_NAME}..."
  sed -i "s/^TAG=.*/TAG=${TAG_NAME}/" "${ENV_FILE}"

  docker compose -f "${TARGET_DIR}/compose.yml" pull
  docker compose -f "${TARGET_DIR}/compose.yml" up -d

  # Rollback determination based on health check
  sleep 5
  HEALTH_STATUS=$(curl -s http://localhost:8080/health | grep -o '"status":"ok"' || true)
  if [ -z "${HEALTH_STATUS}" ]; then
    echo "Health check failed. Rolling back to ${PREV_TAG}..."
    sed -i "s/^TAG=.*/TAG=${PREV_TAG}/" "${ENV_FILE}"
    docker compose -f "${TARGET_DIR}/compose.yml" up -d
    exit 1
  fi
fi
```

### Stage 1 Security Issues

⚠️ <b>Architectural Risks and Limitations:</b>
* <b>Enforced Opening to All IPs</b>: Because the source IP range of GitHub-hosted runners is variable, Port 22 must be constantly kept open to <code>0.0.0.0/0</code> in Lightsail firewall rules.
* <b>Retention of Secrets</b>: There is an operational risk in continuously storing the host's SSH private key (<code>LIGHTSAIL_SSH_KEY</code>) on the external CI/CD service.
* <b>TOFU Pattern Risk</b>: Specifying <code>StrictHostKeyChecking=accept-new</code> when establishing a connection restricts strict verification against Man-In-The-Middle (MITM) attacks.

## 3. Stage 2: Migration to Self-Hosted Runner and Inbound Closure

To fundamentally eliminate security risks in inbound access, the architecture is migrated to a pull-based model where the target server itself is registered as a GitHub Actions Self-Hosted Runner. Outbound long polling is performed from the server to GitHub via HTTPS (Port 443), making external inbound port openings entirely unnecessary.



### Self-Hosted Runner Agent Configuration

Execute the following commands on the host server (Amazon Linux 2023) to complete registration of the Runner agent and start it as a systemd service.



```bash
# Runner setup and label assignment
./config.sh --url https://github.com/<username>/eta-mini-aws \
  --token <registration_token> \
  --name eta-mini \
  --labels lightsail \
  --unattended

# Run persistently as a systemd service
sudo ./svc.sh install ec2-user
sudo ./svc.sh start
```

### Workflow Configuration Modification (`.github/workflows/deploy.yml`)

Change the execution environment label of the deployment job from <code>ubuntu-latest</code> to <code>[self-hosted, lightsail]</code> to switch to direct local shell execution. Add <code>concurrency</code> control to prevent resource contention caused by parallel execution of identical definitions.



```yaml
name: CD Pipeline

on:
  push:
    tags:
      - 'v*'

jobs:
  deploy:
    runs-on: [self-hosted, lightsail]
    concurrency:
      group: lightsail-deploy
      cancel-in-progress: false
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Sync configuration files
        run: |
          cp compose.yml /srv/eta/compose.yml
          cp server.sh /srv/eta/server.sh
          chmod +x /srv/eta/server.sh

      - name: Execute deployment script
        run: |
          echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u "${{ github.actor }}" --password-stdin
          /srv/eta/server.sh image "${{ github.ref_name }}"
```

## Troubleshooting

### 1. Runner Registration Token Expiration
🛠️ <b>Symptom and Countermeasure:</b>
* <b>Symptom</b>: Registration fails when executing <code>./config.sh</code> due to <code>HTTP 404 Not Found</code> or an authentication error.
* <b>Cause</b>: Activation tokens issued from the GitHub UI/API automatically expire 1 hour after generation.
* <b>Countermeasure</b>: Promptly execute the setup script after token issuance, or build a script that uses the GitHub API to dynamically reissue tokens automatically.

### 2. Registration Failure Due to Missing Linux Dependency Libraries

🛠️ <b>Symptom and Countermeasure:</b>
* <b>Symptom</b>: When executing <code>./config.sh</code> in an Amazon Linux 2023 environment, shared libraries such as <code>libicu</code> are not found and the process terminates abnormally.
* <b>Cause</b>: Minimal OS images do not include system libraries required for dynamic linking of the .NET Core runtime.
* <b>Countermeasure</b>: Add pre-installation tasks for dependent packages in the UserData (Launch Script) during instance startup.

```bash
#!/usr/bin/env bash
# Install required packages: libicu, digest-shasum, and docker
sudo dnf install -y libicu digest-shasum docker
# Enable and start the docker service
sudo systemctl enable --now docker
# Add the ec2-user to the docker group to allow non-root execution
sudo usermod -aG docker ec2-user
```

### 3. Failure of Local Mutual Exclusion Control Due to Concurrent Tag Pushes

🛠️ <b>Symptom and Countermeasure:</b>
* <b>Symptom</b>: When multiple Git tags are pushed consecutively, rewrite operations on <code>/srv/eta/.env</code> contend, resulting in an invalid container startup state.
* <b>Cause</b>: Deployment jobs referencing the same host resources were executed concurrently on the Self-Hosted Runner.
* <b>Countermeasure</b>: Appropriately define the <code>concurrency</code> attribute in GitHub Actions to serialize and execute jobs exclusively per target deployment group.

### 4. Deployment Inability Caused by Deleting Credentials Mid-Migration

🛠️ <b>Symptom and Countermeasure:</b>
* <b>Symptom</b>: Premature deletion of GitHub Secrets (<code>LIGHTSAIL_SSH_KEY</code>) before completing the switch to Stage 2 renders rollback impossible.
* <b>Countermeasure</b>: Confirm from execution logs that deployment via a new tag (e.g., <code>v1.1</code>) has succeeded completely via the Self-Hosted Runner before gradually deleting or updating secrets and Port 22 firewall rules from the old environment.

## 4. Network Isolation and Operation Verification

After completing the migration to Stage 2, external access to Port 22 (SSH) on the host is blocked, and final operational verification of the deployment pipeline is performed.



```text
$ ssh -i eta-deploy.pem ec2-user@54.250.x.x
ssh: connect to host 54.250.x.x port 22: Connection timed out

$ curl -s http://54.250.x.x/health
{"status":"ok","model":"onnx","app_version":"v1.1","model_version":"baked"}

$ sudo systemctl status Actions-Runner-Service
● Actions-Runner-Service.service - GitHub Actions Runner (eta-mini)
     Loaded: loaded (/etc/systemd/system/Actions-Runner-Service.service; enabled; preset: disabled)
     Active: active (running) since Mon 2026-11-23 10:15:22 KST; 2h ago
   Main PID: 14205 (Runner.Listener)
      Tasks: 18 (limit: 2282)
     Memory: 48.2M


外部端末からのSSH直接接続はタイムアウトとなり、ポートが遮断されていることが実証されました。同時に、`/health` エンドポイントからは更新された `app_version: v1.1` が正常に応答されています。

## Lessons Learned

1. **インバウンドアクセス全廃による攻撃対象領域の縮小**: デプロイ基盤をアウトバウンドのポーリング型（Self-Hosted Runner）へ変更したことで、本番サーバーのSSHポートをインターネットに露出させるリスクを排除できました。
2. **コンテナとモデルバイナリの疎結合化**: アプリケーションコード（`v1.x`）とモデル（`m<date>`）のデプロイラインを分離したことで、無駄なコンテナイメージリビルドを防ぎ、帯域転送コストとデプロイ時間を削減できました。
3. **ローカル実行に伴う排他制御の必須化**: Self-Hosted Runnerを同一ノードで運用する場合、ホスト側の設定ファイルやDockerデーモンへのアクセス競合を防止するため、ワークフロー側での `concurrency` 制御が不可欠です。</date></registration_token></username>