---
title: "GitLab CI and Harbor Registry Integration Pipeline Implementation for Air-Gapped Clusters"
slug: "airgap-gitlab-ci-harbor-pipeline"
date: 2026-11-13T11:32:58+09:00
draft: false
image: ""
description: "A build note for a GitLab CI/CD pipeline targeting an isolated network Kubespray cluster. Details the setup for internal Harbor integration, Dockerfile static validation, automatic tag generation, and blocking external communication by specifying --pull=false."
categories: ["DevOps Logistics"]
tags: ["kubespray", "harbor", "gitlab-ci", "docker-build", "air-gapped"]
author: "K-Life Hack"
---

In air-gapped environments where internet connectivity is restricted or completely disconnected, outbound communication to external public registries (such as Docker Hub or Quay.io) is blocked by firewalls. When operating a Kubernetes cluster using Kubespray in such infrastructure, if container image dependency resolution includes public endpoints, the build pipeline will halt due to timeouts or name resolution errors. To ensure reproducibility in the container build process and eliminate unintended external network requests, a static validation gate with an internal private registry as a prerequisite and a pipeline configuration dedicated to isolated environments are essential.


This article outlines the implementation specifications of a GitLab CI/CD pipeline designed to securely generate, validate, and distribute workload images deployed to a Kubespray cluster, built upon the internal registry "Harbor".



## Overall Pipeline Architecture and Execution Base Parameters

In the target environment, the GitLab Runner itself is placed within the isolated network, constraining target nodes via the <code>docker</code> and <code>offline</code> execution tags. The global configuration used across the entire pipeline is as follows:



```yaml
stages:
  - validate
  - build

variables:
  HARBOR_REGISTRY: "harbor.devstack.co.kr:8443"
  HARBOR_PROJECT: "kubespray"
  IMAGE_NAME: "nginx-app"

image: "$HARBOR_REGISTRY/$HARBOR_PROJECT/ci/docker:29.1.4-cli"
```

### Configuration Parameter Specifications

1. <b><code>stages</code> definition:</b> Composed of <code>validate</code> (a static validation phase to inspect whether the Dockerfile in the repository correctly references the base image from the internal registry) and <code>build</code> (a phase that performs authentication against the internal Harbor, image tag generation based on commit metadata, container image build and push, and environment variable metadata output).


2. <b><code>variables</code> definition:</b> Specifies the private Harbor's FQDN and TLS communication port (<code>harbor.devstack.co.kr:8443</code>) in <code>HARBOR_REGISTRY</code>, and sets the project namespace (<code>kubespray</code>) to isolate and store Kubespray artifacts in <code>HARBOR_PROJECT</code>. Additionally, defines the target workload container image name (<code>nginx-app</code>) in <code>IMAGE_NAME</code>.


3. <b>Execution image (<code>image</code>):</b> The runner container itself does not rely on a public registry and is pulled from <code>harbor.devstack.co.kr:8443/kubespray/ci/docker:29.1.4-cli</code>. Pinning the version to <code>29.1.4-cli</code> prevents build failures caused by behavioral discrepancies in CLI options.



## Detailed Job Design by Stage

### 1. Dockerfile Static Validation Job (`validate:dockerfile`)

Before entering the build process, validate whether unauthorized <code>FROM</code> clauses referencing external registries have been introduced.



```yaml
validate:dockerfile:
  stage: validate
  tags:
    - docker
    - offline
  script:
    - test -f Dockerfile
    - grep -q "$HARBOR_REGISTRY" Dockerfile
    - echo "Dockerfile validation passed"
```

💡 <code>test -f Dockerfile</code> verifies the existence of the Dockerfile in the root directory, and <code>grep -q "$HARBOR_REGISTRY" Dockerfile</code> inspects whether the base image reference line contains <code>harbor.devstack.co.kr:8443</code>. If a statement directly specifying an external repository (e.g., <code>FROM nginx:latest</code>) exists, the exit status becomes non-zero, immediately blocking subsequent build job execution.



### 2. Build and Registry Distribution Job (`build:push`)

Handles container builds, secure credentials delivery, physical suppression of external requests, and pipeline integration of dynamic metadata.



