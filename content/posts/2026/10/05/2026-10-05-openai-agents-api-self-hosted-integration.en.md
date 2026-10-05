---
title: "Integration Design for Self-Hosted Execution Environments in the OpenAI Agents API"
slug: "openai-agents-api-self-hosted-integration"
date: 2026-10-05T10:12:35+09:00
draft: false
image: ""
description: "Explains the architectural design, codex-exec-server setup, security perimeter establishment, and troubleshooting for integrating the OpenAI Agents API self-hosted execution environment (self_hosted) into your own infrastructure."
categories: ["DevOps Logistics"]
tags: ["self-hosted-runner-사설-인프라-연동"]
author: "K-Life Hack"
---

In enterprise infrastructure design, establishing security perimeters when granting code execution privileges to LLM agents is an extremely challenging problem. Managed sandbox environments provided in the public cloud (such as `openai_hosted`) are suitable for rapid prototyping, but cannot meet requirements for accessing resources within internal private VPCs or satisfying strict data governance rules. Furthermore, transferring highly sensitive source code or internal data to external container environments is generally restricted by compliance constraints.


Against this background, the OpenAI Agents API (released in public beta in September 2026) provides a "self-hosted" (`self_hosted`) execution environment model that delegates control plane orchestration functions to OpenAI while executing actual code execution and filesystem operations on self-managed infrastructure. This article explains the architectural design for safely and stably building this self-hosted environment, deployment procedures for `codex exec-server`, and network/security design for production operations.



---

## 1. Self-Hosted Architecture Connection Model

The core of the self-hosted execution environment lies in the "Outbound-only Connection" model between OpenAI's control plane and the agent execution nodes running within internal infrastructure.


The `codex exec-server` daemon deployed inside internal infrastructure establishes an outbound WebSocket connection (HTTPS/WSS) to OpenAI's servers without opening any external inbound ports. This makes it possible to securely receive tasks and return execution results without modifying firewall inbound rules.



```
┌────────────────────────────────────────────────────────────────────────┐
│                       OpenAI Control Plane (Cloud)                     │
│  - Session Orchestration                                               │
│  - Context Window Compaction                                           │
└──────────────────────────────────┬─────────────────────────────────────┘
                                   ▲
                                   │ Outbound WSS (Port 443)
                                   │ (wss://codex-cloud-environments.chatgpt.com)
┌──────────────────────────────────┴─────────────────────────────────────┐
│                     Customer Private VPC / On-Premise                  │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                      codex exec-server Daemon                    │  │
│  │  - Runs under restricted 'codex-runner' user                     │  │
│  │  - Executes local shell, python, and filesystem mutations        │  │
│  │  - Isolated from Master Application API Keys                     │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────┘
```

### Credential Isolation Design

To ensure security, API key permissions are strictly isolated.



* <b>Master Application Key:</b> Retained by the application server to perform session creation and lifecycle management (requires `api.agents.read`, `api.agents.write`, and `api.responses.write` scopes). This key is never exposed inside the execution environment.
* <b>Environment Scope Key (CODEX_API_KEY):</b> An extremely restricted key used solely by `codex exec-server` to communicate with OpenAI's control plane. This key is not granted permissions for agent operations or model inference execution.

---

## 2. `codex exec-server` Deployment Procedures

Construct the execution daemon as a system service on a self-managed Linux server (assuming an Ubuntu 24.04 LTS environment).



### Step 1: Installing Dependency Packages and Creating a Dedicated User

For security reasons, the daemon must run under a dedicated user other than root.



```bash
# Set up Node.js LTS environment
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs

# Create codex-runner user
sudo useradd -m -s /bin/bash codex-runner

# Install codex daemon as a global package
sudo npm install -g @openai/codex@alpha
```

### Step 2: Creating the systemd Service Definition

To ensure process persistence and automatic restart upon abnormal termination, create `/etc/systemd/system/codex-exec-server.service` as follows.



```ini
[Unit]
Description=Codex Execution Server Daemon
After=network.target

[Service]
Type=simple
User=codex-runner
Group=codex-runner
WorkingDirectory=/home/codex-runner
Environment=NODE_ENV=production
Environment=CODEX_API_KEY=sk-proj-env-restricted-token-here
ExecStart=/usr/bin/codex exec-server \
  --remote "https://api.openai.com/v1" \
  --environment-id "env_your_registered_environment_id"
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target

```bash

bash
# Enabling and starting the service
sudo systemctl daemon-reload
sudo systemctl enable codex-exec-server
sudo systemctl start codex-exec-server

```

---

## 3. Python SDKによるセッション初期化の実装

セルフホスト環境が起動したら、アプリケーション側からその環境を指定してセッションを開始します。以下は、ストリーミングモードでタスクを実行するPythonの実装例です。

```python

python
import os
from openai import OpenAI

# Load master application key from environment variable
api_key = os.getenv("OPENAI_API_KEY")

with OpenAI(api_key=api_key) as client:
    # Initialize session specifying the self-hosted environment ID
    with client.beta.agents.sessions.create(
        agent={
            "model": "gpt-6-astra",
            "instructions": "Write clean Python code, execute it locally, and return the output.",
        },
        environment={
            "type": "self_hosted",
            "id": "env_your_registered_environment_id"
        },
        input="Generate a report of the local system disk usage and list the top 3 directories.",
        stream=True,
    ) as events:
        for event in events:
            # Process event stream in real time
            event_data = event.to_json(indent=2)
            print(event_data, flush=True)

