---
title: "Implementing High-Performance Data Streaming with React 18 and SSE"
slug: "react18-sse-streaming-implementation"
date: 2026-06-27T10:48:24+09:00
draft: false
image: ""
description: "Implementation methods for achieving low-latency streaming on Edge Runtime by combining React 18 Suspense and SSE. Details practical operational points such as avoiding proxy buffering and reconnection logic."
categories: ["Backend Architecture"]
tags: ["react-18", "server-sent-events", "edge-runtime", "nextjs-app-router", "readablestream"]
author: "K-Life Hack"
---

# Implementing Low-Latency Data Streaming with React 18 Streaming SSR and Edge Runtime

Modern web applications, particularly those involving large-scale responses or AI token generation, face degraded Time to First Byte (TTFB) when waiting for complete data sets before rendering. Frontend architecture increasingly adopts incremental delivery to optimize user experience, especially within the context of Large Language Models (LLMs).


This technical overview details implementation patterns for low-latency data streaming on Edge Runtime by combining React 18 Streaming SSR and Server-Sent Events (SSE), while addressing common friction points such as proxy buffering.



## 1. HTML Streaming with React 18 Suspense

In the Next.js App Router environment, utilizing Suspense boundaries allows server-resolved components to be transmitted to the client sequentially. This mechanism ensures the page shell, including headers and navigation, renders immediately without waiting for heavy data fetching operations to complete.



```javascript
import { Suspense } from 'react';

async function SlowSection() {
  // Data fetching with intentional delay
  const data = await fetch('https://api.example.com/slow-endpoint', {
    cache: 'no-store'
  }).then((res) =&gt; res.json());

  return (
    <section classname="p-4 border rounded">
<h2>Data processing complete</h2>
Message: {data.message}


</section>
  );
}

export default function Page() {
  return (
    <main classname="container mx-auto">
<h1>Streaming SSR Demo</h1>
      {/* Fallback is sent immediately without waiting for SlowSection to resolve */}
      <suspense classname="animate-pulse" fallback="{&lt;div">Loading...}&gt;
        <slowsection></slowsection>
</suspense>
</main>
  );
}
```

## 2. Integration of Server-Sent Events (SSE) and Edge Runtime

Server-Sent Events (SSE) facilitate unidirectional real-time communication with high HTTP protocol affinity. Compared to WebSockets, SSE is simpler to implement and maintain. Deploying on Edge Runtime allows streams to originate from a Point of Presence (PoP) near the user, effectively reducing network latency.



```javascript
export const runtime = 'edge';

export async function GET() {
  const encoder = new TextEncoder();

  const stream = new ReadableStream({
    start(controller) {
      const send = (data: any) =&gt; {
        const chunk = `data: ${JSON.stringify(data)}

`;
        controller.enqueue(encoder.encode(chunk));
      };

      // Send initial data
      send({ status: 'connected', timestamp: Date.now() });

      // Simulated data push
      const timer = setInterval(() =&gt; {
        send({ value: Math.random(), ts: Date.now() });
      }, 1000);

      // Heartbeat to prevent proxy timeouts (15-second interval)
      const heartbeat = setInterval(() =&gt; {
        controller.enqueue(encoder.encode(':keep-alive

'));
      }, 15000);

      // Cleanup when connection is closed
      return () =&gt; {
        clearInterval(timer);
        clearInterval(heartbeat);
      };
    },
    cancel() {
      console.log('Stream cancelled by client');
    }
  });

  return new Response(stream, {
    headers: {
      'Content-Type': 'text/event-stream; charset=utf-8',
      'Cache-Control': 'no-cache, no-transform',
      'Connection': 'keep-alive',
      'X-Accel-Buffering': 'no' // Disable buffering for NGINX, etc.
    }
  });
}
```

## 3. Consuming Streams on the Client Side

Managing the standard browser EventSource API within the React lifecycle requires a custom hook to ensure stability, state synchronization, and proper resource cleanup.



```javascript
import { useEffect, useState, useRef } from 'react';

export function useSSE<t>(url: string) {
  const [data, setData] = useState<t[]>([]);
  const eventSourceRef = useRef<eventsource null="" |="">(null);

  useEffect(() =&gt; {
    const es = new EventSource(url);
    eventSourceRef.current = es;

    es.onmessage = (event) =&gt; {
      try {
        const parsed = JSON.parse(event.data);
        setData((prev) =&gt; [...prev, parsed]);
      } catch (err) {
        console.error('Parse error:', err);
      }
    };

    es.onerror = () =&gt; {
      console.error('SSE connection failed. Attempting to reconnect...');
      es.close();
    };

    return () =&gt; {
      es.close();
    };
  }, [url]);

  return data;
}
```

## 4. Alternative Approach with NDJSON (Newline Delimited JSON)

In scenarios where EventSource is restricted or when streaming requires flexible HTTP methods like POST, Newline Delimited JSON (NDJSON) serves as an effective alternative for structured data transmission.



```javascript
async function consumeNDJSON(response: Response, onChunk: (data: any) =&gt; void) {
  const reader = response.body?.getReader();
  if (!reader) return;

  const decoder = new TextDecoder();
  let buffer = '';

  while (true) {
    const { value, done } = await reader.read();
    if (done) break;

    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split('
');
    buffer = lines.pop() || ''; // Keep the incomplete line in the buffer

    for (const line of lines) {
      if (line.trim()) {
        onChunk(JSON.parse(line));
      }
    }
  }
}
```

## Troubleshooting

The primary challenge in streaming implementation involves buffering by intermediate infrastructure.


<b>NGINX Buffering</b>: Default NGINX configurations buffer responses. Implementation requires the X-Accel-Buffering: no header or the proxy_buffering off; directive in the configuration file to ensure immediate data transmission.


<b>Cloudflare Limitations</b>: CDN layers like Cloudflare may terminate streams after specific intervals, such as the default 100-second timeout. Periodic heartbeats are necessary to maintain the connection integrity.


<b>Mobile Safari Behavior</b>: iOS Safari frequently disconnects SSE connections when the browser moves to the background. Robust reconnection logic is required to handle page resumption and state recovery.



```text
# Check headers
$ curl -I http://localhost:3000/api/stream
HTTP/1.1 200 OK
Content-Type: text/event-stream; charset=utf-8
Cache-Control: no-cache, no-transform
Connection: keep-alive
X-Accel-Buffering: no

# Real-time stream reception test (-N disables buffering)
$ curl -N http://localhost:3000/api/stream
data: {"status":"connected","timestamp":1719456000000}

data: {"value":0.4523, "ts":1719456001000}

data: {"value":0.8912, "ts":1719456002000}
```

## Operational Notes

Streaming enhances user experience but increases server resource occupancy duration. Node.js environments require careful monitoring of concurrent connections. Edge Runtime is recommended for distributing load and ensuring scalability. Adjusting data granularity based on empirical measurements is necessary to prevent overhead from excessively small stream chunks.

</eventsource></t[]></t>