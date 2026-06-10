---
title: "Spring BootとReactにおけるステートレスなJWT認証基盤への移行実装"
slug: "spring-boot-react-jwt-migration-guide"
date: 2026-06-10T18:54:11+09:00
draft: false
image: ""
description: "セッションベースの認証からJWT（Access/Refresh Token）への移行プロセスを詳述。Spring BootとReactを用いた実装、二重リクエスト対策、運用メトリクスの改善結果を解説します。"
categories: ["Backend Architecture"]
tags: ["spring-boot", "spring-security", "jwt", "react", "axios-interceptor", "stateless-auth"]
author: "K-Life Hack"
---

# モダンなウェブアプリケーションにおけるスケーラブルな認証基盤の構築：セッションベースからJWTへの移行戦略

モダンなウェブアプリケーションのスケーラビリティにおいて、認証・認可のアーキテクチャは単なるセキュリティ要件を超え、システムの可用性と運用安定性を左右する重要な柱となります。Spring BootによるREST APIとReact SPA（Single Page Application）を組み合わせた分離型アーキテクチャでは、認証状態の管理、トークンの有効期限、およびサイレント・リフレッシュの戦略がシステムの回復力に直結します。

本稿では、CORNERSTONE（cornerstone.io.kr）が実施した、従来のステートフルなサーバーサイドセッションモデルから、デュアルトークンローテーション（Access/Refresh Token）を利用したステートレスなJWTモデルへの移行プロセスについて、技術的な詳細を記述します。

## 既存セッションベースアーキテクチャの課題

移行前のシステムは、Spring Bootの標準的なセッション管理に依存していました。トラフィックの増大に伴い、以下の運用上のボトルネックが顕在化しました。

- <b>セッションクラスタリングの運用負荷</b>: 水平スケーリング時にスティッキーセッションやRedisによる分散セッションストアの管理が必要となり、インフラの複雑性が増大しました。
- <b>デプロイ時の認証不整合</b>: ローリングアップデートやオートスケーリングによるインスタンスの終了時、セッションの同期遅延によりユーザーが予期せずログアウトされる事象が発生しました。
- <b>エラーハンドリングの不一致</b>: 認証失敗時にバックエンドが302リダイレクトや500エラーを返すことがあり、SPA側で有効期限切れとサーバーエラーをプログラム的に判別することが困難でした。

これらの課題を解決するため、信頼性、セキュリティ、運用利便性、開発速度の優先順位に基づき、ステートレスなJWTアーキテクチャへの移行を決定しました。

## ターゲットアーキテクチャとセキュリティポリシー

設計されたJWT認証基盤は、トークンの分離、安全な保存、および標準化されたエラーコントラクトに基づいています。

| トークン種別 | 有効期限 | 保存場所 | 送信メカニズム |
| :--- | :--- | :--- | :--- |
| Access Token | 15分 | クライアントメモリ (React) | Authorization Header (Bearer) |
| Refresh Token | 14日間 | HttpOnly, Secure, SameSite=Lax Cookie | Cookie Header (自動送信) |

### 主要なセキュリティポリシー

- <b>Access Token</b>: XSS攻撃によるトークン奪取を防ぐため、`localStorage`等には保存せず、メモリ内でのみ保持します。
- <b>Refresh Token</b>: JavaScriptからのアクセスを遮断する`HttpOnly`属性を付与し、HTTPS通信のみを許可する`Secure`属性を適用します。
- <b>認可モデル</b>: ロールベースアクセス制御（RBAC）を採用し、JWTのペイロードにクレームとしてロールを含めることで、DB照会なしでの認可チェックを可能にします。

## バックエンド実装：Spring Boot

リクエストごとにAuthorizationヘッダーからトークンを抽出し、署名と有効期限を検証する`JwtAuthenticationFilter`の構成により、ステートレスな検証プロセスを実現しています。

```java
package io.cornerstone.security.jwt;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;

@Component
@RequiredArgsConstructor
public class JwtAuthenticationFilter extends OncePerRequestFilter {

    private final JwtTokenProvider jwtTokenProvider;
    private static final String AUTHORIZATION_HEADER = "Authorization";
    private static final String BEARER_PREFIX = "Bearer ";

    @Override
    protected void doFilterInternal(HttpServletRequest request, 
                                    HttpServletResponse response, 
                                    FilterChain filterChain) throws ServletException, IOException {
        
        String token = resolveAccessToken(request);

        if (StringUtils.hasText(token) &amp;&amp; jwtTokenProvider.validateAccessToken(token)) {
            Authentication authentication = jwtTokenProvider.getAuthentication(token);
            SecurityContextHolder.getContext().setAuthentication(authentication);
        }

        filterChain.doFilter(request, response);
    }

    private String resolveAccessToken(HttpServletRequest request) {
        String bearerToken = request.getHeader(AUTHORIZATION_HEADER);
        if (StringUtils.hasText(bearerToken) &amp;&amp; bearerToken.startsWith(BEARER_PREFIX)) {
            return bearerToken.substring(BEARER_PREFIX.length());
        }
        return null;
    }
}
```

