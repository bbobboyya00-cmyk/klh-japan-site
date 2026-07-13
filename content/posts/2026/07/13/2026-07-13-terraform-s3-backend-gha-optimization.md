---
title: "Terraform S3 Backendの初期化制約とGitHub Actionsパスフィルタリングの最適化"
slug: "terraform-s3-backend-gha-optimization"
date: 2026-07-13T10:13:55+09:00
draft: false
image: ""
description: "TerraformのS3バックエンド設定における変数利用の制限と、GitHub Actionsのパスフィルタリング最適化に関する実務的な実装記録とトラブルシューティング。"
categories: ["DevOps Logistics"]
tags: ["terraform", "s3-backend", "github-actions", "aws-iam", "state-management"]
author: "K-Life Hack"
---

# TerraformにおけるS3バックエンド構成の制約とGitHub Actionsの最適化

Infrastructure as Code (IaC) において、ステート管理（State Management）はシステムの整合性を維持するための核心的な要素です。特に複数人での開発やCI/CDパイプラインを運用する場合、ローカルの terraform.tfstate 管理は競合やデータ損失のリスクを伴うため、Amazon S3などのリモートバックエンドへの移行が不可欠となります。本稿では、TerraformのS3バックエンド構成時に直面した変数の制約、S3キーの命名規則、およびGitHub Actionsによる環境別デプロイの最適化プロセスについて記録します。

## Terraform Backendにおける変数の制約と解決

環境（dev/prod）ごとにバックエンド構成を柔軟に変更するため、variables.tf で定義した変数を使用して backend "s3" ブロックを記述する構成を試行しました。当初、S3バケット名やリージョンを変数化して定義しました。

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

# backend.tf (エラーが発生する構成)
terraform {
  backend "s3" {
    bucket = var.s3_backend
    key    = "dev/"
    region = var.region
  }
}
```

この状態で terraform init を実行すると、以下のエラーが送出されます。これはTerraformの初期化プロセスにおける仕様に起因するものです。

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

Terraformのアーキテクチャ上、バックエンドの初期化は変数（Variables）、関数（Functions）、ローカル変数（Locals）が評価される前に行われます。そのため、backend ブロック内で var. 参照を使用することは言語仕様として許可されていません。この制約を回避するため、バックエンド構成にはハードコードされた文字列を使用するか、実行時に -backend-config オプションを利用して外部から値を注入する必要があります。今回は静的な構成ファイルとして再定義を行いました。

## S3オブジェクトキーの命名規則に関する制約

バックエンド構成を修正する際、S3内のパスを指定する key パラメータの記述においてもエラーが発生しました。以下は無効なキー指定の例です。

```hcl
terraform {
  backend "s3" {
    bucket = "lee-static-web-sre-state-storage"
    key    = "dev/" # エラーの原因
    region = "ap-northeast-2"
  }
}
```

実行時に送出されたエラーログは、パスの指定形式に問題があることを示しています。

```text
╷
│ Error: Invalid Value
│
│   on backend.tf line 4, in terraform:
│    4:     key    = "dev/"
│
│ The value must not start or end with "/"
```

S3バックエンドの key はディレクトリではなく、特定のステートファイルを指すオブジェクトキーである必要があります。末尾の / を削除し、明示的なファイル名を指定することで解決しました。

```hcl
terraform {
  backend "s3" {
    bucket = "lee-static-web-sre-state-storage"
    key    = "dev/state.tfstate"
    region = "ap-northeast-2"
  }
}
```

## GitHub Actionsによるパスフィルタリングの最適化

モノレポ構成や複数の環境ディレクトリを持つプロジェクトでは、特定のディレクトリに変更があった場合のみワークフローをトリガーさせることが、計算リソースの節約とデプロイの安全性確保に繋がります。当初、特定のディレクトリを指定する際に末尾を / で終了させていましたが、これではサブディレクトリ内のファイル変更を検知できない場合があります。

```yaml
on:
  push:
    paths:
      - 'aws/2026/05/static-web-sre/src/environments/dev/' # 不十分な検知
```

GitHub Actionsの仕様では、ディレクトリ配下のすべての変更を再帰的に監視するために ** ワイルドカードを使用することが推奨されます。以下は、IAMロールの確認を目的とした、パスフィルタリング適用後のワークフロー構成です。

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

設定完了後、バックエンドの初期化およびAWSリソースへのアクセス権限を以下のコマンドで確認しました。これにより、リモートバックエンドが正しく認識され、権限に問題がないことが実証されました。

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

1. <b>Terraformの初期化順序</b>: backend ブロックは最優先で評価されるため、変数の動的注入には -backend-config を使用するか、静的な定義を維持する必要がある。
2. <b>S3キーの厳密性</b>: バックエンドの key はプレフィックスではなくオブジェクトのフルパスを要求するため、末尾の / は許容されない。
3. <b>CI/CDのトリガー精度</b>: GitHub Actionsの paths フィルタリングにおいて、ディレクトリ配下の全変更を捕捉するには ** による再帰的指定が必須である。