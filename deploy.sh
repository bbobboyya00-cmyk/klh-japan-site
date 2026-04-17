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
<<<<<<< Updated upstream

# 3. GitHub 전송 준비
=======
# [v94.3 핵심 교정]: 변경사항이 있는 상태에서도 안전하게 원격 데이터를 가져옵니다.
git pull --rebase --autostash origin main

>>>>>>> Stashed changes
git add .
# 변경사항이 없을 때 에러로 멈추지 않게 처리
git commit -m "Update site content: $(date +'%Y-%m-%d %H:%M:%S')" || echo "[-] No changes to commit."

<<<<<<< Updated upstream
# 4. GitHub으로 강제 푸시
echo "📤 Pushing to GitHub..."
git push origin main -f

echo "✅ Deployment Complete! Your updates are now live."
=======
# [v94.3 교정]: 목적지가 사이트 저장소로 바뀌었으므로 이제 안전하게 푸시합니다.
echo "📤 Pushing to klh-japan-site..."
if git push origin main
    echo "✅ Deployment Complete! Your updates are now live."
else
    echo "❌ [ERROR] Git push failed. Checking for remote conflicts..."
    # 마지막 수단으로 한 번 더 리베이스 후 재시도
    git pull --rebase origin main
    git push origin main
fi
>>>>>>> Stashed changes
