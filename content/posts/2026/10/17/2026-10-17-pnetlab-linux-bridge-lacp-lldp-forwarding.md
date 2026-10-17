---
title: "LinuxブリッジにおけるLACP・LLDPフレーム透過処理の自動化構成"
slug: "pnetlab-linux-bridge-lacp-lldp-forwarding"
date: 2026-10-17T10:09:38+09:00
draft: false
image: ""
description: "PNETLab等の仮想ネットワーク環境でLinuxブリッジがLACPやLLDPフレームを破棄する問題を、sysfsのgroup_fwd_mask制御とsystemdデーモンにより自動解決する手法を解説します。"
categories: ["Linux System Admin"]
tags: ["systemd.service"]
author: "K-Life Hack"
---

PNETLabをはじめとする仮想化ネットワークエミュレーション環境では、仮想ノード間のLayer-2接続を構成するためにLinuxブリッジ（kernel bridge module）が動的に生成・再構築されます。標準のLinuxカーネルブリッジ実装では、IEEE 802.1D規格に準拠する形で、特定のリンクローカル制御フレーム（LACP: IEEE 802.3ad、LLDP: IEEE 802.1ABなど）を受信した場合に転送を行わず、内部で処理または破棄する挙動をとります。

この挙動により、仮想ルーターやスイッチ間でLink Aggregation（LAG）を構成したり、LLDPによる隣接機器検出を行う際に、対向機器間で制御パケットが到達せずリンクが確立しない問題が発生します。

### sysfs インターフェースとビットマスク仕様

Linuxカーネルは、ブリッジポート単位で予約済みマルチキャストMACアドレスの転送許可を制御するため、sysfs配下に <code>group_fwd_mask</code> インターフェースを提供しています。

* <b>設定ファイルパス</b>: `/sys/class/net/<bridge_interface>/brif/<port_interface>/group_fwd_mask`

各制御プロトコルのビットオフセットおよび制御マスク値は以下の通りです。

* <b>LACP (IEEE 802.3ad)</b>: ビットオフセット 2 $\rightarrow$ `0x0004`
* <b>LLDP (IEEE 802.1AB)</b>: ビットオフセット 14 $\rightarrow$ `0x4000`
* <b>合成転送マスク（論理OR）</b>: `0x0004 | 0x4000 = 0x4004` (10進数: `16388`)

PNETLab上ではラボの起動・停止に伴い <code>vnet*</code> 仮想インターフェースが動的に生成・削除されるため、静的なワンショット設定ではなく、常駐型スクリプトによる状態監視と自動適用が必要となります。

## 自動化スクリプトの作成

シェルスクリプトを用いて <code>/sys/class/net/vnet*/brif/*/group_fwd_mask</code> を定期的にスキャンし、現在のマスク値が <code>0x4004</code> (16388) を含んでいない場合にのみ書き込みを行います。不必要な I/O 書き込みを削減するため、現在の設定値との差分比較を実施します。

```bash
cat &gt; /usr/local/sbin/pnetlab-lacp-forward.sh &lt;&lt;'EOF'
#!/bin/bash

MASK=0x4004

while true; do
  for f in /sys/class/net/vnet*/brif/*/group_fwd_mask; do
    [ -f "$f" ] || continue

    old=$(cat "$f" 2&gt;/dev/null) || continue

    # Validate hexadecimal or standard integer decimal strings
    [[ "$old" =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]] || continue

    # Convert to base-10 integer and compute bitwise OR with target mask
    old_dec=$((old))
    new_dec=$((old_dec | MASK))

    # Apply configuration update only if current state diverges from target
    if (( old_dec != new_dec )); then
      echo "$new_dec" &gt; "$f" 2&gt;/dev/null
    fi
  done

  sleep 2
done
EOF
```

スクリプトの作成後、実行権限を付与します。

```bash
chmod +x /usr/local/sbin/pnetlab-lacp-forward.sh
```

## systemd サービスユニット登録

プロセス監視およびシステム起動時の自動開始を担保するため、<code>systemd</code> ユニットとして定義します。

```bash
cat &gt; /etc/systemd/system/pnetlab-lacp-forward.service &lt;&lt;'EOF'
[Unit]
Description=PNETLab LACP and LLDP Auto Forwarding
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/pnetlab-lacp-forward.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
```

サービスユニットの反映と起動処理を実行します。

```bash
systemctl daemon-reload
systemctl enable pnetlab-lacp-forward.service
systemctl restart pnetlab-lacp-forward.service
```

## Troubleshooting

⚠️ 運用時および構成構築時に発生する主なエラー要因と対策は以下の通りです。

1. <b>sysfs への書き込み権限エラー (`Permission denied`)</b>
* <b>原因</b>: サービスが root 権限以外で実行されているか、SELinux / AppArmor などのセキュリティモジュールが `/sys` 配下への無制限アクセスを制限している場合に発生します。
* <b>対策</b>: `systemd` の実行ユーザーが `root` であることを確認し、セキュリティプロファイルで sysfs 書き込み権限を許可するか、該当プロセスを非適用対象に設定します。

2. <b>ノード削除時のファイル非存在エラー (`No such file or directory`)</b>
* <b>原因</b>: ポーリングループの途中で PNETLab 上の仮想インターフェースが破棄された場合、`cat` や `echo` のパス参照でエラーログが発生します。
* <b>対策</b>: スクリプト内の `[ -f "$f" ] || continue` による存在確認と、標準エラー出力の `/dev/null` へのリダイレクトで例外ログの発生を防止します。

3. <b>CPUリソース消費の増大</b>
* <b>原因</b>: ポーリングループに `sleep` 待機が挿入されていない場合、CPU使用率が100%に張り付くビジーループが発生します。
* <b>対策</b>: スクリプト末尾に `sleep 2` 程度の適切なインターバルを設定し、カーネルの I/O 負荷を抑えます。

## Verification

🛠️ サービスの稼働状態および正常動作を確認するためのコマンドと出力結果のプロトコルログ例です。

```text
# systemctl status pnetlab-lacp-forward.service --no-pager
● pnetlab-lacp-forward.service - PNETLab LACP and LLDP Auto Forwarding
     Loaded: loaded (/etc/systemd/system/pnetlab-lacp-forward.service; enabled; vendor preset: enabled)
     Active: active (running) since Sat 2026-10-17 10:15:32 KST; 5min ago
   Main PID: 12043 (pnetlab-lacp-f)
      Tasks: 2 (limit: 9452)
     Memory: 1.2M
     CGroup: /system.slice/pnetlab-lacp-forward.service
             ├─12043 /bin/bash /usr/local/sbin/pnetlab-lacp-forward.sh
             └─12089 sleep 2

# cat /sys/class/net/vnet0/brif/vnet0_1/group_fwd_mask
16388
```

<code>group_fwd_mask</code> の値が <code>16388</code>（16進数: <code>0x4004</code>）に自動適用されている場合、LACPおよびLLDP制御フレームの透過処理が正常に有効化されています。

## Operational Notes

💡 <b>運用上の留意事項</b>:
* 新たな制御プロトコル（例: EAPOL `0x0001` 等）を透過対象に追加する場合は、ビットマスク演算 `0x4004 | NEW_MASK` を行い、スクリプト内の `MASK` 変数を更新する必要があります。
* 大規模なトポロジを運用する場合、ポーリング間隔（`sleep` 秒数）を調整することで、I/O 負荷とインターフェース認識の応答速度のトレードオフをチューニングすることが推奨されます。</port_interface></bridge_interface>