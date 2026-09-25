---
title: "API GatewayのCloudWatch実行ログが出力されない問題の構造的解決とIAMロール設計"
slug: "apigateway-cloudwatch-logging-iam-setup"
date: 2026-09-25T10:14:35+09:00
draft: false
image: ""
description: "API Gatewayのステージ設定で実行ログを有効化してもCloudWatch Logsに出力されない原因と、アカウントレベルのIAMロール紐付け手順、401/403エラーのトラブルシューティング手法を解説します。"
categories: ["Backend Architecture"]
tags: ["api gateway"]
author: "K-Life Hack"
---

API Gatewayの運用において、ステージ設定で実行ログ（Execution Logs）を有効化したにもかかわらず、CloudWatch Logsにロググループやログストリームが生成されない事象は頻繁に発生します。これは、API Gatewayのログ出力アーキテクチャが「ステージレベルの設定」と「アカウントレベルの権限（IAMロール）」という2層のライフサイクルで管理されていることに起因します。

ステージレベルでいくら詳細なログ出力を有効化しても、API Gatewayサービス自体がAWSアカウントのCloudWatch Logsに対して書き込みを行うためのIAMロールがグローバル設定に登録されていなければ、ログは内部的にサイレントドロップされます。本稿では、この権限分離のメカニズムを解き明かし、安全かつ確実にログを収集するためのIAMロール設計とトラブルシューティング手順を解説します。

---

## API Gatewayにおけるログ出力の2層アーキテクチャ

API GatewayからCloudWatch Logsへのログ書き込みは、以下の2つの独立した制御プレーンによって制御されています。

1. <b>アカウントレベルの設定（Identity &amp; Access Boundary）</b>
API Gatewayサービス（`apigateway.amazonaws.com`）が、対象のAWSアカウントおよびリージョンにおいて、一時的なセキュリティ認証情報を取得（`sts:AssumeRole`）し、CloudWatch Logs APIを呼び出すためのIAMロールを定義します。
2. <b>ステージレベルの設定（Configuration Scope）</b>
特定のAPIステージにおいて、ログの出力有無、ログレベル（`INFO` / `ERROR`）、詳細なメトリクスの収集、データトレース（リクエスト/レスポンスのペイロード記録）の有効化を定義します。

この2つの設定が揃うことで、初めてログストリームが正常に生成されます。

```
[ Step 1: IAMロールの作成 ] 
       │ (信頼関係: apigateway.amazonaws.com)
       ▼
[ Step 2: API Gatewayのアカウント設定にロールARNを登録 ]
       │ (API Gatewayにグローバルなログ書き込み権限を付与)
       ▼
[ Step 3: APIステージ設定で実行ログを有効化 ]
       │ (ログレベル、メトリクス、トレースの定義)
       ▼
[ Step 4: クライアントからAPIエンドポイントへリクエスト送信 ]
       │
       ▼
[ Step 5: CloudWatch Logsでのログイベント確認 ]
         (ロググループ名: API-Gateway-Execution-Logs_<api-id>/<stage>)
```

---

## 1. CloudWatch書き込み用IAMロールの作成とポリシー定義

API GatewayがCloudWatch Logsにロググループを作成し、ログストリームをプロビジョニングしてログイベントをアップロードするためには、適切な信頼関係とポリシーを持つIAMロールが必要です。

### 信頼ポリシー（Trust Policy）の定義

API Gatewayサービスプリンシパルがこのロールを引き受けられるように設定します。

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "apigateway.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

### 許可ポリシー（Permissions Policy）の定義

最小権限の原則に基づき、以下の3つのアクションが必要です。AWS管理ポリシーである `AmazonAPIGatewayPushToCloudWatchLogs` をアタッチするか、同等のカスタムポリシーを作成します。

* `logs:CreateLogGroup`: ロググループが存在しない場合に自動生成する権限
* `logs:CreateLogStream`: ロググループ内に新しいストリームを生成する権限
* `logs:PutLogEvents`: ログイベントをバッチアップロードする権限

---

## 2. アカウント設定へのIAMロールARNの紐付け

作成したIAMロールのARN（例: `arn:aws:iam::123456789012:role/apigw-cloudwatch-logging-role`）を、API Gatewayのリージョンごとのグローバル設定に登録します。

### AWS CLIによる設定確認と更新

マネジメントコンソールからの設定のほか、AWS CLIを使用してアカウント設定を反映・確認することが可能です。

```bash
# アカウント設定にIAMロールARNを紐付ける
aws apigateway update-account \
  --patch-operations op='replace',path='/cloudwatchRoleArn',value='arn:aws:iam::123456789012:role/apigw-cloudwatch-logging-role' \
  --region us-east-1
```

