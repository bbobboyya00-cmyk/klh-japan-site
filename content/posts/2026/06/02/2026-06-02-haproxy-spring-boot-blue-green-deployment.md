---
title: "HAProxyとSpring Boot Actuatorを用いたBlue/Greenデプロイメントの構成とヘルスチェックの最適化"
slug: "haproxy-spring-boot-blue-green-deployment"
date: 2026-05-29T17:40:32+09:00
draft: false
image: ""
description: "HAProxyとSpring Boot Actuatorを組み合わせたBlue/Greenデプロイメントの実装手法を解説。ヘルスチェックの挙動、Dockerコンテナの入れ替え、NPMによるSSL終端を含む多層プロキシ構成について詳述します。"
categories: ["Linux System Admin"]
tags: ["haproxy"]
author: "K-Life Hack"
---

# HAProxyとSpring Boot Actuatorによる高可用性インフラとBlue/Greenデプロイメントの最適化

本稿では、HAProxyとSpring Boot Actuatorを基盤とした高可用性インフラストラクチャの構築、およびBlue/Greenデプロイメント戦略の実装詳細について分析します。特に、サービス停止時間をゼロにするためのトラフィック制御と、アプリケーションのライフサイクル管理におけるヘルスチェックの役割に焦点を当て、堅牢なシステム構成を検証します。

## 1. デプロイメント環境におけるセキュリティプロトコル

AWSやVercelなどのクラウドプラットフォームにおいて、セッション管理の安全性を確保するためには、クッキーベースの認証に対する厳格な属性設定が求められます。クロスサイトスクリプティング（XSS）およびクロスサイトリクエストフォージェリ（CSRF）のリスクを軽減するため、以下の属性の実装が不可欠です。

*   <b>SameSite</b>: クロスサイトリクエストにおけるクッキーの送信範囲を制限し、意図しないリクエストを遮断します。
*   <b>HttpOnly</b>: クライアントサイドのスクリプトによるクッキーへのアクセスを禁止し、トークン漏洩を防止します。
*   <b>Secure</b>: HTTPSプロトコルを介した暗号化通信時のみクッキーを送信するよう強制します。

これらの設定は、ロードバランサやアプリケーションプロキシのレイヤーで適切に処理される必要があります。

## 2. Spring Boot Actuatorによる監視とヘルス管理

Spring Boot Actuatorは、アプリケーションの稼働状態を外部に公開するためのエンドポイントを提供します。インフラストラクチャのオーケストレーションにおいて、特に重要なエンドポイントは以下の通りです。

*   `/actuator/health`: アプリケーションの稼働状態（UP/DOWN）を返却します。HAProxyなどのロードバランサがバックエンドの生存確認を行う際の主要なターゲットとなります。
*   `/actuator/metrics`: JVMのメモリ使用率、CPU負荷、HTTPリクエスト統計などのテレメトリデータを提供し、リソースの最適化を支援します。
*   `/actuator/env`: アプリケーションに適用されている環境変数の構成情報を表示し、デプロイ時の設定不整合を特定します。

## 3. HAProxyによるマルチドメインマッピングと負荷分散

HAProxyをリバースプロキシおよびロードバランサとして構成し、複数のSpring Bootアプリケーションを単一のドメインに統合します。ACL（Access Control List）を用いたルーティングと、Actuatorを利用したヘルスチェックの設定により、トラフィックの精密な制御が可能となります。

```haproxy
defaults
    mode http
    timeout connect 5s
    timeout client 60s
    timeout server 60s
    
frontend http_front
    bind *:80
    # ホストヘッダーに基づいたACLの定義
    acl host_app1 hdr_beg(host) -i app1-127-0-0-1.nip.io

    # 条件に合致する場合にバックエンドへ振り分け
    use_backend http_back_1 if host_app1

backend http_back_1
    balance roundrobin
    # ヘルスチェック構成: ルートパスではなくActuatorエンドポイントを使用
    option httpchk GET /actuator/health
    
    # チェックパラメータ: 2秒間隔、1回の成功でUP、1回の失敗でDOWNと判定
    default-server inter 2s rise 1 fall 1
    
    # サーバー障害時に他のサーバーへリクエストを再試行する設定
    option redispatch

    # バックエンドサーバーの定義
    server app_server_1_1 app1_1:8080 check
    server app_server_1_2 app1_2:8080 check
```

