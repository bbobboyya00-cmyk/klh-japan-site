---
title: "Supabase Free Planのプロジェクト停止を防止するGitHub Actionsの自動化実装"
slug: "supabase-keepalive-automation-github-actions"
date: 2026-07-05T10:12:16+09:00
draft: false
image: ""
description: "Supabase Free Planの7日間無操作による自動停止を回避するため、GitHub Actionsを利用した定期的なREST APIリクエストによる死活監視の実装手順とセキュリティ上の留意点を解説します。"
categories: ["DevOps Logistics"]
tags: ["supabase", "github-actions", "cron", "rest-api", "devops"]
author: "K-Life Hack"
---

Supabase Free Planの自動停止を回避するGitHub Actionsによる死活監視構成

SupabaseのFree Planにおいて、7日間連続でアクティビティが検出されない場合にプロジェクトが自動的に一時停止（Pause）される仕様は、開発環境やプロトタイプ運用の継続性を阻害する要因となります。一度停止されたデータベースはダッシュボードから手動で再開（Resume）する必要があり、APIリクエストのダウンタイムを招きます。本稿では、GitHub Actionsのスケジュール実行機能を利用し、5日周期でREST APIへ「Ping」を送信することで、この非アクティブタイマーを自動的にリセットするインフラ構成について詳述します。

## 構成アーキテクチャとセキュリティ要件

この自動化スタックは、機密情報であるAPIキーを保護するため、プライベートリポジトリ内での運用を前提とします。GitHub ActionsのFree Tierでは、プライベートリポジトリに対して月間2,000分の実行時間が提供されており、本タスクのような軽量なcurl実行には十分なリソースです。

### 1. GitHub Secretsによる認証情報の管理

ハードコーディングによる漏洩を防止するため、リポジトリの <b>Settings &gt; Secrets and variables &gt; Actions</b> に以下の環境変数を登録します。値に引用符を含めず、生の文字列のみを入力することが重要です。

<b>SUPABASE_URL_1</b>: プロジェクトのRESTエンドポイント (例: https://[PROJECT_ID].supabase.co)
<b>SUPABASE_KEY_1</b>: anon (anonymous) 公開APIキー

⚠️ <b>セキュリティ上の注意点:</b> 認証には必ず <b>anon</b> キーを使用してください。<b>service_role</b> キーはRow Level Security (RLS) をバイパスする権限を持つため、死活監視目的での使用は過剰な権限付与となり、セキュリティリスクを増大させます。

## ワークフローの実装

<b>.github/workflows/keepalive.yml</b> として以下の定義を作成します。<b>workflow_dispatch</b> を含めることで、スケジュール待機なしで手動テストが可能になります。

```yaml
name: Supabase Keep Alive

on:
  schedule:
    - cron: '0 0 */5 * *' # 5日ごとの午前0時に実行
  workflow_dispatch: # 手動実行を許可

jobs:
  keepalive:
    runs-on: ubuntu-latest
    steps:
      - name: Ping Supabase Project
        run: |
          curl -s "${{ secrets.SUPABASE_URL_1 }}/rest/v1/" \
          -H "apikey: ${{ secrets.SUPABASE_KEY_1 }}" \
          -H "Authorization: Bearer ${{ secrets.SUPABASE_KEY_1 }}"
```

## Cron構文の解析と実行間隔の最適化

Supabaseの停止閾値は7日間であるため、実行間隔は余裕を持って5日 (<b>*/5</b>) に設定します。POSIX標準のcron構文に基づき、以下のパラメータで制御されます。

<b>0 0 */5 * *</b>: 5日おきの00:00に実行。GitHub Actionsの共有ランナーの負荷状況により、実際の実行開始時間は数分から数十分遅延する可能性がありますが、死活監視の目的においては許容範囲内です。

## Troubleshooting

実装時に直面する可能性のある主要なエラーとその対策を以下に示します。

1. <b>401 Unauthorized</b>: <b>SUPABASE_KEY_1</b> が正しく設定されていない、または <b>apikey</b> ヘッダーが欠落している場合に発生します。Secretの値に不要なスペースや改行が含まれていないか確認してください。
2. <b>404 Not Found</b>: <b>SUPABASE_URL_1</b> の末尾に <b>/rest/v1/</b> が正しく付与されているか確認してください。エンドポイントが不正確な場合、アクティビティとしてカウントされないリスクがあります。
3. <b>Workflow not triggering</b>: GitHub Actionsのスケジュール実行は、リポジトリに一定期間コミットがない場合に無効化されることがあります。その場合は、手動でワークフローを再有効化するか、ダミーのコミットを定期的にプッシュする構成を検討してください。

## 運用検証ログ

GitHub Actionsのコンソール上で正常にリクエストが完了した場合、以下のプロトコルログが出力されます。HTTPステータスコードが200 OK（またはスキーマ情報を含むJSONレスポンス）であれば、Supabase側でアクティビティとして受理されています。

```text
Run curl -s "***" -H "apikey: ***" -H "Authorization: Bearer ***"
{
  "swagger": "2.0",
  "info": {
    "title": "PostgREST API",
    "description": "Standard REST interface for any PostgreSQL database"
  },
  "host": "your-project.supabase.co",
  "basePath": "/",
  "schemes": ["https"]
}

Process completed with exit code 0
```

## Operational Notes

本手法はあくまでFree Planの制限内での運用を補助するものであり、本番環境やミッションクリティカルなサービスにおいては、Pro Planへのアップグレードによる自動停止の無効化を推奨します。また、GitHub Actionsの実行ログを定期的に監視し、APIキーの有効期限やエンドポイントの変更に追従できる体制を維持してください。