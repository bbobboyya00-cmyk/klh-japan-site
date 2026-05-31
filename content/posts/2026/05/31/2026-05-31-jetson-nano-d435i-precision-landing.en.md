---
title: "Building an Autonomous Precision Landing System Integrating Jetson Nano and RealSense D435i with TensorRT Inference Optimization"
slug: "jetson-nano-d435i-precision-landing"
date: 2026-05-31T12:31:28+09:00
draft: false
image: "https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/jetson-nano-d435i-precision-landing/khack_1780198272_0.webp"
description: "Technical log of a UAV precision landing system using Jetson Nano, D435i, YOLOv8, and TensorRT. Details the implementation process from synthetic dataset generation to MAVLink communication, 3D coordinate transformation, and inference latency troubleshooting."
categories: ["Linux System Admin"]
tags: ["jetson-nano", "realsense-d435i", "yolov8", "tensorrt", "mavlink", "ardupilot"]
author: "K-Life Hack"
---

## System Architecture and Hardware Selection

In 2026 UAV operations, vision-based precision landing systems are essential to overcome GPS errors (typically 2–5m). This project utilizes <b><mark>Jetson Nano</mark></b> as the edge computing device, <b><mark>Intel RealSense D435i</mark></b> for depth data acquisition, and Pixhawk as the flight controller (FC).




<img alt="System operational pipeline topology flow description" fetchpriority="high" height="316" loading="eager" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/jetson-nano-d435i-precision-landing/khack_1780198272_0.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);" width="317"/>


Data flow: Jetson Nano receives RGB-D streams from the D435i, detects the landing pad using a YOLOv8 model, and correlates the center coordinates with the depth map to calculate 3D relative distance. Finally, it sends `LANDING_TARGET` messages to the Pixhawk via `pymavlink` to drive ArduPilot's autonomous landing algorithm. Prerequisites include securing USB 3.0 bus bandwidth and locking the Jetson Nano to 10W power mode for stable operation.




<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/jetson-nano-d435i-precision-landing/khack_1780198273_1.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



## Improving Model Generalization via Synthetic Dataset Generation

Due to limitations in real-world data collection, a synthetic dataset generation script using OpenCV was implemented. Landing pad PNG images are randomly composited onto various asphalt and concrete background images. It is crucial to apply perspective transformation using `cv2.getPerspectiveTransform` to simulate drone approach angles.




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

This script secured 1,000 training images including brightness variations, motion blur, and geometric distortion in a short time. This significantly reduced detection failure rates during field testing.



## YOLOv8 Training and TensorRT Export Process

Jetson Nano CPU resources are extremely limited; using PyTorch models (.pt) directly for inference drops FPS to 2–5, causing fatal latency in flight control. Conversion to <b><mark>TensorRT</mark></b> is mandatory to resolve this.




<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/jetson-nano-d435i-precision-landing/khack_1780198276_3.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>


The YOLOv8-nano model is trained on a high-performance desktop (RTX 4090 environment), followed by engine file generation on the Jetson Nano.



```bash
# Exporting YOLOv8 model to TensorRT format on Jetson Nano
yolo export model=best.pt format=engine device=0 half=True
```

### Export Log Example

```text
TensorRT: starting export with TensorRT 8.2.1...
TensorRT: input "images" with shape(1, 3, 640, 640) DataType.HALF
TensorRT: output "output0" with shape(1, 84, 8400) DataType.HALF
TensorRT: export success, saved as best.engine (14.2 MB)
```

By specifying `half=True` (FP16), a throughput of 35+ FPS was secured on the Jetson Nano while maintaining inference accuracy.




<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/jetson-nano-d435i-precision-landing/khack_1780198277_4.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



## Depth Mapping and 3D Coordinate Transformation with RealSense D435i

The detected bounding box center (u, v) is correlated with the RealSense depth frame. Since single-pixel depth values are susceptible to noise, filtering is implemented to average a 5x5 pixel area around the center.



