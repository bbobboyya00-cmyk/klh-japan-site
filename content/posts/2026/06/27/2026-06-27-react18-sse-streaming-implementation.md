---
title: "React 18とSSEによる高パフォーマンスなデータストリーミングの実装"
slug: "react18-sse-streaming-implementation"
date: 2026-06-27T10:48:23+09:00
draft: false
image: ""
description: "React 18のSuspenseとSSEを組み合わせ、Edge Runtime上で低遅延なストリーミングを実現する実装手法。プロキシのバッファリング回避や再接続ロジックなど、実務的な運用ポイントを詳説します。"
categories: ["Backend Architecture"]
tags: ["react-18", "server-sent-events", "edge-runtime", "nextjs-app-router", "readablestream"]
author: "K-Life Hack"
---

React 18 Streaming SSRとEdge Runtimeによる低遅延データストリーミングの実装

大規模なレスポンスやAIによるトークン生成など、現代のWebアプリケーションにおいて、全データの受信を待機してからレンダリングを開始する手法は、TTFB（Time to First Byte）の悪化を招き、ユーザー体験を著しく損なう要因となります。特にLLM（大規模言語モデル）の普及に伴い、データを逐次的に送信する「Send Incrementally」の設計思想は、フロントエンド・アーキテクチャにおける必須要件となりつつあります。

本稿では、React 18のStreaming SSRとServer-Sent Events（SSE）を組み合わせ、Edge Runtime上で低遅延なデータストリーミングを実現するための実装パターンと、プロキシ環境下でのバッファリング回避といった実務上の摩擦点について解説します。

## 1. React 18 SuspenseによるHTMLストリーミング

Next.jsのApp Router環境では、Suspense境界を利用することで、サーバー側で解決したコンポーネントから順次クライアントへ送信することが可能です。これにより、重いデータ取得を伴うセクションの完了を待たずに、ページのシェル（ヘッダーやナビゲーション）を即座に表示できます。

```javascript
import { Suspense } from 'react';

async function SlowSection() {
  // 意図的な遅延を伴うデータ取得
  const data = await fetch('https://api.example.com/slow-endpoint', {
    cache: 'no-store'
  }).then((res) =&gt; res.json());

  return (
    <section classname="p-4 border rounded">
<h2>データ処理完了</h2>
メッセージ: {data.message}


</section>
  );
}

export default function Page() {
  return (
    <main classname="container mx-auto">
<h1>ストリーミングSSRデモ</h1>
      {/* SlowSectionの解決を待たずにフォールバックが即座に送信される */}
      <suspense classname="animate-pulse" fallback="{&lt;div">読み込み中...}&gt;
        <slowsection></slowsection>
</suspense>
</main>
  );
}
```

## 2. Server-Sent Events (SSE) と Edge Runtime の統合

一方向のリアルタイム通信を実現するSSEは、WebSocketと比較してHTTPプロトコルとの親和性が高く、実装が容易です。Edge Runtimeを使用することで、ユーザーに近いPoP（Point of Presence）からストリームを開始し、ネットワーク遅延を最小化できます。

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

      // 初期データの送信
      send({ status: 'connected', timestamp: Date.now() });

      // 擬似的なデータプッシュ
      const timer = setInterval(() =&gt; {
        send({ value: Math.random(), ts: Date.now() });
      }, 1000);

      // プロキシのタイムアウトを防ぐためのハートビート（15秒間隔）
      const heartbeat = setInterval(() =&gt; {
        controller.enqueue(encoder.encode(':keep-alive

'));
      }, 15000);

      // 接続終了時のクリーンアップ
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
      'X-Accel-Buffering': 'no' // NGINX等のバッファリングを無効化
    }
  });
}
```

## 3. クライアントサイドでのストリーム消費

ブラウザ標準のEventSource APIをReactのライフサイクル内で安全に管理するために、カスタムフックを構築します。

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

## 4. NDJSON (Newline Delimited JSON) による代替アプローチ

EventSourceが制限されている環境や、より柔軟なHTTPメソッド（POST等）でストリーミングを行いたい場合は、NDJSON形式が有効です。

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
    buffer = lines.pop() || ''; // 不完全な行をバッファに保持

    for (const line of lines) {
      if (line.trim()) {
        onChunk(JSON.parse(line));
      }
    }
  }
}
```

## Troubleshooting

ストリーミング実装において最も頻繁に遭遇する問題は、中間インフラによるバッファリングです。

💡 <b>NGINXのバッファリング</b>: デフォルトではNGINXはレスポンスをバッファリングします。X-Accel-Buffering: no ヘッダーを付与するか、設定ファイルで proxy_buffering off; を指定する必要があります。

⚠️ <b>Cloudflareの制限</b>: Cloudflare等のCDNを経由する場合、ストリームが一定時間（デフォルト100秒等）で切断されることがあります。定期的なハートビート送信が不可欠です。

🛠️ <b>Mobile Safariの挙動</b>: iOSのSafariでは、バックグラウンドに移行した際にSSE接続が即座に切断される傾向があります。ページ復帰時の再接続ロジックを実装してください。

```text
# ヘッダーの確認
$ curl -I http://localhost:3000/api/stream
HTTP/1.1 200 OK
Content-Type: text/event-stream; charset=utf-8
Cache-Control: no-cache, no-transform
Connection: keep-alive
X-Accel-Buffering: no

# ストリームのリアルタイム受信テスト (-N はバッファリング無効化)
$ curl -N http://localhost:3000/api/stream
data: {"status":"connected","timestamp":1719456000000}

data: {"value":0.4523, "ts":1719456001000}

data: {"value":0.8912, "ts":1719456002000}
```

## Operational Notes

ストリーミングはユーザー体験を劇的に向上させますが、サーバーリソースの占有時間が長くなるという側面も持ちます。特にNode.js環境では同時接続数に注意が必要です。Edge Runtimeを活用することで、これらの負荷を分散し、スケーラビリティを確保することが推奨されます。また、ストリームのチャンクサイズが極端に小さい場合、オーバーヘッドが増大するため、実測値に基づいた適切なデータ粒度の調整が求められます。</eventsource></t[]></t>