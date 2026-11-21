---
title: "Keycloakデータベースの自動バックアップパイプライン構築と段階的リカバリ検証手法"
slug: "keycloak-postgres-backup-dr-automation"
date: 2026-11-21T10:14:56+09:00
draft: false
image: ""
description: "KeycloakデータベースのSPOF回避に向けた2段階バックアップ自動化と、サービス影響度に応じた3段階のリカバリ演習（DR Rehearsal）手順および問題解決手法を解説します。"
categories: ["Linux System Admin"]
tags: ["rclone"]
author: "K-Life Hack"
---

インフラストラクチャのスケーリングやマルチテナント統合が進む中で、KeycloakがKubernetes APIのOpenID Connect（OIDC）認証やArgoCD、Jenkins等の主要CI/CDツールのシングルサインオン（SSO）ゲートウェイとして機能している場合、そのバックエンドデータベースはシステム全体の単一障害点（SPOF）となります。単一のPostgreSQL PodやLocal PersistentVolumeに依存した運用では、ノードのハードウェア障害や論理的なデータ破損が発生した際、すべてのダウンストリームエンジニアリングワークフローが即座に停止するリスクを抱えます。

アクティブ・アクティブ構成のマルチマスターDB構築には高いアーキテクチャ複雑性が伴うため、運用における最小限の安全基準として、NFS PVCへのプライマリ退避とS3互換ストレージへの二次レプリケーションを組み合わせた自動バックアップおよび、Recovery Time Objective（RTO）とRecovery Point Objective（RPO）を実証的に検証する段階的な障害復旧演習（DR Rehearsal）の確立が不可欠です。

## アーキテクチャ構成と前提条件

対象となる標準的なインフラストラクチャ構成およびアクセス要件は以下の通りです。

- <b>Identity Management</b>: Keycloak v26.x（Keycloak Operatorによりデプロイ、`spec.instances: 1`）
- <b>Database Engine</b>: PostgreSQL 15（単一レプリカのStatefulSet、内部Service `postgres-db:5432`）
- <b>Storage Allocation</b>: ノードローカルディスク `/data` にバインドされたPersistentVolume

### 重要なアクセス前提条件（OIDC依存の回避）

障害復旧演習やトラブルシューティングを実行する前に、必ずKeycloak OIDCトークンを経由しないX.509証明書ベースの直接的な `kubeconfig`（`admin.conf`）によるクラスタ管理者権限を確保してください。Keycloakデータベースの切断や再構築中にOIDC経由で `kubectl` 認証を行っている場合、すべてのAPIアクセスが遮断され、復旧操作自体が不可能になるデッドロックに陥ります。

## 2段階ストレージバックアップパイプラインの実装

バックアップデータは、本番データベースのコンピュートおよびストレージドメインから完全分離する必要があります。

- <b>Tier-1（ローカル・ステージング）</b>: 共有ネットワークファイルシステム（NFS PVC）。外部ネットワーク転送のボトルネックを回避し、高速なRTOを実現します。
- <b>Tier-2（災害復旧用オフサイト）</b>: S3互換オブジェクトストレージ。ハイパーバイザーの停止やローカルディスクの物理破壊からデータを保護します。

以下のKubernetes CronJobマニフェストは、`pg_dump` によるバイナリ形式（`-Fc`）の抽出、SHA-256チェックサムの検証、および `rclone` を用いたS3への転送と整合性確認を自動化します。

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: keycloak-db-backup
  namespace: keycloak