## フロントエンド実装：Axiosインターセプターによる二重リクエスト制御

トークンの有効期限が切れた際、複数のAPIリクエストが同時に401エラーを発生させる「リフレッシュ・ストーム」を防ぐため、後続のリクエストを一時的に保留し、トークン再発行後に一括実行するキューイングメカニズムを構築しました。

```javascript
import axios from 'axios';

const api = axios.create({
  baseURL: 'https://api.cornerstone.io.kr',
  withCredentials: true
});

let isRefreshing = false;
let failedQueue = [];

const processQueue = (error, token = null) =&gt; {
  failedQueue.forEach((prom) =&gt; {
    if (error) {
      prom.reject(error);
    } else {
      prom.resolve(token);
    }
  });
  failedQueue = [];
};

api.interceptors.response.use(
  (response) =&gt; response,
  async (error) =&gt; {
    const originalRequest = error.config;

    if (error.response?.status === 401 &amp;&amp; !originalRequest._retry) {
      if (isRefreshing) {
        return new Promise((resolve, reject) =&gt; {
          failedQueue.push({ resolve, reject });
        })
          .then((token) =&gt; {
            originalRequest.headers.Authorization = `Bearer ${token}`;
            return api(originalRequest);
          })
          .catch((err) =&gt; Promise.reject(err));
      }

      originalRequest._retry = true;
      isRefreshing = true;

      return new Promise((resolve, reject) =&gt; {
        axios.post('https://api.cornerstone.io.kr/auth/refresh', {}, { withCredentials: true })
          .then((res) =&gt; {
            const newAccessToken = res.data.accessToken;
            // メモリ内のトークンストアを更新
            originalRequest.headers.Authorization = `Bearer ${newAccessToken}`;
            processQueue(null, newAccessToken);
            resolve(api(originalRequest));
          })
          .catch((err) =&gt; {
            processQueue(err, null);
            window.location.href = '/login?expired=true';
            reject(err);
          })
          .finally(() =&gt; {
            isRefreshing = false;
          });
      });
    }
    return Promise.reject(error);
  }
);
```

## 運用のトラブルシューティングとエッジケース

### 1. クライアントとサーバーの時刻同期（Clock Skew）
クライアント側でJWTの`exp`クレームを検証すると、端末の時刻設定のズレにより無限リダイレクトが発生するリスクがありました。これを回避するため、クライアント側での事前検証を廃止し、サーバーからの401レスポンスのみをトリガーとする設計に変更しました。また、サーバー側ではネットワーク遅延を考慮し、60秒のリーウェイ（許容誤差）を設定しています。

### 2. マルチタブ間の認証状態同期

あるタブでログアウトが発生した場合、他のタブが古いメモリ内トークンを保持し続ける問題がありました。これを解決するため、`StorageEvent` APIを利用してブラウザタブ間の認証状態を同期させるロジックを実装しました。

```javascript
window.addEventListener('storage', (event) =&gt; {
  if (event.key === 'cornerstone_logout_event') {
    // メモリ内トークンの消去とリダイレクト
    window.location.href = '/login?expired=true';
  }
});
```

## 運用メトリクスの改善結果

移行後90日間の観測データに基づき、インフラの安定性とユーザー体験の両面で顕著な改善が確認されました。

- <b>認証関連のサポートチケット</b>: 月平均32件から11件へ減少（-65.6%）
- <b>ピーク時の認証失敗率</b>: 3.1%から0.9%へ改善（-2.2%p）
- <b>トークン再発行の平均レイテンシ</b>: 240msから130msへ短縮（-45.8%）

## Lessons Learned

ステートフルなセッションからステートレスなJWTへの移行において、最も重要なのは技術の選択そのものではなく、トークンの保存、有効期限、およびエラーハンドリングに関する一貫したポリシーの策定です。特に、同時実行リクエストによるリフレッシュ・ストームや、クライアント側の時刻同期の不一致といったエッジケースを設計段階で考慮することが、本番環境での安定稼働に不可欠です。CORNERSTONEでは、フロントエンドとバックエンド間の厳格なAPIコントラクトを確立することで、スケーラブルで耐障害性の高い認証基盤を構築することができました。