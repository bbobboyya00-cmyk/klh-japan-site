---
title: "AWS Systems ManagerにおけるVPCエンドポイントの設計と実装：Interface型とGateway型の構造的差異"
slug: "aws-ssm-vpc-endpoint-architecture-analysis"
date: 2026-06-01T21:53:22+09:00
draft: false
image: ""
description: "AWS Systems Manager (SSM) をプライベートサブネットで運用するためのVPCエンドポイント設計ガイド。Interface型とGateway型の違い、セキュリティグループ設定、CLIによる検証手順を詳説します。"
categories: ["Linux System Admin"]
tags: ["aws-ssm", "vpc-endpoint", "privatelink", "security-group", "aws-cli"]
author: "K-Life Hack"
---

# AWS VPCエンドポイントの設計と実装：セキュアなプライベート接続の構造的理解

<b>meta_description</b>: Interface型およびGateway型VPCエンドポイントの動作原理、SSM運用のためのセキュリティ設計、CLIによる検証プロセスをシステムアーキテクトの視点から詳説します。

## 1. VPCエンドポイントの基本概念と設計思想

AWS VPCエンドポイントは、Amazon Virtual Private Cloud (VPC) 内のリソースが、パブリックインターネットを経由せずに、サポートされているAWSサービスやVPCエンドポイントサービスにプライベートに接続することを可能にするネットワーク機能です。このアーキテクチャにより、VPCとサービス間のトラフィックはAmazonネットワーク内に留まり、セキュリティとパフォーマンスが向上します。

通常、プライベートサブネット内に配置されたEC2インスタンス、ECSタスク、Lambda関数などのリソースは、AWS Systems Manager (SSM)、Amazon S3、Amazon CloudWatch Logs、Amazon ECRなどのサービスにアクセスするためにVPCエンドポイントを利用します。

### トラフィックフローの論理

`プライベートサブネットリソース` → `AWSサービスAPIコール` → `VPCエンドポイント` → `AWSサービス`

実装において正確に区別すべき4つのコンポーネントは以下の通りです。

1. <b>VPCエンドポイント</b>: プライベート接続機能そのもの。
2. <b>VPCエンドポイントサービス名</b>: 作成時に選択する特定のAWSサービス識別子 (例: `com.amazonaws.ap-northeast-2.ssm`)。
3. <b>プレフィックスリスト</b>: IPアドレス範囲 (CIDRブロック) のグループを含む管理オブジェクト。
4. <b>エンドポイントタイプ</b>: 基盤となる接続手法 (Interface型またはGateway型)。

## 2. ネットワークコンポーネントの比較分析

VPCエンドポイントは、Transit Gateway、NAT Gateway、EC2 Instance Connectなど、他のネットワーク機能と目的が異なります。主要な差異は以下の通りです。

| カテゴリ | 目的 | 代表的なフロー | 主要な判断基準 |
| :--- | :--- | :--- | :--- |
| <b>VPCエンドポイント</b> | 内部リソースからのAWSサービスへのプライベートアクセス | EC2 → VPCE → AWS Service | AWSサービスへのアクセスに使用 |
| <b>Transit Gateway</b> | VPC、VPN、Direct Connect間のルーティングハブ | VPC ↔ TGW ↔ VPC/オンプレミス | ネットワーク間接続に使用 |
| <b>NAT Gateway</b> | プライベートリソースからのインターネット送信 | EC2 → NAT → Internet | インターネットへの外部送信に使用 |
| <b>EIC エンドポイント</b> | パブリックIPなしでのEC2へのSSH/RDPアクセス | User → EIC Endpoint → EC2 | EC2へのアクセスパスとして使用 |

## 3. サービス名とプレフィックスリストの厳密な識別

### 3-1. VPCエンドポイントサービス名の形式
サービス名は、エンドポイントが接続するAWSサービスを指定するための識別子です。ソウルリージョン (ap-northeast-2) の場合、標準的な形式は `com.amazonaws.<region>.<service-code>` となります。

