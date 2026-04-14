#!/bin/bash

# 1. 빌드 (정적 파일 생성 및 유령 페이지 완전 제거)
echo "🚀 Building Hugo site..."
# --cleanDestinationDir: content에서 삭제된 파일의 결과물을 docs 폴더에서도 자동으로 삭제합니다.
/snap/bin/hugo --gc --minify --cleanDestinationDir

# 2. CNAME 복구 (GitHub Pages 커스텀 도메인 유지)
# 빌드 과정에서 docs 폴더가 정리되므로, 도메인 연결을 위해 CNAME 파일을 다시 생성합니다.
echo "klifehack.com" > docs/CNAME

# 3. GitHub 전송 준비
echo "📦 Preparing for GitHub push..."
git add .

# 변경사항이 없을 경우를 대비하여 에러 처리를 포함한 커밋 실행
git commit -m "Update site content: $(date +'%Y-%m-%d %H:%M:%S')" || echo "[-] No changes to commit."

# 4. GitHub으로 푸시 (강제 푸시 -f를 사용하여 로컬과 리모트 동기화 우선)
echo "📤 Pushing to GitHub..."
git push origin main -f

echo "✅ Deployment Complete!"