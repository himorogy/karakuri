#!/usr/bin/env bash
#
# 配布物の file mode の検査。
#
# mode と中身のどちらも working tree ではなく index から読む。clone と
# git archive はそのまま index の mode を配る。npm pack が配るのは working
# tree の mode だが (npm 11.17.0 で実測)、その working tree は index からの
# チェックアウトである。手元の working tree を直に見ると、core.fileMode=false
# や exec ビットを持てないファイルシステムで食い違う。
#
# 「実行して使うもの」と「読み込んで使うもの」の区別を shebang の有無で代用
# している。代用は判定の手段で、約束は mode の側にある——shebang の書き方を
# 縛る規約を足しているのではない。
#
# images/runtime-base/bin と images/runtime-base/shims は対象外である。配られる
# のは clone ではなくイメージで、実行権は Dockerfile の chmod が付ける。shebang
# を持つ 100644 がそこに在るのは設計であり、docs/guarantees.md の C-2b が
# そちらを約束として持っている。
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

# 台帳「公開面の定義」のうち、ファイルとして配られる面。
TARGET_DIRS=(
	packages/env-guard/bin
	packages/env-guard/hooks
	packages/egress-guard/scripts
	packages/egress-guard/templates
	host-tools
	images/runtime-base/templates/project
)

PASS=0
FAIL=0

ok() {
	PASS=$((PASS + 1))
	printf '  ok   %s\n' "$1"
}

ng() {
	FAIL=$((FAIL + 1))
	printf '  FAIL %s\n' "$1" >&2
}

die() {
	printf 'FATAL %s\n' "$1" >&2
	exit 1
}

# expected_mode <blob sha>
expected_mode() {
	local head2
	git -C "$REPO_ROOT" cat-file -e "$1" 2>/dev/null || return 0
	head2="$(git -C "$REPO_ROOT" cat-file blob "$1" 2>/dev/null | dd bs=1 count=2 2>/dev/null)"
	if [ "$head2" = '#!' ]; then
		printf '100755\n'
	else
		printf '100644\n'
	fi
}

# check_modes — `git ls-files -s` 形式の一覧を stdin から読み、違反行を stdout に出す。
check_modes() {
	local line mode sha path expected rest
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		mode="${line%% *}"
		rest="${line#* }"
		sha="${rest%% *}"
		path="${line#*$'\t'}"
		expected="$(expected_mode "$sha")"
		if [ -z "$expected" ]; then
			printf '%s: blob %s が読めない\n' "$path" "$sha"
		elif [ "$mode" != "$expected" ]; then
			if [ "$expected" = 100755 ]; then
				printf '%s: shebang があるのに mode %s (期待 100755)\n' "$path" "$mode"
			else
				printf '%s: shebang が無いのに mode %s (期待 100644)\n' "$path" "$mode"
			fi
		fi
	done
}

listing_of() {
	git -C "$REPO_ROOT" ls-files -s -- "$1"
}

count_lines() {
	if [ -z "$1" ]; then
		printf '0\n'
	else
		printf '%s\n' "$1" | wc -l | tr -d ' '
	fi
}

# --- 本番の一覧 ------------------------------------------------------------------

command -v git >/dev/null 2>&1 || die "git が無いので index の mode を読めない"

LISTING=""
for dir in "${TARGET_DIRS[@]}"; do
	listing="$(listing_of "$dir")" || die "git ls-files が失敗した ($dir)"
	count="$(count_lines "$listing")"
	if [ "$count" -ge 1 ]; then
		ok "$dir の tracked ファイルを $count 件読んだ"
	else
		ng "$dir の tracked ファイルが 0 件 (綴り違いか、対象が移動した)"
	fi
	[ -z "$listing" ] || LISTING="${LISTING}${listing}"$'\n'
done

VIOLATIONS="$(printf '%s' "$LISTING" | check_modes)"
if [ -z "$VIOLATIONS" ]; then
	ok "配布物の mode が、実行して使うものと読み込んで使うものの区別と一致する"
else
	ng "配布物の mode が、実行して使うものと読み込んで使うものの区別と一致する"
	printf '%s\n' "$VIOLATIONS" >&2
fi

# --- 否定対照: この検査に検知能力があること ----------------------------------------
#
# blob は実在のものを使う。shebang を読むのは index の中身なので、作り話の
# sha では判定そのものが走らない。

blob_of() {
	git -C "$REPO_ROOT" ls-files -s -- "$1" | awk '{print $2}'
}

HOST_DIR="host-tools"
SHEBANG_BLOB="$(blob_of "$HOST_DIR/host-run.sh")"
PLAIN_BLOB="$(blob_of "$HOST_DIR/karakuri.sh")"
[ -n "$SHEBANG_BLOB" ] || die "否定対照の材料 (host-run.sh) が見つからない"
[ -n "$PLAIN_BLOB" ] || die "否定対照の材料 (karakuri.sh) が見つからない"

sample="100644 $SHEBANG_BLOB 0	$HOST_DIR/host-run.sh"
if [ -n "$(printf '%s\n' "$sample" | check_modes)" ]; then
	ok "否定対照: 実行して使うスクリプトの 100644 を検知する"
else
	ng "否定対照: 実行して使うスクリプトの 100644 を検知する"
fi

sample="100755 $PLAIN_BLOB 0	$HOST_DIR/karakuri.sh"
if [ -n "$(printf '%s\n' "$sample" | check_modes)" ]; then
	ok "否定対照: 読み込んで使うファイルの 100755 を検知する"
else
	ng "否定対照: 読み込んで使うファイルの 100755 を検知する"
fi

# symlink は配布物の中身をリポジトリの外へ向ける経路なので、素通しにしない。
sample="120000 $SHEBANG_BLOB 0	$HOST_DIR/dock.sh"
if [ -n "$(printf '%s\n' "$sample" | check_modes)" ]; then
	ok "否定対照: 100644 / 100755 以外の mode を検知する"
else
	ng "否定対照: 100644 / 100755 以外の mode を検知する"
fi

sample="100755 0000000000000000000000000000000000000000 0	$HOST_DIR/ghost.sh"
if [ -n "$(printf '%s\n' "$sample" | check_modes)" ]; then
	ok "否定対照: 中身を読めない行を通さない"
else
	ng "否定対照: 中身を読めない行を通さない"
fi

sample="100755 $SHEBANG_BLOB 0	$HOST_DIR/host-run.sh
100644 $PLAIN_BLOB 0	$HOST_DIR/karakuri.sh"
if [ -z "$(printf '%s\n' "$sample" | check_modes)" ]; then
	ok "否定対照: 正しい mode の一覧を誤検知しない"
else
	ng "否定対照: 正しい mode の一覧を誤検知しない"
fi

if [ "$(count_lines "$(listing_of "${HOST_DIR}s")")" = 0 ]; then
	ok "否定対照: 綴りの違うディレクトリは 0 件として出る"
else
	ng "否定対照: 綴りの違うディレクトリは 0 件として出る"
fi

# --- result ----------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
