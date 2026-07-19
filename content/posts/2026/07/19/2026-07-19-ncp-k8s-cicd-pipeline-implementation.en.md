---
title: "Building and Optimizing Kubernetes CI/CD Pipelines with NCP Developer Tools"
slug: "ncp-k8s-cicd-pipeline-implementation"
date: 2026-07-19T10:06:10+09:00
draft: false
image: ""
description: "This article explains how to build a CI/CD pipeline that integrates Naver Cloud Platform's SourceCommit, SourceBuild, SourceDeploy, and SourcePipeline to achieve automated deployment to NKS environments, covering build acceleration and approval flow design."
categories: ["DevOps Logistics"]
tags: ["ncp-sourcecommit", "nks-deployment", "docker-build-cache", "cicd-pipeline", "kubernetes-loadbalancer"]
author: "K-Life Hack"
---

# Building NKS CI/CD Pipelines Using NCP Developer Tools

In cloud-native infrastructure, manual deployment tasks are a major factor in inducing environment inconsistencies and human errors. Especially in microservices architectures, abstracting the process from container image building to Kubernetes (NKS) deployment and managing it through a consistent pipeline is essential for ensuring release reliability. This article details practical methods for building an end-to-end CI/CD pipeline triggered by source code changes using the Naver Cloud Platform (NCP) Developer Tools suite.



## 1. Architectural Components

NCP Developer Tools consists of the following four managed services, covering the entire SDLC (Software Development Life Cycle).


SourceCommit is a private Git repository that also supports migration from platforms like GitHub. SourceBuild is a managed service capable of parallel builds, responsible for creating Docker images and pushing them to the Container Registry. SourceDeploy performs automated deployments to NKS or server groups, supporting strategies such as rolling updates. SourcePipeline functions as an orchestrator that integrates these processes and automates the workflow.



## 2. SourceCommit: Repository Migration and Authentication Design

When migrating from external repositories (such as GitHub) to SourceCommit, managing authentication credentials is the first point of friction. For copying private repositories, the use of a GitHub Personal Access Token (PAT) is mandatory instead of a standard password.


Operators must be assigned the <b>NCP_SOURCECOMMIT_MANAGER</b> policy and set a dedicated Git password on the console. This enables secure cloning and pushing via HTTPS.



## 3. SourceBuild: Container Image Construction and Optimization

In SourceBuild, Docker builds are executed on base runtimes such as Ubuntu 16.04. Here, a configuration is required to resolve application dependencies and create lightweight images.



```dockerfile
FROM python:3.9-slim

WORKDIR /app

# Install dependencies (copy first for cache efficiency)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 5000

CMD ["python", "app.py"]
```

In the build project settings, ease of rollback is ensured by enabling versioning using the build number (using the # symbol) alongside the latest tag.



## 4. SourceDeploy: Deployment Strategy for NKS

SourceDeploy applies Kubernetes manifests (Deployment/Service) to the NKS cluster. To minimize downtime, a rolling update strategy is typically selected.



```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flask-app-deployment
spec:
  replicas: 3
  selector:
    matchLabels:
      app: flask-app
  template:
    metadata:
      labels:
        app: flask-app
    spec:
      containers:
      - name: flask-app
        image: <your-ncr-endpoint>/flask-app:latest
        ports:
        - containerPort: 5000
---
apiVersion: v1
kind: Service
metadata:
  name: flask-app-service
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 5000
  selector:
    app: flask-app
```

## 5. Automation and Governance with SourcePipeline

By setting a push to the master branch of SourceCommit as a trigger in SourcePipeline, the process from code modification to production reflection is fully automated. For production deployments, it is recommended to strengthen governance by incorporating an "approval flow" by users with requestDeploy permissions.



## Troubleshooting

⚠️ <b>Authentication Error (401 Unauthorized)</b>: If this occurs during a push to SourceCommit, verify that the Git password set for the sub-account is entered correctly. When copying from GitHub, you must check the PAT expiration and scope (repo).


🛠️ <b>Increased Build Times</b>: If downloading packages from requirements.txt becomes a bottleneck, you can significantly reduce time by using SourceBuild's "Upload image after build completion" feature to save the build environment itself (containing dependencies) as a cache image in the Container Registry and using it as a custom image for the next build.


💡 <b>Image Pull Error (ErrImagePull)</b>: If NKS cannot pull the image from the Container Registry, verify that the registry endpoint URL is correctly described in the manifest and that the NKS cluster has been granted appropriate access permissions.



## Verification

After deployment is complete, use the following commands to verify the cluster status and application response.



```text
# Check Pod status
$ kubectl get pods -l app=flask-app
NAME                                    READY   STATUS    RESTARTS   AGE
flask-app-deployment-5f7d8b9c4d-abc12   1/1     Running   0          3m
flask-app-deployment-5f7d8b9c4d-def34   1/1     Running   0          3m
flask-app-deployment-5f7d8b9c4d-ghi56   1/1     Running   0          3m

# Get the external IP of the LoadBalancer
$ kubectl get svc flask-app-service
NAME                TYPE           CLUSTER-IP     EXTERNAL-IP      PORT(S)        AGE
flask-app-service   LoadBalancer   10.100.1.50    1.2.3.4          80:32000/TCP   5m

# Verify application response
$ curl -s http://1.2.3.4 | jq .
{
  "pod_ip": "172.16.0.10",
  "pod_name": "flask-app-deployment-5f7d8b9c4d-abc12",
  "timestamp": "2026-07-19T10:00:00Z",
  "uri": "/"
}
```

## Operational Notes

By integrating NCP Developer Tools, Infrastructure as Code (IaC) and continuous delivery of applications are highly synchronized. In particular, utilizing build caches and implementing approval processes are key to resolving the trade-off between development speed and safety. It is recommended to adjust the SourceBuild compute type according to the project scale to optimize resource efficiency.

</your-ncr-endpoint>