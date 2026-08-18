#!/usr/bin/env bash
#
# 出荷物に、このリポジトリの外では意味を持たない記号が残っていないことの検査。
#
# 設計文書の中でしか通じない記号 (不変条件・残余リスク・設計判断の番号や
# 節番号、版番号) は、書いた本人には意味があるが、イメージやテンプレートを
# 受け取った側には参照先が存在しない。「可変 ref はレビュー対象と実行対象の
# 一致を保証しない (設計書 R10 / D21)」という stderr を運用中に踏んだ人間は、
# R10 も D21 も辿れない。棚卸しを一度やっても、次に手を入れた人がまた書けば
# 戻るので、検査として置く。
#
# 検査の強さは「読者が参照先に到達できるか」で二段に分ける。
#
#   strict  … 他リポジトリ・他 org へ丸ごと出るもの。記号は残せない。
#             images/runtime-base の README はこのリポジトリに留まるので
#             docs/ 配下の文書はパスで参照してよいが、templates/ と
#             packages/env-guard の README は受け取った側の手元へ渡るため、
#             docs/ へのパスも解決できない (下の別検査で見る)
#   lenient … イメージに COPY されるコード (bin / shims / hooks)。コメントは
#             docs/ の文書をフルパスで参照してよいが、記号を裸で置くことと、
#             echo/printf で外へ出す文字列に記号を混ぜることは許さない
#
# 対象は runtime-base の出荷物と、そこへ焼き込まれる packages/env-guard の
# 出荷物である。スキャナと pre-commit hook は packages/env-guard へ移したが、
# イメージに入るコードであることは変わらないので lenient のままにしてある。
# packages/env-guard/README.md は npm パッケージとして他 org の手元へ渡るので
# templates/ と同じ strict 扱いにする。
#
# images/devcontainer-base の文書が参照しているのは docs/secure-publish.md と
# 自分自身の節番号なので、受け取った側が辿れないという問題が起きない。
#
set -uo pipefail

IMG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GUARD_DIR="$(cd "$IMG_DIR/../../packages/env-guard" && pwd)"

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

# 不変条件・リスク・判断の番号 (I6 / R12 / D21)、実測の記号 (N-1 / N-2)。
#
# 直前が `-` か `[` の場合を除くのは、正規表現の文字クラス `[A-Z0-9_]` の中の
# `Z0` を拾ってしまうため。env-guard-scan と shim が実際に持っている書き方で、
# 記号ではない。
NUM_RE='(^|[^-[:alnum:]_[])([A-Z][0-9]{1,2}\b|N-[12]\b)'

# 節番号 (§4.2)、上記の番号、版番号 (rev.7)、「設計書」という語そのもの。
SYMBOL_RE="§|${NUM_RE}|設計書|rev\\.[0-9]+"

# 節番号を除いたもの。lenient 側では「フルパス参照に付いた §」だけを別扱い
# したいので、それ以外をこちらで見る。
BARE_RE="${NUM_RE}|設計書|rev\\.[0-9]+"

# git 管理下にあり、このリポジトリを見られる人なら誰でも辿れる参照。
# この形でなら記号を伴ってよい。
ALLOWED_REF='docs/(secure-publish|prod-secret-isolation-design)\.md'

# 設計文書そのもの。git 管理下にあるので karakuri の中では辿れるが、
# templates/ は他リポジトリへコピーされるため、コピー先では解決できない。
DESIGN_DOC='docs/prod-secret-isolation-design\.md'

# scan_strict <file> -> 違反行を stdout に出す
scan_strict() {
	grep -nE "$SYMBOL_RE" "$1" 2>/dev/null | grep -vE "$ALLOWED_REF"
}

# scan_design_doc <file> -> 設計文書へのパス参照を stdout に出す
scan_design_doc() {
	grep -nE "$DESIGN_DOC" "$1" 2>/dev/null
}

# scan_lenient <file> -> 違反行を stdout に出す
#
# 1. 裸の記号はコメントでも許さない
# 2. § はフルパス参照を伴う行だけ許す
# 3. echo / printf で出る行は、フルパス参照であっても記号を許さない
#    (運用者が踏む文字列であり、単体で意味が通る必要がある)
scan_lenient() {
	local f="$1"
	grep -nE "$BARE_RE" "$f" 2>/dev/null | grep -vE "$ALLOWED_REF"
	grep -nE '§' "$f" 2>/dev/null | grep -vE "$ALLOWED_REF"
	grep -nE '(echo|printf)' "$f" 2>/dev/null | grep -E "$SYMBOL_RE" | grep -vE "$ALLOWED_REF"
}

# check <ラベル> <scan 関数> <ファイル...>
check() {
	local label="$1" scanner="$2"
	shift 2
	local f hits all=""
	for f in "$@"; do
		[ -f "$f" ] || continue
		hits="$("$scanner" "$f")"
		if [ -n "$hits" ]; then
			all="${all}${f}
${hits}
"
		fi
	done
	if [ -z "$all" ]; then
		ok "$label"
	else
		ng "$label"
		printf '%s\n' "$all" >&2
	fi
}

# check() は存在しないファイルを黙って飛ばすので、対象の置き場が変わったとき
# に「1 件も見ずに緑」へ倒れうる。出荷物が移動したらここで止まるように、
# 一覧を組む段で在ることを確かめる。

