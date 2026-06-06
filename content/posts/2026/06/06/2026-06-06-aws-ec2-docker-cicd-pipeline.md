---
title: "AWSインフラのプロビジョニングとDockerベースCI/CDパイプラインの実装"
slug: "aws-ec2-docker-cicd-pipeline"
date: 2026-06-06T10:13:37+09:00
draft: false
image: ""
description: "AWS EC2(ARM64)とRDSを用いた決済基盤の構築、およびGitHub ActionsによるDockerデプロイメントの自動化プロセスを詳解。Spring Cloud AWSの依存関係競合解決やHTTPS構成の変遷を含む実務的な実装記録。"
categories: ["Linux System Admin"]
tags: ["aws-ec2", "docker-container", "github-actions", "amazon-corretto", "spring-boot"]
author: "K-Life Hack"
---

本稿では、コマース決済アプリケーションのデプロイメントにおける、手動のAWSインフラ構築からDockerおよびGitHub Actionsを用いた完全自動化CI/CDパイプラインへの移行プロセスについて記述します。ネットワーク環境の構成、HTTPS実装の変遷、Spring Bootエコシステム内での依存関係の競合解決、およびコンテナ化によるクラウドデプロイメントの実装詳細を網羅します。

## 1. AWSインフラストラクチャの構成

### 1.1 ネットワークアーキテクチャ
カスタムVPC（Virtual Private Cloud）内に基礎となるインフラを構築しました。リソースの分離を目的として、パブリックおよびプライベートサブネットを実装し、インターネットゲートウェイ（IGW）とルートテーブルを構成してトラフィックフローを制御しています。

### 1.2 コンピュートレイヤー (EC2)

アプリケーションは、コスト効率とパフォーマンスを考慮し、ARMアーキテクチャを採用したAmazon EC2 <b>t4g.small</b> インスタンス上で稼働しています。ランタイムには Amazon Corretto 17 (OpenJDK 17.0.19) を採用しました。

```bash
sudo dnf install java-17-amazon-corretto -y
java -version
# Output: openjdk version "17.0.19" 2026-04-21 LTS
```

### 1.3 データベースレイヤー (RDS)

永続データ管理のために、マネージドMySQLインスタンスをプロビジョニングしました。

*   <b>Engine:</b> MySQL 8.0.43
*   <b>Instance Class:</b> db.t4g.micro
*   <b>Provisioning Script:</b>

```bash
aws rds create-db-instance \
  --db-instance-identifier commerce-db \
  --db-instance-class db.t4g.micro \
  --engine mysql \
  --engine-version 8.0.43 \
  --master-username admin \
  --master-user-password [PASSWORD_REDACTED] \
  --allocated-storage 20 \
  --db-subnet-group-name commerce-subnet-group \
  --publicly-accessible \
  --region ap-northeast-2
```

## 2. HTTPS構成とドメイン管理

### 2.1 初期実装: Caddy &amp; nip.io
プロトタイプ段階では、自動TLS機能を備えたCaddyとnip.ioワイルドカードDNSサービスを組み合わせてHTTPSを実装しました。ARM64環境への対応のため、バイナリを直接取得する手法をとっています。

```bash
curl -L "https://github.com/caddyserver/caddy/releases/download/v2.8.4/caddy_2.8.4_linux_arm64.tar.gz" -o caddy.tar.gz
tar -xzf caddy.tar.gz
sudo mv caddy /usr/local/bin/
```

### 2.2 本番環境実装: ACM &amp; ALB

本番環境への移行に伴い、AWS Certificate Manager (ACM) と Application Load Balancer (ALB) を用いた構成にアップグレードしました。Route 53でドメイン管理を行い、ALBでHTTPSトラフィックを終端してEC2ターゲットグループへ転送する構造です。

## 3. Spring Cloud AWSの互換性問題と解決

### 3.1 技術的競合の分析
AWS Parameter Storeによる環境変数管理を目的として spring-cloud-aws 依存関係を導入した際、Spring Boot 4.xとの間で深刻な互換性問題が発生しました。

*   <b>Error Log:</b>
```text
java.lang.NoSuchMethodError: 'org.springframework.boot.ConfigurableBootstrapContext 
org.springframework.boot.context.config.ConfigDataLocationResolverContext.getBootstrapContext()'
```

