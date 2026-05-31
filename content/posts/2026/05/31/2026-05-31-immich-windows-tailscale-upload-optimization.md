---
title: "Windows 11 ProとWSL2環境におけるImmichサーバー構築とTailscaleによるセキュアな外部アクセス実装"
slug: "immich-windows-tailscale-upload-optimization"
date: 2026-05-21T17:44:15+09:00
draft: false
image: ""
description: "Windows 11 ProとWSL2を基盤に、Immichを用いたセルフホスト型写真管理サーバーを構築。Tailscaleによるセキュアな外部接続と、Upload Optimizerによるストレージ容量の動的制御を実装したエンジニアリングログ。"
categories: ["Linux System Admin"]
tags: ["immich", "wsl2", "docker-desktop", "tailscale", "upload-optimizer"]
author: "K-Life Hack"
---

# WSL2およびDocker Desktop環境におけるImmichの構築とTailscaleによるセキュアな外部アクセスの確立

Windows 11 Pro環境でImmichを運用するためには、Linuxネイティブなバイナリを実行するための<b><mark>WSL2</mark></b>バックエンドが必須となります。まず、Windowsの機能の有効化から「Linux用Windowsサブシステム」および「仮想マシンプラットフォーム」を有効にします。再起動後、Docker Desktopをインストールしますが、この際「Use WSL 2 instead of Hyper-V」のオプションを必ず選択してください。

WSLのバージョンが古い場合、Dockerエンジンの起動に失敗するケースがあります。その際は、管理者権限のコマンドプロンプトから以下のコマンドを実行し、サブシステムを最新の状態に同期させます。

```bash
wsl --update
wsl --shutdown
```

これにより、2026年現在の最新カーネルが適用され、Immichのマイクロサービス群が要求するシステムコールとの互換性が確保されます。

## Tailscaleを用いたメッシュVPNによる外部アクセス経路の確立

ポート開放や動的DNSの設定を回避し、セキュアなリモートアクセスを実現するために<b><mark>Tailscale</mark></b>を導入します。TailscaleはWireGuardプロトコルをベースとしたメッシュVPNであり、キャリアグレードNAT（CGNAT）環境下でも安定した通信を可能にします。

🛠️ 構築手順：まずMini PC（サーバー側）にTailscaleをインストールし、認証を完了させます。次にTailscale管理コンソールから、当該デバイスに割り当てられた固定IP（例: 100.x.x.x）を確認します。モバイルデバイス（iOS/Android）にもTailscaleを導入し、同一アカウントでログインすることで、物理的なネットワーク構成に依存しないプライベートな通信路が確立されます。

この構成により、外出先からでもサーバーのローカルIPを指定するだけで、写真のバックアップと閲覧が可能になります。

## Docker ComposeによるImmichスタックのデプロイと環境変数定義

Immichのデプロイには、保守性と再現性を担保するためにDocker Composeを利用します。まず、`C:\immich-server`ディレクトリを作成し、その配下にメディア保存用の`library`フォルダを配置します。設定ファイルである`.env`および`docker-compose.yml`の構成を定義します。

`.env`ファイル内でのパス指定は、Dockerのボリュームマウント仕様に基づき、Windows形式ではなくスラッシュを用いた形式で記述する必要があります。

```text
UPLOAD_LOCATION=C:/immich-server/library
DB_PASSWORD=your_secure_password
TZ=Asia/Tokyo
```

次に、`docker compose up -d`を実行してコンテナ群を起動します。初期起動時にはPostgreSQLの拡張機能である`pgvecto-rs`の初期化が行われるため、CPU負荷が一時的に上昇しますが、N100プロセッサの4コア環境であれば数分で安定状態に移行します。

## Immich Upload Optimizerによるストレージ容量の動的制御

1TBのNVMe SSDを効率的に運用するため、アップロードされるメディアのファイルサイズを制限する<b><mark>Immich Upload Optimizer</mark></b>をプロキシとして導入します。このサービスは、クライアントからのリクエストをインターセプトし、指定された閾値を超えるファイルを圧縮してからImmichサーバーへ転送します。

`docker-compose.yml`に以下のサービス定義を追加し、ポート2283をこのプロキシが占有するように構成します。

```yaml
immich-upload-optimizer:
  image: ghcr.io/miguelangel-nubla/immich-upload-optimizer:latest
  ports:
    - "2283:2283"
  environment:
    - IUO_UPSTREAM=http://immich-server:2283
    - IUO_TASKS_IMAGE_MAX_SIZE=4MB
    - IUO_TASKS_VIDEO_MAX_SIZE=40MB
  depends_on:
    - immich-server
  restart: always
```

💡 この設定により、画像は4MB、動画は40MBを超える場合に自動的に最適化処理が実行され、ストレージの枯渇を遅延させることが可能です。

## .envファイルの構文エラーおよびDockerイメージ取得失敗のトラブルシューティング

⚠️ 構築過程で発生しやすいエラーとして、`.env`ファイル内の構文不備があります。特に「key cannot contain a space」というエラーは、変数名の前後に不可視のスペースや全角スペースが混入している場合に発生します。すべての行が`KEY=VALUE`の形式であり、コメントアウトが同一行に存在しないことを確認してください。

また、RedisやPostgreSQLのイメージ取得に失敗する場合は、ネットワークのDNS設定を確認するか、特定のタグを明示的に指定、あるいは以下のコマンドでイメージの強制再取得を試行してください。

```bash
docker compose pull
```

## モバイルクライアントの統合とバックグラウンド同期の最適化

サーバー側の準備が整った後、各スマートフォンのImmichアプリを設定します。サーバーURLにはTailscaleで割り当てられたIPアドレス（例: `http://100.64.0.5:2283`）を入力します。この際、Upload Optimizerのポートを指定することが重要です。

バックグラウンド同期を安定させるため、アプリの設定から「Background Backup」を有効にし、OS側のバッテリー最適化設定からImmichを除外します。これにより、Wi-Fi接続時に自動的に写真がサーバーへ転送される「セット・アンド・フォーゲット」の環境が完成します。

## システムの可搬性とディザスタリカバリの検証

本構成の最大の利点は、`C:\immich-server`ディレクトリを丸ごとバックアップするだけで、システム全体の移行が可能である点です。新しいハードウェアに移行する場合、Docker DesktopとTailscaleをインストールした後、当該ディレクトリをコピーして`docker compose up -d`を実行するだけで、ユーザーアカウント、メタデータ、既存の写真データがすべて復元されます。このポータビリティにより、ハードウェアの故障やアップグレード時にも最小限のダウンタイムで運用を継続できます。