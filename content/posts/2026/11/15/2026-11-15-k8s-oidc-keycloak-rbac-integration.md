---
title: "Keycloakアイデンティティブローカーを経由したKubernetes OIDC認証とRBAC統合設計"
slug: "k8s-oidc-keycloak-rbac-integration"
date: 2026-11-15T11:52:03+09:00
draft: false
image: ""
description: "KeycloakをOIDCアイデンティティブローカーとして配置し、Kubernetes APIサーバーの直接結合を回避しつつ、グループクレームに基づいた細粒度RBACを構築する設計手順とトラブルシューティングを解説します。"
categories: ["Backend Architecture"]
tags: ["jwt authentication filter"]
author: "K-Life Hack"
---

Kubernetesクラスタの運用において、組織規模の拡大に伴い複数存在するIdentity Provider（Azure ADやAuthentikなど）と<code>kubectl</code>のシングルサインオン（SSO）統合が求められます。しかし、各制御プレーンの<code>kube-apiserver</code>をアップストリームのIdPへ直接バインドする構成では、IdP側のスキーマ変更やテナント移行が全クラスタの再設定に直結し、設定の拡散や運用オーバーヘッドの増大を引き起こします。

この課題に対処するため、中間レイヤーとしてKeycloakをOpenID Connect（OIDC）アイデンティティブローカーとして導入し、認証基盤と制御プレーンを疎結合化する構成を策定します。本稿では、<code>kube-apiserver</code>のOIDCフラグ設定からグループクレームの透過パース、細粒度RBACポリシーの適用および検証手順までを整理します。

## 1. 制御プレーンにおける kube-apiserver OIDC統合設定

Kubernetes APIサーバーでJWTトークンを検証するには、すべてのコントロールプレーンノード上の <code>/etc/kubernetes/manifests/kube-apiserver.yaml</code> にOIDC認証パラメータを追加します。スタティックPodマニフェストを更新すると、<code>kube-apiserver</code> Podは自動的に再起動します。

```yaml
spec:
  containers:
  - command:
    - kube-apiserver
    - --oidc-issuer-url=https://keycloak.example.local/realms/kubernetes
    - --oidc-client-id=kubernetes
    - --oidc-username-claim=preferred_username
    - --oidc-groups-claim=groups
    - --oidc-ca-file=/etc/kubernetes/pki/keycloak-ca.crt
```

Keycloakが社内プライベート認証局（CA）で運用されている場合、該当するCA証明書を全コントロールプレーンノードの <code>/etc/kubernetes/pki/keycloak-ca.crt</code> に配置する必要があります。証明書パスが不適切な場合、<code>kube-apiserver</code> の初期化プロセスが停止します。

## 2. アップストリームグループクレームの伝播構成

Keycloak側でユーザーグループを手動二重管理する事態を防ぐため、アップストリームIdPが発行するグループ情報をJWTへ直接透過させます。設定は3つのレイヤーで同期させる必要があります。

### Layer 1: アップストリームIdPのグループシリアライズ（Authentikの例）

アップストリームIdP側のカスタムスコープ式を定義し、グループ属性をカンマ区切りの文字列型または配列形式でサニタイズします。

```python
return ",".join([group.name for group in request.user.ak_groups.all()])
```

### Layer 2: Keycloak Identity Provider スコープ設定

Keycloak管理コンソールにて <code>Identity Providers</code> -&gt; 該当Providerを選択 -&gt; <code>Advanced Settings</code> -&gt; <code>Scopes</code> に以下を指定します。

```text
profile email groups
```

### Layer 3: Keycloak Client Protocol Mapper設定

<code>kubernetes</code> クライアントの設定配下でMapperを追加し、Incomingの <code>groups</code> 属性をOutgoing JWTの <code>groups</code> クレーム（JSON Array形式）へ変換します。

## 3. クライアントサイド認証と kubelogin によるトークン検証

ヘッドレス環境やコマンドライン操作を行う端末では、<code>kubelogin</code> プラグインを使用してOAuth 2.0 Device Code Flow経由で認証を実行します。

```bash
# バイナリのインストールと配置
curl -LO https://github.com/int128/kubelogin/releases/latest/download/kubelogin_linux_amd64.zip
unzip kubelogin_linux_amd64.zip
sudo mv kubelogin /usr/local/bin/kubectl-oidc_login
```

デバイスコードフローによるトークン取得とペイロードデコード検証を実施します。

```bash
kubectl oidc-login get-token \
  --oidc-issuer-url=https://keycloak.example.local/realms/kubernetes \
  --oidc-client-id=kubernetes \
  --oidc-client-secret=<client_secret> \
  --oidc-extra-scope=groups \
  --certificate-authority=./keycloak-ca.crt \
  --grant-type=device-code \
  | jq -r '.status.token' | cut -d. -f2 | base64 -d 2&gt;/dev/null \
  | jq '{preferred_username, groups}'
```

期待される抽出結果:

```json
{
  "preferred_username": "john.doe@example.com",
  "groups": [
    "k8s-dev"
  ]
}
```

## 4. 細粒度RBACポリシーの定義

取得した <code>groups</code> クレームに基づいてアクセス権限を分離します。本設計では <code>k8s-admin</code>（全権限）と <code>k8s-dev</code>（特定ネームスペース限定参照権限およびNode参照権限）の2層構造を採用します。

### 4.1 クラスタ管理者向け ClusterRoleBinding

