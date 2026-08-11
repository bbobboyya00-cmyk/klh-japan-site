---
title: "Implementing Heterogeneous Microservice Integration and SSE Streaming with Spring Boot and FastAPI"
slug: "spring-boot-fastapi-hybrid-ai-gateway"
date: 2026-08-11T10:02:45+09:00
draft: false
image: ""
description: "This article explains asynchronous SSE streaming processing and event loop bottleneck avoidance strategies in a hybrid AI microservice architecture combining Spring Boot and FastAPI."
categories: ["Backend Architecture"]
tags: ["fastapi-비동기-엔드포인트"]
author: "K-Life Hack"
---

When incorporating generative AI features into large-scale enterprise systems, attempting to complete all processing solely within a single Java monolith architecture presents serious structural challenges from the perspectives of the library ecosystem and asynchronous I/O handling. Most major AI toolkits, including PyTorch, LangChain, LlamaIndex, and Hugging Face, are developed natively in Python. Operating wrapper libraries from a Java environment or performing synchronous REST conversions directly causes deployment complexity and performance degradation.


To resolve these architectural constraints, adopting a hybrid microservices pattern (Polyglot Architecture) is highly effective: retaining strict ACID transactions and core business logic in Spring Boot while delegating LLM orchestration, Vector DB integration, and asynchronous response delivery via Server-Sent Events (SSE) to FastAPI.



## Architecture Configuration and Division of Roles

In this architecture, clear system boundaries are established according to workload characteristics.


<b>1. Spring Boot (Main Application Server)</b>


Handles user authentication/authorization (Spring Security), payment processing, data consistency management in RDBMS, and main domain flow control. It receives main requests from clients and forwards only those requests that pass authentication and domain validation to FastAPI via the internal network.


<b>2. FastAPI (AI / LLM Gateway)</b>


Handles prompt construction, context retrieval from Vector DBs (Pinecone, Milvus, etc.) for RAG, LLM inference calls, and SSE streaming delivery. Built as an ASGI application based on Starlette and Pydantic, it leverages Python's asyncio event loop to non-blockingly process I/O wait times during LLM token generation without thread exhaustion.



## SSE Streaming Implementation with FastAPI

Below is a standard implementation example of an asynchronous endpoint on the FastAPI side using StreamingResponse to return tokens to the client in real time.



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
        raise HTTPException(status_code=400, detail="Message is empty")
        
    return StreamingResponse(
        generate_llm_stream(request.message),
        media_type="text/event-stream"
    )
```

## Troubleshooting

### 🛠️ 1. FastAPI Event Loop Blocking (CPU-Bound Operations)

<b>Symptom:</b> Executing heavy computation (tensor calculations, local tokenization, image preprocessing, etc.) or synchronous library calls inside a routing function defined with async def halts the entire single asyncio event loop. As a result, all subsequent asynchronous requests to the same instance are forced into an unresponsive state (timeout).


<b>Mitigation:</b> Declare functions performing CPU-bound synchronous operations as regular synchronous functions (def) instead of async def. FastAPI automatically offloads endpoints defined with regular def to a separate managed thread pool for execution. When calling synchronous blocking code partially inside an asynchronous function, explicitly offload it to a thread using starlette.concurrency.run_in_threadpool.



### ⚠️ 2. Communication Latency and Thread Exhaustion Between Spring Boot ↔ FastAPI

<b>Symptom:</b> LLM generation processing can require long response times of 10 to 30 seconds or more. Calling FastAPI from the Spring Boot side using the traditional synchronous RestTemplate occupies Tomcat worker threads for extended periods. Under high load, this exhausts the thread pool and triggers cascading failures across the entire system.


<b>Mitigation:</b> Use a non-blocking HTTP client for internal communication on the Spring Boot side, such as WebClient (Spring WebFlux) or the async-capable RestClient added in Spring Boot 3.2. If further latency reduction is required, switch the transport protocol between internal microservices from HTTP/1.1 to gRPC.



## Operational Notes

💡 The verification log protocol to confirm normal operation of this architecture is as follows:



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

To achieve stable operations, it is essential to strictly separate the responsibilities of Spring Boot and FastAPI, and thoroughly isolate threads for I/O-bound AI streaming operations and CPU-bound data processing.