```python
def get_filtered_depth(depth_frame, x, y, window_size=5):
    depth_roi = depth_frame[y-window_size:y+window_size, x-window_size:x+window_size]
    valid_depths = depth_roi[depth_roi &gt; 0]
    return np.mean(valid_depths) if len(valid_depths) &gt; 0 else 0
```

This coordinate data is packed into a MAVLink message after applying a rotation matrix that accounts for the camera's mounting angle (pitch).




<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/jetson-nano-d435i-precision-landing/khack_1780198278_5.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



## Sending LANDING_TARGET via MAVLink

`pymavlink` is used to transmit the calculated relative coordinates to the Pixhawk. Upon receiving the `LANDING_TARGET` message, ArduPilot integrates it into the internal EKF3 filter and initiates position correction during the landing phase.



```python
from pymavlink import mavutil

def send_landing_target(connection, x_rad, y_rad, distance):
    connection.mav.landing_target_send(
        0, 0, mavutil.mavlink.MAV_FRAME_BODY_NED,
        x_rad, y_rad, distance, 0, 0
    )
```



<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/jetson-nano-d435i-precision-landing/khack_1780198279_6.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



## Troubleshooting: Inference Latency and Communication Instability

### 1. Thermal Throttling during TensorRT Execution
<b>Symptom</b>: FPS drops sharply from 30 to 12 approximately 10 minutes after starting inference.  
<b>Cause</b>: Jetson Nano SoC temperature exceeded 80°C, triggering frequency scaling.  
<b>Fix</b>: Executed `jetson_clocks` to lock fan speed to maximum and replaced the stock cooler with a larger physical heatsink.



### 2. RealSense USB 3.0 Recognition Error
<b>Symptom</b>: Frequent `RuntimeError: Frame didn't arrive within 5000`.  
<b>Cause</b>: Insufficient power supply to the USB bus on the Jetson Nano carrier board.  
<b>Fix</b>: Resolved by connecting the D435i via an externally powered USB 3.0 hub or switching Jetson Nano power input to the DC jack (5V 4A).



### 3. MAVLink Message Packet Loss
<b>Symptom</b>: `LANDING_TARGET` received intermittently by the Pixhawk.  
<b>Cause</b>: Buffer overflow due to insufficient serial baud rate (115200bps).  
<b>Fix</b>: Increased baud rate to 921600bps and explicitly set `SERIAL1_PROTOCOL=2` (MAVLink 2).




<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/jetson-nano-d435i-precision-landing/khack_1780198281_7.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



## System Verification and Operational Test Results

System verification was conducted with an auto-landing sequence from an altitude of 5m. Target correction status just before touchdown is documented in the operational log.



### Operational Log: Landing Target Tracking Status

```text
[INFO] Target Detected: x=0.12m, y=-0.05m, dist=3.42m | FPS: 36.2
[INFO] Target Detected: x=0.08m, y=-0.02m, dist=2.15m | FPS: 35.8
[INFO] Target Detected: x=0.01m, y=0.01m, dist=0.85m | FPS: 36.1
[SUCCESS] Precision Landing Completed. Offset: 4.2cm
```



<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/jetson-nano-d435i-precision-landing/khack_1780198282_8.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>


Results confirmed final landing accuracy within an 8cm radius of the center, a significant improvement over the ~2.5m error of standalone GPS. Furthermore, <b><mark>TensorRT</mark></b> acceleration enabled the system to track the target without lag even during rapid drone attitude changes.




<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/jetson-nano-d435i-precision-landing/khack_1780198283_9.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>



## Conclusion and Operational Considerations

This system provides a practical solution for synchronizing AI inference and depth sensing under the constrained resources of a Jetson Nano. For operation, it is recommended to switch logic based on the RealSense depth range (approx. 0.3m–10m for D435i): use only YOLO 2D detection above 10m and integrate depth data below 10m.




<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/jetson-nano-d435i-precision-landing/khack_1780198285_10.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>


For night operations, physical measures such as maximizing IR projector output or placing active light sources (LED markers) on the landing pad will contribute to improved detection stability.




<img alt="System operational pipeline topology flow description" decoding="async" loading="lazy" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/jetson-nano-d435i-precision-landing/khack_1780198286_11.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);"/>

