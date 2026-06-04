---
title: "Implementation of Kubernetes Deployment Automation with GitHub Actions and Self-Hosted Runners"
slug: "github-actions-k8s-self-hosted-runner"
date: 2026-06-04T18:02:35+09:00
draft: false
image: ""
description: "This article explains the process of implementing automated deployment to a local Kubernetes environment using GitHub Actions and Self-Hosted Runners, covering practical troubleshooting such as PEM parsing errors and network resolution."
categories: ["DevOps Logistics"]
tags: ["github-actions", "kubernetes", "self-hosted-runner", "ci-cd", "docker-desktop"]
author: "K-Life Hack"
---

## 1. Overview and Purpose

The objective is to construct a CI/CD pipeline integrating GitHub Actions with a local Kubernetes environment to automate the transition from source code push to deployment. This workflow eliminates manual intervention and executes automated rolling updates.


<b>Target Workflow:</b>
1. Git Push: Developer pushes code to the master branch.


2. Docker Build: GitHub Actions triggers the container image build.


3. Docker Push: The built image is pushed to a registry such as DockerHub.


4. Kubernetes Update: The cluster pulls the new image and executes a rolling update.



## 2. Establishing Kubernetes Connection and Authentication Settings

Defining appropriate authentication credentials (kubeconfig) is essential to allow GitHub Actions to operate the cluster from external environments.



### 2.1 Kubeconfig Extraction

Verify the current connection information in the local environment and extract the necessary data.



```bash
kubectl config view
```

The YAML structure includes the cluster server URL, certificate data, and user context. Registering this in GitHub Secrets requires caution to avoid PEM block parsing errors caused by line break codes or indentation issues.



### 2.2 Data Protection via Base64 Encoding

To maintain the integrity of certificate data, the kubeconfig file is encoded in Base64 before registration in GitHub Secrets.



```powershell
# Execution example in Windows PowerShell environment
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\Users\Administrator\.kube\config"))
```

The resulting string is stored in the GitHub repository under Settings &gt; Secrets and variables &gt; Actions as KUBE_CONFIG. <b>Base64 encoding</b> prevents binary data corruption in CI environments.



## 3. Workflow Definition and Troubleshooting

### 3.1 Initial Workflow Configuration (.github/workflows/docker-build.yml)

The initial definition ensures consistent execution of image building, pushing, and deployment.



```yaml
name: Build and Deploy
on:
  push:
    branches:
      - master

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Docker Login
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKER_USERNAME }}
          password: ${{ secrets.DOCKER_PASSWORD }}

      - name: Build Docker Image
        run: |
          docker build -t ${{ secrets.DOCKER_USERNAME }}/my-tomcat:latest .

      - name: Push Docker Image
        run: |
          docker push ${{ secrets.DOCKER_USERNAME }}/my-tomcat:latest

      - name: Set kube config
        run: |
          mkdir -p ~/.kube
          echo "${{ secrets.KUBE_CONFIG }}" | base64 -d &gt; ~/.kube/config

      - name: Deploy to Kubernetes
        run: |
          kubectl rollout restart deployment tomcat-deployment
```

### 3.2 Resolving PEM Parsing Errors

If the error "unable to load root certificates: unable to parse bytes as PEM block" occurs, the decoded file format from Secrets is likely invalid. Applying Base64 encoding and restoring it via base64 -d within the workflow reliably avoids this issue.



## 4. Introduction of Self-Hosted Runners

### 4.1 Network Boundary Issues

GitHub-hosted runners (ubuntu-latest) fail to resolve the name for Docker Desktop on local environments (kubernetes.docker.internal), resulting in connection errors.



```text
Unable to connect to the server: dial tcp: lookup kubernetes.docker.internal: no such host
```

A <b>Self-Hosted Runner</b> operating within the local network enables direct access to internal resources.



### 4.2 Installation Steps for Windows

Select New self-hosted runner from Settings &gt; Actions &gt; Runners. Specify Windows as the OS and execute the PowerShell script to configure the runner.



```powershell
# Runner placement and configuration
mkdir actions-runner; cd actions-runner
# (Execute configuration using the token provided by GitHub)
.\config.cmd --url https://github.com/[USER]/[REPO] --token [TOKEN]
.\run.cmd
```

### 4.3 Modifying the Workflow

Change the runner specification to self-hosted to enable job execution in the local environment.



```yaml
runs-on: self-hosted
```

## 5. Command Compatibility in Cross-Platform Environments

Standard Linux commands like mkdir -p may fail on Windows runners. Adjusting steps to match PowerShell syntax eliminates environment-dependent errors.



```yaml
- name: Set kube config
  shell: powershell
  run: |
    if (!(Test-Path "$HOME\.kube")) {
      New-Item -ItemType Directory -Path "$HOME\.kube"
    }
    [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("${{ secrets.KUBE_CONFIG }}")) | Out-File "$HOME\.kube\config"
```

## 6. Analysis of ErrImagePull and Manifest Adjustments

If a Pod enters the ErrImagePull state, verify the registry push status and the pull policy. If imagePullPolicy: Always is set, the system attempts to retrieve the image from the external registry even if it exists locally.


To prioritize locally cached images in a development environment, modify the Deployment manifest.



```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tomcat2-deployment
spec:
  template:
    spec:
      containers:
      - name: tomcat
        image: abungard/my-tomcat:latest
        imagePullPolicy: IfNotPresent
```

## 7. Conclusion and Future Outlook

Protecting certificate data with Base64 is an effective method for preventing authentication errors in CI environments. Self-Hosted Runners are indispensable for ensuring network reachability when deploying to local environments. Future improvements include transitioning from latest tags to Git SHAs and introducing GitOps tools such as ArgoCD.

