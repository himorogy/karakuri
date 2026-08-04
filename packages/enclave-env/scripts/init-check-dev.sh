#!/bin/sh
# dev コンテナ起動時のセキュリティチェック（devcontainer.json の initializeCommand 用）
# ホスト側で実行されるため、exit 1 でコンテナ起動を中断できる。

# Git for Windows を cmd.exe 経由で起動した場合、
# Windows の find.exe ではなく Git Bash 付属の Unix ツールを優先する。
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    PATH="/usr/bin:$PATH"
    ;;
esac
export PATH

if [ ! -f "./enclave-env" ]; then
  echo "⚠️  enclave-env not found, skipping checks"
  exit 0
fi

# shellcheck disable=SC1091
. ./enclave-env

FAIL_FILE=$(mktemp)

# Check 0: prod コンテナが稼働していないか確認（2層 devcontainer モード時）
if [ -n "$PROD_CONTAINER_NAME" ]; then
  if docker ps --filter "name=$PROD_CONTAINER_NAME" --format "{{.Names}}" 2>/dev/null | grep -q .; then
    echo "❌ ERROR: Prod container is already running ($PROD_CONTAINER_NAME)."
    echo "   Stop it before starting the dev container."
    exit 1
  fi
fi

# Check 1: .env.production / secret.env.* must contain only encrypted values
find . -type f \
  -not -path "*/node_modules/*" \
  -not -path "*/.git/*" \
  \( -name ".env.production" -o -name "secret.env.*" \) \
| while read -r FILE; do
  FILE_HEADER_SHOWN=0
  while IFS= read -r line; do
    case "$line" in
      ''|'#'*|DOTENV_PUBLIC_KEY*) continue ;;
    esac
    if ! echo "$line" | grep -qE '^[A-Z0-9_]+="?encrypted:'; then
      if [ "$FILE_HEADER_SHOWN" = "0" ]; then
        echo "❌ ERROR: $FILE contains unencrypted values:"
        FILE_HEADER_SHOWN=1
      fi
      echo "   $line"
      echo "FAILED" > "$FAIL_FILE"
    fi
  done < "$FILE"
done

# Check 2: .env.container must not contain DOTENV_PRIVATE_KEY_PRODUCTION
find . -type f \
  -not -path "*/node_modules/*" \
  -not -path "*/.git/*" \
  -name ".env.container" \
| while read -r FILE; do
  if grep -q "DOTENV_PRIVATE_KEY_PRODUCTION" "$FILE" 2>/dev/null; then
    echo "❌ ERROR: DOTENV_PRIVATE_KEY_PRODUCTION found in $FILE"
    echo "   Production keys must be placed outside the workspace."
    echo "FAILED" > "$FAIL_FILE"
  fi
done

# Check 3: .env.keys* must not exist inside the workspace
find . -type f \
  -not -path "*/node_modules/*" \
  -not -path "*/.git/*" \
  -name ".env.keys*" \
| while read -r FILE; do
  echo "❌ ERROR: Key file found inside the workspace: $FILE"
  echo "   Move it outside the workspace (e.g. ~/.config/<your-project>/)."
  echo "FAILED" > "$FAIL_FILE"
done

if [ -s "$FAIL_FILE" ]; then
  rm -f "$FAIL_FILE"
  exit 1
fi
rm -f "$FAIL_FILE"

echo "✅ enclave-env - security checks passed"
