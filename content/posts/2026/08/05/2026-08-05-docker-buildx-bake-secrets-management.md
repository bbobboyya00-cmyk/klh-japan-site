---
title: "Docker Buildx Bakeにおける秘密情報注入のアーキテクチャと実装"
slug: "docker-buildx-bake-secrets-management"
date: 2026-08-05T10:05:55+09:00
draft: false
image: ""
description: "Docker Buildx Bakeを用いたコンテナビルド時における機密情報の安全なハンドリング手法を解説します。ARGやENVの脆弱性を排除し、BuildKitの時限マウント機構を活用した認証情報の保護手順をまとめました。"
categories: ["DevOps Logistics"]
tags: ["docker buildx bake"]
author: "K-Life Hack"
---

コンテナイメージのビルドパイプライン拡張に伴い、プライベートリポジトリのアクセストークンやAPIキー、パッケージマネージャの認証情報をイメージ構築時に受け渡す設計パターンが不可欠となっています。しかし、従来のビルド引数（`ARG`）や環境変数（`ENV`）を用いた認証情報の注入は、イメージのメタデータや中間レイヤーにデータが平文のまま永続化するリスクを伴います。本稿では、Docker Buildx Bakeのシークレット管理機構を導入し、ビルドレイヤーへ機密情報を残さずに安全に依存関係を取得するアーキテクチャと設定手法について整理します。

## 従来のビルド引数におけるセキュリティ上の課題

標準的な`Dockerfile`で以下のように`ARG`を利用してトークンを注入する手法は、セキュリティ監査において重大な脆弱性とみなされます。

```dockerfile
ARG TOKEN
RUN git clone https://$TOKEN@github.com/private/repository.git
```

このパターンの根本的な問題点は以下の通りです。

1. <b>レイヤーメタデータへの永続化</b>: `ARG`および`ENV`で設定された値は、イメージのマニフェストおよびレイヤーキャッシュの履歴に明示的に記録されます。
2. <b>イメージ検査による情報漏洩</b>: 生成されたコンテナイメージに対して `docker history <image-id>` や `docker inspect` を実行することで、第三者が容易に平文のトークンを抽出可能です。
3. <b>サプライチェーンリスクの拡大</b>: 該当イメージがパブリックまたは共有レジストリにプッシュされた場合、インフラのアクセス権限が外部へ漏洩する事故に直結します。

## Docker Buildx Bake Secretsの動作原理

BuildKitエンジンに統合されたシークレット機能は、機密情報をビルドコンテキストのファイルシステムに書き込むことなく、実行中のコンテナプロセスに一時的なマウントポイントとして提供します。

```text
+-------------------+        +----------------------+        +-----------------------+
|  Secret Source    | -----&gt; |  Docker Buildx Bake  | -----&gt; | Temporary Mount Point |
| (File / Host Env) |        | Execution Engine     |        | (/run/secrets/id)     |
+-------------------+        +----------------------+        +-----------------------+
                                                                         |
                                                                         v
                                                             +-----------------------+
                                                             | Executed Build Stage  |
                                                             | (RUN Command Access)  |
                                                             +-----------------------+
                                                                         |
                                                                         v
                                                             +-----------------------+
                                                             | Secret Unmounted &amp;    |
                                                             | Excluded from Layers  |
                                                             +-----------------------+
```

### 実行ライフサイクル

1. <b>バインディング定義</b>: HCL設定ファイル（`docker-bake.hcl`）において、ホスト上のローカルファイルまたは環境変数をターゲットのシークレットとして指定します。
2. <b>一時的マウント注入</b>: `docker buildx bake` の実行時、ビルドエンジンはコンテナ内の `/run/secrets/<id>` にインメモリの一時的マウントを生成します。
3. <b>インメモリ処理</b>: 指定された `RUN` 命令のみが該当パスを参照して認証処理（依存ライブラリのダウンロードやGitクローン）を実行します。
4. <b>即時アンマウント</b>: 当該 `RUN` 命令の完了直後にマウントは解除されます。シークレットの中身が中間レイヤーや最終イメージディスクに書き込まれることはありません。

## 設定および実装仕様

### ローカルファイルベースのシークレット注入

ホスト上のファイルをシークレットソースとして定義する基本形式です。

`docker-bake.hcl` の設定:

```hcl
target "app" {
  secret = [
    "id=token,src=token.txt"
  ]
}
```

Dockerfile` 側での参照:

```dockerfile
FROM alpine:3.20
RUN --mount=type=secret,id=token \
    cat /run/secrets/token
```

実行コマンド:

```bash
docker buildx bake app
```

### ホスト環境変数の直接マウント

ローカルディスクに秘密鍵やトークンを平文ファイルとして保存することを避けるため、ホスト環境変数を直接シークレットとしてコンテナに渡すモードです。

ホスト環境変数のセット:

```bash
export API_KEY="abcdef12345"
```

docker-bake.hcl` の設定:

