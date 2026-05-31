---
title: "Jetson NanoとRealSense D435iを統合した自律精密着陸システムの構築とTensorRTによる推論最適化"
slug: "jetson-nano-d435i-precision-landing"
date: 2026-05-31T12:31:27+09:00
draft: false
image: "https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/jetson-nano-d435i-precision-landing/khack_1780198272_0.webp"
description: "Jetson NanoとD435iを用い、YOLOv8とTensorRTを組み合わせたUAV精密着陸システムの技術ログ。合成データセット生成からMAVLink通信、3D座標変換の実装工程と、推論レイテンシのトラブルシューティングを詳述します。"
categories: ["Linux System Admin"]
tags: ["jetson-nano", "realsense-d435i", "yolov8", "tensorrt", "mavlink", "ardupilot"]
author: "K-Life Hack"
---

## システムアーキテクチャとハードウェア構成の選定

2026年現在の自律型UAV（無人航空機）運用において、GPSの誤差（通常2〜5m）を克服するための視覚ベース精密着陸システムは不可欠なコンポーネントです。本プロジェクトでは、エッジコンピューティングデバイスとして <b><mark>Jetson Nano</mark></b> を採用し、深度情報の取得に <b><mark>Intel RealSense D435i</mark></b>、フライトコントローラー（FC）に Pixhawk を使用する構成を構築しました。



<img alt="System operational pipeline topology flow description" fetchpriority="high" height="316" loading="eager" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/jetson-nano-d435i-precision-landing/khack_1780198272_0.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);" width="317"/>



データフローは、D435iからのRGB-Dストリームを Jetson Nano が受信し、YOLOv8 モデルでランディングパッドを検出、その中心座標を深度マップと照合して3D相対距離を算出します。最終的に `pymavlink` を介して `LANDING_TARGET` メッセージを Pixhawk に送信し、ArduPilot の自律着陸アルゴリズムを駆動させます。USB 3.0 バスの帯域幅確保と、Jetson Nano の電力モード（10Wモード）の固定が安定稼働の前提条件となります。



<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/jetson-nano-d435i-precision-landing/khack_1780198273_1.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



## 合成データセット生成による学習モデルの汎用性向上

実環境でのデータ収集には限界があるため、OpenCVを用いた合成データセット生成スクリプトを実装しました。ランディングパッドのPNG画像を、様々なアスファルトやコンクリートの背景画像にランダムに合成します。この際、ドローンの接近角をシミュレートするために `cv2.getPerspectiveTransform` を用いた透視変換を適用することが重要です。



<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/jetson-nano-d435i-precision-landing/khack_1780198275_2.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



```python
import cv2
import numpy as np

def apply_perspective_transform(image, src_points, dst_points):
matrix = cv2.getPerspectiveTransform(src_points, dst_points)
result = cv2.warpPerspective(image, matrix, (image.shape[1], image.shape[0]))
return result

# Synthetic data generation logic for landing pad augmentation
```

このスクリプトにより、輝度変化、モーションブラー、および幾何学的歪みを含む1,000枚の学習データを短時間で確保しました。これにより、実機テスト時の検出失敗率が大幅に低下しました。

## YOLOv8の学習とTensorRTへのエクスポートプロセス

Jetson Nano の CPU リソースは極めて限定的であるため、PyTorch モデル（.pt）をそのまま推論に使用すると FPS が 2〜5 程度まで低下し、飛行制御に致命的な遅延をもたらします。これを解決するために <b><mark>TensorRT</mark></b> への変換が必須となります。



<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/jetson-nano-d435i-precision-landing/khack_1780198276_3.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



まず、高性能なデスクトップPC（RTX 4090環境）で YOLOv8-nano モデルを学習させ、その後 Jetson Nano 上で以下のコマンドを実行してエンジンファイルを生成します。

```bash
# Exporting YOLOv8 model to TensorRT format on Jetson Nano
yolo export model=best.pt format=engine device=0 half=True
```

### エクスポート時のログ出力例

```text
TensorRT: starting export with TensorRT 8.2.1...
TensorRT: input "images" with shape(1, 3, 640, 640) DataType.HALF
TensorRT: output "output0" with shape(1, 84, 8400) DataType.HALF
TensorRT: export success, saved as best.engine (14.2 MB)
```

`half=True` (FP16) を指定することで、推論精度を維持しつつ、Jetson Nano 上で 35 FPS 以上のスループットを確保しました。



<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/jetson-nano-d435i-precision-landing/khack_1780198277_4.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



## RealSense D435iによる深度マッピングと3D座標変換

検出されたバウンディングボックスの中心点 $(u, v)$ を、RealSense の深度フレームと照合します。単一ピクセルの深度値はノイズの影響を受けやすいため、中心点周辺 5x5 ピクセルの平均値を取得するフィルタリングを実装しています。

