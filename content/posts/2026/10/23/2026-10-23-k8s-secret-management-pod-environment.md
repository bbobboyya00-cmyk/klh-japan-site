---
title: "KubernetesにおけるSecretリソースの定義手法とPodへの環境変数注入"
slug: "k8s-secret-management-pod-environment"
date: 2026-10-23T10:30:20+09:00
draft: false
image: ""
description: "KubernetesでDB接続情報等の機密データを安全に扱うためのSecretの作成手順、Base64エンコード時の注意点、Podへの環境変数注入構成について整理します。"
categories: ["DevOps Logistics"]
tags: ["kubernetes yaml 파일로 동적 값을 설정하는 방법"]
author: "K-Life Hack"
---

# Kubernetes Secretオブジェクトによる機密情報の安全な管理と構成手法

<b>Meta Description</b>: KubernetesにおけるSecretオブジェクトを用いた機密情報の分離管理、CLI/YAMLでの生成手順、Podへの注入パターン、Base64エンコードの注意点およびトラブルシューティングを解説します。

---

コンテナ環境において、データベース接続文字列や認証用トークンなどの機密情報をアプリケーションのソースコードやコンテナイメージ内にハードコードすることは、重大なセキュリティリスクを引き起こします。Kubernetesでは、非機密設定をConfigMapで管理する一方、認証情報や暗号化キーなどの感度の高いデータはSecretオブジェクトとして分離管理します。

Secretオブジェクトを利用することで、設定データとアプリケーションロジックを分離し、Podに対して環境変数やボリュームとして安全に設定を配備できます。

## Secretオブジェクトの生成手法

KubernetesにおいてSecretを定義する方法には、CLIコマンドによる宣言的/命令的なアプローチと、YAMLマニフェストを使用するアプローチが存在します。

### CLI命令型コマンドによる生成

`kubectl create secret`コマンドを使用すると、データの手動エンコードを行わずに直接Secretを作成できます。`--from-literal`フラグを使用することで、システム側で自動的にBase64エンコード処理が行われます。

単一の値を登録する構成：

```bash
kubectl create secret generic app-secret --from-literal=DB_HOST=mysql
```

複数の接続情報をまとめて登録する構成：

```bash
kubectl create secret generic app-secret \
  --from-literal=DB_HOST=mysql \
  --from-literal=DB_USER=root \
  --from-literal=DB_PASSWORD=passwrd
```

### プロパティファイルからの生成

既存のプロパティファイル（例: `app_secret.properties`）が存在する場合、`--from-file`フラグを用いて一括でSecretへ変換できます。この場合、ファイル名がKey、ファイルの内容がValueとして自動的にマッピングされます。

対象のファイル構成（`app_secret.properties`）：

```properties
DB_HOST=mysql
DB_USER=root
DB_PASSWORD=passwrd
```

実行コマンド：

```bash
kubectl create secret generic app-secret --from-file=app_secret.properties
```

### YAMLマニフェストによる宣言的定義

GitOpsやCI/CDパイプラインに組み込む場合、YAMLファイルによる定義が一般的です。YAMLマニフェストの`data`フィールドに設定を記述する場合、値は事前にBase64でエンコードされている必要があります。

Base64エンコード処理（Linux/Unix環境）：

```bash
echo -n 'mysql' | base64    # 出力例: bXlzcWw=
echo -n 'root' | base64     # 出力例: cm9vdA==
echo -n 'passwrd' | base64  # 出力例: cGFzc3dyZA==
```

マニフェスト定義（`secret-data.yaml`）：

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-secret
type: Opaque
data:
  DB_HOST: bXlzcWw=
  DB_USER: cm9vdA==
  DB_PASSWORD: cGFzc3dyZA==
```

デプロイ実行：

```bash
kubectl apply -f secret-data.yaml
```

## Secretの確認と参照デコード

デプロイされたSecretの状態を確認するには以下のコマンドを使用します。

登録されているSecret一覧の取得：

```bash
kubectl get secrets
```

Secretのメタデータ確認（※実際の値はマスクされて表示されます）：

```bash
kubectl describe secret app-secret
```

エンコードされた生のデータを確認する場合：

```bash
kubectl get secret app-secret -o yaml
```

取得したBase64文字列を元のプレーンテキストに復号確認するには、`base64 --decode`を実行します。

```bash
echo -n 'bXlzcWw=' | base64 --decode
```

## PodへのSecret注入構成

作成したSecretは、Podのコンテナへ環境変数として注入できます。Kubernetes内部で自動的にBase64が復号され、コンテナのアプリケーションからは通常のプレーンテキストとして参照可能になります。

### 全てのKeyを環境変数として一括注入（envFrom）

Secret内のすべてのキーペアをコンテナ環境変数に読み込ませる構成例です。

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: simple-webapp-color
  labels:
    name: simple-webapp-color
spec:
  containers:
    - name: simple-webapp-color
      image: simple-webapp-color
      ports:
        - containerPort: 8080
      envFrom:
        - secretRef:
            name: app-secret
```

### 特定のKeyを選択して注入（secretKeyRef）

特定のキーのみを選択し、特定の環境変数名にマッピングする構成例です。

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: simple-webapp-color
spec:
  containers:
    - name: simple-webapp-color
      image: simple-webapp-color
      env:
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: app-secret
              key: DB_PASSWORD
```

## Troubleshooting

Secretの作成および運用時には、いくつかの典型的な設定ミスが発生することがあります。

### 🛠️ 1. Base64エンコード時の末尾改行コード混入

⚠️ `echo`コマンドでBase64エンコードを行う際、`-n`オプションを付け忘れると改行文字（`\n`）が含まれた状態でエンコードされます。

```bash
# 不適切な例（改行が含まれる）
echo 'passwrd' | base64
# 出力: cGFzc3dyZAo=

# 適切な例
echo -n 'passwrd' | base64
# 出力: cGFzc3dyZA==
```

末尾に改行コードが含まれたままSecretを生成すると、アプリケーション側でDB接続を試みた際にパスワード不一致のエラー（`Authentication Failed`）が発生する要因となります。

### 🛠️ 2. 環境変数注入における動的更新の反映制限

Podの`env`や`envFrom`フィールド経由で読み込まれたSecretの値は、Podが起動するタイミングでプロセスに渡されます。したがって、後から`kubectl edit secret`などでSecretオブジェクトの値を変更しても、実行中のPod内の環境変数は自動更新されません。

更新された設定を反映させるには、ローリングアップデートを実行するか、Podを再起動する必要があります。

```bash
kubectl rollout restart deployment <deployment-name>
```

## 実行検証ログプロトコル

Pod起動後、Secretが正しく復号されて環境変数へ注入されているかを検証するコマンドライン出力例です。

```text
$ kubectl get secret app-secret
NAME         TYPE     DATA   AGE
app-secret   Opaque   3      5m12s

$ kubectl exec simple-webapp-color -- printenv | grep DB_
DB_HOST=mysql
DB_USER=root
DB_PASSWORD=passwrd
```

## Configuration Notes

💡 Kubernetesの標準Secretは「暗号化（Encryption）」ではなく単なる「Base64エンコード」である点に注意してください。etcd自体への保管時に暗号化を行うには、Kube-apiserver側で`EncryptionConfiguration`を設定するか、外部のシークレット管理ツール（HashiCorp Vaultなど）との連携を検討する必要があります。

💡 Secretのリソース定義マニフェスト（YAML）をGitリポジトリへ登録する際は、SOPS (Secrets Opaque Secret) や Sealed Secrets などのツールを用いて暗号化した状態で管理する構成が推奨されます。</deployment-name>