```yaml
build:push:
  stage: build
  tags:
    - docker
    - offline
  before_script:
    - docker version
    - echo "$HARBOR_PASSWORD" | docker login "$HARBOR_REGISTRY" -u "$HARBOR_USER" --password-stdin
  script:
    - |
      if [ -n "$CI_COMMIT_TAG" ]; then
        IMAGE_TAG="$CI_COMMIT_TAG"
      else
        IMAGE_TAG="sha-$CI_COMMIT_SHORT_SHA"
      fi

      IMAGE_URI="$HARBOR_REGISTRY/$HARBOR_PROJECT/$IMAGE_NAME:$IMAGE_TAG"

      echo "IMAGE_TAG=$IMAGE_TAG"
      echo "IMAGE_URI=$IMAGE_URI"

      docker build --pull=false -t "$IMAGE_URI" .
      docker push "$IMAGE_URI"

      echo "IMAGE_TAG=$IMAGE_TAG" &gt; build.env
      echo "IMAGE_URI=$IMAGE_URI" &gt;&gt; build.env
  artifacts:
    reports:
      dotenv: build.env
    expire_in: 7 days
  rules:
    - if: '$CI_COMMIT_BRANCH == "master"'
    - if: '$CI_COMMIT_TAG'
```

#### Technical Implementation Highlights

🛠️ <b>Credential Obfuscation:</b> Uses <code>echo "$HARBOR_PASSWORD" | docker login ... --password-stdin</code> to prevent password exposure via command-line arguments (plaintext output to process trees or Runner logs).


⚙️ <b>Dynamic Tag Logic:</b> When a release tag is created (<code>$CI_COMMIT_TAG</code>), that tag name is used directly. For branch commits, a unique immutable tag in the format <code>sha-&lt;short-hash&gt;</code> is assigned.


⚠️ <b>External Communication Suppression Flag (<code>--pull=false</code>):</b> Standard <code>docker build</code> may query the remote repository for the latest layer even if a local cache exists. Explicitly specifying <code>--pull=false</code> completely blocks delays and timeout errors caused by unnecessary external probe requests in an isolated environment.


📦 <b>Variable Propagation to Downstream Pipelines:</b> Outputs <code>IMAGE_TAG</code> and <code>IMAGE_URI</code> to the <code>build.env</code> file, passing them to subsequent deployment pipelines (such as Kubespray Playbook execution jobs) via GitLab's <code>artifacts:reports:dotenv</code> feature.



## Integrated Configuration File (`.gitlab-ci.yml`)

The complete pipeline configuration integrating all jobs is as follows:



```yaml
stages:
  - validate
  - build

variables:
  HARBOR_REGISTRY: "harbor.devstack.co.kr:8443"
  HARBOR_PROJECT: "kubespray"
  IMAGE_NAME: "nginx-app"

image: "$HARBOR_REGISTRY/$HARBOR_PROJECT/ci/docker:29.1.4-cli"

validate:dockerfile:
  stage: validate
  tags:
    - docker
    - offline
  script:
    - test -f Dockerfile
    - grep -q "$HARBOR_REGISTRY" Dockerfile
    - echo "Dockerfile validation passed"

build:push:
  stage: build
  tags:
    - docker
    - offline
  before_script:
    - docker version
    - echo "$HARBOR_PASSWORD" | docker login "$HARBOR_REGISTRY" -u "$HARBOR_USER" --password-stdin
  script:
    - |
      if [ -n "$CI_COMMIT_TAG" ]; then
        IMAGE_TAG="$CI_COMMIT_TAG"
      else
        IMAGE_TAG="sha-$CI_COMMIT_SHORT_SHA"
      fi

      IMAGE_URI="$HARBOR_REGISTRY/$HARBOR_PROJECT/$IMAGE_NAME:$IMAGE_TAG"

      echo "IMAGE_TAG=$IMAGE_TAG"
      echo "IMAGE_URI=$IMAGE_URI"

      docker build --pull=false -t "$IMAGE_URI" .
      docker push "$IMAGE_URI"

      echo "IMAGE_TAG=$IMAGE_TAG" &gt; build.env
      echo "IMAGE_URI=$IMAGE_URI" &gt;&gt; build.env
  artifacts:
    reports:
      dotenv: build.env
    expire_in: 7 days
  rules:
    - if: '$CI_COMMIT_BRANCH == "master"'
    - if: '$CI_COMMIT_TAG'
```

## Troubleshooting

Documents common failure modes and resolution steps encountered during CI execution in isolated network environments.



### 1. TLS/x509 Certificate Verification Error on Non-Standard Port (8443)

<b>Failure Symptom:</b> If Harbor uses port 8443 and is secured by a self-signed certificate from an internal private certificate authority (CA), executing <code>docker login</code> fails with the following error and halts the job:



```text
Error response from daemon: Get "https://harbor.devstack.co.kr:8443/v2/": x509: certificate signed by unknown authority
```

