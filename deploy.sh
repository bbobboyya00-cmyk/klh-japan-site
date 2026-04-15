#!/bin/bash

# [핵심 교정]: 어떤 경로에서 실행하든 프로젝트 루트로 강제 이동
SITE_DIR="/home/ubuntu/bot/k_life/site"
cd "$SITE_DIR" || { echo "❌ Directory not found"; exit 1; }

echo "🚀 Building Hugo site in $(pwd)..."

# 1. 빌드 성공 여부 사전 체크 (GA 활성화를 위해 production 환경 강제)
if ! HUGO_ENV=production hugo --gc --minify --cleanDestinationDir; then
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

# 4. GitHub으로 강제 푸시 (아까 날아간 것 복구 포함)
echo "📤 Pushing to GitHub..."
git push origin main -f

echo "✅ Deployment Complete!"