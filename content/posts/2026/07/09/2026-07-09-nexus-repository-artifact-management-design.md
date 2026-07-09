---
title: "Nexus Repositoryを活用したアーティファクト管理の設計手法とパイプライン統合"
slug: "nexus-repository-artifact-management-design"
date: 2026-07-09T10:37:04+09:00
draft: false
image: ""
description: "Nexus RepositoryのHosted/Proxy/Group構成、Maven/npm/Dockerクライアント設定、クリーンアップポリシー、トラブルシューティング手法を解説する技術分析ノート。"
categories: ["DevOps Logistics"]
tags: ["nexus-repository", "maven-settings", "docker-daemon", "artifact-management", "ci-cd"]
author: "K-Life Hack"
---

# Nexus Repositoryを活用したアーティファクト管理の設計とトラブルシューティング

CI/CDパイプラインの自動化が進む現代のインフラ構成において、ソースコード管理（SCM）の最適化だけでは、デプロイメントの整合性と再現性を完全に担保することは困難です。ビルドプロセスによって生成されるバイナリアーティファクト（JAR、WAR、npmパッケージ、Dockerイメージなど）をSCMに直接格納することは、リポジトリの肥大化とパフォーマンス低下を招くため、アンチパターンとされています。これらビルド成果物や外部依存ライブラリを一元管理し、信頼性の高いデリバリーラインを構築するためには、専用のアーティファクトリポジトリの導入が不可欠です。

本稿では、Sonatype Nexus Repositoryを中核としたアーティファクト管理アーキテクチャの設計手法、クライアント統合設定、および運用上のボトルネックを解消するためのトラブルシューティング手順について解説します。

## 1. Nexus Repositoryの3大トポロジー設計

Nexus Repositoryは、役割の異なる3種類のリポジトリタイプ（Hosted、Proxy、Group）を組み合わせることで、効率的なパッケージ配信を実現します。

* <b>Hosted Repository（ホスト型リポジトリ）</b>
組織内部で開発・ビルドされた独自のプライベートパッケージを格納する領域です。外部には公開しない機密性の高いモジュールや、CI/CDパイプラインから直接デプロイされるビルド成果物をホストします。
* <b>Proxy Repository（プロキシ型リポジトリ）</b>
Maven Central、npmjs.org、Docker Hubなどのパブリックレジストリに対するキャッシュプロキシとして動作します。一度ダウンロードされた依存関係はローカルのBlob Storeにキャッシュされるため、外部ネットワークへのトラフィックを削減し、2回目以降のビルド速度を大幅に向上させます。
* <b>Group Repository（グループ型リポジトリ）</b>
複数のHostedリポジトリとProxyリポジトリを仮想的に1つのエンドポイントとして統合するレイヤーです。開発者やCI/CDクライアントは、この単一のURLのみを参照することで、内部成果物と外部ライブラリの双方に透過的にアクセスできます。

## 2. クライアント統合の実装明細

### 2.1 Maven統合設定 (`settings.xml`)

Mavenビルドにおいて、外部への直接アクセスを遮断し、NexusのGroupリポジトリを経由させるための設定例です。

```xml
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemalocation="http://maven.apache.org/SETTINGS/1.0.0 https://maven.apache.org/xsd/settings-1.0.0.xsd">
<mirrors>
<mirror>
<id>nexus-group</id>
<mirrorof>*</mirrorof>
<name>Internal Nexus Group Repository</name>
<url>http://nexus.internal.net/repository/maven-public/</url>
</mirror>
</mirrors>
<servers>
<server>
<id>nexus-group</id>
<username>deployment-user</username>
<password>SecurePassword123!</password>
</server>
</servers>
</settings>
```

### 2.2 Docker Daemon統合設定 (`daemon.json`)

プライベートなDockerレジストリとしてNexusを使用する場合、HTTPS化が推奨されますが、検証環境などでHTTP通信を一時的に許可する、あるいはプロキシミラーを指定する場合は以下の設定を適用します。

```json
{
  "registry-mirrors": [
    "https://nexus.internal.net/repository/docker-proxy/"
  ],
  "insecure-registries": [
    "nexus.internal.net:5001"
  ]
}
```

## 3. ライフサイクル管理とクリーンアップポリシー

アーティファクトリポジトリの運用において最も頻発する課題は、ビルド毎に生成される「Snapshot」や一時的なイメージによるストレージ容量の枯渇です。これを防ぐため、以下のライフサイクル管理を自動化する必要があります。

1. <b>コンポーネント削除ポリシー（Cleanup Policies）の策定</b>
* `Snapshot`リポジトリ：過去14日以内に更新がない、かつリリースバージョンではない成果物を自動削除します。
* `Docker`レジストリ：タグなし（dangling）イメージや、特定の保持期間（例：30日）を超えたイメージのパージを実行します。
2. <b>Blob Storeのコンパクション（タスクスケジューリング）</b>
* Nexusでは、コンポーネントを削除しただけではディスク容量は解放されません。論理削除されたデータを物理的に削除するため、定期的に「Admin - Compact blob store」タスクを実行するスケジュールを構成します。

## 4. トラブルシューティング

### 💡 Friction Point 1: Blob Storeの容量枯渇による書き込みエラー (HTTP 500 / Read-only Mode)

* <b>原因</b>: ディスク使用率が閾値（デフォルトでは90%）を超えると、Nexusはデータ破損を防ぐためにBlob Storeを自動的にRead-onlyモードに移行させます。
* <b>対策</b>: 不要なメタデータや古いSnapshotをタスクから手動削除します。さらに、以下の手順でBlob Store of コンパクションタスクを即時実行し、物理ディスク容量を解放します。

### ⚠️ Friction Point 2: プロキシリポジトリ経由のSSLハンドシェイクエラー (PKIX path building failed)

* <b>原因</b>: 社内プロキシやSSL可視化アプライアンスが介在する場合、外部レジストリ（Maven Central等）の証明書チェーンが切断され、Nexusが動作するJVMが接続を拒否します。
* <b>対策</b>: Nexusの管理画面（`Security -&gt; SSL Certificates`）から対象ホストの証明書を直接取得し、Nexusの信頼済み証明書ストア（Truststore）に追加します。

## 5. 運用検証ログ (Operational Verifications)

インフラ構築後の正常稼働性を確認するための、検証ターミナルログのシミュレーションです。

```text
$ curl -I -u deployment-user:SecurePassword123! http://nexus.internal.net/service/rest/v1/status
HTTP/1.1 200 OK
Date: Thu, 09 Jul 2026 09:00:00 GMT
Server: Nexus/3.68.0-01 (OSS)
X-Content-Type-Options: nosniff
Content-Length: 0

$ docker login nexus.internal.net:5001 -u deployment-user -p SecurePassword123!
WARNING! Using --password via the CLI is insecure. Use --password-stdin.
Login Succeeded

$ docker pull nexus.internal.net:5001/alpine:3.18
3.18: Pulling from alpine
Digest: sha256:48d818124339491250f023456789abcdef1234567890abcdef1234567890ab
Status: Downloaded newer image for nexus.internal.net:5001/alpine:3.18
```

## 6. 運用上の注意点 (Operational Notes)

Nexus RepositoryをCI/CDパイプラインに組み込むことは、単なるストレージの確保に留まらず、ビルドの高速化、外部障害への耐性向上、およびサプライチェーンセキュリティの強化に直結します。Hosted、Proxy、Groupの各リポジトリ特性を正しく理解し、適切なクリーンアップポリシーとディスク監視を設計に組み込むことが、長期的な安定運用の鍵となります。