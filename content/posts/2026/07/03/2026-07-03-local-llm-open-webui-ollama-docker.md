---
title: "Docker環境におけるOpen WebUIとOllamaを用いたローカルLLM基盤の構築"
slug: "local-llm-open-webui-ollama-docker"
date: 2026-07-03T10:52:53+09:00
draft: false
image: ""
description: "Dockerを使用したOpen WebUIとOllamaの統合手順、GPU最適化、およびコンテナ間通信のトラブルシューティングを解説する実装ノート。"
categories: ["DevOps Logistics"]
tags: ["ollama", "open-webui", "docker-container", "gpu-acceleration", "llm-infrastructure"]
author: "K-Life Hack"
---

ローカル環境での大規模言語モデル（LLM）運用において、ホストOSへの直接的なライブラリ導入は、Pythonの依存関係の競合やGPUドライバとの整合性問題、いわゆる「依存関係の地獄」を招くリスクが極めて高いです。特に、複数のモデルを試行する研究開発フェーズでは、環境の分離と再現性が運用の継続性を左右します。本稿では、推論エンジンであるOllamaと、高度なUIを提供するOpen WebUIをDockerコンテナ上で統合し、セキュアかつポータブルなプライベートAI基盤を構築する手法について記述します。

## 構成の合理性とコンテナ化の意義

Open WebUIをDockerでデプロイすることは、単なる利便性の向上ではなく、インフラ管理における標準的なプラクティスです。コンテナ化により、ホスト側のネットワークスタックやファイルシステムを汚染することなく、永続的なデータボリュームの管理と、ホストゲートウェイを介した推論エンドポイントへの安全なアクセスが可能になります。これにより、OS (OSの再インストール)を伴うような致命的な設定ミスを回避しつつ、スケーラブルなインターフェースを提供できます。

## デプロイメント・ワークフロー

### 1. Docker Runtimeの準備と仮想化の検証

まず、コンテナランタイムが正常に動作していることを確認します。Windows環境ではWSL2（Windows Subsystem for Linux）のバックエンドが必須となります。

*   💡 <b>仮想化の有効化:</b> BIOS/UEFI設定で「Virtualization Technology」（VT-xまたはAMD-V）が有効であることを確認してください。これが無効な場合、Docker Engineの初期化に失敗します。
*   🛠️ <b>バイナリの確認:</b> ターミナルで以下のコマンドを実行し、パスが通っていることを確認します。

```bash
docker --version
```

### 2. Open WebUIコンテナの実行

ホストマシンでOllamaサービスが稼働していることを前提とし、以下のコマンドでOpen WebUIを起動します。この際、ホストとコンテナ間の通信を確立するためのネットワークフラグが重要となります。

```bash
docker run -d -p 3000:8080 \
  --add-host=host.docker.internal:host-gateway \
  -v open-webui:/app/backend/data \
  --name open-webui \
  --restart always \
  ghcr.io/open-webui/open-webui:main
```

<b>主要パラメータの技術的解説:</b>

*   <b>-p 3000:8080:</b> ホストの3000番ポートをコンテナ内部の8080番にマッピングします。
*   <b>--add-host=host.docker.internal:host-gateway:</b> コンテナ内部からホスト側で動作しているOllama APIにアクセスするためのブリッジ設定です。
*   <b>-v open-webui:/app/backend/data:</b> チャット履歴やユーザー設定を保持するための名前付きボリュームです。コンテナを破棄してもデータは維持されます。
*   <b>--restart always:</b> システム再起動時やプロセス異常終了時に自動でコンテナを復旧させます。

## Ollamaとの統合とモデル管理

コンテナが起動した後、ブラウザからポート3000番にアクセスし、管理者アカウントを作成します。データはローカルのSQLiteまたはPostgreSQLに保存され、外部への漏洩はありません。

*   <b>接続確認:</b> 設定メニューからOllamaの接続ステータスを確認します。host.docker.internal経由で通信が行われます。
*   <b>モデルのプル:</b> UI上部のモデル選択から、必要なモデル（例: llama3:8b）を指定してダウンロードします。Llama 3 8Bモデルは約4.7GBのストレージを消費します。

## Troubleshooting

運用中に遭遇する代表的な摩擦点とその解決策を以下に示します。

*   ⚠️ <b>ポート競合 (Port 3000 Conflict):</b> 他のWebサービスが3000番を使用している場合、-p 3001:8080 のようにホスト側のポートを変更して再デプロイしてください。
*   ⚠️ <b>接続拒否 (Connection Refused):</b> Open WebUIがOllamaに接続できない場合、ホスト側のOllamaが外部接続を許可しているか確認してください。必要に応じて環境変数 OLLAMA_HOST=0.0.0.0 を設定し、サービスを再起動します。
*   ⚠️ <b>GPUオフロードの失敗:</b> 推論速度が極端に遅い（1-2 tokens/s）場合、VRAM容量が不足しているか、OllamaがCPUモードで動作しています。タスクマネージャーの「専用GPUメモリ」を確認し、モデルサイズがVRAM（8GB以下は8Bモデル推奨、16GB以上は70Bモデル検討）に収まっているか検証してください。

## 稼働状態の検証

デプロイ完了後、以下のコマンドを使用してコンテナの整合性とネットワークの疎通を確認します。

```text
# コンテナのステータス確認
$ docker ps --filter "name=open-webui"
CONTAINER ID   IMAGE                                COMMAND                  STATUS          PORTS                    NAMES
7f8e9d0c1b2a   ghcr.io/open-webui/open-webui:main   "/app/backend/start.…"   Up 15 minutes   0.0.0.0:3000-&gt;8080/tcp   open-webui

# ホスト側ポートのリッスン状態確認
$ ss -tulpn | grep :3000
tcp   LISTEN 0      4096            0.0.0.0:3000       0.0.0.0:*    users:(("docker-proxy",pid=1234,fd=4))

# APIエンドポイントへの疎通確認
$ curl -I http://localhost:3000
HTTP/1.1 200 OK
Content-Type: text/html; charset=utf-8
Content-Length: 1234
```

## Operational Notes

ローカルLLM環境の構築は、サブスクリプションコストの削減だけでなく、機密性の高いコードや内部文書を外部APIに送信することなく処理できるというセキュリティ上の大きな利点があります。Dockerによる抽象化レイヤーを維持することで、将来的なハードウェアのアップグレードや、異なる推論バックエンドへの移行も容易になります。特にVRAM 16GB以上の環境では、Llama 3 70Bクラスのモデルを実用的な速度で運用可能であり、高度な推論タスクを完全にオフラインで完結させることが可能です。