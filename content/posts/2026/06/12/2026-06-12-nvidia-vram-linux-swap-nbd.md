---
title: "NVIDIA GPUのVRAMをLinuxスワップ領域として活用するNBD-VRAMのアーキテクチャと実装"
slug: "nvidia-vram-linux-swap-nbd"
date: 2026-06-12T10:07:01+09:00
draft: false
image: ""
description: "NVIDIA GPUのVRAMをLinuxの高速なスワップ階層として再利用する「NBD-VRAM」の内部アーキテクチャ、導入手順、および運用上の制約事項について解説します。"
categories: ["Linux System Admin"]
tags: ["nbd-vram", "cuda", "linux-swap", "nvidia-driver", "systemd"]
author: "K-Life Hack"
---

開発環境におけるコンテナの乱立や大規模なビルドプロセスの実行は、物理メモリ（System RAM）の枯渇を招き、システム全体のハングアップやOOM（Out Of Memory）キラーによるプロセスの強制終了を引き起こします。特にオンボードメモリを搭載したノートPCや、物理的なメモリ増設が困難なエッジノードにおいて、この問題は顕著です。従来のSSDやHDDを対象としたスワップ領域の拡張は、ストレージの書き込み寿命（TBW）を著しく縮めるだけでなく、I/Oボトルネックによるシステム全体のパフォーマンス低下を招きます。

このような背景から、システムに搭載されているものの、グラフィックス処理や機械学習タスクを実行していない時間帯に遊休状態となっているNVIDIA GPUのVRAM（Video RAM）を、Linuxの高速なスワップ階層として再利用するアプローチが注目されています。本稿では、Network Block Device（NBD）とCUDA APIを組み合わせたオープンソースプロジェクト「NBD-VRAM」のアーキテクチャ、実装プロセス、および運用上の注意点について技術的な分析を行います。

## NBD-VRAMのメモリ階層アーキテクチャ

💡 NBD-VRAMは、VRAMを単なる物理メモリの直接的な拡張として扱うのではなく、Linuxの仮想メモリ管理システムにおける「超高速な中間スワップ階層」として位置づけます。これにより、多段階のメモリ階層が形成されます。

1. <b>System RAM</b>: 最も低レイテンシかつ高帯域なプライマリメモリ領域。
2. <b>VRAM Swap (NBD-VRAM)</b>: SSDよりも高速なセカンダリスワップ領域（RTX 3070環境下で約1.3 GB/sの帯域を確保）。
3. <b>zRAM</b>: メモリ圧縮技術を用いたRAMベースのスワップ領域。
4. <b>SSD/HDD Swap</b>: 永続ストレージ上に構成された最終かつ最も低速なスワップ領域。

物理メモリから溢れたデータは、低速なSSDに直接書き込まれる前にVRAMスワップ層に退避されるため、システム全体のI/Oウェイトを最小限に抑え、高負荷時でも操作の応答性を維持することが可能になります。

## 動作原理とデータフロー

NBD-VRAMは、カーネルモジュールを独自にビルドすることなく、公式のNVIDIAドライバスタックとCUDA API、およびLinux標準のNBD（Network Block Device）プロトコルを組み合わせて動作します。

### 1. VRAMの確保と管理

ユーザ空間で動作するデーモンプロセスが、CUDA APIを呼び出して指定されたサイズのVRAM領域を確保します。NVIDIAのコンシューマ向けGPU（GeForceシリーズなど）では、プロフェッショナル向けGPU（QuadroやTesla）でサポートされているPeer-to-Peer（P2P）APIやBAR1メモリへの直接アクセスに制限があるため、NBD-VRAMは標準的なCUDAメモリコピー関数（cuMemcpyHtoD / cuMemcpyDtoH）を使用して、ホストRAMとGPUデバイスメモリ間のデータ転送を行います。

### 2. 仮想ブロックデバイスの生成

デーモンは、確保したVRAM領域をLinuxカーネルのNBDサブシステムと紐付けます。これにより、カーネルからは /dev/nbd0 などの標準的なブロックデバイスとして認識されます。データパスの構造は以下の通り定義されます。

