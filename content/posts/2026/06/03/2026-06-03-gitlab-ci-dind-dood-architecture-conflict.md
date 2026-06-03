---
title: "GitLab CIにおけるDinDとDooDのアーキテクチャ比較と実装上の競合分析"
slug: "gitlab-ci-dind-dood-architecture-conflict"
date: 2026-06-03T23:55:46+09:00
draft: false
image: ""
description: "GitLab CI/CD環境におけるDocker-in-Docker(DinD)とDocker-out-of-Docker(DooD)の技術的差異、セキュリティ特性、および同一ランナー内での併用不可制約について解説します。"
categories: ["DevOps Logistics"]
tags: ["gitlab-ci", "docker-in-docker", "dood", "container-security", "buildkit"]
author: "K-Life Hack"
---

title: GitLab CI/CDにおけるDockerビルド戦略：DinDとDooDの技術的比較と選定基準
meta_description: GitLab CI/CDパイプラインでDockerコンテナをビルドするためのDinD（Docker-in-Docker）とDooD（Docker-out-of-Docker）のアーキテクチャ、セキュリティ、および実装上の制約を技術的視点から解説します。

GitLab CI/CDパイプラインにおいて、コンテナ化されたランナー内でdocker buildやdocker pushを実行する要件は一般的です。この「コンテナ内コンテナ」を実現する手法として、主にDocker-in-Docker (DinD) と Docker-out-of-Docker (DooD) の2つのアーキテクチャパターンが存在します。本稿では、それぞれの技術的構造、セキュリティ上のインプリケーション、および実装時に発生する致命的な競合問題について分析します。

## Dockerのクライアント・サーバーモデルの再確認

DinDとDooDの差異を理解するためには、Dockerがクライアント・サーバーアーキテクチャであることを認識する必要があります。Dockerコマンドは以下の2つのコンポーネントに分離されています。

- <b>Docker CLI (Client):</b> ユーザーのコマンドを受け取り、サーバーに送信するインターフェース。
- <b>dockerd (Daemon/Server):</b> イメージのビルド、ボリューム管理、コンテナのオーケストレーションを実際に実行するバックグラウンドプロセス。

コンテナ内でDockerを実行する場合、この「Docker Daemonがどこに存在するか」がアーキテクチャの核心となります。

## Docker-in-Docker (DinD) の構造と特性

DinDは、コンテナの内部で完全に独立したDocker Daemonを実行する手法です。

### メカニズム

専用の「サービス」コンテナがDinDイメージを実行し、独自の隔離されたDocker Daemonを初期化します。ビルドコンテナのCLIは、通常 <b>tcp://docker:2375</b> などのネットワークソケットを介して、この内部デーモンに接続します。

### 特権モード (Privileged Mode) の必要性

DinDを動作させるには、GitLab Runnerの設定で <b>privileged = true</b> を有効にする必要があります。これは、内部デーモンがcgroupsの作成やネットワークネームスペースの管理など、カーネル機能への高度なアクセス権限を必要とするためです。

### メリットとデメリット

- <b>メリット:</b> ホスト環境や他のビルドジョブから完全に隔離されるため、マルチテナント環境に適しています。
- <b>デメリット:</b> ジョブごとに新しいデーモンを起動するためオーバーヘッドが大きく、パフォーマンスが低下する傾向があります。また、特権モードの使用に伴うセキュリティリスクを伴います。

## Docker-out-of-Docker (DooD) の構造と特性

DooDは、コンテナ内のCLIがホストマシンのDocker Daemonと直接通信する手法です。

### メカニズム

ホストのDockerソケットファイル（/var/run/docker.sock）をコンテナ内にマウントすることで実現します。

### 設定例

```toml
[runners.docker]
  volumes = ["/var/run/docker.sock:/var/run/docker.sock", "/cache"]
```

また、.gitlab-ci.yml で環境変数を指定します。

```yaml
variables:
  DOCKER_HOST: unix:///var/run/docker.sock
```

### メリットとデメリット

- <b>メリット:</b> 追加のデーモン起動が不要なため、DinDよりも高速かつシンプルに実装可能です。
- <b>デメリット:</b> 隔離性が皆無です。コンテナがホストのデーモンを共有するため、ホスト上の全イメージやコンテナを操作可能になります。docker.sock のマウントは、実質的にコンテナへホストのroot権限を付与することと同義であり、コンテナエスケープのリスクが極めて高い構成です。

## セキュリティ階層の比較

手法ごとのセキュリティ強度は以下の通りです（下に行くほど高セキュリティ）。

1. <b>DooD:</b> 最も低い。ソケットマウントによりホストレベルのrootアクセスを許可する。
2. <b>DinD:</b> 中程度。ホストからは隔離されるが、privileged モードが必要であり、コンテナが侵害された場合にホストへの攻撃ベクトルとなる可能性がある。
3. <b>BuildKit (rootless):</b> 最も高い。特権アクセスやソケットマウントを必要とせず、デーモンレスで動作する現代的な標準アプローチ。

## 技術的制約：DinDとDooDの共存不可問題

エンジニアリング上の重要な注意点として、単一のGitLab Runner構成においてDinDとDooDを併用することはできません。これらを混在させようとすると、以下の論理的破綻によりジョブが失敗します。

1. GitLab Runnerの config.toml に /var/run/docker.sock のボリュームマウントが記述されている場合、そのランナーが生成するすべてのコンテナ（サービスコンテナを含む）にこのマウントが適用されます。
2. DinDサービスコンテナが起動する際、自身の内部でDocker Daemonを初期化しようとします。
3. DinDデーモンは /var/run/docker.sock に自身のソケットを作成しようとしますが、その場所には既にホストからマウントされたソケットが存在します。
4. システムは <mark>"device or resource busy"</mark> エラーを返し、DinDデーモンの起動に失敗します。

このため、DinDを使用する場合は、config.toml から /var/run/docker.sock のマウントを明示的に除外する必要があります。ランナーは一つの手法に専念させるのが設計上の原則です。

## Operational Notes

実装戦略を選択する際の基準は以下の通りです。

- <b>マルチテナント / 高セキュリティ要件:</b> DinDを選択し、ジョブ間の隔離を確保します。
- <b>単一ユーザー / 速度優先:</b> DooDを選択し、オーバーヘッドを最小化します。
- <b>モダンなCI/CD環境:</b> 🛠️ <b>BuildKit (rootless)</b> の採用を検討してください。BuildKitは、特権モードを必要とせず、マルチアーキテクチャビルドやネイティブなシークレット管理をサポートしており、パフォーマンスとセキュリティの両立が可能です。