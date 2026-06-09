---
title: "rcloneによるNAS・Google Drive間同期のパフォーマンス改善と自動化の実装"
slug: "rclone-gdrive-api-performance-optimization"
date: 2026-06-09T10:06:47+09:00
draft: false
image: ""
description: "rcloneのデフォルトAPI制限による転送速度低下を解決するため、専用OAuthクライアントIDの導入とWindowsタスクスケジューラによる2時間周期の同期自動化を実装した技術ノート。"
categories: ["Linux System Admin"]
tags: ["rclone", "google-drive-api", "nas-synchronization", "windows-task-scheduler", "bisync"]
author: "K-Life Hack"
---

NASとGoogle Drive（Google Workspace共有ドライブ）間の同期運用において、初期設定後の運用データから深刻なパフォーマンスのボトルネックが確認されました。本稿では、転送速度の向上と同期遅延の解消を目的とした、専用APIキーの導入および同期サイクルの最適化プロセスについて記述します。

## 1. 現状分析と課題の特定

1.1TB規模のipTIME NASデータをGoogle Driveへ同期する環境において、約2週間の運用テストを実施した結果、以下の2つの制約が明らかになりました。

💡 <b>転送速度の停滞</b>：ギガビットネットワーク環境下であるにもかかわらず、rclone copy実行時の速度が1MB/s〜3MB/s程度で推移。特に数万件の小規模ファイルを含むディレクトリにおいて、同期完了までに多大な時間を要していました。

⚠️ <b>同期遅延による業務への影響</b>：当初設定していた「1日1回（午前2時）」のスケジュールでは、午前中に作成されたドキュメントが翌日までクラウドに反映されず、即時性を求めるユーザーが手動でファイルを転送する事態が発生していました。

## 2. 技術的根本原因：共有APIクォータの制限

rcloneのデフォルト設定では、世界中のユーザーが共有する「Global Default OAuth Client ID」が使用されます。Google APIにはクライアントIDごとに1秒間および1日あたりのリクエスト上限（Quota）が設定されており、共有IDを使用すると他ユーザーの影響で容易に制限に達します。

制限に達した場合、Google側から API rate exceeded や userRateLimitExceeded エラーが返され、rcloneはバックオフ（待機）状態に入ります。これが、実効スループットが極端に低下する直接的な原因です。この問題を解決するには、Google Cloud Consoleで組織専用 of OAuthクライアントID/シークレットを発行し、専用のクォータを確保する必要があります。

## 3. 専用APIキーの発行と設定手順

### 3.1 Google Cloud Consoleでの設定

🛠️ <b>プロジェクトの作成</b>：Google Cloud Console（https://console.cloud.google.com）にて、新規プロジェクト（例: rclone-sync-project）を作成します。

🛠️ <b>APIの有効化</b>：「APIとサービス > ライブラリ」から「Google Drive API」を検索し、有効化します。

🛠️ <b>OAuth同意画面の設定</b>：「OAuth同意画面」にて、ユーザータイプを「内部（Internal）」に設定します。これにより、Google Workspaceドメイン内のユーザーに利用を制限し、トークンの有効期限問題を回避します。

🛠️ <b>認証情報の作成</b>：「認証情報 > 認証情報を作成 > OAuthクライアントID」を選択します。アプリケーションの種類は「デスクトップアプリ」を指定します。

🛠️ <b>IDとシークレットの保存</b>：生成された「クライアントID」と「クライアントシークレット」を安全な場所に記録します。

### 3.2 rclone構成の更新

既存のリモート設定に新しい認証情報を適用します。

```ini
[gdrive]
type = drive
client_id = your_own_client_id.apps.googleusercontent.com
client_secret = your_own_client_secret
scope = drive
```

## 4. 同期自動化の最適化（2時間サイクル）

データの鮮度とシステム負荷のバランスを考慮し、同期頻度を2時間周期に設定します。同期には、双方向の整合性を維持するbisyncコマンドを採用します。

### 4.1 同期用バッチファイルの作成

C:\rclone\sync.batとして以下のスクリプトを構成します。専用APIキーを適用したことで、--transfers（同時転送数）を8まで引き上げてもスロットリングが発生しにくくなります。

```bat
@echo off
rclone bisync C:\nas_data gdrive:shared_drive --transfers 8 --log-file C:\rclone\rclone.log --verbose
```

### 4.2 Windowsタスクスケジューラの設定

🛠️ <b>全般</b>：「ユーザーがログオンしているかどうかにかかわらず実行する」および「最上位の特権で実行する」を選択します。

🛠️ <b>トリガー</b>：毎日実行、繰り返し間隔を「2時間」、継続時間を「1日間」に設定します。

🛠️ <b>操作</b>：C:\rclone\sync.batを指定し、「開始（オプション）」にC:\rcloneを入力します。

🛠️ <b>設定</b>：「タスクが既に実行中の場合に適用される規則」を「新しいインスタンスを開始しない」に設定し、プロセスの重複を防止します。

## 5. 導入後のパフォーマンス比較

| 指標 | フェーズ1 (デフォルトAPI + 1日1回) | フェーズ2 (専用API + 2時間周期) |
| :--- | :--- | :--- |
| <b>平均転送速度</b> | 1–3 MB/s | 15–30 MB/s |
| <b>同期遅延 (最大)</b> | 24時間 | 2時間 |
| <b>スロットリング発生</b> | 頻繁に発生 | ほぼ解消 |
| <b>システム負荷</b> | 深夜に集中（高バースト） | 分散実行（低負荷） |

## Operational Notes

⚠️ <b>トークンの有効期限</b>：OAuth同意画面が「外部（External）」かつ「テスト」状態の場合、トークンは7日で失効します。必ず「内部」または「公開」状態を確認してください。

💡 <b>ログ管理</b>：--log-fileによるログ出力は必須です。同期エラーや競合が発生した際の唯一の診断手段となります。

💡 <b>bisyncの特性</b>：bisyncは初回実行時にパスの整合性をチェックするため、大規模なディレクトリでは初回のみ時間を要します。安定稼働後は変更差分のみをスキャンするため、数分で完了します。