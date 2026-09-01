---
title: "RHEL 8におけるHAProxyのオフライン依存関係解決とローカルリポジトリ構築手順"
slug: "rhel8-haproxy-offline-dnf-repository-deployment"
date: 2026-09-01T10:17:28+09:00
draft: false
image: ""
description: "RHEL 8の閉域網環境において、dnfコマンドを用いたHAProxyとその全依存RPMパッケージの取得、createrepoによるローカルリポジトリ作成、およびオフライン配備の手順とトラブルシューティングを解説します。"
categories: ["Linux System Admin"]
tags: ["haproxy", "dnf", "rhel8", "createrepo", "rpm", "offline-repository"]
author: "K-Life Hack"
---

セキュリティ上の制約から外部ネットワークへの直接接続が制限されるエンタープライズの閉域網（エアギャップ環境）やDMZ領域において、ロードバランサであるHAProxyを新たにデプロイする際、依存ライブラリの不足によるインストールエラーは頻繁に発生する課題です。RHEL 8ではパッケージ管理システムとしてDNF（Dandified YUM）が標準採用されており、オンライン環境で事前にすべての依存関係（Dependency Graph）を解決した上でパッケージを取得し、ターゲット検証機にローカルリポジトリとして構成する運用設計が強く求められます。

## オンライン環境におけるパッケージおよび全依存関係の抽出

閉域網へ持ち込むパッケージ群を用意するため、まずはインターネット接続が可能な作業用ノードにてHAProxyおよびそのランタイムに必要な共有ライブラリ（`openssl-libs`、`pcre2`、`systemd`等）を抽出します。

単にメインのRPMのみを取得するのではなく、ターゲット環境に未導入のライブラリを漏れなく収集するために`--resolve`および`--alldeps`オプションを組み合わせて実行します。

```bash
sudo dnf download --resolve --alldeps --destdir=/tmp/haproxy_rpms haproxy
```

### パラメータ設定仕様

- `--resolve`: 依存関係ツリーを解析し、動作に必要なすべてのRPMファイルをダウンロード対象として特定します。
- `--alldeps`: ダウンロードを実行するホスト上に既に存在するライブラリであっても省略せず、すべての依存パッケージを取得対象として強制します。
- `--destdir=/tmp/haproxy_rpms`: ダウンロードしたRPM群を指定したディレクトリへ一括出力します。

特定バージョン（例: `haproxy-2.2.0-1.el8`）を明示して取得する場合は、リポジトリ内のバージョン一覧を確認した上でバージョン文字列を指定します。

```bash
# 利用可能な重複・過去バージョンの確認
sudo dnf --showduplicates list haproxy

# 特定バージョンの明示的取得
sudo dnf download --destdir=/tmp/haproxy_rpms haproxy-2.2.0-1.el8
```

## オフライン環境でのローカルリポジトリ作成と配置

取得したRPM群をUSBメモリや内部ストレージ経由でエアギャップ環境のターゲットサーバへ転送した後、ローカルファイルシステムベースのDNFリポジトリを初期化します。

### 1. リポジトリメタデータの生成

転送先のディレクトリに移動し、`createrepo` ユーティリティを使用してXML形式のメタデータ（`repodata`）を作成します。

```bash
cd /tmp/haproxy_rpms
sudo createrepo .
```

### 2. リポジトリ定義ファイルの構成

`/etc/yum.repos.d/` 配下にローカルリポジトリを指し示す `.repo` 設定ファイルを作成します。

```bash
cat &lt;&lt; EOF | sudo tee /etc/yum.repos.d/haproxy-local.repo
[haproxy-local]
name=HAProxy Local Repository
baseurl=file:///tmp/haproxy_rpms
enabled=1
gpgcheck=0
EOF
```

### 3. ローカルリポジトリからのインストール実行

構成が完了したら、ローカルメタデータを参照してインストールを実行します。

```bash
sudo dnf clean all
sudo dnf install -y haproxy
```

## Troubleshooting

オフライン環境でのローカルリポジトリ運用やパッケージ導入時、権限・SELinux・依存関係の不整合に起因する代表的なトラブルシューティング手順を以下に示します。

### 1. `/tmp` ディレクトリのパーミッションおよびSELinuxコンテキスト拒否

`/tmp` 配下にリポジトリを配置した場合、SELinuxのアクセス制御やシステムの一時ファイル削除ジョブ（`systemd-tmpfiles`）によってメタデータ読み込みエラーが発生することがあります。

<b>症状例:</b>

```text
Error: Failed to download metadata for repo 'haproxy-local': Cannot download repomd.xml: Cannot open file
```

<b>対処法:</b>

リポジトリ配置先を `/opt/local_repos/haproxy` などの永続ディレクトリへ変更し、適切なSELinuxコンテキストを再適用します。

```bash
sudo mkdir -p /opt/local_repos/haproxy
sudo mv /tmp/haproxy_rpms/* /opt/local_repos/haproxy/
sudo restorecon -Rv /opt/local_repos/haproxy
```

/etc/yum.repos.d/haproxy-local.repo` の `baseurl` を `file:///opt/local_repos/haproxy` へ更新後にキャッシュを再構築します。

### 2. GPG署名チェックエラー

`gpgcheck=1` が設定されている場合、公開鍵がインポートされていないとインストールが中断されます。

<b>対処法:</b>

ローカルでの検証用途では `gpgcheck=0` に設定するか、Red Hatの公式GPGキーをあらかじめインポートしておきます。

```bash
sudo rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release
```

### 3. システム検証ログプロトコル

デプロイ完了後、サービス状態およびシステムソケットの正常性を確認するターミナル検証コマンドと実行ログの例です。

```text
$ sudo systemctl enable --now haproxy
Created symlink /etc/systemd/system/multi-user.target.wants/haproxy.service -&gt; /usr/lib/systemd/system/haproxy.service.

$ sudo systemctl status haproxy
● haproxy.service - HAProxy Load Balancer
   Loaded: loaded (/usr/lib/systemd/system/haproxy.service; enabled; vendor preset: disabled)
   Active: active (running) since Tue 2026-09-01 10:15:30 KST; 12s ago
 Main PID: 14820 (haproxy)
    Tasks: 2 (limit: 23800)
   Memory: 7.4M
   CGroup: /system.slice/haproxy.service
           ├─14820 /usr/sbin/haproxy -Ws -f /etc/haproxy/haproxy.cfg -p /run/haproxy.pid
           └─14822 /usr/sbin/haproxy -Ws -f /etc/haproxy/haproxy.cfg -p /run/haproxy.pid

$ haproxy -v
HA-Proxy version 2.2.9-3.el8 2021/08/10
Configuration file is /etc/haproxy/haproxy.cfg
```

## Configuration Notes

- <b>パッケージ依存関係の完全性確保</b>: ステージング環境で `dnf download --resolve --alldeps` を実行する際は、可能な限りターゲット環境と同等のOSビルドバージョン・最小構成（Minimal Install）のノードを利用することで、依存ライブラリの取りこぼしを防止できます。
- <b>リポジトリインデックスの定期的更新</b>: パッケージを追加または差し替えた場合は、必ず `createrepo --update /opt/local_repos/haproxy` を実行してメタデータインデックスを再計算してください。
- <b>セキュリティポリシーとの整合</b>: 本番運用においては、`gpgcheck=1` を維持し、ダウンロードしたRPMに対するチェックサム比較および署名検証プロセスの自動化を推奨します。