## 4. Blue/Greenデプロイメントの実行ワークフロー

Blue/Greenデプロイメントは、新旧の環境を並行して稼働させ、トラフィックを切り替えることでダウンタイムを排除する手法です。本構成では、Dockerコンテナの入れ替えとシェルスクリプトによるReadiness Probe（準備完了プローブ）を組み合わせます。

### ステップ1: 旧コンテナ（Green）の停止

まず、`app1_2`コンテナを停止・削除します。HAProxyはヘルスチェックの失敗を検知し、トラフィックを自動的に稼働中の`app1_1`（Blue）に集約します。

### ステップ2: 新コンテナの起動と起動確認

新しいイメージを用いてコンテナを起動し、アプリケーションが完全に初期化されるまで待機します。Actuatorの`/health`エンドポイントが`UP`を返すまで、旧コンテナの削除を保留する制御が重要です。

```bash
# 新しいコンテナの起動
docker run -d --network common -p 8081:8080 --name app1_2 chasaem/app260601:1.0

# Readiness Probe スクリプト
START_TIME=$(date +%s);
while true; do
    CONTENT=$(curl -s http://localhost:8081/actuator/health);
    
    if [[ "$CONTENT" == *'"status":"UP"'* ]]; then
        echo "Server is UP!";
        break;
    fi
    
    CURRENT_TIME=$(date +%s);
    ELAPSED_TIME=$((CURRENT_TIME - START_TIME));
    
    if [[ $ELAPSED_TIME -ge 60 ]]; then
        echo "Error: Server did not start within 60 seconds." >&amp;2;
        exit 1;
    fi
    
    sleep 5;
done

# 起動確認後に旧コンテナを削除
docker rm -f app1_1 2> /dev/null
```

## 5. 多層プロキシアーキテクチャ: NPMとHAProxyの連携

SSL/TLS終端と証明書管理を効率化するため、Nginx Proxy Manager (NPM) を最前段に配置する構成を採用します。クライアントからのHTTPSリクエストはNPMで復号され、内部ネットワークを通じてHAProxy（ポート80）へ転送されます。この多層構造により、アプリケーション層の負荷分散とセキュリティ管理を分離することが可能となります。

## 6. HAProxyヘルスチェックのメカニズム詳細

HAProxyのヘルスチェックパラメータを微調整することで、障害検知の感度とシステムの安定性のバランスを最適化できます。💡

*   <b>inter 2s</b>: 2秒ごとにヘルスチェックを実行し、状態変化を迅速に捉えます。
*   <b>rise 1</b>: サーバーがDOWN状態からUP状態に復帰するために必要な連続成功回数です。1に設定することで、起動直後のトラフィック投入を迅速化します。
*   <b>fall 1</b>: サーバーをDOWNと判断するために必要な連続失敗回数です。1に設定することで、異常発生時に即座にトラフィックを遮断します。⚠️
*   <b>option redispatch</b>: 選択されたサーバーがリクエスト処理中にダウンした場合、別の健全なサーバーにリクエストを再送出します。これにより、クライアント側でのエラー発生率を低減させます。

## 7. Infrastructure as Code (IaC) によるプロビジョニング

AWS EC2インスタンスの構築にはTerraformを使用します。`terraform apply`を通じてインフラをコード化し、DNSZIなどの外部DNSサービスでAレコードを管理することで、IPアドレスの変更に伴う運用の複雑さを解消します。構築されたEC2環境上で、前述のHAProxyおよびDockerベースのBlue/Greenデプロイメントロジックを実行し、クラウド環境での動作を検証します。🛠️

## Summary

本構成により、Spring Boot Actuatorによる精密な状態監視と、HAProxyによる柔軟なトラフィック制御を組み合わせた、堅牢なBlue/Greenデプロイメント環境が実現されます。特に、Readiness Probeを自動化スクリプトに組み込むことで、アプリケーションの初期化完了前にトラフィックが流入するリスクを排除し、真のゼロダウンタイムデプロイメントを達成できることが確認されました。