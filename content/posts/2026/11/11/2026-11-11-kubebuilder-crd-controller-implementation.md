---
title: "Kubebuilderによる独自CRD設計とコントローラー実装の基本検証"
slug: "kubebuilder-crd-controller-implementation"
date: 2026-11-11T11:00:34+09:00
draft: false
image: ""
description: "KubernetesのAPI拡張においてCRDスキーマ定義とReconcileループを制御するカスタムコントローラーの実装手順および検証プロセスを記録したエンジニアリングノートです。"
categories: ["DevOps Logistics"]
tags: ["kubebuilder", "kubernetes", "crd", "controller-runtime", "kubectl"]
author: "K-Life Hack"
---

Kubernetesクラスタを運用する過程において、標準のPodやService、Deploymentといったプリミティブのみでは、ドメイン固有のライフサイクル管理や宣言的状態の維持を自動化しきれない課題が生じます。シェルスクリプトや外部スクリプトを用いたアドホックな操作はヒューマンエラーや状態ドリフトを招きやすいため、KubernetesのControl Plane自体に独自のリソース型を登録し、APIサーバー経由で直接ライフサイクルを管理するオペレーターパターンの適用が必要となります。

本稿では、Kubebuilderフレームワークを活用し、カスタムリソース定義（CRD）のスキーマ策定から、Reconcileループによる状態追従コントローラーの実装とローカル環境での疎通検証までを整理します。

## 1. Kubernetes拡張アーキテクチャの構成要素

Kubernetesの拡張機構は、宣言された仕様（Desired State）と実際のシステム状態（Actual State）を一致させるフィードバック制御モデルに基づいています。

* <b>Custom Resource (CR):</b> ユーザーが定義するカスタムオブジェクトのインスタンス。データはクラスタのストレージ基盤であるetcdへ永続化され、APIサーバー経由でCRUD操作が可能となります。
* <b>Custom Resource Definition (CRD):</b> CRのOpenAPI v3スキーマを定義する設計図。フィールドの型検証、必須チェック、ステータスサブリソースの有無を規定します。
* <b>Controller:</b> 指定したリソースのイベント（作成・更新・削除）を監視し、`Reconcile()`関数を無限ループ構造で実行して差分を解消する自律型プロセスです。

### 開発フレームワークの選択特性

Kubernetesのコントローラー実装には主にKubebuilderとOperator SDKが存在します。両者の特徴は以下の通りです。

| 項目 | Kubebuilder | Operator SDK |
| :--- | :--- | :--- |
| 主要メンテナ | Kubernetes SIGs | Operator Framework (CNCF/Red Hat) |
| 対応言語 | Go | Go, Ansible, Helm |
| 守備範囲 | スキャフォールディング、コード生成、テスト | スキャフォールディング、OLM統合、パッケージング |
| 構造的関係 | コントローラー実装の標準コア | Goベース実装のエンジンとして内部でKubebuilderを採用 |

本実装では、依存関係を最小限に抑えGo言語の純粋なコントローラーロジックを迅速に検証するため、Kubebuilderを採用します。

## 2. プロジェクトの初期化とAPIスキーマ定義

まず作業ディレクトリを作成し、プロジェクトのドメインとリポジトリモジュール名を指定してスキャフォールディングを実施します。

```bash
mkdir cinema-operator &amp;&amp; cd cinema-operator
kubebuilder init --domain cinema.com --repo cinema.com/operator
```

次に、グループ名`entertainment`、バージョン`v1`、Kind名`Movie`のAPIリソース構造を生成します。

```bash
kubebuilder create api --group entertainment --version v1 --kind Movie
```

生成された`api/v1/movie_types.go`を編集し、`MovieSpec`にドメイン固有のフィールドを宣言します。