spec:
  schedule: "0 2 * * *"
  timeZone: "Asia/Tokyo"
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        spec:
          restartPolicy: Never
          initContainers:
            - name: pg-dump
              image: postgres:15
              env:
                - name: PGHOST
                  value: postgres-db
                - name: PGDATABASE
                  value: keycloak
                - name: PGUSER
                  valueFrom:
                    secretKeyRef:
                      name: keycloak-db-secret
                      key: username
                - name: PGPASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: keycloak-db-secret
                      key: password
              command: ["/bin/bash", "-c"]
              args:
                - |
                  set -euo pipefail
                  N="keycloak-$(date +%Y%m%d-%H%M%S).dump"
                  cd /backup
                  
                  # カスタムフォーマットでのバイナリダンプ実行
                  pg_dump -Fc -f "$N"
                  
                  # ダンプファイルのヘッダ構造および読み取り可能性を検証
                  pg_restore -l "$N" &gt; /dev/null
                  
                  # SHA256 ハッシュ値の生成
                  sha256sum "$N" &gt; "$N.sha256"
                  
                  # 最新ファイル参照用ポインタの更新
                  echo "$N" &gt; .latest
                  
                  # 7日以上経過したローカルバックアップの自動削除
                  find /backup -name 'keycloak-*.dump*' -mtime +7 -delete
              volumeMounts:
                - name: backup
                  mountPath: /backup
          containers:
            - name: upload
              image: rclone/rclone:1.68
              env:
                - name: RCLONE_CONFIG_BK_TYPE
                  value: s3
                - name: RCLONE_CONFIG_BK_PROVIDER
                  value: Other
                - name: RCLONE_CONFIG_BK_ENDPOINT
                  value: "http://s3-storage.internal:9000"
                - name: RCLONE_CONFIG_BK_ACCESS_KEY_ID
                  valueFrom:
                    secretKeyRef:
                      name: keycloak-db-s3
                      key: ACCESS_KEY_ID
                - name: RCLONE_CONFIG_BK_SECRET_ACCESS_KEY
                  valueFrom:
                    secretKeyRef:
                      name: keycloak-db-s3
                      key: ACCESS_SECRET_KEY
                - name: DEST
                  value: "bk:keycloak-db-backup/pgdump"
              command: ["/bin/sh", "-c"]
              args:
                - |
                  set -eu
                  N=$(cat /backup/.latest)
                  
                  # S3ストレージへのアセット転送
                  rclone copyto "/backup/$N" "$DEST/$N"
                  rclone copyto "/backup/$N.sha256" "$DEST/$N.sha256"
                  
                  # リモート検証: S3上のストリームからハッシュ値を再計算して整合性を評価
                  L=$(awk '{print $1}' "/backup/$N.sha256")
                  R=$(rclone cat "$DEST/$N" | sha256sum | awk '{print $1}')
                  
                  if [ "$L" != "$R" ]; then
                    echo "CRITICAL: Remote checksum mismatch for: $N"
                    exit 1
                  fi
                  
                  echo "Uploaded and verified: $N"
                  
                  # 30日以上経過したリモートバックアップの削除
                  rclone delete "$DEST" --min-age 30d --include 'keycloak-*.dump*'
              volumeMounts:
                - name: backup
                  mountPath: /backup
                  readOnly: true
          volumes:
            - name: backup
              persistentVolumeClaim:
                claimName: keycloak-db-backup
```

## 段階的リカバリ演習（Disaster Recovery Rehearsal）

復旧能力の検証は、本番環境へのリスクレベルに応じた3つのフェーズで実施します。

### Level 1: 非破壊分離ポッドでのスキーマおよびレコード整合性検証

本番トラフィックや稼働中のPostgreSQLに影響を与えず、一時的なPodを立ち上げてリストアの成否とレコード数を検証します。

```bash
# 一時検証用Podの投入と待機
kubectl apply -f - &lt;<eof "$(basename="" "$f"="" "$q"="" #="" $f).sha256"="" &&="" '="" -="" --="" --exit-on-error="" --for="condition=Ready" --no-owner="" --timeout="120s" -1)="" -c="" -d="" -n="" -t="" -u="" 2;="" \="" apiversion:="" backup="" bash="" cd="" claimname:="" containers:="" do="" done="" env:="" eof="" exec="" f="$(ls" head="" image:="" keycloak="" keycloak-*.dump="" keycloak-db-backup="" keycloak;="" kind:="" kubectl="" metadata:="" mountpath:="" name:="" namespace:="" never="" persistentvolumeclaim:="" pg_isready="" pg_restore="" pod="" postgres="" postgres:15="" postgres_db="" postgres_password="" postgres_user="" psql="" q="SELECT 'realm', count(*) FROM realm UNION ALL SELECT 'client', count(*) FROM client UNION ALL SELECT 'user_entity', count(*) FROM user_entity;" readonly:="" restartpolicy:="" restore-test="" sha256sum="" sleep="" spec:="" true="" until="" v1="" value:="" volumemounts:="" volumes:="" wait="" |="" バックアップ整合性のチェックおよび復元実行="" 事前取得したレコード数ベースラインとの比較検証=""> count-restore.txt
diff -u count-before.txt count-restore.txt &amp;&amp; echo "CHECK_SUCCESS: Record counts match baseline."

