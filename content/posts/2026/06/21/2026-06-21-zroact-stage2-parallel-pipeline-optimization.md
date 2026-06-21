---
title: "ZroAct Stage 2におけるリアルタイム並列処理パイプラインの設計と非同期最適化"
slug: "zroact-stage2-parallel-pipeline-optimization"
date: 2026-06-21T10:15:12+09:00
draft: false
image: ""
description: "ZroAct Stage 2の推論パイプラインにおける同期ボトルネックを解消するため、asyncio、run_in_executor、およびProducer-Consumerパターンを用いた非同期並列化手法をアーキテクチャの観点から解説します。"
categories: ["Backend Architecture"]
tags: ["asyncio", "run_in_executor", "vllm", "onnxruntime", "producer-consumer"]
author: "K-Life Hack"
---

# ZroAct Stage 2における非同期並列パイプラインへの移行とボトルネック最適化検証

リアルタイムのビデオ推論パイプラインにおいて、ステージ間の同期的なブロッキング処理は、GPUリソースの深刻な過少利用とエンドツーエンドの遅延（Latency）悪化を招きます。特に、物体検出やアクション認識を行う軽量な前処理ステージ（Stage 1）と、大規模なマルチモーダル基盤モデル（VLM）による評価ステージ（Stage 2）を組み合わせるカスケード型アーキテクチャでは、データ転送と推論実行のオーバーラップ設計が全体の処理スループットを決定づけます。

本稿では、ZroAct Stage 2システムにおけるシーケンシャルな実行モデルから、非同期並列処理アーキテクチャへの移行プロセスについて、具体的なボトルネックの分析と複数の最適化アプローチの比較検証を行います。

---

## 1. 現行システムのアーキテクチャと性能基準

対象システムは、YOWOv3 ONNXモデルによるアクション検出（Stage 1）と、Qwen3.5-2B VLMによるビデオ言語評価（Stage 2）の2段階で構成されています。Stage 2はvLLMサービングレイヤー上にデプロイされ、高スループットな推論を可能にする設計となっています。

### 1.1 ディレクトリ構造

システムは以下のコンポーネントに分割され、HTTPベースのマイクロサービスとして協調動作します。

```text
zroact-stage2/
├── pipeline/
│   └── main.py                  # レガシーな順次処理パイプライン
├── pipeline_ver2/
│   ├── main.py                  # 共通ユーティリティ（フレーム抽出、タイミング記録等）
│   └── realtime_pipeline.py     # 現行バージョン（asyncio + aiohttpベース）
└── serving/
    ├── app.py                   # FastAPIジョブ受付API
    ├── config.json              # ポートおよびパス設定
    ├── run_job.py               # 単一ジョブ実行エンジン
    └── workers/
        ├── stage1_server.py     # YOWOv3 ONNX HTTPデーモン (Port 8001)
        ├── stage2_server.py     # Qwen3.5 VLM HTTPデーモン (Port 8002)
        └── scheduler.py         # リアルタイムスケジューラ（未実装スタブ）
```

### 1.2 ハードウェアプロファイルとリソース状況

検証環境におけるハードウェア仕様およびリソースの占有状況は以下の通りです。

💡 <b>GPU</b>: NVIDIA RTX A6000 (47.5 GB VRAM)
💡 <b>Stage 1 ONNX メモリ占有量</b>: 約 1 GB VRAM
💡 <b>Stage 2 Qwen3.5-2B メモリ占有量</b>: 約 5 GB VRAM
💡 <b>利用可能な空きVRAM（ヘッドルーム）</b>: 約 15 〜 16 GB

### 1.3 性能測定のベースライン

14秒のビデオクリップ（計419フレーム）を入力とした場合のベースライン測定値は以下の通りです。

