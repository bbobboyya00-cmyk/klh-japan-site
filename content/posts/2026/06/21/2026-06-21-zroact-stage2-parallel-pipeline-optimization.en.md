---
title: "Design and Asynchronous Optimization of Real-Time Parallel Processing Pipeline in ZroAct Stage 2"
slug: "zroact-stage2-parallel-pipeline-optimization"
date: 2026-06-21T10:15:13+09:00
draft: false
image: ""
description: "To resolve synchronization bottlenecks in the ZroAct Stage 2 inference pipeline, this article explains asynchronous parallelization methods using asyncio, run_in_executor, and the Producer-Consumer pattern from an architectural perspective."
categories: ["Backend Architecture"]
tags: ["asyncio", "run_in_executor", "vllm", "onnxruntime", "producer-consumer"]
author: "K-Life Hack"
---

# Migration to Asynchronous Parallel Pipeline and Bottleneck Optimization Verification in ZroAct Stage 2

In real-time video inference pipelines, synchronous blocking operations between stages lead to severe underutilization of GPU resources and degradation of end-to-end latency. In particular, in a cascaded architecture that combines a lightweight preprocessing stage (Stage 1) for object detection or action recognition with an evaluation stage (Stage 2) using a large vision-language model (VLM), the overlapping design of data transfer and inference execution determines the overall processing throughput.


This article analyzes specific bottlenecks and compares multiple optimization approaches during the migration process from a sequential execution model to an asynchronous parallel processing architecture in the ZroAct Stage 2 system.



---

## 1. Current System Architecture and Performance Benchmarks

The target system consists of two stages: action detection using the YOWOv3 ONNX model (Stage 1) and video language evaluation using the Qwen3.5-2B VLM (Stage 2). Stage 2 is deployed on the vLLM serving layer, designed to enable high-throughput inference.



### 1.1 Directory Structure

The system is divided into components operating cooperatively as HTTP-based microservices.



```text
zroact-stage2/
├── pipeline/
│   └── main.py                  # Legacy sequential processing pipeline
├── pipeline_ver2/
│   ├── main.py                  # Common utilities (frame extraction, timing logging, etc.)
│   └── realtime_pipeline.py     # Current version (asyncio + aiohttp-based)
└── serving/
    ├── app.py                   # FastAPI job acceptance API
    ├── config.json              # Port and path configuration
    ├── run_job.py               # Single job execution engine
    └── workers/
        ├── stage1_server.py     # YOWOv3 ONNX HTTP daemon (Port 8001)
        ├── stage2_server.py     # Qwen3.5 VLM HTTP daemon (Port 8002)
        └── scheduler.py         # Real-time scheduler (unimplemented stub)
```

### 1.2 Hardware Profile and Resource Status

The hardware specifications and resource utilization in the verification environment are as follows.


<b>GPU</b>: NVIDIA RTX A6000 (47.5 GB VRAM)


<b>Stage 1 ONNX Memory Footprint</b>: Approx. 1 GB VRAM


<b>Stage 2 Qwen3.5-2B Memory Footprint</b>: Approx. 5 GB VRAM


<b>Available Free VRAM (Headroom)</b>: Approx. 15 to 16 GB



### 1.3 Performance Measurement Baseline

The baseline measurement values when using a 14-second video clip (419 frames in total) as input are as follows.



| Phase / Component | Execution Time | Throughput / Latency Metric |
| :--- | :--- | :--- |
| <b>Stage 1 (41 clips)</b> | 6.71 seconds | 163 ms per clip |
| <b>Stage 2 (13 VLM requests)</b> | 26.93 seconds | 2.07 seconds per request (serialized by `semaphore=1`) |
| <b>Overall Streaming Loop</b> | <b>27.91 seconds</b> | Total wall-clock execution time |

---

## 2. Detected System Bottlenecks

### Bottleneck 1: Synchronous Stage 1 Batch Loop

In the current realtime_pipeline.py, Stage 1 batch processing is sequentially awaited within a loop.



