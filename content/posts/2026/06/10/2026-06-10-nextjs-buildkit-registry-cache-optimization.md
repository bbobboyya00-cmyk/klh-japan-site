---
title: "BuildKitレジストリキャッシュによるNext.js 14デプロイパイプラインの高速化とボトルネック解消"
slug: "nextjs-buildkit-registry-cache-optimization"
date: 2026-06-10T14:07:51+09:00
draft: false
image: ""
description: "Next.js 14アプリケーションのCloud Runデプロイにおいて、.dockerignoreの修正、standalone出力、Docker BuildxのRegistry Cache導入により、ビルド時間を12分から4分台へ短縮した最適化手法を解説します。"
categories: ["DevOps Logistics"]
tags: ["nextjs", "docker-buildx", "google-cloud-build", "cloud-run", "buildkit"]
author: "K-Life Hack"
---

# Next.js 14 + Cloud Run ビルド最適化：12分から4分への短縮プロセス

Next.js 14アプリケーションをGoogle Cloud Runへデプロイするパイプラインにおいて、ソースコード自体は5.4MB程度であるにもかかわらず、ビルド時間が12分を超過する深刻なボトルネックが発生しました。本稿では、.dockerignoreの構文修正、不要な依存関係の整理、Next.jsのstandalone出力の適用、そしてKanikoからDocker Buildx（Registry Cache）への移行プロセスを通じて、ビルド時間を12分7.2秒から4分23.5秒（約64%削減）へと短縮した最適化手法について記述します。

## 1. 12分におよぶビルドボトルの要因分析

対象プロジェクトは、約60ページで構成されるNext.jsアプリケーションです。Cloud Buildのログ、Dockerfile、およびcloudbuild.yamlを監査した結果、以下の6つの要因が特定されました。

1.  <b>無効な.dockerignore</b>: 構文の誤りにより、ローカルの巨大なディレクトリがビルドコンテキストに含まれていました。
2.  <b>未使用の依存関係</b>: ビルド時に不要な外部モジュール（SentryやModule Federation関連）が動作し、処理を遅延させていました。
3.  <b>重複したビルドロジック</b>: tscによる型チェックとnext build内部の型チェックが重複して実行されていました。
4.  <b>最適化されていない出力フォーマット</b>: Next.jsのstandaloneモードが有効化されていませんでした。
5.  <b>ランナーステージの肥大化</b>: 最終的なDockerイメージに開発用モジュールや不要なnode_modulesが混入していました。
6.  <b>レイヤーキャッシュの欠如</b>: Cloud BuildのエフェメラルなVM環境において、ビルドごとのレイヤーキャッシュが機能していませんでした。

---

## 2. 基本的な最適化（フェーズ1）

### 2.1 .dockerignoreの修正によるコンテキスト削減
初期の.dockerignoreでは、Markdownのエスケープ構文（例: \*~, \*.md）が混入しており、Dockerが標準的なグロブパターンとして解釈できていませんでした。さらに、node_modulesや.next/cacheが除外対象から漏れていました。これにより、毎回のビルドで約2.5GBのnode_modulesと約909MBの.next/cacheがビルドコンテキストとしてアップロードされていました。標準的なGit構文に準拠した.dockerignoreへ書き換えることで、ビルドコンテキストのサイズを3.6GBから数MBへと削減し、アップロードに伴うオーバーヘッドを解消しました。

### 2.2 依存関係とビルドスクリプトの整理

使用されていなかった@sentry/nextjsおよび@module-federation/nextjs-mfを依存関係から削除しました。特にSentryは、ビルド時にグローバルソースマップを生成・アップロードする処理を実行しており、これが大きな負荷となっていました。また、すでに使用されていなかったリモートモジュールを動的インポートしていたSophiProviderコンポーネントを排除しました。

ビルドスクリプトについては、next buildが内部で型チェックを実行するため、事前のtscを削除しました。静的解析（Lint）はコミット時に実行する運用へ移行し、ビルドプロセスを簡素化しました。

### 2.3 Next.js Standaloneとマルチステージビルドの適用

next.config.jsにoutput: 'standalone'を設定することで、Next.jsは本番稼働に必要な最小限のファイル群のみをトレースして出力します。

```javascript
// next.config.js
module.exports = {
  output: 'standalone',
  // ...other configurations
}
```

Dockerfileをマルチステージビルド構成に変更し、ランナーステージにはこのstandaloneディレクトリと静的アセット（publicおよび.next/static）のみをコピーするように設計しました。これにより、最終的なコンテナイメージサイズは2.5GB以上から約400MBへと縮小され、イメージのプッシュ時間およびCloud Runのコールドスタート時間が大幅に短縮されました。

