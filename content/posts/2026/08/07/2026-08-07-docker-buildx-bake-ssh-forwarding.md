---
title: "Docker Buildx BakeのSSHフォワーディングを利用した秘密鍵非保持ビルドの構成パターン"
slug: "docker-buildx-bake-ssh-forwarding"
date: 2026-08-07T10:05:56+09:00
draft: false
image: ""
description: "Dockerビルド時のSSH Permission Deniedを解消し、コンテナイメージ内に秘密鍵を残留させずにプライベートリポジトリを安全に取得するためのBuildx Bake SSHフォワーディングの実装手順とトラブルシューティングを解説します。"
categories: ["Linux System Admin"]
tags: ["ssh key permission denied"]
author: "K-Life Hack"
---

インフラストラクチャの自動化およびコンテナ化の過程において、ビルド時に組織内のプライベートGitリポジトリや非公開パッケージ（npm、Pythonホイール等）の引き込みが必要となるケースは一般的です。従来、この問題に対してDockerfile内で <code>COPY</code> や <code>ADD</code> 命令を使用し、SSH秘密鍵を直接コンテナ内に配置する運用が見られました。

しかし、ビルド手順の後続で鍵ファイルを削除したとしても、中間イメージのレイヤー履歴に秘密鍵が永久に残存するため、<code>docker history</code> やレイヤー抽出ツールによって認証情報が漏洩するリスクが存在します。このようなセキュリティ上の制約を回避しつつ <code>Permission denied (publickey)</code> エラーを解決するため、Docker Buildx BakeにおけるSSHフォワーディング機能を用いた構成手法を整理します。

### SSHフォワーディングの動作原理

Docker Buildx BakeのSSHフォワーディングメカニズムは、ホストマシン上の <code>ssh-agent</code> ソケットをビルド実行中の特定の <code>RUN</code> ステップにのみ一時的にマウントします。これにより、鍵ファイルそのものをファイルシステムにコピーすることなく、ソケット経由で暗号化ハンドシェイクを完結させます。

```text
[ Host SSH Agent ] ---&gt; ( UNIX Domain Socket ) ---&gt; [ Build Container Mount ]
                                                            |
                                                  [ Git Authentication ]
                                                            |
                                                [ Socket Closed on Exit ]
```

ビルドステップ終了と同時にソケットマウントは解除されるため、最終的に生成されるイメージレイヤーにはSSH鍵のデータが一切残存しません。

### 設定ファイルの基本構成

SSHフォワーディングを有効化するには、<code>docker-bake.hcl</code> と <code>Dockerfile</code> の双方が正しく連携するよう設定します。

#### 1. docker-bake.hcl

ターゲットビルドに対して <code>ssh</code> パラメータを定義し、デフォルトのソケットバインドを指定します。

```hcl
target "app" {
  context = "."
  ssh     = ["default"]
}
```

#### 2. Dockerfile

SSH接続を必要とする <code>RUN</code> 命令に対し、<code>--mount=type=ssh</code> オプションを明示的に付与します。

```dockerfile
FROM alpine:3.19

RUN apk add --no-cache git openssh-client

# SSHソケットをマウントしてプライベートリポジトリを取得
RUN --mount=type=ssh \
    git clone git@github.com:company/private-repository.git /app
```

### ローカル環境での実行手順

🛠️ ホスト環境でビルドを実行する際、<code>ssh-agent</code> が起動しており、対象の鍵が追加されている必要があります。

```bash
# 1. SSH Agentの起動
eval $(ssh-agent -s)

# 2. 秘密鍵の追加
ssh-add ~/.ssh/id_rsa

# 3. 登録済み鍵の確認
ssh-add -l

# 4. Bakeコマンドの実行
docker buildx bake app
```

### パッケージマネージャー依存関係での応用

<code>git clone</code> だけでなく、SSH経由で取得する非公開依存パッケージのインストール処理にも応用可能です。

```dockerfile
FROM node:20-slim

RUN apt-get update &amp;&amp; apt-get install -y --no-install-recommends git openssh-client \
    &amp;&amp; rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/app

# npm経由でプライベートリポジトリのパッケージをインストール
RUN --mount=type=ssh \
    npm install git+ssh://git@github.com:company/private-pkg.git
```