```go
package v1

import (
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

type MovieSpec struct {
    Title       string `json:"title,omitempty"`
    Genre       string `json:"genre,omitempty"`
    RunningTime int    `json:"runningTime,omitempty"`
    IsReleased  bool   `json:"isReleased,omitempty"`
}

type MovieStatus struct {
    // 状態管理用のステータスフィールドを必要に応じて追記
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status

type Movie struct {
    metav1.TypeMeta   `json:",inline"`
    metav1.ObjectMeta `json:"metadata,omitempty"`

    Spec   MovieSpec   `json:"spec,omitempty"`
    Status MovieStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

type MovieList struct {
    metav1.TypeMeta `json:",inline"`
    metav1.ListMeta `json:"metadata,omitempty"`
    Items           []Movie `json:"items"`
}

func init() {
    SchemeBuilder.Register(&amp;Movie{}, &amp;MovieList{})
}
```

## 3. コントローラーのReconcileロジック実装

`internal/controller/movie_controller.go`にイベント検知時の処理フローを実装します。APIサーバーから該当リソースのインスタンスを取得し、存在しない場合はNotFoundエラーを無視してループを終了します。

```go
package controller

import (
    "context"

    "k8s.io/apimachinery/pkg/runtime"
    ctrl "sigs.k8s.io/controller-runtime"
    "sigs.k8s.io/controller-runtime/pkg/client"
    "sigs.k8s.io/controller-runtime/pkg/log"

    entertainmentv1 "cinema.com/operator/api/v1"
)

type MovieReconciler struct {
    client.Client
    Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=entertainment.cinema.com,resources=movies,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=entertainment.cinema.com,resources=movies/status,verbs=get;update;patch

func (r *MovieReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    logger := log.FromContext(ctx)

    var movie entertainmentv1.Movie
    if err := r.Get(ctx, req.NamespacedName, &amp;movie); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }

    logger.Info("Reconciling Movie resource", 
        "Name", movie.Name, 
        "Title", movie.Spec.Title, 
        "Genre", movie.Spec.Genre,
        "RunningTime", movie.Spec.RunningTime,
        "IsReleased", movie.Spec.IsReleased,
    )

    return ctrl.Result{}, nil
}

func (r *MovieReconciler) SetupWithManager(mgr ctrl.Manager) error {
    return ctrl.NewControllerManagedBy(mgr).
        For(&amp;entertainmentv1.Movie{}).
        Complete(r)
}
```

## 4. マニフェスト生成とローカルエンドポイント検証

Go構造体に付与されたマーカーコメント（`+kubebuilder:...`）からCRDマニフェストファイルを自動生成します。

```bash
make manifests
```

生成されたマニフェストファイル`config/crd/bases/entertainment.cinema.com_movies.yaml`を検証用APIサーバーに対して適用します。以下は開発検証用に一時コンテナを立ち上げてリソースを登録する手順です。

```bash
docker run -d --name=k8s-api --net=host \
  registry.k8s.io/kube-apiserver:v1.19.0 \
  kube-apiserver --etcd-servers=http://127.0.0.1:8888 \
  --authorization-mode=AlwaysAllow --bind-address=0.0.0.0 \
  --insecure-port=8080 --secure-port=6444 --allow-privileged=true

kubectl --server=http://127.0.0.1:8080 apply -f config/crd/bases/entertainment.cinema.com_movies.yaml
```

定義したスキーマに適合するCRインスタンスマニフェスト`movie-sample.yaml`を記述します。

```yaml
apiVersion: entertainment.cinema.com/v1
kind: Movie
metadata:
  name: the-outlaws
spec:
  title: "The Outlaws 4"
  genre: "Action"
  runningTime: 109
  isReleased: true
```

クラスタへCRを登録します。

```bash
kubectl --server=http://127.0.0.1:8080 apply -f movie-sample.yaml
```

コントローラープロセスを起動し、APIサーバーと同期させます。

```bash
export KUBERNETES_MASTER="http://127.0.0.1:8080"
make run
```

## 5. Troubleshooting

### CRD適用時のスキーマ検証エラー

CRDを適用する際、Kubebuilderタグの記述誤りや型の不一致により以下のエラーが発生することがあります。

```text
error: unable to recognize "config/crd/bases/entertainment.cinema.com_movies.yaml": no matches for kind "CustomResourceDefinition" in version "apiextensions.k8s.io/v1"
```