---

## 3. Kaniko導入の試みとメモリ不足（OOM）による失敗（フェーズ2）

Cloud BuildのクリーンなVM環境でレイヤーキャッシュを活用するため、コンテナイメージ内でキャッシュを生成・保存できるKanikoの導入を試みました。しかし、Kanikoはファイルシステムのスナップショットをメモリ上に展開して差分を計算する特性があるため、2.5GB規模のnode_modulesが存在する環境では、Cloud BuildのE2_HIGHCPU_8マシン（メモリ8GB）の制限を超過し、OOM（Out Of Memory）によりプロセスが強制終了（Exit 137）しました。

--compressed-caching=falseや--snapshot-mode=redoなどのメモリ削減フラグを適用することでビルド自体は成功したものの、スナップショット処理のオーバーヘッドにより9分12.8秒を要しました。Kanikoのアーキテクチャ特性上、巨大な依存関係を持つプロジェクトでの高速化には限界があると判断し、Docker Buildxへの移行を決定しました。

---

## 4. Docker BuildxとRegistry Cacheの導入（フェーズ3）

最終的な解決策として、docker buildxのdocker-containerドライバーと、Artifact Registryをキャッシュストレージとして利用するtype=registryキャッシュを採用しました。mode=maxを指定することで、最終イメージに含まれない中間レイヤーも含めて、すべてのビルドレイヤーをレジストリにキャッシュします。

```yaml
# cloudbuild.yaml snippet
steps:
  - name: 'gcr.io/cloud-builders/docker'
    entrypoint: 'bash'
    args:
      - '-c'
      - |
        docker buildx create --use --driver docker-container
        ACCESS_TOKEN=$(gcloud auth print-access-token)
        docker login -u oauth2accesstoken -p $$ACCESS_TOKEN https://asia-northeast1-docker.pkg.dev
        docker buildx build \
          --cache-from=type=registry,ref=asia-northeast1-docker.pkg.dev/$PROJECT_ID/cache/app:latest \
          --cache-to=type=registry,ref=asia-northeast1-docker.pkg.dev/$PROJECT_ID/cache/app:latest,mode=max \
          --push \
          -t asia-northeast1-docker.pkg.dev/$PROJECT_ID/repo/app:$COMMIT_SHA .
```

実装における重要な注意点として、docker-containerドライバーはホストの認証ヘルパーを自動的には継承しません。そのため、Google Cloudのメタデータサーバーから一時的なアクセストークンを直接取得し、コンテナ内で明示的にdocker loginを実行する必要があります。また、Cloud BuildのYAML内でBashの変数を使用する場合、置換パラメータとの競合を防ぐため、$$ACCESS_TOKENのようにダブルドル記号でエスケープする必要があります。

---

## 5. 導入効果とパフォーマンス検証

各フェーズにおけるビルド時間の推移は以下の通りです。

| ビルド構成 | 総ビルド時間 | ステータス |
| :--- | :--- | :--- |
| <b>初期状態 (標準 Docker Build)</b> | 12分 7.2秒 | 成功 (キャッシュなし) |
| <b>Kaniko (初期適用)</b> | N/A | <b>失敗 (Exit 137 - OOM)</b> |
| <b>Kaniko (メモリ削減フラグ適用)</b> | 9分 12.8秒 | 成功 |
| <b>Buildx (初回 - キャッシュ生成時)</b> | 6分 41.5秒 | 成功 |
| <b>Buildx (2回目以降 - キャッシュヒット時)</b> | <b>4分 23.5秒</b> | <b>成功 (初期比 -64%)</b> |

Buildxとレジストリキャッシュの組み合わせにより、ビルド時間を約8分短縮しました。パッケージの追加や削除が発生した場合でも、キャッシュが無効化されるのは依存関係のインストールレイヤーのみであり、Kanikoのようなスナップショット処理に伴う全体的な遅延は発生しません。

---

## Lessons Learned

*   <b>ビルドコンテキストの厳密な管理</b>: .dockerignoreの記述ミスは、数ギガバイト単位の不要なデータ転送を引き起こし、CI/CD全体のパフォーマンスを著しく低下させます。
*   <b>キャッシュエンジンの選定</b>: エフェメラルなビルド環境においては、ファイルシステム全体のスナップショットをメモリ上で処理するツールよりも、BuildKit（Buildx）によるレイヤーベースのレジストリキャッシュの方が、メモリ効率および実行速度の面で優れています。
*   <b>今後の課題</b>: さらなる高速化に向けて、ビルド間で.next/cacheを永続化し、Next.jsの増分コンパイル（Incremental Compilation）を有効化する仕組みの導入を検討します。