### 3.2 回避策の実装

依存関係のバージョンを 3.1.1 から 3.3.0 へ更新しても NoSuchMethodError が解消されなかったため、当該依存関係を削除し、JAR実行時に環境変数を直接注入する戦略に切り替えました。

```bash
nohup java -jar commerce-payment-application-0.0.1-SNAPSHOT.jar \
  --spring.profiles.active=prod \
  --PROD_DB_URL=jdbc:mysql://[RDS_ENDPOINT]:3306/commerce_db \
  --PROD_DB_USERNAME=admin \
  --PROD_DB_PASSWORD=[PASSWORD_REDACTED] \
  --PROD_JWT_SECRET=[SECRET_KEY_REDACTED] &gt; ~/app.log 2&gt;&amp;1 &amp;
```

## 4. Docker CI/CD パイプラインの構築

### 4.1 コンテナ化 (Dockerfile)
Amazon Corretto 17をベースイメージとし、AWS環境に最適化したコンテナイメージを作成しました。

```dockerfile
FROM amazoncorretto:17
WORKDIR /app
COPY commerce-payment-application-0.0.1-SNAPSHOT.jar app.jar
ENTRYPOINT ["java", "-jar", "app.jar"]
```

### 4.2 GitHub Actionsによる自動ワークフロー

dev ブランチへのプッシュをトリガーに、ビルド、Docker Hubへのプッシュ、EC2へのデプロイを自動化するパイプラインを構築しました。

```yaml
name: Deploy to EC2
on:
  push:
    branches: [ dev ]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v3
      - name: Set up JDK 17
        uses: actions/setup-java@v3
        with:
          java-version: '17'
          distribution: 'corretto'
      - name: Build with Gradle
        run: ./gradlew build -x test
      - name: Docker Build &amp; Push
        run: |
          docker build -t ${{ secrets.DOCKER_USERNAME }}/commerce-payment:latest .
          docker push ${{ secrets.DOCKER_USERNAME }}/commerce-payment:latest
      - name: Deploy on EC2
        uses: appleboy/ssh-action@master
        with:
          host: ${{ secrets.EC2_HOST }}
          username: ec2-user
          key: ${{ secrets.EC2_KEY }}
          script: |
            docker pull ${{ secrets.DOCKER_USERNAME }}/commerce-payment:latest
            docker stop commerce-app || true
            docker rm commerce-app || true
            docker run -d --name commerce-app --restart=always -p 8080:8080 \
              -e SPRING_PROFILES_ACTIVE=prod \
              -e PROD_DB_URL=${{ secrets.PROD_DB_URL }} \
              -e PROD_DB_USERNAME=${{ secrets.PROD_DB_USERNAME }} \
              -e PROD_DB_PASSWORD=${{ secrets.PROD_DB_PASSWORD }} \
              -e PROD_JWT_SECRET=${{ secrets.PROD_JWT_SECRET }} \
              ${{ secrets.DOCKER_USERNAME }}/commerce-payment:latest
```

## 5. トラブルシューティング・ログ

| 事象 | 原因 | 解決策 |
| :--- | :--- | :--- |
| Spring Cloud AWS 競合 | Spring Boot 4.xとの互換性欠如 | 依存関係を削除し、環境変数の直接注入を採用 |
| RDS 接続失敗 | エンドポイントのタイポ | DNSエンドポイント文字列の修正 |
| Hibernate テーブルエラー | ddl-auto: validate の失敗 | 初回起動時に ddl-auto: create を適用 |
| Caddy インストール失敗 | ARMアーキテクチャの不一致 | arm64用バイナリを明示的にダウンロード |
| Docker 権限エラー | デーモンへのアクセス権限不足 | sudo実行またはユーザーグループの調整 |

## Lessons Learned

本プロジェクトを通じて、環境設定の分離とセキュリティの重要性が再確認されました。application-local.yaml を .gitignore で除外し、機密情報を GitHub Secrets で管理することで、ソースコードへの露出を防止しています。また、インフラ構築においては RDS を EC2 より先にプロビジョニングし、同一 VPC 内でのセキュリティグループ制御を厳格に行うことが、安定したクラウドアーキテクチャ構築の要諦です。