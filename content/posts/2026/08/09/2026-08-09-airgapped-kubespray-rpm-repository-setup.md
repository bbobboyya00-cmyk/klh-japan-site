---
title: "エアギャップ環境におけるKubespray向けローカルRPMリポジトリの構築手順"
slug: "airgapped-kubespray-rpm-repository-setup"
date: 2026-08-09T10:04:13+09:00
draft: false
image: ""
description: "外部ネットワークから隔離されたエアギャップ環境でのKubesprayデプロイに向け、dnfを用いた依存RPMの一括全取得とローカルYumリポジトリの構築手順を解説します。"
categories: ["DevOps Logistics"]
tags: ["kubespray", "dnf", "rpm", "containerd", "rocky-linux"]
author: "K-Life Hack"
---

外部ネットワークから完全に隔離されたエアギャップ環境において、Kubesprayを用いたKubernetesクラスタの自動構築を行う場合、ブートストラップ処理やOSレベルの初期化に必要なパッケージ群を事前調達しておく必要があります。インターネット接続が可能な環境から単純に単一のRPMパッケージのみを取得して持ち込んでも、OSのマイナーバージョンや依存関係ツリーの欠損により、プロビジョニング中にパッケージインストールのエラーが発生する事例が多発します。

本稿では、Rocky Linux 9.7環境を前提とし、インターネット接続が可能なステージングホスト上で <code>dnf</code> の依存解決フラグを利用して必要なすべてのRPMパッケージを完全収集し、内部ネットワークのWebサーバー上にローカルYumリポジトリを構築・検証する手順を整理します。

## 1. ステージング環境の準備と依存解決メカニズム

インターネットに接続されたステージングホストは、ターゲットとなるエアギャップノードと同じOSディストリビューションおよびアーキテクチャで構成します。パッケージ依存ツリーを走査し、ダウンストリームの全依存関係を漏れなく収集するため、<code>dnf-plugins-core</code> プラグインを導入した上で <code>dnf download</code> コマンドを使用します。

```bash
sudo dnf install -y dnf-plugins-core

# ペイロード格納用ディレクトリの作成
mkdir -p /data/kubespray-rpms/os
mkdir -p /data/kubespray-rpms/docker-ce-stable
```

### dnf download コマンドの主要オプション仕様

依存関係のダウンロードには以下のフラグを指定します。

* `--resolve`: 指定したパッケージに必要な依存関係グラフを自動的に全件解析します。
* `--alldeps`: ステージングホスト上に既にインストールされているパッケージであっても、依存ツリーに含まれるすべてのRPMファイルを強制的にダウンロード対象とします。

```bash
dnf download --resolve --alldeps --destdir=<target_directory> <package_name>
```

## 2. RPMパッケージの取得手順

### 2.1 OS基本パッケージおよびKubernetesネットワーク依存関係のダウンロード

Ansibleの実行やKubesprayのノードセットアップに必要な基本ツール、ネットワーク制御ユーティリティ、Pythonバインディングを収集します。

```bash
sudo dnf download --resolve --alldeps \
  --destdir=/data/kubespray-rpms/os \
  python3 \
  python3-libselinux \
  conntrack-tools \
  socat \
  iproute \
  iproute-tc \
  iptables \
  ipset \
  ipvsadm \
  ethtool \
  chrony \
  rsync \
  tar \
  unzip \
  curl \
  openssl \
  ca-certificates \
  ebtables
```

※ Rocky Linux 9などのEnterprise Linux 9系リポジトリにおいて <code>ebtables</code> パッケージが提供されていない、あるいは非推奨化されている場合は、対象リストから <code>ebtables</code> を除外して実行します。

```bash
sudo dnf download --resolve --alldeps \
  --destdir=/data/kubespray-rpms/os \
  python3 python3-libselinux conntrack-tools socat iproute iproute-tc \
  iptables ipset ipvsadm ethtool chrony rsync tar unzip curl openssl ca-certificates
```

### 2.2 コンテナランタイム依存関係（containerd.io）の取得

標準のOSリポジトリにはプロダクションレベルの <code>containerd.io</code> パッケージが含まれていないため、公式のDocker CEリポジトリを登録して取得します。

```bash
# Docker CE Stableリポジトリの追加
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

# containerdおよびSELinuxポリシーのダウンロード
sudo dnf download --resolve --alldeps \
  --destdir=/data/kubespray-rpms/docker-ce-stable \
  containerd.io \
  container-selinux
```

