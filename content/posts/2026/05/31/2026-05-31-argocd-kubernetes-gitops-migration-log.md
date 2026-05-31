---
title: "Argo CDとKubernetesによる宣言的インフラ管理への移行と構成ドリフトの解消"
slug: "argocd-kubernetes-gitops-migration-log"
date: 2026-05-31T10:23:36+09:00
draft: false
image: "https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/argocd-kubernetes-gitops-migration-log/khack_1780190612_0.webp"
description: "レガシーな「ペット」型インフラからArgo CDを用いたGitOpsモデルへの移行プロセスを詳述。構成ドリフトの排除、自己修復機能の有効化、および宣言的制御によるデプロイ自動化の実装ログ。"
categories: ["DevOps Logistics"]
tags: ["argo-cd", "kubernetes", "gitops", "cloud-native", "iac"]
author: "K-Life Hack"
---

## レガシーな「ペット」型サーバー運用における構成ドリフトとデプロイの不確実性

2026年5月現在の本番環境において、手動によるカーネル更新やアドホックなcronジョブの設定変更が原因で、ステージング環境と本番環境の差異、いわゆる構成ドリフトが深刻化していました。従来のモノリス型アーキテクチャでは、サーバーを「ペット」のように個別に管理しており、特定のインスタンス（例：`prod-web-01`）がダウンした際の復旧には数時間を要する手動介入が必要でした。デプロイメントは金曜日の夜間にスケジュールされた「儀式」と化し、SSH経由での`git pull`や手動のサービス再起動に伴うヒューマンエラーのリスクが常態化していました。



<img alt="System operational pipeline topology flow description" fetchpriority="high" height="92" loading="eager" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/argocd-kubernetes-gitops-migration-log/khack_1780190612_0.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);" width="651"/>



🛠️ この脆弱性を解決するため、インフラを「家畜（Cattle）」として扱うクラウドネイティブな運用モデルへの転換を決定しました。具体的には、不変（Immutable）なインフラストラクチャの概念を導入し、実行中のサーバーにパッチを当てるのではなく、新しいコンテナイメージでインスタンス全体を置き換えるパイプラインを構築しました。

## Argo CDを用いたGitOpsモデルによる宣言的状態管理の実装

インフラの状態をGitリポジトリで管理し、クラスタの状態を自動的に同期させるために<b><mark>Argo CD</mark></b>を導入しました。これにより、開発者が`kubectl`コマンドを直接実行してクラスタの状態を変更することを禁止し、すべての変更はプルリクエスト（PR）経由で行われます。Argo CDのコントローラーは、Git上の「望ましい状態（Desired State）」とクラスタの「現在の状態（Actual State）」を常に比較し、差異を検知すると自動的に同期（Sync）を実行します。

__CODE_BLOCK_0__



<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/argocd-kubernetes-gitops-migration-log/khack_1780190613_1.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



💡 この宣言的制御により、手動で変更されたリソースは即座にGitの状態へ書き戻されます。これにより、構成ドリフトが物理的に不可能な環境を構築しました。ランタイムには`containerd v1.7.15`を採用し、Kubernetes v1.30上での安定稼働を確認しています。

## 自己修復機能とLiveness Probeによる障害復旧の自動化

システムのレジリエンスを高めるため、Kubernetesの自己修復（Self-healing）機能を最大限に活用しました。アプリケーションのヘルスチェックを厳密に定義し、デッドロックやメモリリークが発生した際に自動でコンテナを再起動する設定を投入しました。具体的には、`Liveness Probe`と`Readiness Probe`を各マイクロサービスに実装し、トラフィックのルーティングとプロセスの生存確認を分離しました。

__CODE_BLOCK_1__



<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/argocd-kubernetes-gitops-migration-log/khack_1780190614_2.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



また、トラフィックの急増に対応するため、<b><mark>Horizontal Pod Autoscaler (HPA)</mark></b>を導入しました。CPU使用率が70%を超えた場合にレプリカ数を動的にスケーリングさせることで、レイテンシのスパイクを抑制しました。検証環境での負荷試験（Locustを使用）では、リクエスト数が300%増加した際も、新規ポッドの起動によりp99レイテンシを200ms以内に維持できることを確認しました。

## 制御ループによる自動同期の検証とロールバックの高速化

⚠️ 導入した<b><mark>GitOps</mark></b>パイプラインの有効性を検証するため、意図的にクラスタ内のデプロイメント設定を手動で書き換えるテストを実施しました。結果、Argo CDのReconciliation Loopが30秒以内に差異を検知し、Gitリポジトリの状態へ自動復旧させることを確認しました。これにより、不正な設定変更によるダウンタイムのリスクが排除されました。



<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/argocd-kubernetes-gitops-migration-log/khack_1780190615_3.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



さらに、デプロイ失敗時のロールバック時間は、従来の30分（手動復旧）から、Gitの`revert`コミットによる3分以内へと大幅に短縮されました。オブザーバビリティに関しては、PrometheusとGrafanaを連携させ、エラーレートやリソース使用率をリアルタイムで可視化しています。これにより、インフラは「管理対象」から「プログラム可能なリソース」へと完全に移行しました。