```hcl
target "app" {
  secret = [
    "id=apikey,env=API_KEY"
  ]
}
```

Dockerfile` 側での参照:

```dockerfile
FROM alpine:3.20
RUN --mount=type=secret,id=apikey \
    API_KEY=$(cat /run/secrets/apikey) &amp;&amp; \
    echo "Processing authenticated task..."
```

## ユースケース別実装例

### SSHエージェント転送を利用したプライベートリポジトリ取得

SSHキーペアを用いたGit操作を行う場合、専用のSSHマウントオプションをターゲットに指定します。

`docker-bake.hcl` の設定:

```hcl
target "app" {
  ssh = [
    "default"
  ]
}
```

Dockerfile` の記述:

```dockerfile
FROM alpine:3.20
RUN apk add --no-cache git openssh-client
RUN mkdir -p -m 0700 ~/.ssh &amp;&amp; ssh-keyscan github.com &gt;&gt; ~/.ssh/known_hosts
RUN --mount=type=ssh \
    git clone git@github.com:company/project.git
```

### GitHub Actions CI/CD パイプライン統合

CI/CD環境において、ワークフローのシークレットをBake経由で安全にビルドコンテキストへ供給する構成例です。

`.github/workflows/build.yml`:

```yaml
name: Production Build Pipeline

on:
  push:
    branches:
      - main

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build with Bake
        env:
          TOKEN: ${{ secrets.PRODUCTION_PIPELINE_TOKEN }}
        run: |
          docker buildx bake production
```

docker-bake.hcl`:

```hcl
target "production" {
  secret = [
    "id=token,env=TOKEN"
  ]
  tags = [
    "registry.company.com/app:v1"
  ]
  output = [
    "type=image,push=false"
  ]
}
```

## 監査および動作検証手順

ビルド完了後、生成されたイメージ内にシークレットが混入していないか実機ターミナルにて検証を行います。

### 1. Bake ターゲット設定の事前解析

ビルド実行前に、HCLの評価結果をJSON構造で出力してバインディングを確認します。

```text
$ docker buildx bake production --print
{
  "group": {
    "default": {
      "targets": [
        "production"
      ]
    }
  },
  "target": {
    "production": {
      "context": ".",
      "dockerfile": "Dockerfile",
      "secrets": [
        "id=token,env=TOKEN"
      ],
      "tags": [
        "registry.company.com/app:v1"
      ]
    }
  }
}
```

### 2. コンテナイメージ履歴のレイヤー解析

生成されたイメージのビルドヒストリを走査し、平文のシークレット引数が命令履歴に含まれていないか検証します。

```text
$ docker history registry.company.com/app:v1
IMAGE          CREATED         CREATED BY                                      SIZE      COMMENT
a1b2c3d4e5f6   2 minutes ago   RUN /bin/sh -c --mount=type=secret,id=token…   0B        buildkit.dockerfile.v0
<missing>      2 minutes ago   /bin/sh -c #(nop) WORKDIR /app                  0B        buildkit.dockerfile.v0
```

出力結果から、`CREATED BY` の領域にシークレットの文字列自体は一切記録されず、マウントフラグの定義のみが残るため安全性が証明されます。

## Troubleshooting

| 発生現象 / エラー | 原因解析 | 対処手順 |
| :--- | :--- | :--- |
| <b>`secret file token.txt: no such file or directory`</b> | `docker-bake.hcl` で定義した `src=` の相対パスに該当ファイルが存在しない。 | ビルド実行カレントディレクトリからのファイル存在パスを確認し、`src` の定義を修正する。 |
| <b>`secret id "token" required`</b> | `Dockerfile` 内の `--mount=type=secret,id=X` と `docker-bake.hcl` の `id=Y` が一致していない。 | HCL内の `id` 識別子と Dockerfile 内の `id` 識別子を完全に同一の文字列にそろえる。 |
| <b>CI環境でシークレットが空になる</b> | ホスト環境変数がワークフローの `env:` ブロックで正しくエクスポートされていない。 | CI定義ファイル内で `env` キーを用いて環境変数がステップへ明示的に渡されているか見直す。 |

## Key Takeaways

1. <b>`ARG` / `ENV` の全廃</b>: イメージに含めるべきでない認証情報の受け渡しにビルド引数を使用してはなりません。必ず `--mount=type=secret` を利用してください。
2. <b>シークレット値の再代入禁止</b>: `RUN --mount=type=secret` 内で取得した内容を `ENV` 変数やファイルシステムへコピーして書き出す操作を行うと、その時点でレイヤーに永続化するため厳禁です。
3. <b>最小権限の原則</b>: ビルド時に注入するトークンは、必要な範囲（例: 読み取り専用権限）に限定し、短時間で失効する一時トークンを発行して運用してください。</missing></id></image-id>