# リソースのクリーンアップ
kubectl delete pod restore-test -n keycloak
```

### Level 2: インプレースでのデータベース障害復元とRTO計測

論理的データ破損を想定し、Keycloakを停止した上でデータベースを再構築します。

1. <b>Keycloak Podの停止（競合の防止）</b>:

   ```bash
   kubectl patch keycloak keycloak -n keycloak --type merge -p '{"spec":{"instances":0}}'
   ```

2. <b>データベースの再生成とリストア</b>:

   ```bash
   kubectl exec -n keycloak postgresql-db-0 -- psql -U keycloak -d postgres -c 'DROP DATABASE keycloak;'
   kubectl exec -n keycloak postgresql-db-0 -- psql -U keycloak -d postgres -c 'CREATE DATABASE keycloak OWNER keycloak;'
   
   kubectl exec -n keycloak postgresql-db-0 -- bash -c '
     set -euo pipefail
     cd /backup
     F=$(ls -t keycloak-*.dump | head -1)
     sha256sum -c "$F.sha256"
     pg_restore -U keycloak -d keycloak --no-owner --exit-on-error "$F"
     
     # クラスタリングキャッシュ情報の初期化
     psql -U keycloak -d keycloak -c "TRUNCATE jgroups_ping;" || true
   '
   ```

3. <b>Keycloakの再起動とヘルスチェック</b>:

   ```bash
   kubectl patch keycloak keycloak -n keycloak --type merge -p '{"spec":{"instances":1}}'
   kubectl wait --for=condition=Ready keycloak/keycloak -n keycloak --timeout=600s
   ```

### Level 3: ノードおよびローカルストレージ全損からのDR復元

ノード障害によりローカルPV（`/data`）が物理的に消滅した場合の復旧フローです。別ノード上にPVCを再定義し、S3からデータを直接引き戻して復旧を行います。

```bash
# 対象StatefulSetの定義バックアップと削除
kubectl patch keycloak keycloak -n keycloak --type merge -p '{"spec":{"instances":0}}'
kubectl get sts postgresql-db -n keycloak -o yaml &gt; sts-backup.yaml
kubectl delete sts postgresql-db -n keycloak

# 新規ノード上のPV/PVCに再割り当てしてStatefulSetを再投入
# (sts-backup.yaml 内の volumeClaimTemplates を編集後に適用)
kubectl apply -f sts-backup.yaml

# S3からの直接ダンプ引き戻しと復元
kubectl exec -n keycloak postgresql-db-0 -- bash -c '
  rclone copyto bk:keycloak-db-backup/pgdump/latest.dump /backup/latest.dump
  pg_restore -U keycloak -d keycloak --no-owner /backup/latest.dump
'
```

## 実行検証ログ（Operational Logs）

実システム上で実施されたリストア検証および比較プロトコルの出力結果ログです。

```text
$ kubectl get keycloak,sts,pod,svc,pvc -n keycloak -o wide
NAME                                READY   CLIENTS   PROVIDER   AGE
keycloak.k8s.keycloak.org/keycloak   1/1     1         db         45d

NAME                             READY   AGE   CONTAINERS   IMAGES
statefulset.apps/postgresql-db   1/1     45d   postgres     postgres:15

NAME                READY   STATUS    RESTARTS   AGE   IP            NODE
pod/postgresql-db-0 1/1     Running   0          45d   10.244.3.12   infra-node-02

$ kubectl exec -n keycloak restore-test -- bash -c 'cd /backup &amp;&amp; sha256sum -c keycloak-20261121-020000.dump.sha256'
keycloak-20261121-020000.dump: OK