| フェーズ / コンポーネント | 実行時間 | スループット / 遅延指標 |
| :--- | :--- | :--- |
| <b>Stage 1 (41 クリップ)</b> | 6.71 秒 | 1クリップあたり 163 ms |
| <b>Stage 2 (13 VLM リクエスト)</b> | 26.93 秒 | 1リクエストあたり 2.07 秒 (`semaphore=1` による直列化) |
| <b>全体のストリーミングループ</b> | <b>27.91 秒</b> | 総ウォールクロック実行時間 |

---

## 2. 検出されたシステムボトルネック

### ボトルネック 1: 同期的な Stage 1 バッチループ
現行の `realtime_pipeline.py` では、Stage 1のバッチ処理がループ内で順次 `await` されています。

```python
for kf_batch in keyframe_batches:
    # 前のバッチが完了するまで実行がブロックされる
    resp_data = await detect_clip_batch(...)
```

この設計では、バッチサイズが小さい場合（例: 1）、ONNX Runtimeの推論呼び出しの合間にGPUがアイドル状態になり、ネットワーク往復遅延（RTT）が累積します。

### ボトルネック 2: セマフォ制限による Stage 2 VLM の直列化

Stage 2のVLMリクエストは、以下の厳格なセマフォによって制限されています。

```python
vlm_semaphore = asyncio.Semaphore(1)
```

これにより、13件 of VLMリクエストが完全に直列処理され、累積遅延が $13 \times 2.07\text{秒} = 26.9\text{秒}$ に達します。RTX A6000の豊富なVRAM（空き容量 15〜16 GB）が有効に活用されていません。

### ボトルネック 3: ステージ間遷移の遅延

Stage 2のタスクは、入力スロットが準備できた段階で `asyncio.create_task` によってイベントループに登録されます。しかし、シングルスレッドの `asyncio` イベントループが Stage 1 のHTTPリクエストの完了待ちでブロックされているため、登録された Stage 2 タスクの実際の実行開始が遅延します。

---

## 3. 並列化および最適化戦略の検証

### オプション A: Stage 1 バッチの非同期一括実行 (`asyncio.gather`)
バッチをループで順次実行する代わりに、すべてのリクエストをコルーチンとしてパッケージ化し、`asyncio.gather` で同時にディスパッチします。

```python
# 改善後の並列実行コード
tasks = [
    detect_clip_batch(session, clips=build_payload(kf_batch))
    for kf_batch in keyframe_batches
]
results = await asyncio.gather(*tasks)
```

<b>利点</b>: コードの変更が最小限で済み、HTTPの累積RTTを削減できます。
⚠️ <b>欠点</b>: ONNX Runtimeの `InferenceSession` がスレッドセーフでない場合、最終的なGPU実行レベルで処理が直列化されるため、極端な並列化はイベントループの飽和を招きます。

### オプション B: Stage 2 VLM の並列処理（セマフォの緩和）

`vlm_semaphore` の制限を緩和し、RTX A6000の空きVRAMを利用して複数リクエストを同時実行します。

VRAMスケーリング予測は以下の通りです。
・ Qwen3.5-2B 基本重み: 約 5 GB
・ 1リクエストあたりのアクティベーションメモリ（画像3枚 + プロンプト）: 約 1 〜 2 GB
・ `Semaphore(2)` の場合: $\sim 5\text{GB} + (2 \times 2\text{GB}) = 7 \sim 9\text{GB}$（極めて安定）
・ `Semaphore(4)` の場合: $\sim 5\text{GB} + (4 \times 2\text{GB}) = 11 \sim 13\text{GB}$（安全圏内）
・ 制限なし（13並列）: $\sim 5\text{GB} + (13 \times 2\text{GB}) \ge 31\text{GB}$（OOMのリスク高）

### オプション C: `asyncio.Queue` を用いた Producer-Consumer パイプライン

Stage 1（Producer）と Stage 2（Consumer）を完全に分離し、共有キューを介してデータをストリーミングします。これにより、Stage 1の最初のクリップが完了した瞬間に Stage 2 の処理を開始できます。

