---
title: "Architecture and Implementation of Secret Injection in Docker Buildx Bake"
slug: "docker-buildx-bake-secrets-management"
date: 2026-08-05T10:05:56+09:00
draft: false
image: ""
description: "Explains secure handling methods for sensitive information during container builds using Docker Buildx Bake. Summarizes procedures for protecting credentials by eliminating ARG and ENV vulnerabilities and leveraging BuildKit's temporary mount mechanism."
categories: ["DevOps Logistics"]
tags: ["docker-buildx-bake"]
author: "K-Life Hack"
---

With the expansion of container image build pipelines, design patterns for passing private repository access tokens, API keys, and package manager credentials during image construction have become essential. However, credential injection using traditional build arguments (`ARG`) or environment variables (`ENV`) carries the risk of persisting data as plaintext in image metadata or intermediate layers. This article outlines the architecture and configuration methods for introducing Docker Buildx Bake's secret management mechanism to securely fetch dependencies without leaving sensitive information in build layers.



## Security Challenges with Traditional Build Arguments

Injecting tokens using `ARG` in a standard `Dockerfile` as shown below is considered a severe vulnerability in security audits.



```dockerfile
ARG TOKEN
RUN git clone https://$TOKEN@github.com/private/repository.git
```

The fundamental issues with this pattern are as follows:



1. <b>Persistence in layer metadata</b>: Values set via `ARG` and `ENV` are explicitly recorded in the image manifest and layer cache history.
2. <b>Information disclosure via image inspection</b>: Executing `docker history <image-id>` or `docker inspect` on the generated container image allows third parties to easily extract plaintext tokens.
3. <b>Expansion of supply chain risk</b>: If the image is pushed to a public or shared registry, it directly leads to an incident where infrastructure access permissions are leaked externally.

## Operating Principles of Docker Buildx Bake Secrets

The secrets functionality integrated into the BuildKit engine provides sensitive information to running container processes as temporary mount points without writing it to the build context file system.



```text
+-------------------+        +----------------------+        +-----------------------+
|  Secret Source    | -----&gt; |  Docker Buildx Bake  | -----&gt; | Temporary Mount Point |
| (File / Host Env) |        | Execution Engine     |        | (/run/secrets/id)     |
+-------------------+        +----------------------+        +-----------------------+
                                                                         |
                                                                         v
                                                             +-----------------------+
                                                             | Executed Build Stage  |
                                                             | (RUN Command Access)  |
                                                             +-----------------------+
                                                                         |
                                                                         v
                                                             +-----------------------+
                                                             | Secret Unmounted &amp;    |
                                                             | Excluded from Layers  |
                                                             +-----------------------+
```

### Execution Lifecycle

1. <b>Binding Definition</b>: In the HCL configuration file (`docker-bake.hcl`), specify local files or environment variables on the host as target secrets.
2. <b>Temporary Mount Injection</b>: When executing `docker buildx bake`, the build engine creates an in-memory temporary mount at `/run/secrets/<id>` inside the container.
3. <b>In-Memory Processing</b>: Only the specified `RUN` instruction references the corresponding path to perform authentication operations (such as downloading dependent libraries or cloning Git repositories).
4. <b>Immediate Unmounting</b>: The mount is released immediately after the completion of the relevant `RUN` instruction. The secret contents are never written to intermediate layers or the final image disk.

## Configuration and Implementation Specifications

### Local File-Based Secret Injection

This is the basic format for defining a file on the host as a secret source.


`docker-bake.hcl` configuration:



```hcl
target "app" {
  secret = [
    "id=token,src=token.txt"
  ]
}
```

Reference in `Dockerfile`:



```dockerfile
FROM alpine:3.20
RUN --mount=type=secret,id=token \
    cat /run/secrets/token
```

Execution command:



```bash
docker buildx bake app
```

### Direct Mounting of Host Environment Variables

To avoid saving private keys or tokens as plaintext files on the local disk, this mode passes host environment variables directly to the container as secrets.


Setting host environment variables:



```bash
export API_KEY="abcdef12345"
```

`docker-bake.hcl` configuration:



```hcl
target "app" {
  secret = [
    "id=apikey,env=API_KEY"
  ]
}
```

Reference in `Dockerfile`:



