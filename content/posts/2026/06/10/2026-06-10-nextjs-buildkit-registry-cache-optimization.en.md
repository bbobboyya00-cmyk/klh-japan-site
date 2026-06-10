---
title: "Speeding Up Next.js 14 Deployment Pipelines and Resolving Bottlenecks with BuildKit Registry Cache"
slug: "nextjs-buildkit-registry-cache-optimization"
date: 2026-06-10T14:07:51+09:00
draft: false
image: ""
description: "This article explains optimization techniques that reduced build times from 12 minutes to the 4-minute range in Cloud Run deployments of Next.js 14 applications, by fixing .dockerignore, using standalone output, and introducing Docker Buildx Registry Cache."
categories: ["DevOps Logistics"]
tags: ["nextjs", "docker-buildx", "google-cloud-build", "cloud-run", "buildkit"]
author: "K-Life Hack"
---

# Next.js 14 + Cloud Run Build Optimization: Process of Reducing Build Time from 12 to 4 Minutes

In the pipeline for deploying a Next.js 14 application to Google Cloud Run, a significant bottleneck occurred where the build time exceeded 12 minutes, despite the source code size being only 5.4 MB. This technical log details the optimization methods used to reduce the build time from 12 minutes 7.2 seconds to 4 minutes 23.5 seconds—approximately a 64% reduction—by correcting .dockerignore syntax, removing unnecessary dependencies, implementing Next.js standalone output, and migrating from Kaniko to Docker Buildx with Registry Cache.



## 1. Analysis of the Factors Behind the 12-Minute Build Bottleneck

The target project is a Next.js application consisting of approximately 60 pages. An audit of the Cloud Build logs, Dockerfile, and cloudbuild.yaml identified the following six factors contributing to the delay:



1. <b>Invalid .dockerignore</b>: Syntax errors caused large local directories to be included in the build context.
2. <b>Unused Dependencies</b>: Unnecessary external modules related to Sentry and Module Federation were processed during the build.
3. <b>Duplicate Build Logic</b>: Type checking via tsc and internal type checking during next build were executed redundantly.
4. <b>Unoptimized Output Format</b>: Next.js standalone mode was not enabled.
5. <b>Bloated Runner Stage</b>: Development modules and unnecessary node_modules were included in the final Docker image.
6. <b>Lack of Layer Cache</b>: Per-build layer caching was not functioning within the ephemeral VM environment of Cloud Build.

---

## 2. Basic Optimization (Phase 1)

### 2.1 Reducing Context by Correcting .dockerignore
In the initial .dockerignore, Markdown escape syntax (e.g., \*~, \*.md) was incorrectly used, preventing Docker from interpreting them as standard glob patterns. Furthermore, node_modules and .next/cache were not excluded. Consequently, approximately 2.5 GB of node_modules and 909 MB of .next/cache were uploaded as the build context in every cycle. Rewriting the .dockerignore to comply with standard Git syntax reduced the build context size from 3.6 GB to a few megabytes, eliminating the upload overhead.



### 2.2 Cleaning Up Dependencies and Build Scripts
Unused @sentry/nextjs and @module-federation/nextjs-mf were removed. Sentry, in particular, was generating and uploading global source maps during the build, imposing a heavy load. The SophiProvider component, which dynamically imported obsolete remote modules, was also eliminated. Regarding build scripts, the redundant tsc step was removed since next build performs type checking internally. Static analysis (Lint) was moved to the commit stage to simplify the build pipeline.



### 2.3 Applying Next.js Standalone and Multi-Stage Builds
By setting output: 'standalone' in next.config.js, Next.js traces and outputs only the minimal set of files required for production.



// next.config.js
module.exports = {
  output: 'standalone',
  // ...other configurations
}

The Dockerfile was transitioned to a multi-stage build configuration to copy only the standalone directory and static assets (public and .next/static) into the runner stage. This reduced the final container image size from over 2.5 GB to approximately 400 MB, significantly shortening image push times and Cloud Run cold start durations.



---

## 3. Attempted Kaniko Integration and Failure Due to Out of Memory (OOM) (Phase 2)

To utilize layer caching in Cloud Build's clean VM environment, Kaniko was initially introduced to generate and store cache inside the container image. However, Kaniko loads filesystem snapshots into memory to calculate differences. In an environment with 2.5 GB of node_modules, it exceeded the 8 GB memory limit of the E2_HIGHCPU_8 machine, resulting in an Exit 137 (OOM) error. Although the build eventually succeeded using memory-reduction flags like --compressed-caching=false and --snapshot-mode=redo, the process took 9 minutes 12.8 seconds due to snapshot overhead. This led to the decision to migrate to Docker Buildx.



---

## 4. Introducing Docker Buildx and Registry Cache (Phase 3)

The final solution involved adopting the docker-container driver of docker buildx and the type=registry cache, utilizing Artifact Registry as the cache storage. Specifying mode=max ensures all build layers, including intermediate layers, are cached.



# cloudbuild.yaml snippet
steps:
  - name: 'gcr.io/cloud-builders/docker'
    entrypoint: 'bash'
    args:
      - '-c'
      - |
        docker buildx create --use --driver docker-container
        ACCESS_TOKEN=$(gcloud auth print-access-token)
        docker login -u oauth2accesstoken -p $$ACCESS_TOKEN https://asia-northeast1-docker.pkg.dev
        docker buildx build \
          --cache-from=type=registry,ref=asia-northeast1-docker.pkg.dev/$PROJECT_ID/cache/app:latest \
          --cache-to=type=registry,ref=asia-northeast1-docker.pkg.dev/$PROJECT_ID/cache/app:latest,mode=max \
          --push \
          -t asia-northeast1-docker.pkg.dev/$PROJECT_ID/repo/app:$COMMIT_SHA .

Implementation requires the docker-container driver to explicitly handle credentials, as it does not automatically inherit host credential helpers. A temporary access token is retrieved from the Google Cloud metadata server to perform a docker login inside the container. Bash variables within the Cloud Build YAML must be escaped with double dollar signs ($$ACCESS_TOKEN) to avoid conflicts with substitution parameters.



---

## 5. Implementation Results and Performance Verification

The transition of build times across the optimization phases is summarized below:



| Build Configuration | Total Build Time | Status |
| :--- | :--- | :--- |
| <b>Initial State (Standard Docker Build)</b> | 12 min 7.2 sec | Success (No cache) |
| <b>Kaniko (Initial Attempt)</b> | N/A | <b>Failure (Exit 137 - OOM)</b> |
| <b>Kaniko (Memory-reduction flags applied)</b> | 9 min 12.8 sec | Success |
| <b>Buildx (First run - Cache generation)</b> | 6 min 41.5 sec | Success |
| <b>Buildx (Subsequent runs - Cache hit)</b> | <b>4 min 23.5 sec</b> | <b>Success (approx. -64% vs. initial)</b> |

The combination of Buildx and registry cache reduced the build time by approximately 8 minutes. Even when packages are modified, only the dependency installation layer is invalidated, preventing the massive delays associated with full filesystem snapshot processing.



---

## Lessons Learned

*   <b>Strict Management of Build Context</b>: Errors in .dockerignore lead to unnecessary gigabyte-scale data transfers, severely degrading CI/CD performance.
*   <b>Selection of Cache Engine</b>: In ephemeral build environments, layer-based registry caching with BuildKit (Buildx) is superior to snapshot-based tools in terms of memory efficiency and execution speed.
*   <b>Future Work</b>: Further speedups will be explored by implementing mechanisms to persist .next/cache between builds and enabling Next.js Incremental Compilation.