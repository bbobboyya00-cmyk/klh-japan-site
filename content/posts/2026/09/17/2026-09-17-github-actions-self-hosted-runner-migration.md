---
title: "GitHub Actions セルフホストランナー最小バージョン強制適用に伴う移行構成手順"
slug: "github-actions-self-hosted-runner-migration"
date: 2026-09-17T10:13:18+09:00
draft: false
image: ""
description: "GitHub Actionsのセルフホストランナーにおける最小バージョン2.329.0強制適用およびブラウンアウト期間に対応するため、インベントリ監査と段階的な置き換え手順を解説します。"
categories: ["DevOps Logistics"]
tags: ["self-hosted runner"]
author: "K-Life Hack"
---

大規模なCI/CDパイプライン運用において、セルフホストランナーのバイナリ管理を自動化せずに放置すると、コントロールプレーン側のAPI仕様変更に伴う突然のビルド停止リスクが発生します。GitHub Enterprise Cloudにおけるセルフホストランナーの最小バージョン（`2.329.0`）強制適用およびブラウンアウト（Brownout）フェーズの導入は、旧バージョンを使用しているパイプラインに対して意図的な接続制限と疑似障害を発生させます。単にコントロールプレーンへの登録ログのみを確認して正常稼働と判断すると、実際のビルドジョブ実行時にネットワーク隔離やキャッシュエンドポイントの認証エラーによりパイプラインが停止する障害を招きます。本稿では、ブラウンアウト開始前のインベントリ監査から段階的な置き換え、障害発生時の切り戻しプロトコルまでの実務手順を記述します。

## 🛠️ 技術的制約とバージョン要件

今回のアーキテクチャ変更に伴い、GitHub Enterprise Cloudで要求されるセルフホストランナーの運用条件は以下の通りです。

- <b>最小バージョン床値</b>: <b>`2.329.0`</b> 以降
- <b>登録要件</b>: `2.329.0` 未満のランナーバイナリは、ブラウンアウト期間中に意図的な接続ドロップが発生し、完全適用後は新規登録およびジョブ割り当てが不可となります。
- <b>ライフサイクルウィンドウ</b>: 新しいランナーバイナリがリリースされてから<b>30日以内</b>に運用環境のランナーを更新する必要があります。この更新窓口を越えた場合、ジョブ実行層での拒否が発生します。

## 4段階の段階的移行プロトコル

CI/CDパイプラインの全停止を防ぐため、以下のフェーズに沿って移行を進めます。

```text
       [ Phase 1: インベントリ監査 ]
   (バージョン, ラベル, OS, ワークフロー, 所有者の特定)
                         │
                         ▼
      [ Phase 2: カナリア置き換え検証 ]
  (v2.329.0+ 配置 ──► Read-Only スモークテスト ──► 段階的ワークフロー移行)
                         │
                         ▼
     [ Phase 3: 切り戻し &amp; 障害対応定義 ]
   (閾値設定, 予備プール確保, 障害分離)
                         │
                         ▼
     [ Phase 4: 旧バージョンの完全廃止 ]
```

### Step 1: 総合インベントリ監査

コントロールプレーンの静的登録ログのみに依存した場合、オートスケーリング（KEDA、actions-runner-controller、AWS ASG等）により動的に生成されるエフェメラルノードの追跡を取りこぼす危険性があります。以下の項目を統合したマトリクスを作成します。

- ランナーバイナリのバージョン情報 (`runner.version`)
- 割り当てられているカスタムタグおよびラベル (`labels`)
- ベースOSイメージ (Ubuntu, RHEL, Windows Server ビルド番号, カスタムAMI/Dockerタグ)
- 該当ランナーを指定しているワークフロー記述 (`.github/workflows/*.yml`)
- 該当インフラノードの管理担当チーム

### Step 2: 実行パスおよび置き換え経路の検証

新しいランナーバージョン (`&gt;= 2.329.0`) を独立した検証プールに配置し、読み取り専用のワークフローを用いて動作検証を実施します。

```yaml
# 検証用ワークフロー例 (.github/workflows/runner-validation.yml)
name: Runner Environment Validation
on:
  workflow_dispatch:

jobs:
  validate-runner:
    runs-on: [self-hosted, linux, x64, validation-pool]
    steps:
      - name: Checkout Source Code
        uses: actions/checkout@v4

      - name: Test Dependency Cache Access
        uses: actions/cache@v4
        with:
          path: ~/.cache/pip
          key: ${{ runner.os }}-pip-validation
          restore-keys: |
            ${{ runner.os }}-pip-

      - name: Verify Environment Variables and Runtime
        run: |
          echo "Runner Version Check:"
          ./run.sh --version || true
          echo "Network Connectivity Check:"
          curl -Is https://pipelines.actions.githubusercontent.com | head -n 1
```

