#!/bin/bash

# [핀셋 수정]: 스크립트가 위치한 경로(site)로 강제 이동
cd "/home/ubuntu/bot/k_life/site"

# 1. 빌드 (정적 파일 생성 및 유령 페이지 완전 제거)
echo "🚀 Building Hugo site in $(pwd)..."
/snap/bin/hugo --gc --minify --cleanDestinationDir

# 2. CNAME 복구
echo "klifehack.com" > docs/CNAME

# 3. GitHub 전송 준비
echo "📦 Preparing for GitHub push..."
git add .
git commit -m "Update site content: $(date +'%Y-%m-%d %H:%M:%S')" || echo "[-] No changes to commit."

# 4. GitHub으로 푸시
echo "📤 Pushing to GitHub..."
git push origin main -f

echo "✅ Deployment Complete!"