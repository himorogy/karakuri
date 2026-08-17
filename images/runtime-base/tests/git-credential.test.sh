#!/usr/bin/env bash
#
# github.com への git 認証が GIT_ASKPASS -> /run/secrets/GH_TOKEN の経路に
# 固定されていることを docker なしで検証する。
#
# 守りたいのは「注入した fine-scoped なトークンではなく、別の資格情報で認証が
# 通ってしまい、しかも成功するので気づけない」という形を作らないこと。git は
# credential helper を先に呼び、資格情報が返った時点で解決を確定する。
# GIT_ASKPASS はどの helper も返さなかった場合のフォールバックでしかないので、
# helper が 1 本でも生きているとこの経路は素通りされる。dev container では
# VS Code の Dev Containers 拡張が global gitconfig へ helper を書き込むため、
# これは仮定ではなく既定の状態である
# (docs/prod-secret-isolation-design.md §4.6)。
#
# 検証は本物の git に対して `git credential fill` / `approve` を実行して行う。
# ネットワークもコンテナも要らず、判定は「どのプログラムが呼ばれたか」だけで
# 足りる。helper と askpass は呼ばれたことを記録するだけのフェイクに差し替える。
#
# 打ち消しの値は Dockerfile から読む。テスト側に同じ値を書くと、イメージの値を
# 変えてもテストが緑のままになる。
#
set -uo pipefail

IMG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DOCKERFILE="$IMG_DIR/Dockerfile"
ASKPASS_SRC="$IMG_DIR/bin/git-askpass"
AUTH_CHECK_SRC="$IMG_DIR/bin/git-auth-check"

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

for f in "$DOCKERFILE" "$ASKPASS_SRC" "$AUTH_CHECK_SRC"; do
	[ -f "$f" ] || die "検査対象のファイルが無い: $f"
done

# --- Dockerfile から打ち消しの値を読む ------------------------------------------
# コメント行は除く。コメント内にも同じ変数名が出てくるが、そちらは説明であって
# 値ではない。
dockerfile_env() {
	local name="$1" hit
	hit="$(grep -v '^[[:space:]]*#' "$DOCKERFILE" |
		grep -oE "(^|[[:space:]])${name}=[^[:space:]\\\\]*" |
		head -n1 |
		sed -E "s/^.*${name}=//; s/^\"(.*)\"$/\\1/")"
	printf '%s' "$hit"
}

# VALUE_0 は空が正常値なので「取れたかどうか」を空文字で判定できない。行の存在で
# 確かめる。
grep -v '^[[:space:]]*#' "$DOCKERFILE" | grep -q 'GIT_CONFIG_VALUE_0=' ||
	die "Dockerfile に GIT_CONFIG_VALUE_0 の指定が無い"

CFG_COUNT="$(dockerfile_env GIT_CONFIG_COUNT)"
CFG_KEY0="$(dockerfile_env GIT_CONFIG_KEY_0)"
CFG_VALUE0="$(dockerfile_env GIT_CONFIG_VALUE_0)"

[ -n "$CFG_COUNT" ] || die "Dockerfile から GIT_CONFIG_COUNT を読めない"
[ -n "$CFG_KEY0" ] || die "Dockerfile から GIT_CONFIG_KEY_0 を読めない"

echo "Dockerfile の打ち消し設定"

if [ "$CFG_COUNT" = "1" ] && [ "$CFG_KEY0" = "credential.https://github.com.helper" ] &&
	[ -z "$CFG_VALUE0" ]; then
	ok "github.com の credential helper を空値で打ち消している"
else
	ng "github.com の credential helper を空値で打ち消している (COUNT=$CFG_COUNT KEY_0=$CFG_KEY0 VALUE_0=$CFG_VALUE0)"
fi