この場合、接続先APIサーバーのバージョンがCRDのAPI仕様（`v1`または`v1beta1`）と合致しているか確認が必要です。旧バージョン互換性が必要な場合は、`Makefile`内のController-tools生成オプションで`crd:crdVersions=v1beta1`を指定し直します。

### RBAC権限不足によるReconcile失敗

コントローラーを実クラスタ環境のPodとして実行する場合、ServiceAccountのRoleBinding不足により、以下のようなアクセス拒否が発生します。

```text
ERROR   controllers.Movie       unable to fetch Movie   {"error": "movies.entertainment.cinema.com is forbidden: User \"system:serviceaccount:cinema-system:cinema-operator\" cannot get resource \"movies\" in API group \"entertainment.cinema.com\""}
```

この事象は、Goコード内のRBACマーカー（`// +kubebuilder:rbac:groups=...`）が不足しているか、生成後のRole設定が適用されていないことに起因します。マーカーを修正後、`make manifests`を再実行し、生成されたClusterRole/Roleマニフェストを再デプロイしてください。

## 6. 検証ログと実行プロトコル

CRの適用およびコントローラーの起動ログを確認し、Reconcile処理が正常に実行されていることを検証します。

```text
$ kubectl --server=http://127.0.0.1:8080 get crd
NAME                                  CREATED AT
movies.entertainment.cinema.com       2026-11-11T09:12:44Z

$ kubectl --server=http://127.0.0.1:8080 get movie the-outlaws -o yaml
apiVersion: entertainment.cinema.com/v1
kind: Movie
metadata:
  name: the-outlaws
  namespace: default
spec:
  genre: Action
  isReleased: true
  runningTime: 109
  title: The Outlaws 4

$ make run
/home/user/cinema-operator/bin/controller-gen rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases
go run ./cmd/main.go
2026-11-11T09:15:02.114Z INFO controller-runtime.metrics Metrics server is starting to listen {"addr": ":8080"}
2026-11-11T09:15:02.115Z INFO Starting server {"path": "/metrics", "kind": "metrics", "addr": "[::]:8080"}
2026-11-11T09:15:02.116Z INFO Starting EventSource {"controller": "movie", "controllerGroup": "entertainment.cinema.com", "controllerKind": "Movie", "source": "kind source: *v1.Movie"}
2026-11-11T09:15:02.116Z INFO Starting Controller {"controller": "movie", "controllerGroup": "entertainment.cinema.com", "controllerKind": "Movie"}
2026-11-11T09:15:02.218Z INFO Starting workers {"controller": "movie", "controllerGroup": "entertainment.cinema.com", "controllerKind": "Movie", "worker count": 1}
2026-11-11T09:15:02.219Z INFO Reconciling Movie resource {"controller": "movie", "controllerGroup": "entertainment.cinema.com", "controllerKind": "Movie", "Movie": {"name":"the-outlaws","namespace":"default"}, "namespace": "default", "name": "the-outlaws", "reconcileID": "84e3d179-8ab3-4c91-921c-cb9716ebff12", "Name": "the-outlaws", "Title": "The Outlaws 4", "Genre": "Action", "RunningTime": 109, "IsReleased": true}
```

## 7. CRDとAnnotationの設計上の分離

Kubernetesにおいて独自データを保持する手段として、Annotationの利用とCRDの新設の二通りが検討対象となります。両者の境界線はシステムの責務設計に直結します。

* <b>CRD:</b> システムの厳格なスキーマ検証を伴い、APIエンドポイントとして型を確立したい場合に使用します。Reconcileループを通じて別リソース（Pod、Job、外部クラウドサービスなど）を能動的に作成・更新・削除するオペレーターパターンの構築にはCRDが必須です。
* <b>Annotation:</b> 単なる付随情報、外部監査用のメタデータ、または非構造化テキストの一時的な保持に限定して使用します。APIサーバーによる型バリデーションは行われません。

## Operational Notes

カスタムリソースとコントローラーの設計時は、Reconcile処理が冪等（Idempotent）であることを保証しなければなりません。Kubernetesのイベント通知機構はAt-Least-Once配信モデルであるため、同一のオブジェクトに対してReconcileが複数回連続して呼び出されても、重複作成や状態不整合が発生しないロジック構成を維持する必要があります。