検証時には以下のコンポーネントが正常に機能するかを確認します。

1. `actions/checkout` によるGit資格情報およびプロキシ経由のソースコード取得
2. `actions/cache` によるストレージエンドポイント（S3、GCS、Blob Storage）への読み書き権限
3. OIDCトークン交換およびIAMロール引き受けプロトコル

### Step 3: 緊急切り戻しおよびブラウンアウト対応基準の策定

ブラウンアウト期間中は意図的なエラーが注入されるため、インフラのバージョン更新作業とアクティブな障害対応を明確に分離します。

- エスカレーションパスと担当者の定義
- セルフホストランナーの登録失敗時に備えた、フォールバック用クラウドランナープールの事前確保
- ブラウンアウト発生時の作業中断閾値（Abort Threshold）の事前設定

## ⚠️ Troubleshooting

セルフホストランナーのアップデート時および運用中に発生する典型的なトラブルシューティング手順です。

### 1. `config.sh` 実行時のプロキシ/SSL証明書エラー

企業内ネットワーク環境下でランナーを更新する際、環境変数が引き継がれず登録APIへの接続がタイムアウトする場合があります。

<b>原因</b>: ランナーディレクトリ内の `.env` および `.path` ファイルにプロキシ設定が正しく記述されていない。

<b>対策</b>: ランナーのルートディレクトリに `.env` を作成し、明示的に設定を追加します。

```bash
cat &lt;&lt; 'EOF' &gt; /opt/actions-runner/.env
HTTP_PROXY=http://proxy.internal.example.com:8080
HTTPS_PROXY=http://proxy.internal.example.com:8080
NO_PROXY=169.254.169.254,.internal.example.com
EOF
```

### 2. systemd サービス起動時の権限不足および `svc.sh` の失敗

新しいバージョンへバイナリを置き換えた際、systemd ユニットファイルの実行権限不整合によりサービスが起動しないケースがあります。

<b>対策</b>: 既存サービスを停止・アンインストールした上で、適切な権限で再登録を行います。

```bash
cd /opt/actions-runner
sudo ./svc.sh stop
sudo ./svc.sh uninstall
sudo chown -R runner-user:runner-group /opt/actions-runner
sudo ./svc.sh install runner-user
sudo ./svc.sh start
```

### 3. Actions Runner Controller (ARC) における旧イメージの滞留

Kubernetes上でARCを使用している場合、RunnerDeploymentやRunnerSetのカスタムリソース（CRD）内でイメージタグがハードコーディングされていると、Podの再作成時に旧バージョン（&lt; `2.329.0`）が適用され続けます。

<b>対策</b>: マニフェスト内の `spec.template.spec.containers` イメージタグを `2.329.0` 以降に更新し、Podのローリングアップデートを実行します。

## 💡 Operational Notes

移行完了後の正常性を検証するため、対象ノードで以下の確認コマンドを実行し、プロセスの稼働状態およびバージョン情報をログとして採取します。

```text
$ sudo systemctl status actions.runner.*.service --no-pager
● actions.runner.org-repo.node01.service - GitHub Actions Runner (org-repo.node01)
     Loaded: loaded (/etc/systemd/system/actions.runner.org-repo.node01.service; enabled; vendor preset: enabled)
     Active: active (running) since Thu 2026-09-17 09:15:22 UTC; 2h 40min ago
   Main PID: 14205 (Runner.Listener)
      Tasks: 18 (limit: 9451)
     Memory: 112.4M
        CPU: 1.820s
     CGroup: /system.slice/actions.runner.org-repo.node01.service
             ├─14205 /opt/actions-runner/bin/Runner.Listener run --startuptype service
             └─14218 /opt/actions-runner/bin/Runner.Worker

$ cat /opt/actions-runner/.runner
{
  "agentId": 1042,
  "agentName": "node01",
  "poolId": 1,
  "poolName": "Default",
  "serverUrl": "https://pipelines.actions.githubusercontent.com/",
  "gitHubUrl": "https://github.com/my-org",
  "workFolder": "_work"
}

$ /opt/actions-runner/config.sh --version
2.329.0
```

ブラウンアウト期間およびその後の完全適用に向け、各環境における動的ランナープールを含めたログ監視とバージョン固定の解除を継続的に実施する必要があります。