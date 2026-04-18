#!/bin/bash

# [1단계] 경로 이동 및 환경 설정
SITE_DIR="/home/ubuntu/k_life/site"
cd "$SITE_DIR" || { echo "❌ Directory not found"; exit 1; }

echo "🚀 Starting Clean Deployment Process..."

# [2단계] 사전 동기화 및 충돌 방지 (v145.0 TA 교정본)
# [이유]: WinSCP 수동 수정/삭제(Unstaged changes)가 있을 경우 rebase가 실패하는 현상을 방지.
# rebase 실행 전, 현재 로컬의 모든 변화를 일단 기록(Commit)하여 작업 트리를 깨끗하게 만듭니다.
echo "📦 Syncing manual changes from WinSCP..."
git add .
git commit -m "Auto sync: Manual changes before deployment $(date +'%Y-%m-%d %H:%M:%S')" || echo "[-] No manual changes to sync."

echo "🔄 Reversing remote updates (API Commits)..."
git fetch origin main
# -X ours 옵션 없이 표준 rebase를 수행하여 로컬 수정본과 API 업로드 이미지를 안전하게 병합합니다.
if ! git rebase origin/main; then
    echo "❌ [CRITICAL] Rebase failed. Please check manual conflicts in $SITE_DIR"
    exit 1
fi

# [3단계] 리소스 정리 및 빌드
# [교정]: Hugo의 --gc 및 --cleanDestinationDir 옵션을 사용하여 구형 리소스를 안전하게 관리합니다.
echo "🧹 Running Hugo Garbage Collection & Build..."
if ! hugo -D -F --gc --minify --cleanDestinationDir; then
    echo "❌ [ERROR] Hugo build failed!"
    exit 1
fi

# [4단계] CNAME 복구 (배포 시 도메인 연결 유지)
echo "klifehack.com" > docs/CNAME

# [5단계] 최종 결과물 반영 및 푸시
echo "📦 Preparing for final GitHub push..."
git add .
# 빌드 결과물(docs/) 변화가 없을 때 에러로 멈추지 않도록 처리
git commit -m "Site recovery: Force build all posts $(date +'%Y-%m-%d %H:%M:%S')" || echo "[-] No changes to commit."

echo "📤 Pushing to klh-japan-site..."
# [주의]: force push는 금지하며, rebase로 정렬된 이력을 일반 push로 올립니다.
if git push origin main; then
    echo "✅ Deployment Complete! Your updates are now live."
else
    echo "❌ [ERROR] Git push failed. GitHub status or network check required."
    exit 1
fi