#!/bin/bash

# [1단계] 경로 이동 및 환경 설정
SITE_DIR="/home/ubuntu/k_life/site"
cd "$SITE_DIR" || { echo "❌ Directory not found"; exit 1; }

echo "🚀 Starting Clean Deployment Process..."

# ==========================================
# [NEW] 스마트 삭제 감지 및 DB 자동 청소 엔진 (v2605.225 TA 패치)
# 파일 이동(Move)으로 인한 오탐지를 방어하기 위해 물리적 생존 여부를 교차 검증합니다.
# ==========================================
DELETED_FILES=$(git ls-files --deleted | grep 'content/posts/.*\.md$')

if [ -n "$DELETED_FILES" ]; then
    echo "=========================================="
    echo "🧹 [자동 감지] 삭제된 마크다운 파일 추적 및 DB 청소 가동"
    echo "=========================================="
    
    for FILE in $DELETED_FILES; do
        BASENAME=$(basename "$FILE")
        SLUG=$(echo "$BASENAME" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//' | sed 's/\.md$//')
        
        if [ -n "$SLUG" ]; then
            # 🛡️ [TA 안전 가드] Git이 삭제됐다고 해도, 하위 폴더 어딘가에 물리적 파일이 살아있는지 전수 조사
            ALIVE_FILE=$(find content/posts -name "*${SLUG}.md" -print -quit)
            
            if [ -n "$ALIVE_FILE" ]; then
                echo "[!] 파일 이동 감지: '$SLUG' 파일이 삭제되지 않고 하위 폴더로 이동되었습니다. DB 말소를 방어(Bypass)합니다."
                continue # DB 삭제 로직을 건너뜀
            fi

            echo "[-] 삭제 타겟 감지: $SLUG"
            
            TARGET_KEYWORD=$(sqlite3 /home/ubuntu/k_life/khack_posts.db "SELECT keywords FROM published_posts WHERE url LIKE '%$SLUG%' LIMIT 1;")
            
            if [ -n "$TARGET_KEYWORD" ]; then
                echo "[-] 연동된 키워드 획득: '$TARGET_KEYWORD'. 관련 EN/JP 트랙 전체를 말소합니다."
                sqlite3 /home/ubuntu/k_life/khack_posts.db "DELETE FROM source_history WHERE post_id IN (SELECT id FROM published_posts WHERE keywords = '$TARGET_KEYWORD');"
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