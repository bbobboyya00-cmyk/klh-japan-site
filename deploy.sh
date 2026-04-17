#!/bin/bash

# [1단계] 경로 이동 및 환경 설정
SITE_DIR="/home/ubuntu/k_life/site"
cd "$SITE_DIR" || { echo "❌ Directory not found"; exit 1; }

echo "🚀 Starting Clean Deployment Process..."

# [2단계] 사전 동기화 및 충돌 강제 해결
# pull 시 발생하는 충돌을 방지하기 위해 원격 데이터를 먼저 정렬합니다.
git fetch origin main
git merge -s recursive -X ours origin/main --no-edit

# [3단계] 리소스 정리 및 빌드 (중요: -D -F 옵션 추가)
echo "🧹 Clearing Hugo resource cache..."
rm -rf resources/_gen

# [교정]: 페이지 누락 방지를 위해 드래프트(-D)와 미래 날짜(-F) 글을 강제로 포함합니다.
if ! hugo -D -F --gc --minify --cleanDestinationDir; then
    echo "❌ [ERROR] Hugo build failed!"
    exit 1
fi

# [4단계] CNAME 복구
echo "klifehack.com" > docs/CNAME

# [5단계] 변경사항 반영 및 푸시
echo "📦 Preparing for GitHub push..."
git add .
git commit -m "Site recovery: Force build all posts $(date +'%Y-%m-%d %H:%M:%S')" || echo "[-] No changes to commit."

echo "📤 Pushing to klh-japan-site..."
# [인증]: 이미 토큰이 주입된 주소를 사용 중이므로 바로 푸시됩니다.
if git push origin main; then
    echo "✅ Deployment Complete! Your updates are now live."
else
    echo "❌ [ERROR] Git push failed."
    exit 1
fi