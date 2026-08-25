---
title: "MagicMirror²における自動起動制御と画面回転・タッチ座標系のキャリブレーション"
slug: "magicmirror-pm2-systemd-xrandr-xinput-setup"
date: 2026-08-25T10:10:41+09:00
draft: false
image: ""
description: "MagicMirror²環境におけるPM2・Systemdを用いたプロセス自動起動制御、xrandrおよびxinputによる画面・タッチ座標系の非同期変換、モジュールカスタマイズの構成手順を解説します。"
categories: ["Linux System Admin"]
tags: ["magicmirror2", "pm2", "systemd", "xrandr", "xinput"]
author: "K-Life Hack"
---

組み込みディスプレイやスマートミラー基盤の運用において、OS起動時のプロセス自動復旧と画面表示の同期制御は重要です。ネットワークインターフェースが有効化される前にフロントエンドアプリケーションが起動すると、外部RSSフィードやAPIの非同期リクエストが失敗し、描画不良を起こすリスクが存在します。また、液晶パネルを縦置き（Portrait）や上下反転で設置する場合、表示出力（`xrandr`）のみを変更してもタッチパネル（`xinput`）の入力座標系が同期されず、操作軸が逆転する問題が生じます。

本稿では、PM2とSystemdを組み合わせた遅延起動シーケンスの設計、ディスプレイの回転設定およびタッチ座標変換行列（Coordinate Transformation Matrix）のキャリブレーション、モジュールコードの改修手順について整理します。

## 1. プロセス自動起動とシステムデーモン構成

アプリケーションのプロセス生存確認およびOS再起動時の自動復旧を担保するため、PM2およびSystemdを利用した管理構成を導入します。

### PM2のグローバルインストールと初期化

Node.js環境下でプロセス管理を行うPM2を導入します。

```bash
sudo npm install -g pm2
```

PM2をOSのスタートアップデーモンとして登録するため、以下のコマンドを実行して生成されたSystemd登録コマンドを端末で実行します。

```bash
pm2 startup
```

### 遅延起動スクリプト (mm.sh) の作成

ネットワーク接続が確立される前にアプリケーションが起動するのを防ぐため、バッファ時間を設けた実行スクリプトをユーザーホームディレクトリ配下に作成します。

```bash
cd ~
nano mm.sh
```

スクリプトの内部実装は以下の通りです。`sleep 10` を配置することでWi-Fi/EthernetのIPアドレス取得完了を待機し、`DISPLAY=:0` によってX11セッションの出力先を明示的にバインドします。

```bash
#!/bin/bash
sleep 10
cd ./MagicMirror
DISPLAY=:0 npm start
```

実行権限を付与します。

```bash
chmod +x mm.sh
```

### プロセス状態の保存とSystemd制御

PM2で起動したプロセス状態を永続化します。

```bash
pm2 save
```

Systemdサービスとして自動起動を有効化・無効化するコマンドは以下の通りです。

```bash
# スタートアップ有効化
sudo systemctl enable magicmirror.service

# スタートアップ無効化
sudo systemctl disable magicmirror.service
```

## 2. ディスプレイ電源制御と構文静的解析

連続稼働を行うサイネージ環境において、OSデフォルトのスクリーンセーバーや省電力ブラックアウトを防止する必要があります。

### スリープ機能の無効化

`xscreensaver` を導入し、GUI設定画面または構成ファイルよりスクリーンセーバーおよびディスプレイのブランク化機能を「Disable Screen Saver」へ変更します。

```bash
sudo apt install xscreensaver
```

### 設定ファイル (config.js) の構文チェック

`config/config.js` の記述ミス（ブラケットの閉じ忘れやカンマの過不足）はランタイムエラーを引き起こします。デプロイ前に静的解析ツール（JSHint等）へソースコードを通し、構文の無謬性を確認します。

## 3. xrandrおよびxinputによる表示・タッチ座標同期

物理ディスプレイの配置変更に伴い、X11の表示出力（`xrandr`）とタッチ入力デバイス（`xinput`）の座標変換行列を合致させる必要があります。

### 標準HDMI出力の回転 (xrandr)

`HDMI-1` デバイスに対する回転設定のコマンドパラメータです。

```bash
# 通常表示 (横置き)
xrandr --output HDMI-1 --rotate normal

# 左90度回転 (縦置き)
xrandr --output HDMI-1 --rotate left

# 右90度回転 (縦置き)
xrandr --output HDMI-1 --rotate right

# 180度反転
xrandr --output HDMI-1 --rotate inverted
```

### タッチパネル座標系キャリブレーション (xinput)

DSI接続のタッチディスプレイ（例: `FT5406 memory based driver`）を使用する場合、画面回転に合わせて `Coordinate Transformation Matrix`（3x3行列）を計算・設定する必要があります。

#### 1. 通常配置 (normal)

```bash
xrandr --output DSI-1 --rotate normal
xinput --set-prop "FT5406 memory based driver" "Coordinate Transformation Matrix" 0 0 0 0 0 0 0 0 0
```

#### 2. 反時計回り90度回転 (left)

```bash
xrandr --output DSI-1 --rotate left
xinput --set-prop "FT5406 memory based driver" "Coordinate Transformation Matrix" 0 -1 1 1 0 0 0 0 1
```

