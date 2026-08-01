#!/bin/sh
set -e

# main ブランチであることを確認
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "main" ]; then
  echo "Error: release must be run on main branch (current: ${BRANCH})."
  exit 1
fi

# changeset ファイルの存在確認
COUNT=$(ls .changeset/*.md 2>/dev/null | grep -v README | wc -l)
if [ "$COUNT" -eq 0 ]; then
  echo "Error: no changeset files found. Run 'pnpm changeset add' first."
  exit 1
fi

# バージョン更新・CHANGELOG 生成
pnpm changeset version

VERSION=$(node -p "require('./package.json').version")

# git コミット・タグ・push
git add .
git commit -m "chore: release v${VERSION}"
git tag "v${VERSION}"
git push origin main --tags

echo ""
echo "v${VERSION} pushed. Starting publish..."
echo ""

# publish
npm login
npm publish --access public