<b>Resolution Steps:</b> Place the internal root CA certificate on the Docker daemon of the Runner host. Docker automatically references the path <code>/etc/docker/certs.d/&lt;registry-hostname:port&gt;/ca.crt</code>.



```bash
sudo mkdir -p /etc/docker/certs.d/harbor.devstack.co.kr:8443
sudo cp /path/to/internal-ca.crt /etc/docker/certs.d/harbor.devstack.co.kr:8443/ca.crt
sudo systemctl restart docker
```

### 2. Missing Base Layer Error When `--pull=false` Is Specified

<b>Failure Symptom:</b> If <code>--pull=false</code> is specified while the base image referenced in the Dockerfile does not exist in the local cache of the Runner host, the build fails as follows:



```text
ERROR: failed to solve: harbor.devstack.co.kr:8443/kubespray/base-nginx:1.25: not found: image not present locally and --pull=false set
```

<b>Resolution Steps:</b> Add a step in <code>before_script</code> to pre-fetch the necessary base image from Harbor into the local pool before job execution, or explicitly preload the image prior to the initial build.



```bash
docker pull harbor.devstack.co.kr:8443/kubespray/base-nginx:1.25
```

### Execution Verification Log Example

Log output recording authentication and push operations on a successfully executed pipeline node.



```text
$ docker version
Client:
 Version:           29.1.4
 API version:       1.47
 Go version:        go1.22.8
 Git commit:        06f9d74
 Built:             Wed Nov 12 18:22:10 2026
 OS/Arch:           linux/amd64
 Context:           default

Server:
 Engine:
  Version:          29.1.4
  API version:      1.47 (minimum version 1.12)
  Go version:       go1.22.8
  Git commit:       a3f9e2b
  Built:            Wed Nov 12 18:21:45 2026
  OS/Arch:          linux/amd64
  Experimental:     false

$ echo "$HARBOR_PASSWORD" | docker login "$HARBOR_REGISTRY" -u "$HARBOR_USER" --password-stdin
WARNING! Your password will be stored unencrypted in /root/.docker/config.json.
Configure a credential helper to remove this warning. See
https://docs.docker.com/engine/reference/commandline/login/#credentials-store

Login Succeeded

$ IMAGE_TAG="sha-3b8c1a9e"
$ IMAGE_URI="harbor.devstack.co.kr:8443/kubespray/nginx-app:sha-3b8c1a9e"
$ docker build --pull=false -t "$IMAGE_URI" .
[+] Building 1.2s (6/6) FINISHED
 =&gt; [internal] load build definition from Dockerfile
 =&gt; =&gt; transferring dockerfile: 312B
 =&gt; [internal] load metadata for harbor.devstack.co.kr:8443/kubespray/base-nginx:1.25
 =&gt; [1/2] FROM harbor.devstack.co.kr:8443/kubespray/base-nginx:1.25
 =&gt; [2/2] COPY ./html /usr/share/nginx/html
 =&gt; exporting to image
 =&gt; =&gt; exporting layers
 =&gt; =&gt; writing image sha256:7f4a21e69b0dc881cb31e5f84918e9c60e42fbe5aa65825cfd9d06b12a8ff93a
 =&gt; =&gt; naming to harbor.devstack.co.kr:8443/kubespray/nginx-app:sha-3b8c1a9e

$ docker push "$IMAGE_URI"
The push refers to repository [harbor.devstack.co.kr:8443/kubespray/nginx-app]
3f8b091fca1e: Pushed
e6b8b0934c22: Layer already exists
sha-3b8c1a9e: digest: sha256:4d7b29a28e7529841f4812a0f6b3e9491ac9480dcbe82f8a50f3b4dc36f018e6 size: 739
```

## Operational Notes

🛠️ <b>GitLab Runner Tag Management:</b> Ensure Runners in isolated environments are always assigned the <code>docker</code> and <code>offline</code> tags to maintain isolation and prevent build requests from being routed to shared Runners with internet connectivity.


⚠️ <b>dotenv Artifact Expiration:</b> Because <code>expire_in: 7 days</code> is configured, if building pipelines that re-reference metadata from historical jobs older than 7 days, consideration must be given to storing data in an external key-value store or implementing a commit-back mechanism to Git.


💡 <b>Quota Management on Harbor:</b> Untagged intermediate layers and old commit SHA images accumulate easily in Kubespray projects. Therefore, tag retention policies (e.g., retaining the last 20 tags or automatic cleanup after a specified period) must be configured on Harbor.

