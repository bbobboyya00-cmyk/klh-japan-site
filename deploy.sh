#!/bin/bash

# [1단계] 경로 이동 및 환경 설정
SITE_DIR="/home/ubuntu/k_life/site"
cd "$SITE_DIR" || { echo "❌ Directory not found"; exit 1; }

echo "🚀 Starting Clean Deployment Process..."

# [2단계] 사전 동기화 (교정: -X ours 삭제)
# [이유]: -X ours는 API로 올라간 이미지 커밋을 '충돌'로 간주해 지워버릴 위험이 큽니다.
# 안전하게 원격의 변경사항(API 커밋 등)을 가져온 뒤 진행합니다.
git fetch origin main
git rebase origin/main || { echo "❌ Rebase failed. Please check manual conflicts."; exit 1; }

# [3단계] 리소스 정리 및 빌드
# [교정]: rm -rf resources/_gen 삭제
# [이유]: 원본 유실 시 resources/_gen은 유일한 '복구용 파편'입니다. 
# Hugo의 --gc 옵션만으로도 충분히 관리가 가능하므로 강제 삭제는 금지합니다.
echo "🧹 Running Hugo Garbage Collection & Build..."

if ! hugo -D -F --gc --minify --cleanDestinationDir; then
    echo "❌ [ERROR] Hugo build failed!"
    exit 1
fi

# [4단계] CNAME 복구
echo "klifehack.com" > docs/CNAME

# [5단계] 변경사항 반영 및 푸시
echo "📦 Preparing for GitHub push..."
git add .
# 변경사항이 없을 때 에러로 멈추지 않도록 처리
git commit -m "Site recovery: Force build all posts $(date +'%Y-%m-%d %H:%M:%S')" || echo "[-] No changes to commit."

echo "📤 Pushing to klh-japan-site..."
# [주의]: force push는 절대 금지입니다. rebase 후 일반 push를 사용합니다.
if git push origin main; then
    echo "✅ Deployment Complete! Your updates are now live."
else
    echo "❌ [ERROR] Git push failed."
    exit 1
fi