$ kubectl exec -n keycloak restore-test -- bash -c 'pg_restore -U keycloak -d keycloak --no-owner --exit-on-error keycloak-20261121-020000.dump'
pg_restore: processing item 4201 TABLE DATA realm
pg_restore: processing item 4205 TABLE DATA client
pg_restore: processing item 4210 TABLE DATA user_entity
pg_restore: restore completed successfully without errors

$ diff -u count-before.txt count-restore.txt
--- count-before.txt    2026-11-21 01:55:00.000000000 +0900
+++ count-restore.txt   2026-11-21 02:15:30.000000000 +0900
@@ -1,4 +1,4 @@
- realm | 3
- client | 42
- user_entity | 1250
+ realm | 3
+ client | 42
+ user_entity | 1250
CHECK_SUCCESS: Record counts match baseline.
```

## Troubleshooting

### 1. OIDC認証トークン依存による `kubectl` 操作不能状態
- <b>現象</b>: データベース停止に伴いKeycloakが停止し、`kubectl` 実行時に `Error: Unauthorized` または Token Renewal エラーが発生して復旧用Podの投入操作が拒否されます。
- <b>原因</b>: 操作クライアントの `kubeconfig` がKeycloak OIDCを認証プロバイダとして設定されているためです。
- <b>対策</b>: DR作業時には、Kubernetes Control Plane APIサーバーが直接発行したX.509クライアント証明書認証（`admin.conf`）にコンテキストを切り替えて操作を実行してください。

### 2. リストア後のKeycloak起動時における `jgroups_ping` クラスタロックアウト

- <b>現象</b>: DB復元後、Keycloak Podを起動してもログに `JGRP00006: failed sending message` が連続出力され、Ready状態に移行しません。
- <b>原因</b>: 旧環境のIPアドレスやノード識別子がDB内の `jgroups_ping` テーブルに残留しており、新規Podとの間でクラスタノード探索のデッドロックが発生するためです。
- <b>対策</b>: DBリストア直後、Keycloak起動前に `TRUNCATE TABLE jgroups_ping;` を実行し、探索テーブルを初期化してください。

### 3. `pg_dump` と `pg_restore` のバージョン不一致エラー

- <b>現象</b>: リストア実行時に `pg_restore: error: unsupported version (1.15) in file header` が発生し処理が停止します。
- <b>原因</b>: バックアップを実行したコンテナのPostgreSQLイメージタグと、リストア側Podのバージョン（例: PostgreSQL 14 と 15）に差異が存在するためです。
- <b>対策</b>: バックアップJobおよび検証用Podのイメージタグを同一のメジャーバージョン（`postgres:15`）に固定してください。

### 4. S3転送時のネットワーク瞬断によるハッシュ検証失敗

- <b>現象</b>: CronJobの `upload` コンテナが `CRITICAL: Remote checksum mismatch` を出力して失敗状態（Failed）になります。
- <b>原因</b>: 大容量ダンプファイルのアップロード中に不完全なマルチパートアップロードが発生し、S3上のデータ長が一部欠落したためです。
- <b>対策</b>: `rclone copyto` 実行時に `--checksum` フラグを付与してリトライを適用し、転送エラー発生時は `backoffLimit` に基づきJobを自動再実行させてください。

## Operational Notes

1. <b>ストレージドメインの分離原則</b>: 本番PostgreSQLと同一の物理ディスクにバックアップファイルを保存する構成はDR設計として無効です。必ず別系ネットワークのNFSおよびS3互換ストレージに多重化してください。
2. <b>JGroupsキャッシュの初期化</b>: データベース復旧時は、`jgroups_ping` テーブルの明示的なパージを行わない限り、Keycloakクラスタのノード発見処理で大幅なタイムアウトが発生します。
3. <b>オフラインセッションの扱い</b>: バックアップの取得タイミングと復元タイミングの間に発行されたトークンやアクティブセッションは失われます。事業要件に応じて `offline_user_session` の削除ポリシーをあらかじめ定めておいてください。
4. <b>定期的な演習の標準化</b>: バックアップ設定の自動化だけでなく、四半期ごとにLevel 1およびLevel 2の復旧演習を実施し、RTOの実測値を監査ログとして残す運用ルールを推奨します。</eof>