# --- 足場 -----------------------------------------------------------------------
# 呼ばれたことを記録するだけのフェイク。実際の資格情報の中身は問題ではなく、
# 「どちらが呼ばれたか」だけを見る。
# shellcheck disable=SC2016 # 単引用符は意図的。ここの $1 は生成されるフェイク
# スクリプトの側の引数であって、このシェルで展開してはいけない。
make_stage() {
	local dir="$1"
	mkdir -p "$dir/repo"

	{
		printf '#!/bin/sh\n'
		printf 'echo "HELPER($1)" >> "%s/log"\n' "$dir"
		printf 'if [ "$1" = get ]; then echo username=host-user; echo password=HOST-PW; fi\n'
		printf 'exit 0\n'
	} >"$dir/helper.sh"

	{
		printf '#!/bin/sh\n'
		printf 'echo "ASKPASS" >> "%s/log"\n' "$dir"
		printf 'case "$1" in\n'
		printf 'Username*) echo "x-access-token" ;;\n'
		printf 'Password*) echo "TOKEN-FROM-SECRETS" ;;\n'
		printf 'esac\n'
	} >"$dir/askpass.sh"

	chmod +x "$dir/helper.sh" "$dir/askpass.sh"
	: >"$dir/log"

	# VS Code の Dev Containers 拡張が書くのと同じ形 — global の、URL スコープを
	# 持たない generic な helper。
	printf '[credential]\n\thelper = %s/helper.sh\n' "$dir" >"$dir/global.gitconfig"
	: >"$dir/system.gitconfig"
	git -C "$dir/repo" init -q
}

# run_git <stage> <打ち消し: on|off> <git の引数...>
#
# テスト自身がこのイメージの上で走ることがあるため、環境から GIT_CONFIG_* と
# GIT_ASKPASS を必ず落としてから組み立てる。落とさないと「打ち消し無し」の
# 否定対照が、周囲の環境のおかげで緑になりうる。
run_git() {
	local dir="$1" reset="$2"
	shift 2
	local -a e=(env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 -u GIT_ASKPASS
		"GIT_CONFIG_SYSTEM=$dir/system.gitconfig"
		"GIT_CONFIG_GLOBAL=$dir/global.gitconfig"
		"GIT_ASKPASS=$dir/askpass.sh")
	if [ "$reset" = on ]; then
		e+=("GIT_CONFIG_COUNT=$CFG_COUNT" "GIT_CONFIG_KEY_0=$CFG_KEY0" "GIT_CONFIG_VALUE_0=$CFG_VALUE0")
	fi
	"${e[@]}" git -C "$dir/repo" "$@"
}

fill() {
	printf 'protocol=https\nhost=%s\n\n' "$2" | run_git "$1" "$3" credential fill
}

# --- 打ち消しが helper より優先されること ----------------------------------------
echo "credential helper の打ち消し"

t="$(mktemp -d)"
make_stage "$t"
out="$(fill "$t" github.com on 2>&1)"
log="$(cat "$t/log")"
if printf '%s\n' "$log" | grep -qx "ASKPASS" && ! printf '%s\n' "$log" | grep -q "^HELPER" &&
	printf '%s\n' "$out" | grep -qx "password=TOKEN-FROM-SECRETS"; then
	ok "打ち消しあり: github.com では helper が呼ばれず askpass が使われる"
else
	ng "打ち消しあり: github.com では helper が呼ばれず askpass が使われる (log=$log out=$out)"
fi
rm -rf "$t"

# 否定対照。打ち消しを外せば helper が先に確定し、askpass は呼ばれない。これが
# 出ないなら上の ok は「helper がそもそも動いていない」ことを見ているだけになる。
t="$(mktemp -d)"
make_stage "$t"
out="$(fill "$t" github.com off 2>&1)"
log="$(cat "$t/log")"
if printf '%s\n' "$log" | grep -q "^HELPER(get)" && ! printf '%s\n' "$log" | grep -qx "ASKPASS" &&
	printf '%s\n' "$out" | grep -qx "password=HOST-PW"; then
	ok "否定対照: 打ち消しが無ければ helper が askpass を先取りする"
else
	ng "否定対照: 打ち消しが無ければ helper が askpass を先取りする (log=$log out=$out)"
fi
rm -rf "$t"

# 打ち消しは URL 限定である。github.com 以外のホストまで巻き込むと、利用側が
# 自分で設定した helper を黙って壊す。
t="$(mktemp -d)"
make_stage "$t"
fill "$t" gitlab.com on >/dev/null 2>&1
log="$(cat "$t/log")"
if printf '%s\n' "$log" | grep -q "^HELPER(get)"; then
	ok "打ち消しは URL 限定: gitlab.com では helper が残る"
else
	ng "打ち消しは URL 限定: gitlab.com では helper が残る (log=$log)"
fi
rm -rf "$t"