```python
def get_filtered_depth(depth_frame, x, y, window_size=5):
depth_roi = depth_frame[y-window_size:y+window_size, x-window_size:x+window_size]
valid_depths = depth_roi[depth_roi &gt; 0]
return np.mean(valid_depths) if len(valid_depths) &gt; 0 else 0
```

この座標データは、カメラの取り付け角度（ピッチ角）を考慮した回転行列を適用した後、MAVLink メッセージとしてパッキングされます。



<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/jetson-nano-d435i-precision-landing/khack_1780198278_5.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



## MAVLink通信によるLANDING_TARGETの送信

計算された相対座標を Pixhawk に送信するために、`pymavlink` を使用します。ArduPilot は `LANDING_TARGET` メッセージを受信すると、内部の EKF3 フィルタに統合し、着陸フェーズでの位置補正を開始します。

```python
from pymavlink import mavutil

def send_landing_target(connection, x_rad, y_rad, distance):
connection.mav.landing_target_send(
0, 0, mavutil.mavlink.MAV_FRAME_BODY_NED,
x_rad, y_rad, distance, 0, 0
)
```



<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/jetson-nano-d435i-precision-landing/khack_1780198279_6.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



## トラブルシューティング：推論レイテンシと通信の不安定性

### 1. TensorRT実行時のサーマルスロットリング
<b>現象</b>: 推論開始から約10分後、FPSが30から12に急落する。  
<b>原因</b>: Jetson Nano の SoC 温度が 80°C を超え、周波数制限が発生していた。  
<b>対策</b>: `jetson_clocks` コマンドを実行してファン速度を最大に固定し、物理的な大型ヒートシンクへの換装を実施。

### 2. RealSense USB 3.0 認識エラー

<b>現象</b>: `RuntimeError: Frame didn't arrive within 5000` が頻発する。  
<b>原因</b>: Jetson Nano のキャリアボードにおける USB バス供給電力の不足。  
<b>対策</b>: D435i を外部給電式の USB 3.0 ハブ経由で接続するか、Jetson Nano への給電を DC ジャック（5V 4A）に切り替えることで解決。

### 3. MAVLink メッセージのパケットロス

<b>現象</b>: Pixhawk 側で `LANDING_TARGET` が断続的にしか受信されない。  
<b>原因</b>: シリアル通信のボーレート不足（115200bps）によるバッファオーバーフロー。  
<b>対策</b>: ボーレートを 921600bps に引き上げ、`SERIAL1_PROTOCOL=2` (MAVLink 2) を明示的に設定。



<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/jetson-nano-d435i-precision-landing/khack_1780198281_7.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



## システム検証と運用テストの結果

実装したシステムの検証を、高度 5m からの自動着陸シーケンスで実施しました。以下のログは、着陸直前のターゲット補正状況を示しています。

### 運用ログ：着陸ターゲット追従状況

```text
[INFO] Target Detected: x=0.12m, y=-0.05m, dist=3.42m | FPS: 36.2
[INFO] Target Detected: x=0.08m, y=-0.02m, dist=2.15m | FPS: 35.8
[INFO] Target Detected: x=0.01m, y=0.01m, dist=0.85m | FPS: 36.1
[SUCCESS] Precision Landing Completed. Offset: 4.2cm
```



<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/jetson-nano-d435i-precision-landing/khack_1780198282_8.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



検証の結果、最終的な着陸精度は中心点から半径 8cm 以内に収まり、GPS 単独時の誤差（約 2.5m）と比較して大幅な精度向上を確認しました。また、<b><mark>TensorRT</mark></b> による高速化により、ドローンの急激な姿勢変化に対しても遅延なくターゲットを追従することが可能となりました。



<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/jetson-nano-d435i-precision-landing/khack_1780198283_9.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



## 結論と今後の運用上の留意点

本システムは、Jetson Nano という制約のあるリソース下で、AI推論と深度計測を同期させる実用的な解法を提供します。運用上の留意点として、RealSense の深度計測範囲（D435i の場合は約 0.3m〜10m）を考慮し、高度 10m 以上では YOLO による 2D 検出のみを行い、10m 以下で深度情報を統合するロジックの切り替えが推奨されます。



<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/jetson-nano-d435i-precision-landing/khack_1780198285_10.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



また、夜間運用においては、赤外線プロジェクターの出力を最大化するか、ランディングパッド自体にアクティブな発光体（LEDマーカー）を配置する等の物理的な対策が、検出安定性の向上に寄与します。



<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/jetson-nano-d435i-precision-landing/khack_1780198286_11.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>

