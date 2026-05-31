---
title: "Troubleshooting Errors in Kubernetes Deployment Automation with GitHub Actions and Windows Self-Hosted Runner"
slug: "github-actions-windows-runner-kubernetes"
date: 2026-05-22T13:53:13+09:00
draft: false
image: ""
description: "Steps to resolve PEM block parsing errors, DNS resolution failures, and PowerShell syntax errors during Kubernetes deployment using GitHub Actions integrated with a Windows Self-Hosted Runner."
categories: ["DevOps Logistics"]
tags: ["github-actions", "kubernetes", "self-hosted-runner", "powershell", "kubeconfig"]
author: "K-Life Hack"
---

## 🛠️ Resolving Kubeconfig PEM Block Parsing Error (unable to parse bytes as PEM block)

The following error occurred during authentication with the Kubernetes cluster when running the GitHub Actions workflow:



```
error: unable to load root certificates: unable to parse bytes as PEM block
Error: Process completed with exit code 1.
```

### Cause

When copying and pasting the YAML text of the local <b><mark>kubeconfig</mark></b> file directly into GitHub Secrets, line ending mismatches (\n vs \r\n), indentation issues, or truncation of the Base64-encoded certificate data occurred, causing the certificate data (PEM format) parsing to fail.



### Resolution

To prevent data corruption, encode the Windows environment's kubeconfig file into a Base64 string before registering it in GitHub Secrets.


1. Open PowerShell on Windows and run the following command to Base64-encode the kubeconfig:



```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\Users\Administrator\.kube\config"))
```

Copy the outputted single-line long Base64 string.


2. In the GitHub repository, go to "Settings" -&gt; "Secrets and variables" -&gt; "Actions", delete the existing `KUBE_CONFIG`, and register the copied Base64 string as the new value.


3. Modify the decoding process in the workflow file (`.github/workflows/docker-build.yml`) as follows:



```yaml
      - name: Set kube config
        run: |
          mkdir -p ~/.kube
          echo "${{ secrets.KUBE_CONFIG }}" | base64 -d &gt; ~/.kube/config
```

---

## 🛠️ Resolving DNS Resolution Failure from Cloud Runner (kubernetes.docker.internal:6443: no such host)

After resolving the certificate error, the following network timeout and DNS resolution error occurred during the deployment step:



```
E0528 01:43:09.437587    2260 memcache.go:265] "Unhandled Error" err="couldn't get current server API group list: Get \"https://kubernetes.docker.internal:6443/api?timeout=32s\": dial tcp: lookup kubernetes.docker.internal on 127.0.0.53:53: no such host"
Unable to connect to the server: dial tcp: lookup kubernetes.docker.internal on 127.0.0.53:53: no such host
```

### Cause

The standard GitHub Actions hosted runner (`runs-on: ubuntu-latest`) runs on a cloud virtual machine provided by GitHub. Consequently, it cannot resolve `kubernetes.docker.internal`, which is the private DNS of the local development environment (Docker Desktop), and cannot route to the local Kubernetes API server.



### Resolution

To directly access resources within the local network, set up a <b><mark>Self-Hosted Runner</mark></b> on the local machine.


1. In the GitHub repository, go to "Settings" -&gt; "Actions" -&gt; "Runners", select "New self-hosted runner", and specify "Windows" as the OS.


2. Run the following commands in local PowerShell to download and extract the runner package:



```powershell
mkdir actions-runner
cd actions-runner
Invoke-WebRequest -Uri https://github.com/actions/runner/releases/download/v2.334.0/actions-runner-win-x64-2.334.0.zip -OutFile actions-runner-win-x64-2.334.0.zip
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory("$PWD/actions-runner-win-x64-2.334.0.zip", "$PWD")
```

3. Register the runner using the token displayed on the screen.



```powershell
.\config.cmd --url https://github.com/giturl-id/tomcat-k8s --token <your_token>
```

4. Start the runner.



```powershell
.\run.cmd
```

5. Modify the execution environment target in the workflow file.



```yaml
# Before
runs-on: ubuntu-latest

# After
runs-on: self-hosted
```

---

## 🛠️ Resolving mkdir -p Command Execution Error in Windows Environment

When switching the execution environment to the Windows Self-Hosted Runner, the following error occurred during the directory creation step:



```
mkdir : An item with the specified name C:\Users\Administrator\.kube already exists.
At C:\study\tomcat\actions-runner\_work\_temp\836d0b14-98fc-4377-a457-faf5123b7885.ps1:2 char:1
+ mkdir -p ~/.kube
+ ~~~~~~~~~~~~~~~
    + CategoryInfo          : ResourceExists: (C:\Users\Administrator\.kube:String) [New-Item], IOException
    + FullyQualifiedErrorId : DirectoryExist,Microsoft.PowerShell.Commands.NewItemCommand
```

### Cause

On a Windows Self-Hosted Runner, GitHub Actions steps run in PowerShell by default. In PowerShell, `mkdir` is an alias for `New-Item -ItemType Directory`, which does not support the `-p` option. Additionally, if the target directory already exists, PowerShell throws an `IOException` and terminates with exit code `1`.



### Resolution

Change the logic to use native PowerShell syntax to check for directory existence before creation. Also, handle the Base64 decoding entirely within PowerShell using .NET runtime features.



```yaml
      - name: Set kube config
        shell: powershell
        run: |
          if (!(Test-Path "$HOME\.kube")) {
              New-Item -ItemType Directory -Path "$HOME\.kube"
          }
          
          [System.Text.Encoding]::UTF8.GetString(
              [System.Convert]::FromBase64String("${{ secrets.KUBE_CONFIG }}")
          ) | Out-File "$HOME\.kube\config" -Encoding utf8
```

---

## 🛠️ Resolving Kubernetes Pod Image Pull Error (ErrImagePull)

After executing the deployment, the pod status became `ErrImagePull`, and the container failed to start.



```bash
kubectl get pods
# Output:
# NAME                                  READY   STATUS         RESTARTS   AGE
# tomcat2-deployment-59d4ff8df8-cwwb2   0/1     ErrImagePull   0          9s
```

### Cause

Because `imagePullPolicy` in the manifest file (`Deployment.yaml`) is set to `Always`, Kubernetes forces a query to the external registry (such as DockerHub) for the latest image, even if the image exists in the local Docker cache. If the image has not been pushed to the remote registry or credentials are missing, this pull process fails.



### Resolution

When using locally built images directly in a development environment, change `imagePullPolicy` to `IfNotPresent` to skip querying the external registry.


1. Modify the container definition in `Deployment.yaml` as follows:



```yaml
spec:
  containers:
    - name: tomcat
      image: abungard/my-tomcat:latest
      imagePullPolicy: IfNotPresent
```

2. Delete the existing deployment and reapply.



```bash
kubectl delete deployment tomcat2-deployment
kubectl apply -f Deployment.yaml
```

3. Verify the pod startup status.



```bash
kubectl get pods
```

Verify that the status transitions to `Running`.



```
NAME                                  READY   STATUS    RESTARTS   AGE
tomcat2-deployment-59d4ff8df8-cwwb2   1/1     Running   0          12s
```</your_token>