# --- 認証成功後の store が helper へ渡らないこと ---------------------------------
# git は認証に成功すると、資格情報を **全ての** helper へ store で渡す。helper が
# 1 本でも残っていると、/run/secrets の fine-scoped なトークンがそこへ書き戻る。
# dev では書き戻り先がホストの資格情報ストアになるため、コンテナ内 tmpfs に
# 閉じるはずのトークンがホストへ出る。打ち消しは helper を 1 本も残さないので、
# この書き戻し先ごと消える。
echo "認証成功後の store"

approve() {
	printf 'protocol=https\nhost=github.com\nusername=x-access-token\npassword=TOKEN-FROM-SECRETS\n\n' |
		run_git "$1" "$2" credential approve
}

t="$(mktemp -d)"
make_stage "$t"
approve "$t" on >/dev/null 2>&1
log="$(cat "$t/log")"
if ! printf '%s\n' "$log" | grep -q "^HELPER"; then
	ok "打ち消しあり: store がどの helper にも渡らない"
else
	ng "打ち消しあり: store がどの helper にも渡らない (log=$log)"
fi
rm -rf "$t"

t="$(mktemp -d)"
make_stage "$t"
approve "$t" off >/dev/null 2>&1
log="$(cat "$t/log")"
if printf '%s\n' "$log" | grep -q "^HELPER(store)"; then
	ok "否定対照: 打ち消しが無ければ store が helper へ渡る"
else
	ng "否定対照: 打ち消しが無ければ store が helper へ渡る (log=$log)"
fi
rm -rf "$t"

# --- repo local の .git/config も打ち消せること ----------------------------------
# prod で効く側面。checkout 済みの信頼しないコードが .git/config に
# credential.helper を仕込むと、次の entrypoint 自身の fetch で呼ばれ、まだ破棄
# 前の GH_TOKEN を受け取れる。環境変数の設定は local を含む全ての設定ファイルを
# 読んだ後に適用されるため、local に仕込まれた helper にも打ち消しが及ぶ。
echo "repo local の helper"

t="$(mktemp -d)"
make_stage "$t"
: >"$t/global.gitconfig"
git -C "$t/repo" config credential.helper "$t/helper.sh"
fill "$t" github.com on >/dev/null 2>&1
log="$(cat "$t/log")"
if printf '%s\n' "$log" | grep -qx "ASKPASS" && ! printf '%s\n' "$log" | grep -q "^HELPER"; then
	ok "打ち消しあり: .git/config に仕込まれた helper も呼ばれない"
else
	ng "打ち消しあり: .git/config に仕込まれた helper も呼ばれない (log=$log)"
fi
rm -rf "$t"

t="$(mktemp -d)"
make_stage "$t"
: >"$t/global.gitconfig"
git -C "$t/repo" config credential.helper "$t/helper.sh"
fill "$t" github.com off >/dev/null 2>&1
log="$(cat "$t/log")"
if printf '%s\n' "$log" | grep -q "^HELPER(get)"; then
	ok "否定対照: 打ち消しが無ければ .git/config の helper が呼ばれる"
else
	ng "否定対照: 打ち消しが無ければ .git/config の helper が呼ばれる (log=$log)"
fi
rm -rf "$t"

# --- system の gitconfig では打ち消せないこと ------------------------------------
# 環境変数ではなく /etc/gitconfig に同じ打ち消しを書く案を退けた理由の回帰。
# git は system -> global の順に読み、空値で捨てた後に global の helper が積み
# 直されるため、system に書いた打ち消しは効かない。ここが赤くなったら、環境変数
# をやめて /etc/gitconfig へ移せる可能性がある (git の挙動が変わったということ)。
echo "system gitconfig では打ち消せない"

t="$(mktemp -d)"
make_stage "$t"
printf '[credential "https://github.com"]\n\thelper =\n' >"$t/system.gitconfig"
fill "$t" github.com off >/dev/null 2>&1
log="$(cat "$t/log")"
if printf '%s\n' "$log" | grep -q "^HELPER(get)"; then
	ok "system に書いた打ち消しは global の helper に負ける"
else
	ng "system に書いた打ち消しは global の helper に負ける (log=$log)"
fi
rm -rf "$t"

# --- git-askpass の三値 -----------------------------------------------------------
# askpass は /run/secrets/GH_TOKEN を絶対パスで見るので、shim のテストと同じく
# tmpdir へ差し替えたコピーを実行する。
echo "git-askpass"

