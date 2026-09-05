#!/usr/bin/env bash
#
# 配布物 (images/runtime-base/templates/host) の file mode の検査。
#
# host/ の中身はホスト側へそのまま配られ、karakuri.sh から名前で呼ばれる。
# 実行ビットが落ちていると、利用側は最初のコマンドで止まり、そこから先の
# 検証に着手すらできない。実際に host-run.sh が mode 100644 で記録された
# まま配られ、clone した全ホストで `karakuri-run` が失敗した。
#
# 検査の対象は working tree ではなく git の index である。配られるのは
# clone や git archive の結果であり、そこに載るのは index が持っている
# mode だからである。working tree 側の mode は、exec ビットを持てない
# ファイルシステムや core.fileMode=false の環境で簡単に食い違う。
#
# 見るのは「実行して使うもの」と「読み込んで使うもの」の区別と mode の一致で
# ある。判定は shebang の有無で代用する——これは検査の手段であって、約束の
# 一部ではない（「実行するスクリプトには shebang を書く」という別の規約を
# 足しているのではない）。ファイルの一覧を持たないのは、区別が既にファイル
# 自身に書かれているためである。一覧を別に置くと同じ判断の二重管理になり、
# host/ にファイルが増えるたび一覧の更新漏れという別の壊れ方を作る。
#
# 中身も index から読む。working tree の shebang と index の mode を突き
# 合わせると、どちらか一方だけがコミットされた状態で判定がずれる。
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOST_DIR="images/runtime-base/templates/host"

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

# expected_mode <blob sha> — 期待する mode を stdout に出す。
# blob が読めなければ空を出す (呼び出し側が失敗として扱う)。
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

# check_modes — `git ls-files -s` 形式の一覧を stdin から読み、期待と違う行を
# stdout に出す。違反が無ければ何も出さない。
#
# 一覧を引数ではなく stdin で受けるのは、下の否定対照で壊した一覧を流し込んで
# 検知能力を確かめるためである。
check_modes() {
	local line mode sha path expected rest
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		mode="${line%% *}"
		rest="${line#* }"
		sha="${rest%% *}"
		path="${line#*$'\t'}"
		path="${path#"$HOST_DIR"/}"
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

# --- 本番の一覧 ------------------------------------------------------------------

command -v git >/dev/null 2>&1 || die "git が無いので index の mode を読めない"

LISTING="$(git -C "$REPO_ROOT" ls-files -s -- "$HOST_DIR")" ||
	die "git ls-files が失敗した ($HOST_DIR)"

[ -n "$LISTING" ] || die "$HOST_DIR に tracked ファイルが 1 件も無い"

# 対象が丸ごと移動した場合に「0 件見て緑」へ倒れないよう、既知の下限を置く。
# 件数そのものに意味は無く、一覧が空でないことより一段強い歯止めとして使う。
COUNT="$(printf '%s\n' "$LISTING" | wc -l | tr -d ' ')"
if [ "$COUNT" -ge 10 ]; then
	ok "$HOST_DIR の tracked ファイルを $COUNT 件読んだ"
else
	ng "$HOST_DIR の tracked ファイルが $COUNT 件しか無い (対象が移動した可能性)"
fi

VIOLATIONS="$(printf '%s\n' "$LISTING" | check_modes)"
if [ -z "$VIOLATIONS" ]; then
	ok "配布物の mode が、実行して使うものと読み込んで使うものの区別と一致する"
else
	ng "配布物の mode が、実行して使うものと読み込んで使うものの区別と一致する"
	printf '%s\n' "$VIOLATIONS" >&2
fi

# --- 否定対照: この検査に検知能力があること ----------------------------------------
#
# 「検査が緑であること」と「検査に検知能力があること」は別である。既知の
# 壊れ方を流し込んで、実際に引っかかることを確かめる。
#
# blob は実在のものを使う。shebang を読むのは index の中身なので、作り話の
# sha では判定そのものが走らない。

blob_of() {
	git -C "$REPO_ROOT" ls-files -s -- "$HOST_DIR/$1" | awk '{print $2}'
}

SHEBANG_BLOB="$(blob_of host-run.sh)"
PLAIN_BLOB="$(blob_of karakuri.sh)"
[ -n "$SHEBANG_BLOB" ] || die "否定対照の材料 (host-run.sh) が見つからない"
[ -n "$PLAIN_BLOB" ] || die "否定対照の材料 (karakuri.sh) が見つからない"

# 実際に踏んだ壊れ方。shebang を持つスクリプトが 100644 で記録されている。
sample="100644 $SHEBANG_BLOB 0	$HOST_DIR/host-run.sh"
if [ -n "$(printf '%s\n' "$sample" | check_modes)" ]; then
	ok "否定対照: 実行して使うスクリプトの 100644 を検知する"
else
	ng "否定対照: 実行して使うスクリプトの 100644 を検知する"
fi

# 逆向き。source されるだけのファイルに実行ビットが立っている。
sample="100755 $PLAIN_BLOB 0	$HOST_DIR/karakuri.sh"
if [ -n "$(printf '%s\n' "$sample" | check_modes)" ]; then
	ok "否定対照: 読み込んで使うファイルの 100755 を検知する"
else
	ng "否定対照: 読み込んで使うファイルの 100755 を検知する"
fi

# symlink (120000) も期待と一致しないので落ちる。配布物の中身がリポジトリの
# 外を指す形に差し替わったときに素通しにしない。
sample="120000 $SHEBANG_BLOB 0	$HOST_DIR/dock.sh"
if [ -n "$(printf '%s\n' "$sample" | check_modes)" ]; then
	ok "否定対照: 100644 / 100755 以外の mode を検知する"
else
	ng "否定対照: 100644 / 100755 以外の mode を検知する"
fi

# index に無い blob を指す行は、shebang が読めないので判定できない。
# 「読めなかったから通す」へ倒れないことを確かめる。
sample="100755 0000000000000000000000000000000000000000 0	$HOST_DIR/ghost.sh"
if [ -n "$(printf '%s\n' "$sample" | check_modes)" ]; then
	ok "否定対照: 中身を読めない行を通さない"
else
	ng "否定対照: 中身を読めない行を通さない"
fi

# 誤検知の対照。正しい組み合わせは通ること。
sample="100755 $SHEBANG_BLOB 0	$HOST_DIR/host-run.sh
100644 $PLAIN_BLOB 0	$HOST_DIR/karakuri.sh"
if [ -z "$(printf '%s\n' "$sample" | check_modes)" ]; then
	ok "否定対照: 正しい mode の一覧を誤検知しない"
else
	ng "否定対照: 正しい mode の一覧を誤検知しない"
fi

# --- result ----------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
