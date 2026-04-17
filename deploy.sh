#!/bin/bash

# [핵심 교정]: 어떤 경로에서 실행하든 프로젝트 루트로 강제 이동
SITE_DIR="/home/ubuntu/bot/k_life/site"
cd "$SITE_DIR" || { echo "❌ Directory not found"; exit 1; }

echo "🚀 Starting Clean Deployment Process in $(pwd)..."

# [v85.1 Editor's Patch]: 빌드 전 리소스 캐시 강제 삭제
# 로고 교체, 사이드바 문구 수정 등 설정 변경 시 '찌꺼기'가 남지 않도록 보장합니다.
echo "🧹 Clearing Hugo resource cache..."
rm -rf resources/_gen

# 1. 빌드 성공 여부 사전 체크 (절대 경로 /snap/bin/hugo 사용 필수)
# --gc (Garbage Collection) 옵션과 함께 실행하여 최적화된 결과물을 생성합니다.
if ! HUGO_ENV=production /snap/bin/hugo --gc --minify --cleanDestinationDir; then
    echo "❌ [ERROR] Hugo build failed! Deployment aborted to save your files."
    exit 1
fi

# 2. CNAME 복구
echo "klifehack.com" > docs/CNAME

echo "📦 Preparing for GitHub push..."

# 3. GitHub 전송 준비
git add .
# 변경사항이 없을 때 에러로 멈추지 않게 처리
git commit -m "Update site content: $(date +'%Y-%m-%d %H:%M:%S')" || echo "[-] No changes to commit."

# 4. GitHub으로 강제 푸시
echo "📤 Pushing to GitHub..."
git push origin main -f

echo "✅ Deployment Complete! Your updates are now live."