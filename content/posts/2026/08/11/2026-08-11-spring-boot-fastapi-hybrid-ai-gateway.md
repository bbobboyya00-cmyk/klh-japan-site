---
title: "Spring BootとFastAPIによる異種マイクロサービス連携とSSEストリーミングの実装"
slug: "spring-boot-fastapi-hybrid-ai-gateway"
date: 2026-08-11T10:02:44+09:00
draft: false
image: ""
description: "Spring BootとFastAPIを組み合わせたハイブリッドAIマイクロサービス構成における、非同期SSEストリーミング処理とイベントループのボトルネック回避策を解説します。"
categories: ["Backend Architecture"]
tags: ["fastapi 비동기 엔드포인트"]
author: "K-Life Hack"
---

生成AI機能を大規模なエンタープライズシステムへ組み込む際、単一のJavaモノリス構成のみで全処理を完結させようとすると、ライブラリのエコシステムおよび非同期I/O処理の観点から深刻な構造的課題に直面します。PyTorch、LangChain、LlamaIndex、Hugging Faceをはじめとする主要なAIツールキットの大部分はPythonネイティブで開発されており、Java環境からのラッパーライブラリ運用や同期型REST変換は、デプロイメントの複雑化とパフォーマンス低下を直接的に引き起こします。

このアーキテクチャ上の制約を解消するため、厳格なACIDトランザクションとコアビジネスロジックをSpring Bootで保持しつつ、LLMオーケストレーションやVector DB連携、Server-Sent Events（SSE）による非同期レスポンス配信をFastAPIに委任するハイブリッド・マイクロサービスパターン（Polyglot Architecture）の採用が非常に有効です。

## アーキテクチャ構成と役割分担

本構成では、ワークロードの特性に応じて明確なシステム境界を設定します。

<b>1. Spring Boot (Main Application Server)</b>

ユーザー認証・認可（Spring Security）、決済処理、RDBMSでのデータ整合性管理、主要ドメインフローの制御を担当します。クライアントからのメインリクエストを受信し、認証およびドメイン検証を通過したリクエストのみを内部ネットワーク経由でFastAPIへ転送します。

<b>2. FastAPI (AI / LLM Gateway)</b>

プロンプト構築、Vector DB（Pinecone, Milvus等）からのコンテキスト検索（RAG）、LLM推論呼び出し、SSEストリーミング配信を担当します。StarletteおよびPydanticをベースにしたASGI構成であり、Pythonのasyncioイベントループを活用することで、LLMのトークン生成時に発生するI/O待ち時間をスレッドの枯渇なしに非ブロッキングで処理します。

## FastAPIによるSSEストリーミング実装

FastAPI側でStreamingResponseを利用し、クライアントへリアルタイムにトークンを返送する非同期エンドポイントの標準実装例を示します。

```python
import asyncio
from fastapi import FastAPI, Depends, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
import openai

app = FastAPI(title="AI Gateway Service")

class ChatRequest(BaseModel):
    user_id: str
    message: str

async def generate_llm_stream(prompt: str):
    try:
        client = openai.AsyncOpenAI(api_key="YOUR_API_KEY")
        stream = await client.chat.completions.create(
            model="gpt-4o",
            messages=[{"role": "user", "content": prompt}],
            stream=True,
        )
        
        async for chunk in stream:
            content = chunk.choices[0].delta.content
            if content:
                yield f"data: {content}

"
    except Exception as e:
        yield f"data: [ERROR] {str(e)}

"

@app.post("/api/v1/chat/stream")
async def chat_stream_endpoint(request: ChatRequest):
    if not request.message:
        raise HTTPException(status_code=400, detail="メッセージが空です")
        
    return StreamingResponse(
        generate_llm_stream(request.message),
        media_type="text/event-stream"
    )
```

## Troubleshooting

### 🛠️ 1. FastAPIのイベントループ・ブロッキング（CPUバウンド処理）

<b>現象:</b> async defで定義されたルーティング関数内で、重い計算処理（テンソル計算、ローカルでのトークナイズ、画像前処理など）や同期ライブラリの呼び出しを実行すると、単一のasyncioイベントループ全体が停止します。これにより、同一インスタンスに対する後続の全非同期リクエストが応答停止（タイムアウト）に追い込まれます。

<b>対策:</b> CPUバウンドな同期処理を行う関数は、async defではなく通常の同期関数（def）として宣言します。FastAPIは通常のdefで定義されたエンドポイントを自動的に別個のマネージドスレッドプールへオフロードして実行します。非同期関数内で部分的に同期ブロッキングコードを呼び出す場合は、starlette.concurrency.run_in_threadpoolを用いて明示的にスレッドへ退避させます。

### ⚠️ 2. Spring Boot ↔ FastAPI間の通信レイテンシとスレッド枯渇

<b>現象:</b> LLMの生成処理には10秒〜30秒以上の長時間レスポンスを要することがあります。Spring Boot側から従来の同期型RestTemplateを用いてFastAPIを呼び出すと、Tomcatのワーカースレッドが長時間占有され、高負荷時にスレッドプールが枯渇しシステム全体へカスケード障害が波及します。

<b>対策:</b> Spring Boot側の内部通信クライアントには、非ブロッキングHTTPクライアントであるWebClient（Spring WebFlux）またはSpring Boot 3.2以降で追加された非同期対応のRestClientを採用します。さらなる低レイテンシ化が必要な場合は、内部マイクロサービス間の転送プロトコルをHTTP/1.1からgRPCへ変更します。

## Operational Notes

💡 本アーキテクチャの正常動作を確認するための検証ログプロトコルは以下の通りです。

```text
$ curl -N -X POST http://localhost:8000/api/v1/chat/stream \
  -H "Content-Type: application/json" \
  -d '{"user_id": "usr_9921", "message": "Microservice Architecture"}'

data: Microservice
data:  architecture
data:  enables
data:  decoupled
data:  deployments.

$ ss -tulpn | grep 8000
tcp   LISTEN 0      128          0.0.0.0:8000      0.0.0.0:*    users:(("uvicorn",pid=41029,fd=3))
```

安定した運用を実現するためには、Spring BootとFastAPIの責務を厳密に分離し、I/OバウンドなAIストリーミング処理とCPUバウンドなデータ処理のスレッド分離を徹底することが不可欠です。