Kubesprayで <code>container_manager: containerd</code> 構成を採用する場合、フルセットの <code>docker-ce</code> エンジンは不要であり、<code>containerd.io</code> および <code>container-selinux</code> のみで構成可能です。

## 3. アーカイブの作成とローカルリポジトリの展開

取得したパッケージ群の容量を確認し、圧縮アーカイブとしてまとめます。

```bash
cd /data
tar czf kubespray-rpms-rocky9.7.tgz kubespray-rpms
```

作成したアーカイブを内部のミラーサーバー（Nginx等）に転送し、ドキュメントルート下に展開します。

```bash
sudo mkdir -p /usr/share/nginx/html/ROCKY_9.7
sudo tar xzf kubespray-rpms-rocky9.7.tgz -C /usr/share/nginx/html/ROCKY_9.7
```

展開後、<code>createrepo_c</code> ユーティリティを実行してリポジトリのメタデータ（repodata）を生成します。

```bash
sudo createrepo_c /usr/share/nginx/html/ROCKY_9.7/kubespray-rpms/os
sudo createrepo_c /usr/share/nginx/html/ROCKY_9.7/kubespray-rpms/docker-ce-stable
```

## 4. クライアントノードの設定と検証

エアギャップ環境内のターゲットノードにおいて、外部リポジトリ設定を無効化し、作成したローカルリポジトリを参照するよう <code>/etc/yum.repos.d/kubespray-local.repo</code> を作成します。

```ini
[kubespray-os]
name=Kubespray OS RPMs
baseurl=http://harbor.devstack.co.kr/ROCKY_9.7/kubespray-rpms/os
enabled=1
gpgcheck=0

[kubespray-containerd]
name=Kubespray Containerd RPMs
baseurl=http://harbor.devstack.co.kr/ROCKY_9.7/kubespray-rpms/docker-ce-stable
enabled=1
gpgcheck=0
```

## Troubleshooting

### 発生ケース1: ミラーサーバー側に `createrepo_c` が存在しない

エアギャップ環境内のリポジトリサーバー自身に <code>createrepo_c</code> コマンドがインストールされていない場合、メタデータの生成が行えず <code>dnf makecache</code> が失敗します。

<b>対処手順:</b>
インターネット接続のあるステージングホスト側で、あらかじめ <code>createrepo_c</code> 自体も依存関係を含めて取得し、ペイロードに同梱して持ち込みます。

```bash
sudo dnf download --resolve --alldeps \
  --destdir=/data/kubespray-rpms/os \
  createrepo_c
```

### 発生ケース2: リポジトリインデックス同期エラーとパッケージ見つからない問題

ローカルリポジトリ設定後、<code>dnf list</code> 実行時に旧キャッシュが残っていると、パッケージが発見できないエラーが発生します。キャッシュのクリアとインデックス再構築を明示的に実行する必要があります。

<b>検証ログ例:</b>

```text
$ sudo dnf clean all
15 files removed

$ sudo dnf makecache
Kubespray OS RPMs                                3.2 MB/s | 2.1 MB     00:00    
Kubespray Containerd RPMs                        1.8 MB/s |  12 kB     00:00    
Metadata cache created successfully.

$ sudo dnf repolist
repo id               repo name
kubespray-containerd  Kubespray Containerd RPMs
kubespray-os          Kubespray OS RPMs

$ dnf list containerd.io conntrack-tools socat
Available Packages
conntrack-tools.x86_64            1.4.7-2.el9                kubespray-os        
containerd.io.x86_64              1.7.25-3.1.el9             kubespray-containerd
socat.x86_64                      1.7.4.1-5.el9              kubespray-os        
```

## Lessons Learned

1. <b>依存関係の強制全取得</b>: `--alldeps` オプションを付与しない場合、ステージングホストの導入済みパッケージがスキップされ、エアギャップ環境のノードで依存不足が発生するリスクがあります。
2. <b>コンテナランタイムの分離管理</b>: `containerd.io` はDocker CEリポジトリから個別に取得し、OS標準リポジトリと分離してインデックス化することで、バージョン競合を回避できます。
3. <b>repodataの事前生成</b>: リポジトリサーバー上で `createrepo_c` によるメタデータ作成を行ってからクライアントに公開することが、健全なYum/DNFパッケージ配布の必須要件となります。</package_name></target_directory>