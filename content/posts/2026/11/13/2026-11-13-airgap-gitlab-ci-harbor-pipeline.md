---
title: "エアギャップクラスタ向けGitLab CIとHarborレジストリ連携パイプライン実装"
slug: "airgap-gitlab-ci-harbor-pipeline"
date: 2026-11-13T11:32:57+09:00
draft: false
image: ""
description: "閉域網Kubesprayクラスタを対象としたGitLab CI/CDパイプラインの構築メモ。内部Harbor連携、Dockerfile静的検証、タグ自動採番、--pull=false指定による外部通信遮断の構成を詳解します。"
categories: ["DevOps Logistics"]
tags: ["kubespray", "harbor", "gitlab-ci", "docker-build", "air-gapped"]
author: "K-Life Hack"
---

インターネット接続が制限または完全に切断されたエアギャップ環境では、外部のパブリックレジストリ（Docker HubやQuay.ioなど）へのアウトバウンド通信がファイアウォールによって遮断されます。このようなインフラストラクチャにおいてKubesprayを用いたKubernetesクラスタを運用する場合、コンテナイメージの依存解決にパブリックエンドポイントが含まれていると、ビルドパイプラインがタイムアウトや名前解決エラーにより停止することになります。コンテナビルドプロセスの再現性を確保し、意図しない外部ネットワークリクエストを排除するには、内部プライベートレジストリを前提条件とした静的検証ゲートおよび閉域環境専用のパイプライン構成が不可欠となります。

本稿では、内部レジストリである「Harbor」を基盤とし、Kubesprayクラスタへデプロイするワークロードイメージを安全に生成・検証・配布するためのGitLab CI/CDパイプラインの実装仕様を整理します。

## パイプライン全体構造と実行基盤パラメータ

対象環境では、GitLab Runner自体も閉域ネットワーク内に配置し、<code>docker</code>および<code>offline</code>の実行タグによってターゲットノードを制約します。パイプライン全体で使用するグローバル設定は以下の通りです。

```yaml
stages:
  - validate
  - build

variables:
  HARBOR_REGISTRY: "harbor.devstack.co.kr:8443"
  HARBOR_PROJECT: "kubespray"
  IMAGE_NAME: "nginx-app"

image: "$HARBOR_REGISTRY/$HARBOR_PROJECT/ci/docker:29.1.4-cli"
```

### 設定パラメータの仕様

1. <b><code>stages</code> 定義:</b> <code>validate</code>（リポジトリ内のDockerfileが内部レジストリのベースイメージを正しく参照しているかを検査する静的検証フェーズ）および <code>build</code>（内部Harborへの認証、コミット情報に基づくイメージタグの生成、コンテナイメージのビルドおよびプッシュ、環境変数のメタデータ出力を行うフェーズ）で構成します。
2. <b><code>variables</code> 定義:</b> <code>HARBOR_REGISTRY</code>にはプライベートHarborのFQDNおよびTLS通信ポート（<code>harbor.devstack.co.kr:8443</code>）を指定し、<code>HARBOR_PROJECT</code>にはKubespray用アーティファクトを分離・収容するプロジェクト名前空間（<code>kubespray</code>）を設定します。また<code>IMAGE_NAME</code>として生成対象のワークロードコンテナイメージ名（<code>nginx-app</code>）を定義します。
3. <b>実行イメージ (<code>image</code>):</b> ランナーコンテナ自体もパブリックレジストリに依存せず、<code>harbor.devstack.co.kr:8443/kubespray/ci/docker:29.1.4-cli</code>から取得します。バージョンを<code>29.1.4-cli</code>に固定することで、CLIオプションの挙動差分によるビルド失敗を防止します。

## ステージ別ジョブ詳細設計

### 1. Dockerfileの静的検証ジョブ (`validate:dockerfile`)

ビルドプロセスに突入する前に、外部レジストリを参照する不正な<code>FROM</code>句が混入していないかを検証します。

```yaml
validate:dockerfile:
  stage: validate
  tags:
    - docker
    - offline
  script:
    - test -f Dockerfile
    - grep -q "$HARBOR_REGISTRY" Dockerfile
    - echo "Dockerfile validation passed"
```

💡 <code>test -f Dockerfile</code> でルートディレクトリにおけるDockerfileの存在を確認し、<code>grep -q "$HARBOR_REGISTRY" Dockerfile</code> によってベースイメージ参照行に <code>harbor.devstack.co.kr:8443</code> が含まれているかを検査します。外部リポジトリ（例: <code>FROM nginx:latest</code>）を直接指定した記述が存在する場合、終了ステータスが非ゼロとなり、後続のビルドジョブ実行を即時に遮断します。

### 2. ビルドおよびレジストリ配布ジョブ (`build:push`)

コンテナのビルド、認証情報の安全な引き渡し、外部リクエストの物理的抑制、動的メタデータのパイプライン連携を担います。

