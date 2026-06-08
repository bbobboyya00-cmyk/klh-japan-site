---
title: "Automating Kubernetes Manifest Generation and Helm Migration with Claude Code"
slug: "claude-code-k8s-helm-migration"
date: 2026-06-08T18:03:25+09:00
draft: false
image: ""
description: "This article explains practical workflows and configuration methods for automating Kubernetes manifest generation and migrating to Helm charts using Claude Code."
categories: ["DevOps Logistics"]
tags: ["kubernetes", "helm", "gke", "claude-code", "devops", "yaml-automation"]
author: "K-Life Hack"
---

# GKE Manifest Automation and Helm Migration via Claude Code

## 1. Context Persistence: Defining CLAUDE.md

To maintain AI generation accuracy and apply consistent constraints across sessions, a <b>CLAUDE.md</b> file must be placed in the project root. This enables the AI to pre-learn cluster-specific conventions, naming rules, and deployment strategies, ensuring consistent output.



```markdown
# CLAUDE.md Configuration for GKE

- Cluster Provider: GKE (Google Kubernetes Engine)
- Region: asia-northeast3 (Seoul)
- Namespace Convention: {app}-{environment}
- Resource Management: Always define both requests and limits.
- Image Registry: gcr.io/my-project/
- Mandatory Labels: app, env, version
- Health Checks: Liveness and Readiness probes are mandatory.
- High Availability: Pod anti-affinity for multi-AZ distribution.
```

## 2. Automated Deployment Generation

Providing specific resource requirements and environment variables to Claude Code allows for the generation of production-ready manifests. For a Node.js API service, sophisticated YAML including resource limits (Requests/Limits), Liveness/Readiness probes, and inter-pod affinity settings is configured.



```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-server
  namespace: payments-prod
  labels:
    app: api
    env: production
    version: v1.2.0
spec:
  replicas: 3
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values:
                  - api
              topologyKey: "topology.kubernetes.io/zone"
      containers:
      - name: api-container
        image: gcr.io/my-project/api:v1.2.0
        ports:
        - containerPort: 3000
        resources:
          requests:
            cpu: "250m"
            memory: "256Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
        livenessProbe:
          httpGet:
            path: /health
            port: 3000
          initialDelaySeconds: 30
          periodSeconds: 30
```

Internal verification confirms that this process significantly reduces manifest construction time compared to manual creation. Furthermore, the occurrence rate of syntax errors is minimized during pre-validation using `kubectl apply --dry-run=client`.



## 3. Helm Chart Migration Workflow

The process of converting static YAML files into reusable Helm charts involves identifying parameters that require dynamic changes per environment. Claude Code analyzes existing YAML to structure the migration into specific steps:



1. <b>Parameterization</b>: Extracting variable elements such as image tags, replica counts, and resource limits into `values.yaml`.
2. <b>Directory Structure Construction</b>: Automatically generating `Chart.yaml` and the `templates/` directory to configure a standard Helm layout.
3. <b>Helper Function Definition</b>: Creating `_helpers.tpl` to centrally manage common labels and naming conventions, improving maintainability.

Example of a standard directory structure configuration generated.



```text
helm/api/
├── Chart.yaml
├── values.yaml
├── values-prod.yaml
├── values-staging.yaml
└── templates/
    ├── deployment.yaml
    ├── service.yaml
    ├── hpa.yaml
    └── _helpers.tpl
```

## 4. Cluster Troubleshooting and Optimization

Claude Code functions as a diagnostic agent for running clusters by analyzing `kubectl` execution results. It performs root cause analysis of failures and presents fix proposals based on real-time data.


🛠️ <b>CrashLoopBackOff Analysis</b>: Identifies OOMKilled (out of memory) or secret reference errors from `kubectl describe pod` event logs and generates fix patches.


💡 <b>Resource Optimization</b>: Proposes `requests` adjustments suited to actual CPU/memory usage based on `kubectl top pods` metrics, maximizing cluster cost efficiency.



## 5. Security and Network Control

To ensure security, Claude Code generates a `NetworkPolicy` based on the Principle of Least Privilege. This facilitates the implementation of zero-trust network configurations that allow communication only between pods with specific Namespaces or labels.



```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-allow-ingress
  namespace: payments-prod
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
  egress:
  - to:
    - ports:
      - protocol: TCP
        port: 5432
```

## Configuration Notes

While AI-driven automated generation is a powerful tool, verification via `--dry-run` and engineer peer reviews of the generated manifests are mandatory before production application. Specific constraints described in <b>CLAUDE.md</b>, such as the use of specific Ingress controllers or mandatory annotations, increase the accuracy and environmental suitability of the output. For multi-cloud environments (EKS, AKS, etc.), adding cloud-provider-specific annotation settings to the context enables flexible multi-platform deployment.