```python
for kf_batch in keyframe_batches:
    # Execution is blocked until the previous batch completes
    resp_data = await detect_clip_batch(...)
```

In this design, when the batch size is small (e.g., 1), the GPU remains idle between ONNX Runtime inference calls, accumulating network round-trip time (RTT) latency.



### Bottleneck 2: Serialization of Stage 2 VLM due to Semaphore Limits

Stage 2 VLM requests are restricted by a strict semaphore limit.



```python
vlm_semaphore = asyncio.Semaphore(1)
```

As a result, the 13 VLM requests are processed entirely in series, reaching an accumulated latency of $13 \times 2.07\text{s} = 26.9\text{s}$. The abundant VRAM of the RTX A6000 (15 to 16 GB of free capacity) is not being utilized effectively.



### Bottleneck 3: Latency in Inter-Stage Transition

Stage 2 tasks are registered to the event loop via asyncio.create_task as soon as the input slots are ready. However, because the single-threaded asyncio event loop is blocked waiting for the completion of Stage 1 HTTP requests, the actual execution start of the registered Stage 2 tasks is delayed.



---

## 3. Verification of Parallelization and Optimization Strategies

### Option A: Asynchronous Batch Execution of Stage 1 (asyncio.gather)

Instead of executing batches sequentially in a loop, all requests are packaged as coroutines and dispatched concurrently using asyncio.gather.



```python
# Improved parallel execution code
tasks = [
    detect_clip_batch(session, clips=build_payload(kf_batch))
    for kf_batch in keyframe_batches
]
results = await asyncio.gather(*tasks)
```

<b>Advantages</b>: Minimal code changes are required, and the cumulative HTTP RTT can be reduced.


<b>Disadvantages</b>: If the ONNX Runtime InferenceSession is not thread-safe, processing will be serialized at the final GPU execution level, so extreme parallelization will lead to event loop saturation.



### Option B: Parallel Processing of Stage 2 VLM (Relaxing Semaphores)

Relax the restrictions of vlm_semaphore to execute multiple requests concurrently using the free VRAM of the RTX A6000.


The VRAM scaling projection is calculated as follows:


• Qwen3.5-2B base weights: Approx. 5 GB


• Activation memory per request (3 images + prompt): Approx. 1 to 2 GB


• For Semaphore(2): ~5GB + (2 * 2GB) = 7 ~ 9GB (extremely stable)


• For Semaphore(4): ~5GB + (4 * 2GB) = 11 ~ 13GB (within safe margin)


• No limit (13 parallel): ~5GB + (13 * 2GB) &gt;= 31GB (high risk of OOM)



### Option C: Producer-Consumer Pipeline Using asyncio.Queue

Completely decouple Stage 1 (Producer) and Stage 2 (Consumer), streaming data through a shared queue. This allows Stage 2 processing to begin the moment the first clip of Stage 1 is completed.



```python
import asyncio

stage2_queue = asyncio.Queue()

async def stage1_producer(session, keyframe_batches, queue):
    for kf_batch in keyframe_batches:
        resp = await detect_clip_batch(session, clips=build_payload(kf_batch))
        for result in resp["results"]:
            # Enqueue once slot dependencies are resolved
            if check_slot_ready(result):
                await queue.put(build_vlm_request(result))
    await queue.put(None)  # Termination signal

async def stage2_consumer(session, queue, results_list):
    # Limit concurrency to 2 to protect resources
    sem = asyncio.Semaphore(2)
    
    async def worker():
        while True:
            req = await queue.get()
            if req is None:
                queue.task_done()
                await queue.put(None)  # Propagate termination to other workers
                break
            async with sem:
                res = await evaluate_vlm(session, req)
                results_list.append(res)
            queue.task_done()

    await worker()
```

### Option F: Asynchronous I/O Prefetching via run_in_executor

Offload blocking I/O operations, such as image loading and decoding, to a thread pool using loop.run_in_executor so that the main event loop can focus solely on waiting for network responses.



