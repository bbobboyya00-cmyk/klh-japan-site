---
title: "GitHub ActionsによるSpring Boot CIパイプライン構築とマージ競合・障害解析"
slug: "github-actions-ci-pipeline-diagnostics-merge-resolution"
date: 2026-10-25T10:35:55+09:00
draft: false
image: ""
description: "GitHub Actionsを用いたSpring Boot CIパイプラインの構築手順と、マージ競合発生時のワークフロー配置障害やテスト失敗アーティファクト回収による障害解析手法を解説します。"
categories: ["DevOps Logistics"]
tags: ["github-actions", "gradle", "ci-cd", "git-merge", "spring-boot"]
author: "K-Life Hack"
---

ソフトウェア開発プロセスにおいて、ローカル環境でのテスト実行のみに依存した変更の適用は、ターゲットブランチへの不安定なコードの混入を引き起こす原因となります。特に複数メンバーでの並行開発下では、Gitブランチ構成の複雑化やコンフリクト解決時の設定誤りによって、CI/CDパイプラインが正常に発火しなくなるリスクが常に存在します。

本記事では、GitHub Actionsを活用したSpring Bootプロジェクトの自動ビルド・テスト検証パイプラインの構築手法と、マージ競合の解消過程で発生したワークフローファイルのパス逸脱問題、およびテスト失敗時の診断アーティファクト収集メカニズムについて記述します。

## GitHub Actionsの基本構造と宣言的パイプライン設計

GitHub Actionsで実行される自動化処理（Workflow）は、リポジトリ内の特定ディレクトリに配置されたYAML宣言ファイルによって定義されます。実行エンジンはエフェメラル（使い捨て）な仮想マシンコンテナ上で稼働するため、依存環境のセットアップや実行ステップを漏れなく明示する必要があります。

### ディレクトリ構成の厳格な規約

GitHub Actionsのパイプライン定義ファイルは、以下のパスに厳格に配置されている必要があります。

```text
.github/workflows/ci.yml
```

このパス構造から外れた場所（例: <code>docs/ci.yml</code> や <code>.github/ci.yml</code>）にファイルを配置した場合、GitHubのイベント検知エンジンはこれをワークフロー定義として認識しません。

### Spring Boot CIワークフローの実装例

以下は、<code>main</code> ブランチへのコードPushおよびPull Requestをトリガーとして、Gradleビルドとテストを実行する一般的なワークフロー設定です。

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-24.04

    steps:
      - name: Checkout Source Code
        uses: actions/checkout@v4

      - name: Provision Temurin JDK 21
        uses: actions/setup-java@v4
        with:
          distribution: 'temurin'
          java-version: '21'

      - name: Set Executable Permission for Gradle Wrapper
        run: chmod +x ./gradlew

      - name: Execute Automated Unit Tests
        run: ./gradlew test

      - name: Preserve Test Failure Artifacts
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: test-report
          path: build/reports/tests/test/
          if-no-files-found: warn
```

## マージ競合とワークフローパス逸脱の復旧処理

機能開発ブランチ（<code>lab/ci</code>）の運用中に、リモートの <code>main</code> ブランチ側で並行して変更が加わった場合、Pull Request上でマージ競合（Merge Conflict）が発生します。

### 競合解消とファイルパスの不整合

ローカル環境でリモートの最新状態を取得し、マージ処理を実施します。

```bash
git switch lab/ci
git fetch cicd
git merge cicd/main
```

このマージ処理（Git 3-way merge <code>ort</code> 戦略）を実行した際、上流ブランチ側の変更履歴によって <code>.github/workflows/ci.yml</code> が意図せず <code>docs/ci.yml</code> に移動（Rename）されるケースが発生することがあります。

ファイルが <code>docs/</code> ディレクトリに移動すると、以降のPushイベントでGitHub Actionsがトリガーされなくなります。この状態を解消するには、Gitコマンドを用いて正しいディレクトリへ配置を復元する必要があります。

```bash
# 誤ったパスから正規のディレクトリ構造へ移動
git mv docs/ci.yml .github/workflows/ci.yml

