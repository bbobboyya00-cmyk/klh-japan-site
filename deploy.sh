#!/bin/bash

# [1단계] 경로 이동 및 환경 설정
SITE_DIR="/home/ubuntu/k_life/site"
cd "$SITE_DIR" || { echo "❌ Directory not found"; exit 1; }

echo "🚀 Starting Clean Deployment Process..."

# [2단계] 사전 동기화 (CRITICAL)
# 빌드(hugo)를 하기 전에 먼저 원격의 최신 소스를 가져와야 컨플릭트가 나지 않습니다.
git pull --rebase origin main

# [3단계] 리소스 정리 및 빌드
echo "🧹 Clearing Hugo resource cache..."
rm -rf resources/_gen

if ! hugo --gc --minify --cleanDestinationDir; then
    echo "❌ [ERROR] Hugo build failed!"
    exit 1
fi

# [4단계] CNAME 복구
echo "klifehack.com" > docs/CNAME

# [5단계] 변경사항 반영 및 푸시
echo "📦 Preparing for GitHub push..."
git add .

# 변경사항이 없을 경우를 대비해 commit 성공 여부 상관없이 진행
git commit -m "Update site content: $(date +'%Y-%m-%d %H:%M:%S')" || echo "[-] No changes to commit."

echo "📤 Pushing to klh-japan-site..."
git push origin main

# [교정]: dash/sh 호환성을 위해 [ $? -eq 0 ] 방식 사용
if [ $? -eq 0 ]; then
    echo "✅ Deployment Complete! Your updates are now live."
else
    echo "❌ [ERROR] Git push failed. Try manual push."
    exit 1
fi