### CI/CDパイプラインとの統合

自動化されたCI/CD環境では、リポジトリ内に鍵を直接配置せず、パイプラインのシークレット変数から動的に <code>ssh-agent</code> へ注入します。

#### GitHub Actions 統合例

```yaml
name: Build Container Image

on:
  push:
    branches: [ "main" ]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Setup SSH Keys
        uses: webfactory/ssh-agent@v0.9.0
        with:
          ssh-private-key: ${{ secrets.SSH_PRIVATE_KEY }}

      - name: Build with Buildx Bake
        run: |
          docker buildx bake app
```

#### GitLab CI 統合例

```yaml
build_job:
  stage: build
  image: docker:24.0.7
  services:
    - docker:24.0.7-dind
  before_script:
    - eval $(ssh-agent -s)
    - echo "$SSH_PRIVATE_KEY" | tr -d '' | ssh-add -
  script:
    - docker buildx bake app
```

## Troubleshooting

⚠️ 実務において発生する主なエラーと原因、対処ワークフローを整理します。

| エラー症状 | 主な原因 | 確認コマンド / 対処方法 |
| :--- | :--- | :--- |
| `Permission denied (publickey)` | ホストの `ssh-agent` に鍵が未登録、またはGitサービス側の公開鍵設定不備 | `ssh-add -l` で鍵の存在を確認し、`ssh-add ~/.ssh/id_rsa` を実行 |
| `SSH_AUTH_SOCK` 関連エラー | ホスト上でAgentプロセスが起動していない | `echo $SSH_AUTH_SOCK` の出力有無を確認し、`eval $(ssh-agent -s)` を再実行 |
| `git: command not found` または `ssh: command not found` | コンテナイメージ側に `git` や `openssh-client` パッケージが未導入 | Dockerfileのベースイメージ準備段階で `apt` や `apk` によるパッケージ追加を実施 |

### システム検証プロトコルログ

ビルド実行時の動作検証、および最終イメージに鍵データが含まれていないことを証明するターミナルログの出力例です。

```text
$ ssh-add -l
2048 SHA256:abc123xyz890... /home/user/.ssh/id_rsa (RSA)

$ docker buildx bake app
[+] Building 4.2s (8/8) FINISHED
 =&gt; [internal] load build definition from Dockerfile                              0.0s
 =&gt; =&gt; transferring dockerfile: 210B                                              0.0s
 =&gt; [internal] load .dockerignore                                                 0.0s
 =&gt; =&gt; transferring context: 2B                                                   0.0s
 =&gt; [internal] load metadata for docker.io/library/alpine:3.19                    1.1s
 =&gt; [1/3] FROM docker.io/library/alpine:3.19@sha256:c5b54...                     0.0s
 =&gt; [2/3] RUN apk add --no-cache git openssh-client                               1.8s
 =&gt; [3/3] RUN --mount=type=ssh git clone git@github.com:company/private-repo.git  1.2s
 =&gt; exporting to image                                                            0.1s
 =&gt; =&gt; exporting layers                                                           0.1s
 =&gt; =&gt; writing image sha256:8f431a...                                             0.0s

$ docker run --rm -it app:latest ls -la /root/.ssh
ls: /root/.ssh: No such file or directory
```

## Operational Notes

🛠️ <b>1. 最小権限原則の適用</b>: CI/CD環境へ注入するSSH鍵には、個人の秘密鍵ではなく、特定リポジトリへの読み取り権限のみを付与したデプロイキー（Deploy Keys）を設定してください。

⚠️ <b>2. プロトコルの統一</b>: Dockerfile内のリポジトリ指定には、HTTP(S)形式（<code>https://...</code>）ではなく、必ずSSH形式（<code>git@...</code>）を使用してください。

💡 <b>3. Agentのクリーンアップ</b>: 開発用ホスト環境で作業終了後は <code>ssh-add -D</code> を使用し、Agent上の秘密鍵メモリを破棄する習慣を推奨します。