```text
[Kernel Swap Subsystem] ──&gt; [/dev/nbd0] ──&gt; [NBD Daemon (User Space)] ──&gt; [CUDA API] ──&gt; [GPU VRAM]
```

### 3. スワップ領域の有効化

生成された仮想ブロックデバイスは、標準のLinuxユーティリティを用いてスワップとして初期化・有効化されます。

```bash
mkswap /dev/nbd0
swapon -p 100 /dev/nbd0
```

## システムの実装と構成設定

🛠️ NBD-VRAMをシステム起動時に自動的に有効化するため、Systemdサービスユニットとして構成します。7GB（7168MB）のVRAMをスワップ優先度100で割り当てる設定例を以下に示します。

### 1. デーモン設定ファイルの配置

/etc/systemd/system/nbd-vram.service にサービス定義を記述します。

```ini
[Unit]
Description=NBD-VRAM Swap Service
After=systemd-modules-load.service

[Service]
Type=simple
ExecStart=/usr/local/bin/nbd-vram --size 7168 --device /dev/nbd0 --priority 100
ExecStop=/usr/bin/nbd-client -d /dev/nbd0
Restart=always

[Install]
WantedBy=multi-user.target
```

### 2. 動的リサイズ機能

起動時に指定されたサイズ（例: 7168MB）のVRAM確保に失敗した場合、NBD-VRAMは自動的に割り当てサイズを <b>512MB</b> ずつ縮小しながら再試行するフォールバック機構を備えています。これにより、他のプロセスが既にVRAMを消費している場合でも、確保可能な最大容量でスワップを自動構成します。

## Troubleshooting

⚠️ 実環境への導入において発生しやすい代表的な障害要因と、その解決ワークフローを以下に示します。

### 1. NBDカーネルモジュールがロードされていない

サービス起動時に modprobe: FATAL: Module nbd not found などのエラーが発生する場合、カーネル構成でNBDが有効になっていないか、モジュールがロードされていません。

対策として、カーネルパッケージの再インストール、または手動でのモジュールロードを試行します。

```bash
sudo modprobe nbd
```

### 2. CUDA初期化エラー（Driver/Library Mismatch）

NVIDIAドライバのアップデート後にシステムを再起動していない場合、デーモンが libcuda.so の初期化に失敗します。

対策として、nvidia-smi が正常に応答することを確認し、不整合がある場合はドライバスタックを再ロードするか、ホストを再起動します。

### 3. 正常動作の検証手順

サービス起動後、システムの状態を確認するための検証コマンドを実行します。

```bash
swapon --show
free -h
```

## Operational Notes

NBD-VRAMは、メモリ制約の厳しい環境において極めて有効なワークアラウンドですが、運用の際には以下の技術的制約を許容する必要があります。

・<b>レイテンシオーバーヘッド</b>: データの転送経路に Swap -&gt; NBD -&gt; Unix Socket -&gt; Daemon -&gt; CUDA -&gt; VRAM という複数の抽象化レイヤが介在するため、物理RAMへの直接アクセスと比較してレイテンシが発生します。本機能は「物理RAMの完全な代替」ではなく、「SSDスワップへのフォールバックを防止するための高速バッファ」として位置づけるべきです。

・<b>リソース競合</b>: VRAMをスワップとして占有するため、同一GPU上で3Dレンダリングやディープラーニングの学習処理を実行する場合、VRAM容量の競合が発生し、パフォーマンス低下やメモリ不足エラーの原因となります。

・<b>CUDAメモリ拡張との違い</b>: 本ツールは「オペレーティングシステムのスワップ領域」を拡張するものであり、大規模なAIモデルの重みデータをGPUの演算用メモリとして直接拡張するものではありません。モデルのロードは依然としてGPUのネイティブな空きVRAM容量に依存します。

これらの特性を理解した上で、開発用コンテナの並行稼働や、一時的なメモリバーストが発生するビルドサーバーなどの環境において、SSDの寿命保護とシステム安定化の両立を図る手段として導入を検討してください。