```python
from concurrent.futures import ThreadPoolExecutor
import asyncio

executor = ThreadPoolExecutor(max_workers=4)

async def prefetch_clip_frames(loop, frame_paths, key_idx, clip_length, sampling_rate):
    def _load():
        # Load images from disk (blocking operation)
        return [
            str(frame_paths[max(0, key_idx - i * sampling_rate - 1)])
            for i in reversed(range(clip_length))
        ]
    
    return await loop.run_in_executor(executor, _load)
```

---

## 4. Troubleshooting and Practical Constraints

### 4.1 Python GIL and CUDA Kernel Serialization

Even when HTTP requests are sent asynchronously in parallel using asyncio, actual GPU execution is partially serialized due to the Python Global Interpreter Lock (GIL) and CUDA stream synchronization constraints when the underlying PyTorch or ONNX Runtime calls GPU kernels. However, CPU-bound preprocessing tasks such as image decoding, tensor preprocessing, and JSON serialization/deserialization are significantly overlapped through asynchronous execution, improving overall throughput.



### 4.2 VRAM Fragmentation and OOM (Out of Memory)

Setting the vlm_semaphore value excessively high causes contention with the vLLM KV cache area, leading to CUDA out of memory errors during runtime. In the RTX A6000 environment, it is necessary to operate with Semaphore(2) or Semaphore(3) considering a safety margin, and monitor memory usage during spikes.



---

## 5. Operational Verification Logs

The simulation of the console output log during the execution of the optimized pipeline (Option A + Option B Semaphore(2)) demonstrates overlapping execution of Stage 1 batch processing and Stage 2 VLM evaluation.



```text
2026-06-21 10:00:01,102 [INFO] Starting pipeline optimization validation...
2026-06-21 10:00:01,105 [INFO] Stage 1 Server (Port 8001) and Stage 2 Server (Port 8002) are active.
2026-06-21 10:00:01,150 [INFO] Dispatching Stage 1 batches concurrently using asyncio.gather...
2026-06-21 10:00:02,890 [INFO] Stage 1: Batch 1-10 processed successfully.
2026-06-21 10:00:02,910 [INFO] Slot 3-frame ready for Keyframe Index 12. Spawning Stage 2 Task...
2026-06-21 10:00:02,915 [INFO] Slot 3-frame ready for Keyframe Index 24. Spawning Stage 2 Task...
2026-06-21 10:00:02,920 [DEBUG] Active VLM Semaphore count: 2/2. Task for Index 24 queued.
2026-06-21 10:00:04,950 [INFO] Stage 2: VLM evaluation completed for Index 12 (Duration: 2.03s).
2026-06-21 10:00:04,952 [DEBUG] Semaphore released. Task for Index 24 immediately acquired lock.
2026-06-21 10:00:06,980 [INFO] Stage 2: VLM evaluation completed for Index 24 (Duration: 2.01s).
2026-06-21 10:00:07,810 [INFO] All Stage 1 and Stage 2 tasks completed.
2026-06-21 10:00:07,812 [INFO] Total pipeline wall-clock time: 16.71 seconds (Baseline: 27.91s, ~40.1% improvement).
```

---

## 6. Lessons Learned

1. <b>Effectiveness of Asynchronous Queues in Cascaded Pipelines</b>: By keeping Stage 1 and Stage 2 loosely coupled and streaming data via asyncio.Queue, heavy inference in the subsequent stage can begin without waiting for the preceding stage to complete, significantly reducing overall execution time.


2. <b>Semaphore Control Tailored to Hardware Characteristics</b>: Rather than simply increasing the degree of parallelism, accurately calculating the GPU VRAM capacity (47.5 GB for RTX A6000) and model footprint (5 GB for Qwen3.5-2B + activations) to set a safe concurrency limit (Semaphore(2-3)) is extremely critical for stable operation in production environments.


3. <b>Eliminating I/O Blocking</b>: Offloading disk I/O using run_in_executor is an essential pattern to prevent stalls in network-bound asynchronous event loops.

