---
title: "DjangoとNginxを用いたDocker Composeによるサービスオーケストレーションの実装"
slug: "docker-compose-django-nginx-setup"
date: 2026-06-03T08:47:43+09:00
draft: false
image: ""
description: "Docker Composeを利用してDjangoとNginxのマルチコンテナ環境を構築する際の実装ノート。docker-compose.ymlの定義、依存関係の制御、およびビルドプロセスの検証結果を記録します。"
categories: ["DevOps Logistics"]
tags: ["docker-compose", "django", "nginx", "container-orchestration", "yaml-configuration"]
author: "K-Life Hack"
---

# Docker Composeを活用したマルチコンテナ・オーケストレーションの構築と管理

Docker Composeは、複数のコンテナで構成されるアプリケーションを定義・実行するためのオーケストレーションツールです。個別のコンテナを単体で管理するのではなく、サービス間の依存関係、ネットワーク、ボリュームの設定を一元化し、スタック全体を一つのユニットとして制御することを目的としています。

## 1. 手動コンテナ管理における課題

Docker Composeを導入しない場合、マルチコンテナ構成の運用には複数の技術的負債が発生します。各コンテナに対して個別に <b>docker run</b> コマンドを実行するプロセスの煩雑化、ネットワーク（--network）やポートマッピング（-p）などのパラメータをコマンドライン引数として正確に維持しなければならない管理コスト、そしてデータベース起動後にアプリケーションを起動させるといった依存関係の手動制御に伴うヒューマンエラーのリスクです。Docker Composeは、これらの設定を <b>docker-compose.yml</b> という宣言的なファイルに集約することで、環境の再現性と運用の安定性を確保します。

## 2. 実装環境の定義

```bash
% docker compose version
Docker Compose version v5.1.3
```

## 3. 構成解析: docker-compose.yml

DjangoバックエンドとNginxフロントエンドを統合し、効率的なリバースプロキシ構成を実現するための定義を実装しました。

```yaml
services:
  djangotest:
    build: ./myDjango02
    networks:
      - composenet01
    restart: always

  nginxtest:
    build: ./myNginx02
    networks:
      - composenet01
    ports:
      - "80:80"
    depends_on:
      - djangotest
    restart: always

networks:
  composenet01:
```

### 主要パラメータの技術仕様

*   <b>build</b>: 指定されたディレクトリにあるDockerfileを参照し、イメージのビルドプロセスを自動化します。
*   <b>networks</b>: カスタムネットワーク <b>composenet01</b> を定義し、コンテナ間のサービスディスカバリを有効にします。これにより、Nginxはサービス名 <b>djangotest</b> を解決してバックエンドにアクセス可能となります。
*   <b>depends_on</b>: コンテナの起動順序を制御します。本構成では <b>djangotest</b> が先に開始され、その後に <b>nginxtest</b> が起動するフローを強制します。
*   <b>restart: always</b>: コンテナのクラッシュ時やデーモンの再起動時に、自動的にプロセスを復旧させる再起動ポリシーです。

## 4. デプロイメントおよびビルドの実行

<b>docker compose up</b> コマンドを使用して、スタック全体の構築と起動を実行します。<b>-d</b> フラグによるバックグラウンド実行と <b>--build</b> フラグによる最新のソースコード反映を同時に行います。

```bash
% docker compose up -d --build
[+] Building 1.2s (22/22) FINISHED
 =&gt; [djangotest internal] load build definition from Dockerfile
 =&gt; [nginxtest internal] load build definition from Dockerfile
 =&gt; CACHED [djangotest 2/6] WORKDIR /usr/src/app
 =&gt; CACHED [djangotest 5/6] RUN pip install -r requirements.txt
 =&gt; [nginxtest] exporting to image
[+] up 4/4
 ✔ Image docker4-nginxtest        Built
 ✔ Image docker4-djangotest       Built
 ✔ Container docker4-djangotest-1 Started
 ✔ Container docker4-nginxtest-1  Started
```

ビルドログの解析により、レイヤーキャッシュ（CACHED）が最適に機能し、デプロイ時間が短縮されていることが確認できます。また、定義された依存関係に従い、Djangoコンテナが先行してプロビジョニングされます。

## 5. 稼働状況の検証

デプロイ完了後、各サービスのステータスおよびネットワークの疎通確認を行います。

```bash
% docker container ls
CONTAINER ID   IMAGE                COMMAND                   STATUS         PORTS                                 NAMES
c349c6fd0c7e   docker4-nginxtest    "/docker-entrypoint.…"   Up 2 minutes   0.0.0.0:80-&gt;80/tcp, [::]:80-&gt;80/tcp   docker4-nginxtest-1
14c38ae2f5e0   docker4-djangotest   "gunicorn --bind 0.0…"   Up 2 minutes   8000/tcp                              docker4-djangotest-1
```

Nginxがポート80でリッスンし、内部ネットワークを通じてDjangoアプリケーション（Gunicorn）へトラフィックを正常にプロキシしていることが確認されました。🛠️

## 6. 運用管理コマンドリファレンス

Compose環境のライフサイクル管理において、エンジニアが頻繁に使用する主要コマンド群です。

*   <b>docker compose up -d</b>: サービスをバックグラウンドで起動。構成変更を検知した場合は対象コンテナのみを再作成します。
*   <b>docker compose down</b>: コンテナの停止・削除、および定義されたネットワークリソースの破棄を実行します。
*   <b>docker compose ps</b>: 現在のサービス稼働状況、終了コード、およびポートマッピングを表示します。
*   <b>docker compose logs</b>: 全サービスの標準出力を集約して表示し、ランタイムエラーのデバッグを容易にします。

## Configuration Notes

Docker Composeによるオーケストレーションにおいて、<b>depends_on</b> はコンテナの「起動」のみを保証し、アプリケーション内部の「準備完了（Ready）」状態までは保証しません。より厳密な依存関係制御が必要な場合は、<b>healthcheck</b> セクションを導入し、ヘルスチェックに合格するまで依存コンテナの起動を待機させる構成を検討する必要があります。⚠️ また、カスタムネットワークを利用することで、外部に公開する必要のないバックエンドサービスをホストのポートから隔離し、セキュリティ境界を明確にすることが可能です。💡