---

## 3. ステージレベルでの実行ログ有効化

アカウントレベルの権限設定が完了した後、対象となるAPIのステージ設定でログ出力を有効化します。

* <b>ログレベル</b>: `INFO`（すべての実行パスを記録）または `ERROR`（ランタイムエラーのみ記録）を選択します。トラブルシューティング時は `INFO` を推奨します。
* <b>詳細なメトリクス</b>: 有効化すると、レイテンシーやリクエスト数などのメトリクスがCloudWatch Metricsに送信されます。
* <b>完全なリクエスト/レスポンスデータのログ（データトレース）</b>: 有効化すると、HTTPリクエスト/レスポンスのボディやヘッダーがすべて記録されます。ただし、本番環境では認証トークンや個人情報（PII）がログに露出するリスクがあるため、一時的なデバッグ目的以外では無効化することを推奨します。

---

## 4. Troubleshooting

設定を完了してもログが出力されない場合や、API呼び出し時に特定のHTTPエラーが発生する場合の診断フローです。

### 代表的な摩擦点（Friction Points）と対策

* <b>信頼関係の不整合</b>: IAMロールの信頼ポリシーで、サービスプリンシパルが `lambda.amazonaws.com` や `ec2.amazonaws.com` になっている場合、API Gatewayはロールを引き受けられず、ログ出力に失敗します。必ず `apigateway.amazonaws.com` であることを確認してください。
* <b>リージョン間の不整合</b>: API Gatewayのアカウント設定（CloudWatch Logs Role ARN）はリージョンごとに独立しています。APIをデプロイしたリージョンと同じリージョンの設定にロールARNが登録されているか確認してください。

### 401 / 403 エラー発生時のログ解析マトリクス

実行ログが有効化されると、クライアントに `401 Unauthorized` や `403 Forbidden` が返された際、どのフェーズで拒否されたかを時系列で特定できます。

| エラー要因 | ログ内の主なシグネチャ | 確認すべきポイント |
| :--- | :--- | :--- |
| <b>認証ヘッダーの欠落</b> | `Unauthorized request` / `Missing Authentication Token` | クライアントが `Authorization` ヘッダーやカスタムヘッダーを正しく送信しているか。 |
| <b>カスタムオーソライザーの失敗</b> | `Execution failed due to configuration error: Authorizer...` | Lambdaオーソライザーが返却したIAMポリシーの構文エラー、またはLambda自体のランタイムエラー。 |
| <b>APIキーの不整合</b> | `Forbidden` / `Invalid API Key` | メソッド設定で `API Key Required` が `true` になっているか、および `x-api-key` ヘッダーが有効な使用量プランに紐付いているか。 |
| <b>リソースポリシーによる拒否</b> | `Access Denied` / `Explicit Deny` | API Gatewayのリソースポリシーで、送信元IPアドレスやVPCエンドポイントが拒否対象になっていないか。 |

### 正常稼働時の検証ログ（ターミナル出力例）

設定が正常に反映されているか、AWS CLIを用いて検証します。

```text
$ aws apigateway get-account --region us-east-1
{
    "cloudwatchRoleArn": "arn:aws:iam::123456789012:role/apigw-cloudwatch-logging-role",
    "throttleSettings": {
        "burstLimit": 5000,
        "rateLimit": 10000.0
    }
}

$ aws iam get-role --role-name apigw-cloudwatch-logging-role --query 'Role.AssumeRolePolicyDocument'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "apigateway.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}

$ aws logs describe-log-groups --log-group-name-prefix "API-Gateway-Execution-Logs" --region us-east-1 --query 'logGroups[0].logGroupName'
"API-Gateway-Execution-Logs_abc123xyz/prod"
```

---

## Operational Notes

* <b>データプライバシーの保護</b>: 本番環境において「完全なリクエスト/レスポンスデータのログ」を有効化することは避けてください。セッショントークンやAPIキー、個人情報がCloudWatch Logsに平文で記録され、セキュリティコンプライアンス（GDPR、PCI-DSS等）に抵触する原因となります。
* <b>ログの保持期間（Retention Period）</b>: API Gatewayが自動生成するCloudWatchロググループのデフォルト保持期間は「無期限（Never Expire）」です。ストレージコストの肥大化を防ぐため、ロググループ作成後に保持期間（例: 30日〜90日）を明示的に設定する運用ルールを設けることを推奨します。
* <b>メトリクスフィルターの活用</b>: ログのフルスキャンによるコスト増を避けるため、特定のステータスコード（`4XX` / `5XX`）の発生頻度を監視する場合は、CloudWatchのメトリクスフィルターを定義してアラートを構成するのが効率的です。</stage></api-id>