```dockerfile
FROM alpine:3.20
RUN --mount=type=secret,id=apikey \
    API_KEY=$(cat /run/secrets/apikey) &amp;&amp; \
    echo "Processing authenticated task..."
```

## Implementation Examples by Use Case

### Fetching Private Repositories Using SSH Agent Forwarding

When performing Git operations using SSH key pairs, specify dedicated SSH mount options in the target.


`docker-bake.hcl` configuration:



```hcl
target "app" {
  ssh = [
    "default"
  ]
}
```

`Dockerfile` definition:



```dockerfile
FROM alpine:3.20
RUN apk add --no-cache git openssh-client
RUN mkdir -p -m 0700 ~/.ssh &amp;&amp; ssh-keyscan github.com &gt;&gt; ~/.ssh/known_hosts
RUN --mount=type=ssh \
    git clone git@github.com:company/project.git
```

### GitHub Actions CI/CD Pipeline Integration

This is a configuration example for securely supplying workflow secrets to the build context via Bake in a CI/CD environment.


`.github/workflows/build.yml`:



```yaml
name: Production Build Pipeline

on:
  push:
    branches:
      - main

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build with Bake
        env:
          TOKEN: ${{ secrets.PRODUCTION_PIPELINE_TOKEN }}
        run: |
          docker buildx bake production
```

`docker-bake.hcl`:



```hcl
target "production" {
  secret = [
    "id=token,env=TOKEN"
  ]
  tags = [
    "registry.company.com/app:v1"
  ]
  output = [
    "type=image,push=false"
  ]
}
```

## Audit and Operational Verification Procedures

After the build is complete, perform verification in a terminal on the target machine to check whether secrets have leaked into the generated image.



### 1. Pre-Analysis of Bake Target Configurations

Prior to executing the build, output the HCL evaluation results in a JSON structure to verify the bindings.



```text
$ docker buildx bake production --print
{
  "group": {
    "default": {
      "targets": [
        "production"
      ]
    }
  },
  "target": {
    "production": {
      "context": ".",
      "dockerfile": "Dockerfile",
      "secrets": [
        "id=token,env=TOKEN"
      ],
      "tags": [
        "registry.company.com/app:v1"
      ]
    }
  }
}
```

### 2. Layer Analysis of Container Image History

Scan the build history of the generated image to verify that plaintext secret arguments are not included in the instruction history.



```text
$ docker history registry.company.com/app:v1
IMAGE          CREATED         CREATED BY                                      SIZE      COMMENT
a1b2c3d4e5f6   2 minutes ago   RUN /bin/sh -c --mount=type=secret,id=token…   0B        buildkit.dockerfile.v0
<missing>      2 minutes ago   /bin/sh -c #(nop) WORKDIR /app                  0B        buildkit.dockerfile.v0
```

From the output results, safety is proven because the secret string itself is not recorded in the `CREATED BY` area at all, leaving only the definition of the mount flags.



## Troubleshooting

| Incident / Error | Cause Analysis | Remediation Steps |
| :--- | :--- | :--- |
| <b>`secret file token.txt: no such file or directory`</b> | The specified file does not exist at the relative path defined in `src=` within `docker-bake.hcl`. | Verify the path where the file exists relative to the build execution current directory, and correct the `src` definition. |
| <b>`secret id "token" required`</b> | `--mount=type=secret,id=X` in `Dockerfile` and `id=Y` in `docker-bake.hcl` do not match. | Align the `id` identifier in the HCL and the `id` identifier in the Dockerfile to be exactly identical strings. |
| <b>Secret becomes empty in CI environment</b> | Host environment variables are not correctly exported in the workflow's `env:` block. | Review the CI definition file to ensure environment variables are explicitly passed to steps using the `env` key. |

## Key Takeaways

1. <b>Complete Elimination of `ARG` / `ENV`</b>: Never use build arguments for passing credentials that should not be included in the image. Always use `--mount=type=secret`.
2. <b>Prohibition of Secret Value Reassignment</b>: Performing operations to copy and output content obtained inside `RUN --mount=type=secret` to `ENV` variables or the file system is strictly forbidden, as it will persist in the layer at that point.
3. <b>Principle of Least Privilege</b>: Limit tokens injected during builds to the minimum required scope (e.g., read-only permissions) and operate by issuing short-lived temporary tokens.</missing></id></image-id>