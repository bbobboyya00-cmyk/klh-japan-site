---
title: "Configuration Patterns for Keyless Builds Using Docker Buildx Bake SSH Forwarding"
slug: "docker-buildx-bake-ssh-forwarding"
date: 2026-08-07T10:05:58+09:00
draft: false
image: ""
description: "Explains the implementation procedures and troubleshooting for Buildx Bake SSH forwarding to resolve SSH Permission Denied errors during Docker builds and securely pull private repositories without leaving private keys in container images."
categories: ["Linux System Admin"]
tags: ["ssh-key-permission-denied"]
author: "K-Life Hack"
---

In infrastructure automation and containerization workflows, it is common to pull private Git repositories or non-public packages (e.g., npm, Python wheels) within an organization during build time. Conventionally, operational practices involved using <code>COPY</code> or <code>ADD</code> instructions inside a Dockerfile to place SSH private keys directly into the container.


However, even if the key file is deleted in a subsequent build step, the private key remains permanently in the layer history of intermediate images, creating a risk of credential leakage via <code>docker history</code> or layer extraction tools. To bypass these security constraints while resolving <code>Permission denied (publickey)</code> errors, this document outlines configuration methods using the SSH forwarding feature in Docker Buildx Bake.



### SSH Forwarding Mechanism

The Docker Buildx Bake SSH forwarding mechanism temporarily mounts the <code>ssh-agent</code> socket on the host machine only to specific <code>RUN</code> steps during build execution. This completes the cryptographic handshake via the socket without copying the key file itself to the filesystem.



```text
[ Host SSH Agent ] ---&gt; ( UNIX Domain Socket ) ---&gt; [ Build Container Mount ]
                                                        |
                                              [ Git Authentication ]
                                                        |
                                            [ Socket Closed on Exit ]
```

Because the socket mount is unmounted as soon as the build step completes, no SSH key data remains in the final generated image layers.



### Basic Configuration Structure

To enable SSH forwarding, configure both <code>docker-bake.hcl</code> and <code>Dockerfile</code> to work together correctly.



#### 1. docker-bake.hcl

Define the <code>ssh</code> parameter for the target build and specify the default socket binding.



```hcl
target "app" {
  context = "."
  ssh     = ["default"]
}
```

#### 2. Dockerfile

Explicitly append the <code>--mount=type=ssh</code> option to the <code>RUN</code> instruction requiring SSH connection.



```dockerfile
FROM alpine:3.19

RUN apk add --no-cache git openssh-client

# Mount SSH socket to clone the private repository
RUN --mount=type=ssh \
    git clone git@github.com:company/private-repository.git /app
```

### Execution Steps in a Local Environment

🛠️ When executing builds in a host environment, <code>ssh-agent</code> must be running and the target key must be added.



```bash
# 1. Start SSH Agent
eval $(ssh-agent -s)

# 2. Add private key
ssh-add ~/.ssh/id_rsa

# 3. Verify registered keys
ssh-add -l

# 4. Run Bake command
docker buildx bake app
```

### Application to Package Manager Dependencies

This approach applies not only to <code>git clone</code>, but also to the installation process of private dependency packages retrieved via SSH.



```dockerfile
FROM node:20-slim

RUN apt-get update &amp;&amp; apt-get install -y --no-install-recommends git openssh-client \
    &amp;&amp; rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/app

# Install package from private repository via npm
RUN --mount=type=ssh \
    npm install git+ssh://git@github.com:company/private-pkg.git
```

### Integration with CI/CD Pipelines

In automated CI/CD environments, keys are not placed directly in the repository; instead, they are dynamically injected into <code>ssh-agent</code> from pipeline secret variables.



#### GitHub Actions Integration Example

```yaml
name: Build Container Image

on:
  push:
    branches: [ "main" ]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Setup SSH Keys
        uses: webfactory/ssh-agent@v0.9.0
        with:
          ssh-private-key: ${{ secrets.SSH_PRIVATE_KEY }}

      - name: Build with Buildx Bake
        run: |
          docker buildx bake app
```

#### GitLab CI Integration Example

```yaml
build_job:
  stage: build
  image: docker:24.0.7
  services:
    - docker:24.0.7-dind
  before_script:
    - eval $(ssh-agent -s)
    - echo "$SSH_PRIVATE_KEY" | tr -d '' | ssh-add -
  script:
    - docker buildx bake app
```

## Troubleshooting

⚠️ Key errors encountered in practice, along with their causes and resolution workflows, are summarized below.



| Error Symptom | Primary Cause | Verification Command / Resolution |
| :--- | :--- | :--- |
| `Permission denied (publickey)` | Key not registered in host `ssh-agent`, or improper public key configuration on the Git service side | Check key existence with `ssh-add -l`, then execute `ssh-add ~/.ssh/id_rsa` |
| `SSH_AUTH_SOCK`-related error | Agent process is not running on the host | Verify if `echo $SSH_AUTH_SOCK` outputs a value, then re-execute `eval $(ssh-agent -s)` |
| `git: command not found` or `ssh: command not found` | `git` or `openssh-client` packages are not installed in the container image | Add packages using `apt` or `apk` during the base image preparation phase in the Dockerfile |

### System Verification Protocol Logs

Example terminal log output demonstrating operational verification during build execution and proving that no key data is contained in the final image.



```text
$ ssh-add -l
2048 SHA256:abc123xyz890... /home/user/.ssh/id_rsa (RSA)

$ docker buildx bake app
[+] Building 4.2s (8/8) FINISHED
 =&gt; [internal] load build definition from Dockerfile                              0.0s
 =&gt; =&gt; transferring dockerfile: 210B                                              0.0s
 =&gt; [internal] load .dockerignore                                                 0.0s
 =&gt; =&gt; transferring context: 2B                                                   0.0s
 =&gt; [internal] load metadata for docker.io/library/alpine:3.19                    1.1s
 =&gt; [1/3] FROM docker.io/library/alpine:3.19@sha256:c5b54...                     0.0s
 =&gt; [2/3] RUN apk add --no-cache git openssh-client                               1.8s
 =&gt; [3/3] RUN --mount=type=ssh git clone git@github.com:company/private-repo.git  1.2s
 =&gt; exporting to image                                                            0.1s
 =&gt; =&gt; exporting layers                                                           0.1s
 =&gt; =&gt; writing image sha256:8f431a...                                             0.0s

$ docker run --rm -it app:latest ls -la /root/.ssh
ls: /root/.ssh: No such file or directory
```

## Operational Notes

🛠️ <b>1. Apply the Principle of Least Privilege</b>: For SSH keys injected into CI/CD environments, configure Deploy Keys granted read-only access to specific repositories rather than personal private keys.


⚠️ <b>2. Standardize Protocols</b>: Always use the SSH format (<code>git@...</code>) instead of the HTTP(S) format (<code>https://...</code>) for repository specifications in Dockerfiles.


💡 <b>3. Agent Cleanup</b>: After completing work in local development host environments, adopting the habit of purging private key memory from the Agent using <code>ssh-add -D</code> is recommended.

