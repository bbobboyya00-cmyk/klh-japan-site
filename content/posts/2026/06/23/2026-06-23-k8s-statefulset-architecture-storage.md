---
title: "Kubernetes StatefulSetにおける永続データ管理とネットワーク識別子の設計"
slug: "k8s-statefulset-architecture-storage"
date: 2026-06-23T10:11:29+09:00
draft: false
image: ""
description: "Kubernetes StatefulSetの内部メカニズム、Headless Serviceによる名前解決、およびVolumeClaimTemplatesを用いた動的ストレージプロビジョニングの技術的詳細を解説します。"
categories: ["DevOps Logistics"]
tags: ["kubernetes", "statefulset", "headless-service", "pvc", "volumeclaimtemplates"]
author: "K-Life Hack"
---

# Kubernetes StatefulSetにおける永続的アイデンティティとストレージの管理手法

分散システムやデータベース（MySQL、PostgreSQL、Kafkaなど）の運用において、ポッドの再起動後も同一のアイデンティティとデータを保持することは、システムの整合性を維持するための必須要件です。標準的なDeploymentでは、ポッドはエフェメラル（一時的）な存在として扱われ、再起動のたびにランダムなホスト名とIPアドレスが割り当てられます。このようなステートレスな設計は、データの永続性やマスター・スレーブ間の固定的な通信が必要なワークロードにおいて、重大な運用上の制約となります。本稿では、これらの課題を解決するStatefulSetの内部構造と、Headless ServiceおよびVolumeClaimTemplatesを用いた実装手法について技術的分析を行います。

## 1. StatefulSetとDeploymentの構造的相違

StatefulSetは、ポッドの「順序性」と「一意性」を保証するために設計されています。Deploymentとの主な違いは以下の通りです。

- <b>識別子</b>: Deploymentはランダムなサフィックスを付与しますが、StatefulSetは `mysql-0`, `mysql-1` のように固定の序数インデックスを付与します。
- <b>ストレージ</b>: Deploymentは全レプリカで同一のボリュームを共有（またはボリュームなし）しますが、StatefulSetは各ポッドに専用のPVC（PersistentVolumeClaim）を1対1で割り当てます。
- <b>デプロイ順序</b>: Deploymentは並列で作成・削除されますが、StatefulSetはインデックス0から順次作成され、削除時は逆順（OrderedReady）で実行されます。

## 2. Headless Serviceによるネットワーク識別子の固定

StatefulSetのポッドが固定のFQDN（Fully Qualified Domain Name）を持つためには、Headless Serviceとの連携が不可欠です。`clusterIP: None` を設定することで、Serviceは仮想IPを持たず、DNSクエリに対して個々のポッドのIPアドレスを直接返します。

```yaml
apiVersion: v1
kind: Service
metadata:
  name: sfs-service01
spec:
  selector:
    app.kubernetes.io/name: web-sfs01
  type: ClusterIP
  clusterIP: None
  ports:
  - protocol: TCP
    port: 80
```

この設定により、各ポッドは `[Pod Name].[Service Name].[Namespace].svc.cluster.local` という形式で相互に通信可能となります。これは、クラスタ内でのリーダー選定やデータ同期において、特定のノードを明示的に指定する必要がある分散データベースにおいて極めて重要です。

## 3. StatefulSetの実装とポッドのライフサイクル

以下は、Nginxイメージを使用したStatefulSetの基本構成です。`serviceName` フィールドによって、前述のHeadless Serviceと明示的に紐付けられます。

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: sfs-test01
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: web-sfs01
  serviceName: sfs-service01
  template:    metadata:
      labels:
        app.kubernetes.io/name: web-sfs01
    spec:
      containers:
      - name: nginx
        image: nginx:latest
```

## 4. VolumeClaimTemplatesによる動的プロビジョニング

StatefulSetの最も強力な機能の一つは、`volumeClaimTemplates` です。これにより、ポッドごとに独立したストレージが自動的にプロビジョニングされます。ポッドが削除されてもPVCは保持されるため、再起動後のポッドは以前と同じデータボリュームに再マウントされます。

```yaml
  volumeClaimTemplates:
  - metadata:
      name: sfs-vol01
    spec:
      accessModes: [ "ReadWriteOnce" ]
      storageClassName: pv-sfs-test01
      resources:
        requests:
          storage: 5Mi
```

## Troubleshooting

StatefulSetの運用において最も頻繁に遭遇する問題は、スケーリング時の <b>PVCのPending状態</b> です。手動でPersistentVolume（PV）を管理している環境において、`replicas` を増やした際、対応する `storageClassName` を持つ利用可能なPVが不足していると、新しいポッドは `Pending` のまま起動しません。⚠️

また、StatefulSetを削除してもPVCは自動削除されないため、ディスク容量の枯渇を招く可能性があります。不要になったデータは、StatefulSetの削除後に手動で `kubectl delete pvc` を実行してクリーンアップする必要があります。

## Operational Verifications

デプロイ後のリソース状態およびネットワーク疎通の確認ログを以下に示します。

```text
# リソースの起動確認
% kubectl get pod -o wide
NAME           READY   STATUS    RESTARTS   AGE   IP            NODE
sfs-test01-0   1/1     Running   0          80s   10.244.2.9    worker-node-01
sfs-test01-1   1/1     Running   0          80s   10.244.1.17   worker-node-02
sfs-test01-2   1/1     Running   0          79s   10.244.1.18   worker-node-02

# Headless Serviceの確認
% kubectl get svc sfs-service01
NAME            TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
sfs-service01   ClusterIP   None         <none>        80/TCP    14m

# 特定ポッドへの疎通確認 (Pod 1への直接アクセス)
% kubectl exec -it nginx-client -- curl -I sfs-test01-1.sfs-service01.default.svc.cluster.local
HTTP/1.1 200 OK
Server: nginx/1.25.x
Content-Type: text/html
```

## Lessons Learned

StatefulSetの導入は、単なるポッドの管理を超え、インフラ層におけるストレージのライフサイクル管理とネットワークトポロジの固定化を意味します。特にデータベースのコンテナ化においては、`volumeClaimTemplates` によるデータの局所性確保と、Headless Serviceによる安定したエンドポイントの提供が、システムの信頼性を左右する決定的な要因となります。💡 運用設計においては、ポッドの異常終了時におけるPVCの再アタッチ時間や、スケーリング時のPV供給能力を事前に検証しておくことが推奨されます。</none>