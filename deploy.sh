#!/bin/bash

# 1. 빌드 (정적 파일 생성)
echo "🚀 Building Hugo site..."
/snap/bin/hugo --gc --minify

# 2. GitHub 전송 준비
echo "📦 Preparing for GitHub push..."
git add .
git commit -m "Update Japanese posts: $(date +'%Y-%m-%d %H:%M:%S')"

# 3. GitHub으로 푸시 (이미 연결된 리모트로 전송)
echo "📤 Pushing to GitHub..."
git push origin main

echo "✅ Deployment Complete!"