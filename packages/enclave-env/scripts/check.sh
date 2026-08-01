#!/bin/sh
#
# Pre-commit hook: checks that staged .env* and secret.env.* files contain only encrypted values.

for file in $(git diff --cached --name-only | grep -E '(^|/)\.env|(^|/)secret\.env\.'); do
  if [ ! -f "$file" ]; then
    continue
  fi

  case "$file" in
    *.env.container.example) continue ;;
  esac

  while IFS= read -r line; do
    case "$line" in
      ''|'#'*|DOTENV_PUBLIC_KEY*) continue ;;
    esac

    if ! echo "$line" | grep -qE '^[A-Z0-9_]+="?encrypted:'; then
      echo "❌ Error: $file contains unencrypted value:"
      echo "  $line"
      echo "  Run: pnpm dotenvx encrypt"
      exit 1
    fi
  done < "$file"
done