#### 3. 時計回り90度回転 (right)

```bash
xrandr --output DSI-1 --rotate right
xinput --set-prop "FT5406 memory based driver" "Coordinate Transformation Matrix" 0 1 0 -1 0 1 0 0 1
```

#### 4. 180度上下反転 (inverted)

```bash
xrandr --output DSI-1 --rotate inverted
xinput --set-prop "FT5406 memory based driver" "Coordinate Transformation Matrix" -1 0 1 0 -1 1 0 0 1
```

## 4. MMM-BackgroundSlideshow モジュールのソースコード改修

背景スライドショーを表示するモジュール `MMM-BackgroundSlideshow` において、画面上のヘッダーテキスト（"Picture Info"）および画像カウント情報（例: "1 of 10"）を無効化するためのリファクタリング例です。

対象ファイル: `MMM-BackgroundSlideshow.js`

### 修正前コード

```javascript
case 'imagecount':
    imageProps.push(`${this.imageIndex} of ${this.imageList.length}`);
    break;
default:
    Log.warn(prop + ' is not a valid value for imageInfo. Please check your configuration');
}
});

let innerHTML = '<header class="infoDivHeader">Picture Info</header>';
imageProps.forEach((val, idx) =&gt; {
    innerHTML += val + '<br/>';
});
```

### 修正後コード

配列への追加処理をコメントアウトし、`innerHTML` の初期値を空文字列に置き換えることでUI上の非表示化を実現します。

```javascript
case 'imagecount':
    // カウント情報の非表示化のため配列挿入を無効化
    // imageProps.push(`${this.imageIndex} of ${this.imageList.length}`);
    break;
default:
    Log.warn(prop + ' is not a valid value for imageInfo. Please check your configuration');
}
});

// ヘッダーテキストを完全に除去
let innerHTML = '';
imageProps.forEach((val, idx) =&gt; {
    innerHTML += val + '<br/>';
});
```

## 5. Troubleshooting

### ディスプレイ非バインドによる起動失敗 (DISPLAY 環境変数不備)

💡 <b>現象</b>: SystemdやCron経由の起動時に `Error: Cannot open display: null` が発生し、Electronウィンドウが立ち上がりません。

🛠️ <b>原因</b>: 非対話型シェル環境からプロセスを実行する際、X11ディスプレイ環境変数 `$DISPLAY` が定義されていません。

⚠️ <b>対策</b>: `mm.sh` などの実行スクリプト内部で `export DISPLAY=:0` を明示的に宣言してからコマンドを実行します。

### タッチパネルの操作軸ずれ (xinput 行列のミスマッチ)

💡 <b>現象</b>: 画面表示は縦向きに切り替わっていますが、画面の上部をタッチすると右側にカーソルが移動します。

🛠️ <b>原因</b>: `xrandr` によるグラフィック出力の回転のみが適用され、入力カーネルドライバー側の変換行列が更新されていません。

⚠️ <b>対策</b>: `xinput list` でデバイス識別名を確認し、該当回転角に対応する `Coordinate Transformation Matrix` パラメータを再適用します。

## 6. システム検証ログ (System Verification Logs)

デプロイ後のプロセスの稼働状態、X11ディスプレイの割り当て状態、および入力デバイスのプロパティ整合性を確認したターミナルログ例です。

```text
$ pm2 status
┌────┬─────────────────┬─────────────┬─────────┬─────────┬─────────┬────────┬─────┬───────────┬──────────┬──────────┐
│ id │ name            │ namespace   │ version │ mode    │ pid     │ uptime │ ↺   │ status    │ cpu      │ mem      │
├────┼─────────────────┼─────────────┼─────────┼─────────┼─────────┼────────┼─────┼───────────┼──────────┼──────────┤
│ 0  │ magicmirror     │ default     │ 2.25.0  │ fork    │ 2104    │ 12m    │ 0   │ online    │ 1.2%     │ 142.5MB  │
└────┴─────────────────┴─────────────┴─────────┴─────────┴─────────┴────────┴─────┴───────────┴──────────┴──────────┘

$ xrandr --query
Screen 0: minimum 320 x 200, current 1080 x 1920, maximum 7680 x 7680
DSI-1 connected primary 1080x1920+0+0 right (normal left inverted right x axis y axis) 154mm x 85mm
   1080x1920     60.00*+

$ xinput list-props "FT5406 memory based driver"
Device 'FT5406 memory based driver':
	Device Enabled (115):	1
	Coordinate Transformation Matrix (117):	0.000000, 1.000000, 0.000000, -1.000000, 0.000000, 1.000000, 0.000000, 0.000000, 1.000000
```

## 7. Lessons Learned

組み込みサイネージ環境の安定運用においては、ソフトウェアレイヤー（PM2/Node.js）だけでなく、OSの表示サブシステム（X11/xrandr）および入力デバイスドライバー（xinput）の相互依存関係を包括的に把握することが重要です。特にスタートアップ時にネットワークとディスプレイサーバーが完全に準備されるまでの時間的タイミング（Race Condition）を設計段階で考慮することにより、フィールドデプロイ後の不要な再起動トラブルを大幅に抑止できます。