```

---

## 4. ライフサイクルダイナミクスとトラフィック制御

セルフホスト環境におけるエージェントセッションのライフサイクル管理は、コンテナのローリングアップデートやスケーリング時に特有の課題をもたらします。

*   <b>セッションの固定性（Session Affinity）:</b> エージェントのセッションは特定の実行環境ID（`environment_id`）に関連付けられます。実行ノードのメンテナンスやコンテナの入れ替え（Replacement）を行う際、稼働中のセッションが存在する場合にノードを即座に破棄すると、実行中のタスクが異常終了します。
*   <b>無停止スケーリング（Zero-Downtime Scaling）:</b> 新しいバージョンの実行イメージをデプロイする際は、古いノードへの新規セッション割り当てを停止（Drain）し、既存のセッションが完了するかタイムアウト（デフォルトで1時間の無操作による自動クリーンアップ）に達した後に、古いノードを安全にシャットダウンするローリングアップデート戦略を採用する必要があります。

---

## 5. Troubleshooting

セルフホスト環境の構築および運用時に直面しやすい代表的な障害要因と、その解決策を以下に示します。

### 1. WebSocket接続の切断と再確立（Handshake Failures）

*   <b>事象:</b> `codex exec-server`のログに `Connection closed transitionally (code: 1006)` が頻発する。
*   <b>原因:</b> 社内プロキシや次世代ファイアウォール（NGFW）によるSSL/TLSインスペクションが有効な場合、`wss://codex-cloud-environments.chatgpt.com`へのWebSocketハンドシェイクが拒否されることがあります。
*   <b>対策:</b> プロキシサーバー側で、上記ドメインに対するSSL復号化のバイパス設定（SSL Decryption Bypass）を適用してください。

### 2. セットアップコマンドの異常終了（Setup Command Failures）

*   <b>事象:</b> セッション作成時に `environment.failed` イベントが発生し、タスクが実行されない。
*   <b>原因:</b> 環境テンプレートで定義された `setup_commands` が非ゼロの終了コード（$? != 0）を返すと、環境のプロビジョニングフェーズで即座にエラーとなり、セッションが停止します。
*   <b>対策:</b> 各コマンドの末尾に適切なエラーハンドリングを施すか、冪等性を担保したスクリプト構成に修正してください（例: `mkdir -p` の使用、パッケージインストールの `-y` フラグ付与）。

### 3. 権限分離の不備による特権昇格リスク

*   <b>事象:</b> エージェントがホストOS上のシステムファイルを改ざん、または不要なパッケージをシステム全体にインストールしてしまう。
*   <b>原因:</b> `codex exec-server`を `root` ユーザーで起動している、または `sudo` 権限が制限なしで付与されている。
*   <b>対策:</b> 必ず前述の `codex-runner` のような非特権ユーザーを作成し、実行ディレクトリ（`/workspace`に相当するローカルパス）以外の書き込み権限を剥奪してください。

---

## 6. Operational Verification

デプロイ完了後、実行ノードの健全性を確認するための検証コマンドと期待される出力プロトコルログです。

### サービス稼働状態の確認

```text

console
$ systemctl status codex-exec-server
● codex-exec-server.service - Codex Execution Server Daemon
Loaded: loaded (/etc/systemd/system/codex-exec-server.service; enabled; preset: enabled)
Active: active (running) since Mon 2026-10-05 10:00:00 UTC; 15min ago
Main PID: 12345 (node)
Tasks: 11 (limit: 4915)
Memory: 45.2M
CPU: 120ms
CGroup: /system.slice/codex-exec-server.service
└─12345 /usr/bin/node /usr/bin/codex exec-server --remote https://api.openai.com/v1 --environment-id env_your_registered_environment_id

Oct 05 10:00:00 node-01 codex[12345]: [info] Initializing Codex Execution Server...
Oct 05 10:00:01 node-01 codex[12345]: [info] Connecting to remote control plane: wss://codex-cloud-environments.chatgpt.com
Oct 05 10:00:02 node-01 codex[12345]: [info] WebSocket connection established successfully. Listening for tasks...

```

### ネットワーク接続状態の確認

```text

console
$ ss -tulpn | grep node
# Confirm no inbound listening ports exist (Operates on outbound-only, so empty output is normal)

$ ss -tapn | grep -E "(openai|chatgpt)"
ESTAB 0      0      192.168.1.50:54321    104.18.2.10:443    users:(("node",pid=12345,fd=19))
# Confirm ESTABLISHED connection exists to OpenAI control plane (port 443)

```

### コントロールプレーンへの疎通確認

```text

http
$ curl -I -H "OpenAI-Beta: agents=v1" https://api.openai.com/v1/agents/environments
HTTP/2 200
server: cloudflare
date: Mon, 05 Oct 2026 10:05:00 GMT
content-type: application/json; charset=utf-8

```

---

## 7. Operational Notes

セルフホスト型実行環境を本番運用に投入するにあたり、以下の運用ポリシーを策定することを推奨します。

1.  <b>リソース制限（cgroups）の適用:</b> エージェントによる無限ループやメモリリークからホストOSを保護するため、systemdサービス定義内で `CPUQuota=50%` や `MemoryLimit=2G` などのリソース制限を明示的に設定してください。
2.  <b>データ保存期間の管理:</b> セルフホスト環境であっても、コントロールプレーンを通過するセッションの会話履歴や実行ログはOpenAI側に一時的に保持されます。現時点でZero Data Retention（ZDR）はサポートされていないため、個人情報（PII）や極秘データの取り扱いには十分な注意が必要です。
3.  <b>定期的なデーモンの更新:</b> `codex exec-server` はパブリックベータ期間中、頻繁にアップデートが提供されます。パッケージの脆弱性対応およびプロトコル仕様変更に追従するため、週次のメンテナンスウィンドウで `@openai/codex` のバージョン更新を確認するパイプラインを構築してください。