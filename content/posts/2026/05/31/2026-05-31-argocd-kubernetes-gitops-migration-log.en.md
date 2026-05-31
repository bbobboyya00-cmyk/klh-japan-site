---
title: "Migration to Declarative Infrastructure Management with Argo CD and Kubernetes and Elimination of Configuration Drift"
slug: "argocd-kubernetes-gitops-migration-log"
date: 2026-05-31T10:23:37+09:00
draft: false
image: "https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/argocd-kubernetes-gitops-migration-log/khack_1780190612_0.webp"
description: "Detailed process of migrating from legacy "Pet" infrastructure to a GitOps model using Argo CD. Implementation log covering elimination of configuration drift, enabling self-healing, and deployment automation via declarative control."
categories: ["DevOps Logistics"]
tags: ["argo-cd", "kubernetes", "gitops", "cloud-native", "iac"]
author: "K-Life Hack"
---

## Configuration Drift and Deployment Uncertainty in Legacy "Pet" Server Operations

As of May 2026, configuration drift—discrepancies between staging and production environments—was worsening in the production environment due to manual kernel updates and ad-hoc cron job changes. In the traditional monolithic architecture, servers were managed individually as "pets," requiring hours of manual intervention for recovery if a specific instance (e.g., prod-web-01) went down. Deployments had become "rituals" scheduled for Friday nights, with human error risks from git pull via SSH and manual service restarts becoming normalized.




<img alt="System operational pipeline topology flow description" fetchpriority="high" height="92" loading="eager" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/argocd-kubernetes-gitops-migration-log/khack_1780190612_0.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);" width="651"/>


To resolve this vulnerability, the operational model shifted to a cloud-native "Cattle" approach. This involved introducing Immutable Infrastructure, where entire instances are replaced with new container images rather than patching running servers.



## Implementing Declarative State Management via GitOps Model with Argo CD

The implementation of <b><mark>Argo CD</mark></b> facilitates infrastructure state management within Git repositories, enabling automatic synchronization of the cluster state. This protocol prohibits direct execution of kubectl commands for state changes; all modifications must proceed through Pull Requests (PRs). The Argo CD controller continuously compares the "Desired State" in Git with the "Actual State" of the cluster, triggering a Sync operation upon detecting discrepancies.



__CODE_BLOCK_0__



<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/argocd-kubernetes-gitops-migration-log/khack_1780190613_1.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>


This declarative control ensures that manually altered resources are immediately overwritten by the state defined in Git, rendering configuration drift physically impossible. The runtime environment utilizes containerd v1.7.15, with stable operations confirmed on Kubernetes v1.30.



## Automating Fault Recovery with Self-healing and Liveness Probes

To enhance system resilience, Kubernetes' self-healing capabilities were maximized. Application health checks were strictly defined, and configurations were implemented to automatically restart containers in the event of deadlocks or memory leaks. Specifically, Liveness Probes and Readiness Probes were configured for each microservice, decoupling traffic routing from process health checks.



__CODE_BLOCK_1__



<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/argocd-kubernetes-gitops-migration-log/khack_1780190614_2.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>


Additionally, the <b><mark>Horizontal Pod Autoscaler (HPA)</mark></b> was introduced to manage traffic surges. By dynamically scaling replicas when CPU usage exceeds 70%, latency spikes were suppressed. Load testing via Locust in the validation environment confirmed that p99 latency remained within 200ms even during a 300% increase in request volume, facilitated by rapid pod instantiation.



## Validating Auto-Sync via Control Loops and Accelerating Rollbacks

To verify the efficacy of the <b><mark>GitOps</mark></b> pipeline, tests were conducted by intentionally modifying deployment settings manually within the cluster. The Argo CD Reconciliation Loop detected the discrepancy within 30 seconds and automatically restored the state to match the Git repository. This eliminated downtime risks associated with unauthorized configuration changes.




<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/argocd-kubernetes-gitops-migration-log/khack_1780190615_3.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>


Furthermore, rollback duration during deployment failures was reduced from 30 minutes (manual recovery) to under 3 minutes via Git revert commits. Observability was enhanced by integrating Prometheus and Grafana to visualize error rates and resource utilization in real-time. Infrastructure has transitioned from managed objects to programmable resources.