```yaml
build:push:
  stage: build
  tags:
    - docker
    - offline
  before_script:
    - docker version
    - echo "$HARBOR_PASSWORD" | docker login "$HARBOR_REGISTRY" -u "$HARBOR_USER" --password-stdin
  script:
    - |
      if [ -n "$CI_COMMIT_TAG" ]; then
        IMAGE_TAG="$CI_COMMIT_TAG"
      else
        IMAGE_TAG="sha-$CI_COMMIT_SHORT_SHA"
      fi

      IMAGE_URI="$HARBOR_REGISTRY/$HARBOR_PROJECT/$IMAGE_NAME:$IMAGE_TAG"

      echo "IMAGE_TAG=$IMAGE_TAG"
      echo "IMAGE_URI=$IMAGE_URI"

      docker build --pull=false -t "$IMAGE_URI" .
      docker push "$IMAGE_URI"

      echo "IMAGE_TAG=$IMAGE_TAG" &gt; build.env
      echo "IMAGE_URI=$IMAGE_URI" &gt;&gt; build.env
  artifacts:
    reports:
      dotenv: build.env
    expire_in: 7 days
  rules:
    - if: '$CI_COMMIT_BRANCH == "master"'
    - if: '$CI_COMMIT_TAG'
```

#### 実装上の技術的要点

🛠️ <b>認証情報の秘匿化:</b> <code>echo "$HARBOR_PASSWORD" | docker login ... --password-stdin</code> を使用し、コマンドライン引数経由でのパスワード露出（プロセスツリーやRunnerログへの平文出力）を防止します。
⚙️ <b>動的タグ判定ロジック:</b> リリースタグ発行時（<code>$CI_COMMIT_TAG</code>）はそのタグ名をそのまま採用し、ブランチコミット時は <code>sha-&lt;短縮ハッシュ&gt;</code> 形式でユニークなイミュータブルタグを割り当てます。
⚠️ <b>外部通信抑制フラグ (<code>--pull=false</code>):</b> 通常の <code>docker build</code> はローカルにキャッシュが存在してもリモートリポジトリへ最新レイヤーの問い合わせを行う挙動をとる場合があります。<code>--pull=false</code> を明示的に指定することで、閉域環境において不要な外部プローブ通信による遅延やタイムアウトエラーを完全に遮断します。
📦 <b>下流パイプラインへの変数伝播:</b> <code>build.env</code> ファイルに <code>IMAGE_TAG</code> と <code>IMAGE_URI</code> を出力し、GitLabの <code>artifacts:reports:dotenv</code> 機能を通じて後続のデプロイパイプライン（KubesprayのPlaybook実行ジョブ等）へ渡します。

## 統合設定ファイル (`.gitlab-ci.yml`)

全ジョブを統合した完全なパイプライン構成は以下の通りです。

```yaml
stages:
  - validate
  - build

variables:
  HARBOR_REGISTRY: "harbor.devstack.co.kr:8443"
  HARBOR_PROJECT: "kubespray"
  IMAGE_NAME: "nginx-app"

image: "$HARBOR_REGISTRY/$HARBOR_PROJECT/ci/docker:29.1.4-cli"

validate:dockerfile:
  stage: validate
  tags:
    - docker
    - offline
  script:
    - test -f Dockerfile
    - grep -q "$HARBOR_REGISTRY" Dockerfile
    - echo "Dockerfile validation passed"

build:push:
  stage: build
  tags:
    - docker
    - offline
  before_script:
    - docker version
    - echo "$HARBOR_PASSWORD" | docker login "$HARBOR_REGISTRY" -u "$HARBOR_USER" --password-stdin
  script:
    - |
      if [ -n "$CI_COMMIT_TAG" ]; then
        IMAGE_TAG="$CI_COMMIT_TAG"
      else
        IMAGE_TAG="sha-$CI_COMMIT_SHORT_SHA"
      fi

      IMAGE_URI="$HARBOR_REGISTRY/$HARBOR_PROJECT/$IMAGE_NAME:$IMAGE_TAG"

      echo "IMAGE_TAG=$IMAGE_TAG"
      echo "IMAGE_URI=$IMAGE_URI"

      docker build --pull=false -t "$IMAGE_URI" .
      docker push "$IMAGE_URI"

      echo "IMAGE_TAG=$IMAGE_TAG" &gt; build.env
      echo "IMAGE_URI=$IMAGE_URI" &gt;&gt; build.env
  artifacts:
    reports:
      dotenv: build.env
    expire_in: 7 days
  rules:
    - if: '$CI_COMMIT_BRANCH == "master"'
    - if: '$CI_COMMIT_TAG'
```

## Troubleshooting

閉域網環境のCI実行で発生しやすい代表的な障害要因と対処方法を記録します。

### 1. 非標準ポート（8443）でのTLS/x509証明書検証エラー

<b>障害事象:</b> Harborがポート8443を使用し、社内プライベート認証局（CA）による自己署名証明書で保護されている場合、<code>docker login</code> 実行時に以下のエラーが発生してジョブが停止します。