make_askpass() {
	local dir="$1"
	mkdir -p "$dir/secrets"
	sed -e "s#/run/secrets#$dir/secrets#g" "$ASKPASS_SRC" >"$dir/git-askpass"
	chmod +x "$dir/git-askpass"
}

t="$(mktemp -d)"
make_askpass "$t"
printf 'the-token' >"$t/secrets/GH_TOKEN"
u="$("$t/git-askpass" "Username for 'https://github.com': ")"
p="$("$t/git-askpass" "Password for 'https://x-access-token@github.com': ")"
if [ "$u" = "x-access-token" ] && [ "$p" = "the-token" ]; then
	ok "トークンあり: username と password を返す"
else
	ng "トークンあり: username と password を返す (u=$u p=$p)"
fi
rm -rf "$t"

t="$(mktemp -d)"
make_askpass "$t"
err="$("$t/git-askpass" "Password for 'https://x-access-token@github.com': " 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ] && [ -n "$err" ]; then
	ok "トークン不在: 非ゼロ終了して理由を stderr に出す"
else
	ng "トークン不在: 非ゼロ終了して理由を stderr に出す (rc=$rc err=$err)"
fi
rm -rf "$t"

t="$(mktemp -d)"
make_askpass "$t"
: >"$t/secrets/GH_TOKEN"
out="$("$t/git-askpass" "Password for 'https://x-access-token@github.com': " 2>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
	ok "トークンが空: 空の password を返さず非ゼロ終了する"
else
	ng "トークンが空: 空の password を返さず非ゼロ終了する (rc=$rc out=$out)"
fi
rm -rf "$t"

# Username の問い合わせはトークンの有無に関わらず答える。ここで落とすと、認証が
# 要らない操作まで巻き込んで落ちる。
t="$(mktemp -d)"
make_askpass "$t"
u="$("$t/git-askpass" "Username for 'https://github.com': " 2>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$u" = "x-access-token" ]; then
	ok "トークン不在でも Username には答える"
else
	ng "トークン不在でも Username には答える (rc=$rc u=$u)"
fi
rm -rf "$t"

# --- git-auth-check ----------------------------------------------------------------
# 打ち消しが黙って外れたことを検出する側。正常時は何も言わないので、「言わない
# こと」と「言うこと」の両方を見る。
echo "git-auth-check"

run_check() {
	local dir="$1" reset="$2"
	local -a e=(env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0
		"GIT_CONFIG_SYSTEM=$dir/system.gitconfig"
		"GIT_CONFIG_GLOBAL=$dir/global.gitconfig")
	if [ "$reset" = on ]; then
		e+=("GIT_CONFIG_COUNT=$CFG_COUNT" "GIT_CONFIG_KEY_0=$CFG_KEY0" "GIT_CONFIG_VALUE_0=$CFG_VALUE0")
	fi
	"${e[@]}" sh "$AUTH_CHECK_SRC"
}

t="$(mktemp -d)"
make_stage "$t"
out="$(run_check "$t" on 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
	ok "打ち消しが生きていれば何も言わない"
else
	ng "打ち消しが生きていれば何も言わない (rc=$rc out=$out)"
fi
rm -rf "$t"

t="$(mktemp -d)"
make_stage "$t"
out="$(run_check "$t" off 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q "helper.sh"; then
	ok "否定対照: 打ち消しが外れていれば生き残った helper を名指しで警告する"
else
	ng "否定対照: 打ち消しが外れていれば生き残った helper を名指しで警告する (rc=$rc out=$out)"
fi
rm -rf "$t"

# 警告は「気づかせる」ためのものなので、シェルの起動を止めてはいけない。
# prod-context はサブシェル + || true で握り潰すが、握り潰しに頼らず自分でも
# rc=0 で返すことを見る (上の 2 つで rc を見ているのがそれ)。
t="$(mktemp -d)"
make_stage "$t"
: >"$t/global.gitconfig"
out="$(run_check "$t" off 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
	ok "helper が元から無ければ、打ち消しの有無に関わらず何も言わない"
else
	ng "helper が元から無ければ、打ち消しの有無に関わらず何も言わない (rc=$rc out=$out)"
fi
rm -rf "$t"

# --- result --------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