*   `com.amazonaws.ap-northeast-2.ssm` (SSM API)
*   `com.amazonaws.ap-northeast-2.ssmmessages` (Session Managerデータチャネル)
*   `com.amazonaws.ap-northeast-2.ec2messages` (SSMエージェントメッセージング)

### 3-2. プレフィックスリスト (Prefix Lists)

プレフィックスリストは、`pl-xxxxxxxx` という形式のIDで管理されるCIDRブロックの集合です。AWS管理のプレフィックスリストは、セキュリティグループやルートテーブルで参照可能ですが、すべてのVPCエンドポイントサービスにプレフィックスリストが存在するわけではありません。主にS3やDynamoDBなどのGateway型エンドポイントで重要な役割を果たします。

## 4. エンドポイントタイプ別の構造的論理

### 4-1. Interface型エンドポイント (AWS PrivateLink)
Interface型エンドポイントは、AWS PrivateLinkを利用します。作成時、指定したサブネット内に<b>エンドポイントENI</b> (Elastic Network Interface) が生成されます。

*   <b>論理</b>: `EC2` → `TCP 443` → `エンドポイントENI` → `AWS PrivateLink` → `AWSサービス`。
*   <b>セキュリティ</b>: エンドポイントENIにはセキュリティグループをアタッチし、インバウンドトラフィックを制御する必要があります。

### 4-2. Gateway型エンドポイント

Gateway型エンドポイントは、ENIやセキュリティグループを使用しません。代わりに、<b>ルートテーブル</b>を直接変更することで機能します。

*   <b>メカニズム</b>: 送信先をAWS管理プレフィックスリスト (例: S3)、ターゲットをVPCエンドポイントID (`vpce-xxxxxxxx`) とするルートをルートテーブルに追加します。
*   <b>論理</b>: `EC2` → `ルートテーブル (Dest: S3 Prefix List, Target: VPCE)` → `S3/DynamoDB`。

## 5. SSM運用におけるインターフェースエンドポイントのセキュリティ設計

SSM、Logs、MonitoringなどのサービスはInterface型を使用するため、セキュリティグループの設定が不可欠です。

### セキュリティグループの標準設定

*   <b>インバウンドルール</b>: ソース (EC2インスタンスのセキュリティグループまたは内部CIDR) からの <b>TCP 443</b> を許可します。
*   <b>アウトバンドルール</b>: 通常は「すべてのトラフィック」を許可しますが、組織のポリシーに応じて制限可能です。

⚠️ <b>注意</b>: プライベートDNS (Private DNS) を有効にする必要があります。これにより、サービスURLがエンドポイントENIのプライベートIPアドレスに解決されるようになります。

## 6. CLIによるインフラ状態の検証手順

構成が正しく行われているかを確認するために、以下の手順で検証を実施します。

### ステップ1: VPCエンドポイントの特定

```bash
aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=vpc-xxxxxxxx --query 'VpcEndpoints[*].{ID:VpcEndpointId,Service:ServiceName,Type:VpcEndpointType}'
```

### ステップ2: セキュリティグループルールの確認

```bash
aws ec2 describe-security-group-rules --filters Name=group-id,Values=sg-xxxxxxxx
```

### ステップ3: DNS解決の確認

```bash
nslookup ssm.ap-northeast-2.amazonaws.com
```
💡 プライベートDNSが正しく設定されている場合、結果はInterface型エンドポイントENIのプライベートIPアドレスを返します。

## 7. Operational Notes

*   <b>Interface型</b>: ENI、セキュリティグループ、プライベートDNSの3点が揃っていることを確認してください。
*   <b>Gateway型</b>: ルートテーブルにプレフィックスリストを宛先とするエントリが存在することを確認してください。
*   <b>SSMの要件</b>: SSMを完全に機能させるには、`ssm`、`ssmmessages`、`ec2messages` の3つのエンドポイントがすべて必要です。これらが欠けると、Session Managerの接続失敗やエージェントのオフライン状態が発生します。</service-code></region>