die() {
	printf 'FATAL %s\n' "$1" >&2
	exit 1
}

# list_files <ディレクトリ...> — 配下の全ファイルのパスを stdout に出す。
# ディレクトリが無い、または 1 件も入っていなければ落ちる。
list_files() {
	local d found
	for d in "$@"; do
		[ -d "$d" ] || die "検査対象のディレクトリが無い: $d"
		found="$(find "$d" -type f | sort)"
		[ -n "$found" ] || die "検査対象のディレクトリが空: $d"
		printf '%s\n' "$found"
	done
}

# require_files <ファイル...> — 無ければ落ちる。
require_files() {
	local f
	for f in "$@"; do
		[ -f "$f" ] || die "検査対象のファイルが無い: $f"
	done
}

# --- strict: 他リポジトリ・他 org へ出るもの ---------------------------------------

TEMPLATE_LIST="$(list_files "$IMG_DIR/templates")" || exit 1
mapfile -t TEMPLATE_FILES <<<"$TEMPLATE_LIST"

check "templates/ に設計文書内でしか通じない記号が無い" scan_strict "${TEMPLATE_FILES[@]}"

# templates は丸ごとコピーされるので、パスで参照しても受け取った側では解決できない。
check "templates/ がコピー先で解決できない設計文書のパスを持たない" scan_design_doc \
	"${TEMPLATE_FILES[@]}"

# packages/env-guard の README は npm パッケージとして他 org の手元へ渡る。
# templates と同じ扱いで、記号もこのリポジトリ内のパスも許さない。
GUARD_README="$GUARD_DIR/README.md"
require_files "$GUARD_README"

check "env-guard の README に設計文書内でしか通じない記号が無い" scan_strict "$GUARD_README"
check "env-guard の README が受け取った側で解決できない設計文書のパスを持たない" \
	scan_design_doc "$GUARD_README"

# runtime-base の README はこのリポジトリに留まるので、docs/ 配下へのリンクは
# 辿れる。禁じるのは記号だけ。
require_files "$IMG_DIR/README.md" "$IMG_DIR/migration.md"

check "README に設計文書内でしか通じない記号が無い" scan_strict \
	"$IMG_DIR/README.md" "$IMG_DIR/migration.md"

# --- lenient: イメージに COPY されるコード -----------------------------------------
#
# スキャナと pre-commit hook は packages/env-guard にあるが、named build
# context 経由でイメージへ焼き込まれるので、runtime-base の bin / shims と
# 同じ扱いで見る。

BAKED_LIST="$(list_files \
	"$IMG_DIR/bin" \
	"$IMG_DIR/shims" \
	"$GUARD_DIR/bin" \
	"$GUARD_DIR/hooks")" || exit 1
mapfile -t BAKED_FILES <<<"$BAKED_LIST"

check "イメージに入るコードに裸の記号が無い / 出力文字列に記号が無い" scan_lenient "${BAKED_FILES[@]}"

# --- 否定対照: この検査に検知能力があること ----------------------------------------
#
# 「検査が緑であること」と「検査に検知能力があること」は別である。
# 既知の違反を作って、実際に引っかかることを確かめる。

t="$(mktemp -d)"

printf '# 可変 ref を拒否する理由は設計書 §4.6 / D21 を参照\n' >"$t/strict-sample"
if [ -n "$(scan_strict "$t/strict-sample")" ]; then
	ok "否定対照: strict が既知の違反 (記号入りコメント) を検知する"
else
	ng "否定対照: strict が既知の違反 (記号入りコメント) を検知する"
fi

printf 'echo "prod: 可変 ref は一致を保証しない（設計書 R10 / D21）" >&2\n' >"$t/lenient-out"
if [ -n "$(scan_lenient "$t/lenient-out")" ]; then
	ok "否定対照: lenient が既知の違反 (記号入りの出力文字列) を検知する"
else
	ng "否定対照: lenient が既知の違反 (記号入りの出力文字列) を検知する"
fi

# 逆向きの対照。lenient が許すべきものを誤検知しないこと。
printf '# 詳細は docs/prod-secret-isolation-design.md §4.6 にある\n' >"$t/lenient-okref"
if [ -z "$(scan_lenient "$t/lenient-okref")" ]; then
	ok "否定対照: lenient はフルパス参照付きの節番号を誤検知しない"
else
	ng "否定対照: lenient はフルパス参照付きの節番号を誤検知しない"
fi

printf '# 判断の根拠は docs/secure-publish.md §4.3 にある\n' >"$t/allowed-ref"
if [ -z "$(scan_strict "$t/allowed-ref")" ]; then
	ok "否定対照: git 管理下の文書への参照は strict でも通る"
else
	ng "否定対照: git 管理下の文書への参照は strict でも通る"
fi

printf '# 詳細は docs/prod-secret-isolation-design.md にある\n' >"$t/doc-path"
if [ -n "$(scan_design_doc "$t/doc-path")" ]; then
	ok "否定対照: templates 向けの検査が設計文書へのパスを検知する"
else
	ng "否定対照: templates 向けの検査が設計文書へのパスを検知する"
fi

rm -rf "$t"

# --- result ----------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
