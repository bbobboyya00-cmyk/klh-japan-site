#!/bin/bash

# [1단계] 경로 이동 및 환경 설정
SITE_DIR="/home/ubuntu/k_life/site"
cd "$SITE_DIR" || { echo "❌ Directory not found"; exit 1; }

echo "🚀 Starting Clean Deployment Process..."

# ==========================================
# [NEW] 스마트 삭제 감지 및 DB 자동 청소 엔진
# WinSCP에서 .md 파일을 삭제하면, Git이 변경사항을 추적하여 자동으로 DB를 말소합니다.
# ==========================================
# 아직 commit되지 않은(삭제된) md 파일 목록 추출
DELETED_FILES=$(git ls-files --deleted | grep 'content/posts/.*\.md$')

if [ -n "$DELETED_FILES" ]; then
    echo "=========================================="
    echo "🧹 [자동 감지] 삭제된 마크다운 파일 추적 및 DB 청소 가동"
    echo "=========================================="
    
    for FILE in $DELETED_FILES; do
        # 파일명 추출 (예: 2026-04-18-yangpyeong-song-barbecue-backribs.md)
        BASENAME=$(basename "$FILE")
        # 날짜(YYYY-MM-DD-) 및 확장자(.md)를 잘라내어 순수 슬러그만 확보
        SLUG=$(echo "$BASENAME" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//' | sed 's/\.md$//')
        
        if [ -n "$SLUG" ]; then
            echo "[-] 삭제 타겟 감지: $SLUG"
            
            # 1. DB에서 해당 슬러그를 보유한 레코드의 '공통 키워드(예: 쏭바베큐)'를 역추적
            TARGET_KEYWORD=$(sqlite3 /home/ubuntu/k_life/khack_posts.db "SELECT keywords FROM published_posts WHERE url LIKE '%$SLUG%' LIMIT 1;")
            
            if [ -n "$TARGET_KEYWORD" ]; then
                echo "[-] 연동된 키워드 획득: '$TARGET_KEYWORD'. 관련 EN/JP 트랙 전체를 말소합니다."
                
                # 2. 해당 키워드로 엮인 모든 포스팅(영어, 일어)의 source_history 삭제
                sqlite3 /home/ubuntu/k_life/khack_posts.db "DELETE FROM source_history WHERE post_id IN (SELECT id FROM published_posts WHERE keywords = '$TARGET_KEYWORD');"
                
                # 3. published_posts에서 해당 키워드 기록 영구 삭제
                sqlite3 /home/ubuntu/k_life/khack_posts.db "DELETE FROM published_posts WHERE keywords = '$TARGET_KEYWORD';"
            else
                echo "[-] DB 매칭 키워드 없음. 슬러그 기반 단독 삭제를 진행합니다."
                sqlite3 /home/ubuntu/k_life/khack_posts.db "DELETE FROM source_history WHERE post_id IN (SELECT id FROM published_posts WHERE url LIKE '%$SLUG%');"
                sqlite3 /home/ubuntu/k_life/khack_posts.db "DELETE FROM published_posts WHERE url LIKE '%$SLUG%';"
            fi
        fi
    done
    echo "✅ 삭제된 파일에 대한 DB 스마트 청소 완료."
fi

# [2단계] 사전 동기화 및 충돌 방지 (v145.0 TA 교정본)
echo "📦 Syncing manual changes from WinSCP..."
git add .
git commit -m "Auto sync: Manual changes before deployment $(date +'%Y-%m-%d %H:%M:%S')" || echo "[-] No manual changes to sync."

echo "🔄 Reversing remote updates (API Commits)..."
git fetch origin main
if ! git rebase origin/main; then
    echo "❌ [CRITICAL] Rebase failed. Please check manual conflicts in $SITE_DIR"
    exit 1
fi

# [3단계] 리소스 정리 및 빌드
echo "🧹 Running Hugo Garbage Collection & Build..."
if ! hugo -D -F --gc --minify --cleanDestinationDir; then
    echo "❌ [ERROR] Hugo build failed!"
    exit 1
fi

# [4단계] CNAME 복구
echo "klifehack.com" > docs/CNAME

# [5단계] 최종 결과물 반영 및 푸시
echo "📦 Preparing for final GitHub push..."
git add .
git commit -m "Site recovery: Force build all posts $(date +'%Y-%m-%d %H:%M:%S')" || echo "[-] No changes to commit."

echo "📤 Pushing to klh-japan-site..."
if git push origin main; then
    echo "✅ Deployment Complete! Your updates are now live."
else
    echo "❌ [ERROR] Git push failed. GitHub status or network check required."
    exit 1
fi