# 変更のコミットとリモートブランチへのPush
git commit -m "fix: restore workflow definition path"
git push cicd lab/ci
```

## 構造的マージ可能性とアプリケーション検証ステータスの分離

Pull Requestの診断画面において、以下の2つのステータスは明確に区別して解釈する必要があります。

1. <b>Gitの構造的マージ可能性（Merge Conflict Status）</b>: テキストレベルでコミットツリーが結合可能か否かを示します。<code>No conflicts with base branch</code> と表示されている場合、Gitのファイル結合自体は正常に完了します。

2. <b>CIステータスチェック（Status Checks）</b>: アプリケーションのビルドや単体テストが成功したか否かを示します。<code>All checks have failed</code> の場合、Gitレベルでマージ可能であっても、コードは破損状態にあります。

ブランチ保護ルール（Branch Protection Rules）が設定されていない場合、テストが失敗している状態であってもGitHubのUI上では Merge ボタンが押し下げ可能な状態となります。品質ゲートとしてのCIを機能させるには、ステータスチェックの成功をマージの必須条件として構成することが要求されます。

## Troubleshooting

### 1. ワークフローが実行されず「No workflow runs found」と表示される

⚠️ <b>原因</b>: ワークフローファイルの配置パスが <code>.github/workflows/</code> から外れている、またはYAMLファイルのインデント構文エラーが存在します。

🛠️ <b>対策</b>: ファイルパスが <code>.github/workflows/*.yml</code> にあるかを確認します。また、<code>jobs</code> や <code>steps</code> のインデント階層（スペース2文字基準）が正しいかを検証します。

### 2. Gradleテスト失敗時にコンソールログから詳細原因が特定できない

⚠️ <b>原因</b>: Gradleの標準出力ログだけでは、断片的なアサーション失敗や設定ファイルの読み込みエラーの詳細が出力しきれない場合があります。

🛠️ <b>対策</b>: <code>actions/upload-artifact@v4</code> に <code>if: failure()</code> 条件を付与して設定し、<code>build/reports/tests/test/</code> 内のHTMLテストレポートをアーティファクトとして保存します。これにより、パイプライン失敗時にブラウザで詳細なスタックトレースを確認できます。

### 3. リモートへPushした際にシークレットリークの警告で処理が拒否される

⚠️ <b>原因</b>: <code>.env</code> ファイルやハードコードされたAPIキー、プライベートキーがGitコミット履歴に含まれています。

🛠️ <b>対策</b>: 該当の秘密情報をコードベースから削除し、<code>.gitignore</code> に対象ファイルパターンを追加します。過去のコミット履歴に含まれてしまった場合は、認証情報自体を即座に失効・再発行し、<code>GitHub Actions Secrets</code> などの安全なストアに移行します。

## 検証用ターミナルログ

パイプライン配置の正常化およびローカル環境でのビルド動作検証時のターミナル出力例です。

```text
$ git status
On branch lab/ci
Your branch is up to date with 'cicd/lab/ci'.

nothing to commit, working tree clean

$ ls -la .github/workflows/
total 12
drwxr-xr-x 1 runner 1049000     0 Oct 25 10:15 .
drwxr-xr-x 1 runner 1049000     0 Oct 25 10:15 ..
-rw-r--r-- 1 runner 1049000   824 Oct 25 10:15 ci.yml

$ ./gradlew test
BUILD SUCCESSFUL in 8s
4 actionable tasks: 4 executed
```

## Lessons Learned

💡 <b>1. Gitマージ成功とアプリケーション健全性の非等価性</b>: テキストコンフリクトが発生せずにマージできた場合であっても、ビルドやテストが正常に通過することを意味しません。CIパイプラインによる自動検証が不可欠です。

💡 <b>2. 設定ファイルの配置規約の遵守</b>: GitHub Actions等の自動化ツールでは、特定のディレクトリ構造（<code>.github/workflows/</code>）が実行条件となっているため、ブランチ操作時のファイル移動に注意が必要です。

💡 <b>3. 失敗診断アーティファクトの保持</b>: パイプライン失敗時の原因調査コストを削減するため、単にエラー終了させるのではなく、テストレポート等の診断用ファイルを適切に保存する構成が有効です。