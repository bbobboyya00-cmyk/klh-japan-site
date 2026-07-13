---
title: "Initialization Constraints of Terraform S3 Backend and Optimization of GitHub Actions Path Filtering"
slug: "terraform-s3-backend-gha-optimization"
date: 2026-07-13T10:13:56+09:00
draft: false
image: ""
description: "Practical implementation records and troubleshooting regarding variable usage restrictions in Terraform S3 backend configuration and path filtering optimization in GitHub Actions."
categories: ["DevOps Logistics"]
tags: ["terraform", "s3-backend", "github-actions", "aws-iam", "state-management"]
author: "K-Life Hack"
---

# Constraints of S3 Backend Configuration in Terraform and Optimization of GitHub Actions

In Infrastructure as Code (IaC), state management is a core element for maintaining system consistency. Especially when operating with multiple developers or CI/CD pipelines, local terraform.tfstate management carries risks of conflicts and data loss, making migration to a remote backend such as Amazon S3 essential. This article records the variable constraints faced during Terraform S3 backend configuration, S3 key naming conventions, and the optimization process for environment-specific deployments using GitHub Actions.



## Variable Constraints and Resolution in Terraform Backend

To flexibly change the backend configuration for each environment (dev/prod), an attempt was made to write the backend "s3" block using variables defined in variables.tf. Initially, the S3 bucket name and region were defined as variables.



```hcl
# variables.tf
variable "s3_backend" {
  type        = string
  description = "The ARN of the S3 Backend for storing Terraform State"
}

variable "region" {
  type        = string
  description = "AWS Region Code"
}

# backend.tf (Configuration that causes an error)
terraform {
  backend "s3" {
    bucket = var.s3_backend
    key    = "dev/"
    region = var.region
  }
}
```

Executing terraform init in this state results in the following error. This is due to the specifications in Terraform's initialization process.



```text
Initializing the backend...

╷
│ Error: Variables not allowed
│
│   on backend.tf line 3, in terraform:
│    3:     bucket = var.s3_backend
│
│ Variables may not be used here.
╵
```

Due to Terraform's architecture, backend initialization occurs before variables, functions, and locals are evaluated. Therefore, using var. references within the backend block is not permitted by the language specification. To circumvent this constraint, one must use hardcoded strings in the backend configuration or inject values externally using the -backend-config option at runtime. In this case, the configuration was redefined as a static file.



## Constraints Regarding S3 Object Key Naming Conventions

When modifying the backend configuration, an error also occurred in the description of the key parameter, which specifies the path within S3. The following example demonstrates an invalid key specification.



```hcl
terraform {
  backend "s3" {
    bucket = "lee-static-web-sre-state-storage"
    key    = "dev/" # Cause of the error
    region = "ap-northeast-2"
  }
}
```

The error log emitted during execution indicates an issue with the path specification format.



```text
╷
│ Error: Invalid Value
│
│   on backend.tf line 4, in terraform:
│    4:     key    = "dev/"
│
│ The value must not start or end with "/"
```

The S3 backend key must be an object key pointing to a specific state file, not a directory. This was resolved by removing the trailing / and specifying an explicit filename.



```hcl
terraform {
  backend "s3" {
    bucket = "lee-static-web-sre-state-storage"
    key    = "dev/state.tfstate"
    region = "ap-northeast-2"
  }
}
```

## Optimization of Path Filtering with GitHub Actions

In projects with monorepo structures or multiple environment directories, triggering workflows only when changes occur in specific directories helps save computational resources and ensure deployment safety. Initially, when specifying a specific directory, it was terminated with a /, but this may fail to detect file changes within subdirectories.



```yaml
on:
  push:
    paths:
      - 'aws/2026/05/static-web-sre/src/environments/dev/' # Insufficient detection
```

In GitHub Actions specifications, using the ** wildcard is recommended to recursively monitor all changes under a directory. The following workflow configuration applies path filtering for the purpose of verifying IAM roles.



```yaml
name: Show Current IAM Role

on:
  push:
    branches:
      - dev
    paths:
      - 'aws/2026/05/static-web-sre/src/environments/dev/**'
  workflow_dispatch:

env:
  AWS_REGION: ap-northeast-2
  DEV_ROLE: arn:aws:iam::345003923266:role/github_action-dev_branch

permissions:
  id-token: write
  contents: read

jobs:
  show-iam-role:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v5

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v6.2.1
        with:
          role-to-assume: ${{ env.DEV_ROLE }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Show IAM Role
        run: |
          aws sts get-caller-identity
```

## Operational Verifications

After completing the configuration, the backend initialization and access permissions to AWS resources were verified using the following commands. This demonstrated that the remote backend was correctly recognized and there were no permission issues.



```text
$ terraform init

Initializing the backend...
Successfully configured the backend "s3"!

$ aws s3api list-objects --bucket lee-static-web-sre-state-storage --query 'Contents[].Key'
[
    "dev/state.tfstate",
    "prod/"
]

$ aws sts get-caller-identity
{
    "UserId": "AROAXXXXXXXXXXXXXXXXX:github-actions-session",
    "Account": "345003923266",
    "Arn": "arn:aws:sts::345003923266:assumed-role/github_action-dev_branch/github-actions-session"
}
```

## Lessons Learned

1. <b>Terraform Initialization Order</b>: Since the backend block is evaluated with the highest priority, dynamic injection of variables requires the use of -backend-config or maintaining static definitions.


2. <b>S3 Key Strictness</b>: The backend key requires the full path of the object rather than a prefix, so a trailing / is not allowed.


3. <b>CI/CD Trigger Precision</b>: In GitHub Actions paths filtering, recursive specification using ** is mandatory to capture all changes under a directory.