```text
Error response from daemon: Get "https://harbor.devstack.co.kr:8443/v2/": x509: certificate signed by unknown authority
```

<b>対処手順:</b> Runnerホスト上のDockerデーモンに内部ルートCA証明書を配置します。Dockerは <code>/etc/docker/certs.d/&lt;レジストリホスト名:ポート&gt;/ca.crt</code> のパスを自動参照します。

```bash
sudo mkdir -p /etc/docker/certs.d/harbor.devstack.co.kr:8443
sudo cp /path/to/internal-ca.crt /etc/docker/certs.d/harbor.devstack.co.kr:8443/ca.crt
sudo systemctl restart docker
```

### 2. `--pull=false` 指定時におけるベースレイヤー消失エラー

<b>障害事象:</b> Dockerfile内のベースイメージがRunnerホストのローカルキャッシュに存在しない状態で <code>--pull=false</code> を指定すると、以下のようにビルドが失敗します。

```text
ERROR: failed to solve: harbor.devstack.co.kr:8443/kubespray/base-nginx:1.25: not found: image not present locally and --pull=false set
```

<b>対処手順:</b> ジョブ実行前に必要なベースイメージをHarborから確実にローカルプールへフェッチする処理を <code>before_script</code> に追加するか、初回ビルド時に明示的なイメージ事前ロードを実施してください。

```bash
docker pull harbor.devstack.co.kr:8443/kubespray/base-nginx:1.25
```

### 実行検証ログ例

正常に動作したパイプラインノードにおける認証およびプッシュログの記録です。

```text
$ docker version
Client:
 Version:           29.1.4
 API version:       1.47
 Go version:        go1.22.8
 Git commit:        06f9d74
 Built:             Wed Nov 12 18:22:10 2026
 OS/Arch:           linux/amd64
 Context:           default

Server:
 Engine:
  Version:          29.1.4
  API version:      1.47 (minimum version 1.12)
  Go version:       go1.22.8
  Git commit:       a3f9e2b
  Built:            Wed Nov 12 18:21:45 2026
  OS/Arch:          linux/amd64
  Experimental:     false

$ echo "$HARBOR_PASSWORD" | docker login "$HARBOR_REGISTRY" -u "$HARBOR_USER" --password-stdin
WARNING! Your password will be stored unencrypted in /root/.docker/config.json.
Configure a credential helper to remove this warning. See
https://docs.docker.com/engine/reference/commandline/login/#credentials-store

Login Succeeded

$ IMAGE_TAG="sha-3b8c1a9e"
$ IMAGE_URI="harbor.devstack.co.kr:8443/kubespray/nginx-app:sha-3b8c1a9e"
$ docker build --pull=false -t "$IMAGE_URI" .
[+] Building 1.2s (6/6) FINISHED
 =&gt; [internal] load build definition from Dockerfile
 =&gt; =&gt; transferring dockerfile: 312B
 =&gt; [internal] load metadata for harbor.devstack.co.kr:8443/kubespray/base-nginx:1.25
 =&gt; [1/2] FROM harbor.devstack.co.kr:8443/kubespray/base-nginx:1.25
 =&gt; [2/2] COPY ./html /usr/share/nginx/html
 =&gt; exporting to image
 =&gt; =&gt; exporting layers
 =&gt; =&gt; writing image sha256:7f4a21e69b0dc881cb31e5f84918e9c60e42fbe5aa65825cfd9d06b12a8ff93a
 =&gt; =&gt; naming to harbor.devstack.co.kr:8443/kubespray/nginx-app:sha-3b8c1a9e

$ docker push "$IMAGE_URI"
The push refers to repository [harbor.devstack.co.kr:8443/kubespray/nginx-app]
3f8b091fca1e: Pushed
e6b8b0934c22: Layer already exists
sha-3b8c1a9e: digest: sha256:4d7b29a28e7529841f4812a0f6b3e9491ac9480dcbe82f8a50f3b4dc36f018e6 size: 739
```

## Operational Notes

🛠️ <b>GitLab Runnerのタグ管理:</b> 閉域環境のRunnerには必ず <code>docker</code> および <code>offline</code> のタグを付与し、インターネット接続可能な共用Runnerへビルド要求がルーティングされないよう分離を維持してください。
⚠️ <b>dotenvアーティファクトの有効期限:</b> <code>expire_in: 7 days</code> を設定しているため、7日以上経過した過去ジョブのメタデータを再参照するパイプラインを組む場合は、外部KeyValueストアへの保管やGitコミットへのコミットバック機構を検討する必要があります。
💡 <b>Harbor側のクォータ管理:</b> Kubesprayプロジェクトではタグなし中間レイヤーや古いコミットSHAイメージが蓄積しやすいため、Harbor側でタグ保持ポリシー（例: 直近20タグ保持、あるいは一定期間経過後の自動クリーンアップ）を設定しておく必要があります。