```bash
kubectl create clusterrolebinding oidc-k8s-admin \
  --clusterrole=cluster-admin \
  --group=k8s-admin
```

### 4.2 開発者向けネームスペース限定 Role / RoleBinding

開発用ネームスペース <code>team-a</code> 内でのみ参照を許可するマニフェストです。

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: namespace-viewer
  namespace: team-a
rules:
- apiGroups: ["", "apps", "batch"]
  resources: ["*"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: k8s-dev-viewer
  namespace: team-a
subjects:
- kind: Group
  name: k8s-dev
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: namespace-viewer
  apiGroup: rbac.authorization.k8s.io
```

### 4.3 開発者向けクラスタリソース（Node）の参照権限分離

<code>Node</code> はネームスペースに属さないリソースであるため、クラスタレベルの <code>ClusterRole</code> と <code>ClusterRoleBinding</code> が必要です。

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: node-viewer
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: k8s-dev-node-viewer
subjects:
- kind: Group
  name: k8s-dev
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: node-viewer
  apiGroup: rbac.authorization.k8s.io
```

## 5. クライアント Kubeconfig の構成と SelfSubjectAccessReview による監査

開発者端末で自動認証を維持するため、Execヘルパー形式で <code>kubeconfig</code> を構成します。

```bash
# 1. クラスタ接続情報の登録
kubectl config set-cluster my-k8s \
  --server=https://api.k8s.example.local:6443 \
  --certificate-authority=./cluster-ca.crt

# 2. Exec認証ヘルパーの設定
kubectl config set-credentials oidc-user \
  --exec-api-version=client.authentication.k8s.io/v1beta1 \
  --exec-command=kubectl \
  --exec-arg=oidc-login --exec-arg=get-token \
  --exec-arg=--oidc-issuer-url=https://keycloak.example.local/realms/kubernetes \
  --exec-arg=--oidc-client-id=kubernetes \
  --exec-arg=--oidc-extra-scope=groups \
  --exec-arg=--grant-type=device-code

# 3. コンテキストのバインド
kubectl config set-context my-k8s --cluster=my-k8s --user=oidc-user
kubectl config use-context my-k8s
```

権限判定の動作確認は <code>SelfSubjectAccessReview</code> APIを利用して実行します。

```bash
curl -sk https://api.k8s.example.local:6443/apis/authorization.k8s.io/v1/selfsubjectaccessreviews \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "apiVersion": "authorization.k8s.io/v1",
    "kind": "SelfSubjectAccessReview",
    "spec": {
      "resourceAttributes": {
        "namespace": "kube-system",
        "verb": "get",
        "resource": "pods"
      }
    }
  }' | jq '.status.allowed'
```

## Troubleshooting

認証ブローカー構成時に発生する主な不具合パターンと解決策を以下に整理します。

### 1. Reverse Proxy配下での無限リダイレクトループ

ロードバランサー等でTLS終端を行う環境において、Keycloakがプロキシヘッダーを認識できず、HTTPコンテキストとして判定してSecureクッキー属性を削除することが原因です。Gateway APIを利用している場合は、<code>HTTPRoute</code> リソースにて <code>X-Forwarded-Proto</code> ヘッダーを注入します。

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: keycloak-route
  namespace: keycloak
spec:
  rules:
  - filters:
    - type: RequestHeaderModifier
      requestHeaderModifier:
        set:
        - name: X-Forwarded-Proto
          value: https
        - name: X-Forwarded-Port
          value: "443"
```

### 2. トークン内の groups クレームが null になる現象

リクエスト時の <code>groups</code> スコープ指定漏れ、またはKeycloakプロトコルマッパーでの配列変換ミスマッチが原因です。Authentik側でグループ名を文字列に結合して送信するか、Keycloakの Mapper 設定で <code>Multivalued</code> オプションを有効化してください。

### 3. PKIX Path Building Failed エラー

Upstream IdPの証明書検証時に、中間CA証明書がKeycloakのTruststoreに登録されていない場合に発生します。サーバー証明書ではなく発行元ルート/中間CA証明書をKeycloak側にインポートする必要があります。

### 動作検証プロトコルログ

コントロールプレーンノードでの Pod 正常性および API レスポンス検証のログ出力例です。

```text
$ kubectl get pod -n kube-system -l component=kube-apiserver
NAME                                         READY   STATUS    RESTARTS   AGE
kube-apiserver-control-plane-01              1/1     Running   0          4m12s

$ curl -skI https://api.k8s.example.local:6443/livez
HTTP/2 200 
content-type: text/plain; charset=utf-8
x-content-type-options: nosniff
date: Sun, 15 Nov 2026 10:15:30 GMT
```

## Operational Notes

💡 <b>アーキテクチャの疎結合化</b>: Keycloakを中間ブローカーとして配置することで、アップストリームIdPの移行時にもKubernetes制御プレーン側の再設定を一切不要にできます。

⚠️ <b>クレーム伝播の整合性</b>: <code>groups</code> クレームの正常な伝播には、IdP側のスコープ定義、Keycloakにおけるプロトコルマッピング、<code>kube-apiserver</code> のフラグ定義の3箇所が正確に一致している必要があります。

🛠️ <b>クラスタ範囲リソースの明示的分離</b>: ネームスペースに非依存な <code>Node</code> などのクラスタリソースの参照権限には、ネームスペース固有の <code>Role</code> ではなく <code>ClusterRoleBinding</code> の個別定義が必須となります。</client_secret>