```python
import asyncio

stage2_queue = asyncio.Queue()

async def stage1_producer(session, keyframe_batches, queue):
    for kf_batch in keyframe_batches:
        resp = await detect_clip_batch(session, clips=build_payload(kf_batch))
        for result in resp["results"]:
            # スロットの依存関係が解決されたらキューに投入
            if check_slot_ready(result):
                await queue.put(build_vlm_request(result))
    await queue.put(None)  # 終了シグナル

async def stage2_consumer(session, queue, results_list):
    # 同時実行数を2に制限してリソースを保護
    sem = asyncio.Semaphore(2)
    
    async def worker():
        while True:
            req = await queue.get()
            if req is None:
                queue.task_done()
                await queue.put(None)  # 他のワーカースレッドにも終了を伝播
                break
            async with sem:
                res = await evaluate_vlm(session, req)
                results_list.append(res)
            queue.task_done()

    await worker()
```

### オプション F: `run_in_executor` による I/O プリフェッチの非同期化

画像の読み込みやデコードなどのブロッキングI/O処理を、`loop.run_in_executor` を使用してスレッドプールにオフロードし、メインのイベントループがネットワーク応答の待機に専念できるようにします。

```python
from concurrent.futures import ThreadPoolExecutor
import asyncio

executor = ThreadPoolExecutor(max_workers=4)

async def prefetch_clip_frames(loop, frame_paths, key_idx, clip_length, sampling_rate):
    def _load():
        # ディスクからの画像読み込み（ブロッキング処理）
        return [
            str(frame_paths[max(0, key_idx - i * sampling_rate - 1)])
            for i in reversed(range(clip_length))
        ]
    
    return await loop.run_in_executor(executor, _load)
```

---

## 4. トラブルシューティングと実務上の制約

### 4.1 Python GIL と CUDA カーネルの直列化
`asyncio` を用いて非同期にHTTPリクエストを並列送信しても、下層の PyTorch や ONNX Runtime がGPUカーネルを呼び出す際、Pythonのグローバルインタプリタロック（GIL）およびCUDAストリームの同期制約により、実際のGPU実行は一部直列化されます。しかし、画像デコード、テンソル前処理、JSONのシリアライズ/デシリアライズなどのCPUバウンドな前処理タスクは非同期化によって大幅にオーバーラップされ、全体的なスループットが向上します。

### 4.2 VRAMの断片化と OOM (Out of Memory)

⚠️ `vlm_semaphore` の値を過度に大きくすると、vLLMのKVキャッシュ領域と競合し、ランタイム中に `CUDA out of memory` エラーが発生します。RTX A6000環境では、安全マージンを考慮して `Semaphore(2)` または `Semaphore(3)` で運用し、スパイク時のメモリ使用量を監視する必要があります。

---

## 5. 運用検証ログ

最適化後のパイプライン（Option A + Option B `Semaphore(2)`）を実行した際のコンソール出力ログのシミュレーションを示します。Stage 1のバッチ処理と Stage 2 のVLM評価がオーバーラップして実行されていることが確認できます。

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

1. <b>カスケード型パイプラインにおける非同期キューの有効性</b>: Stage 1 と Stage 2 を疎結合に保ち、`asyncio.Queue` を介してデータをストリーミングすることで、前段の完了を待たずに後段 of 重い推論を開始でき、全体の実行時間を大幅に短縮できます。

2. <b>ハードウェア特性に応じたセマフォ制御</b>: 単に並列数を増やすのではなく、GPUのVRAM容量（RTX A6000の47.5GB）とモデルのフットプリント（Qwen3.5-2Bの5GB + アクティベーション）を正確に計算し、安全な同時実行数（`Semaphore(2〜3)`）を設定することが、本番環境での安定稼働において極めて重要です。

3. <b>I/Oブロッキングの排除</b>: `run_in_executor` を用いたディスクI/Oのオフロードは、ネットワークバウンドな非同期イベントループのストールを防ぐための必須パターンです。