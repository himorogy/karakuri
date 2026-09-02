#!/usr/bin/env bash
#
# github.com への git 認証が、イメージ自前の credential helper
# (/usr/local/bin/git-credential-gh-token -> /run/secrets/GH_TOKEN) に固定されて
# いることを docker なしで検証する。
#
# 守りたいのは「注入した fine-scoped なトークンではなく、別の資格情報で認証が
# 通ってしまい、しかも成功するので気づけない」という形を作らないこと。git は
# credential helper を設定順に呼び、最初に資格情報を返した helper で解決を確定
# する。GIT_ASKPASS は「どの helper も答えなかった場合」のフォールバックでしか
# ない。dev container では VS Code の Dev Containers 拡張が (a) global の
# gitconfig へ helper を書き込み、(b) 統合ターミナルの environ へ GIT_ASKPASS を
# 注入して上書きしてくる。askpass 側だけを固定しても (b) に負けるので、認証先の
# 固定は helper 側で行う (docs/prod-secret-isolation-design.md)。
#
# したがってここでの主眼は「敵対的な askpass と VS Code 相当の helper が両方
# 生きている状態で、自前 helper だけが呼ばれること」である。
#
# 検証は本物の git に対して `git credential fill` / `approve` を実行して行う。
# ネットワークもコンテナも要らず、判定は「どのプログラムが呼ばれ、どの資格情報
# で確定したか」だけで足りる。VS Code 相当の helper と askpass は、呼ばれたこと
# を記録してホスト側の資格情報を返すだけのフェイクに差し替える。
#
# この検査は「緑であること」ではなく「検知能力があること」を示す必要がある。
# 肯定ケースには必ず否定対照 (設定を外せば守りが崩れること) を併記する。
#
# 設定の値は Dockerfile から読む。テスト側に同じ値を書くと、イメージの値を
# 変えてもテストが緑のままになる。
#
set -uo pipefail

IMG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DOCKERFILE="$IMG_DIR/Dockerfile"
AUTH_CHECK_SRC="$IMG_DIR/bin/git-auth-check"
TOKEN_HELPER_SRC="$IMG_DIR/bin/git-credential-gh-token"

PASS=0
FAIL=0
SKIP=0

ok() {
	PASS=$((PASS + 1))
	printf '  ok   %s\n' "$1"
}

ng() {
	FAIL=$((FAIL + 1))
	printf '  FAIL %s\n' "$1" >&2
}

skip() {
	SKIP=$((SKIP + 1))
	printf '  skip %s\n' "$1"
}

die() {
	printf 'FATAL %s\n' "$1" >&2
	exit 1
}

# root で走ると chmod 000 でも読めてしまうため、mode 000 のケースは root では
# 意味を失う。skip してその旨を明示する。
IS_ROOT=0
if [ "$(id -u)" -eq 0 ]; then
	IS_ROOT=1
fi

for f in "$DOCKERFILE" "$AUTH_CHECK_SRC" "$TOKEN_HELPER_SRC"; do
	[ -f "$f" ] || die "検査対象のファイルが無い: $f"
done

# --- A. Dockerfile から設定の値を読む --------------------------------------------
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
CFG_KEY1="$(dockerfile_env GIT_CONFIG_KEY_1)"
CFG_VALUE1="$(dockerfile_env GIT_CONFIG_VALUE_1)"

[ -n "$CFG_COUNT" ] || die "Dockerfile から GIT_CONFIG_COUNT を読めない"
[ -n "$CFG_KEY0" ] || die "Dockerfile から GIT_CONFIG_KEY_0 を読めない"
[ -n "$CFG_KEY1" ] || die "Dockerfile から GIT_CONFIG_KEY_1 を読めない"
[ -n "$CFG_VALUE1" ] || die "Dockerfile から GIT_CONFIG_VALUE_1 を読めない"

echo "Dockerfile の credential 設定"

# スロット 0 は空値で「それまでに積まれた helper を捨てる」役。スロット 1 が同じ
# キーへ自前 helper を積み直す役。2 つが同じキーでなければ打ち消しと積み直しが
# 噛み合わない。
if [ "$CFG_COUNT" = "2" ] &&
	[ "$CFG_KEY0" = "credential.https://github.com.helper" ] &&
	[ "$CFG_KEY1" = "$CFG_KEY0" ] && [ -z "$CFG_VALUE0" ]; then
	ok "スロット 0 が github.com の helper を空値で打ち消し、スロット 1 が同じキーを使う"
else
	ng "スロット 0 が github.com の helper を空値で打ち消し、スロット 1 が同じキーを使う (COUNT=$CFG_COUNT KEY_0=$CFG_KEY0 VALUE_0=$CFG_VALUE0 KEY_1=$CFG_KEY1)"
fi

# helper 名を裸で書くと git は PATH から git-credential-<name> を探すため、PATH の
# 先頭に同名のものを置かれると乗っ取られる。絶対パスであることが要る。
if [ "$CFG_VALUE1" = "/usr/local/bin/git-credential-gh-token" ] &&
	[ -f "$IMG_DIR/bin/${CFG_VALUE1##*/}" ]; then
	ok "スロット 1 が自前 helper を絶対パスで積み、その実体が bin にある"
else
	ng "スロット 1 が自前 helper を絶対パスで積み、その実体が bin にある (VALUE_1=$CFG_VALUE1)"
fi

# 否定対照。上の 2 つは「Dockerfile から値を読めている」ことが前提になっている。
# 読み取りが何にでも一致するなら、値を変えても緑のままになる。
if [ -z "$(dockerfile_env GIT_CONFIG_VALUE_9)" ]; then
	ok "否定対照: Dockerfile に無い名前では値が取れない (読み取りが偶然一致していない)"
else
	ng "否定対照: Dockerfile に無い名前では値が取れない (読み取りが偶然一致していない)"
fi

# --- 足場 -------------------------------------------------------------------------
# HELPER は make_stage が tmpdir 配下へ作る自前 helper のコピー。run_git が
# GIT_CONFIG_VALUE_1 へ渡す値でもあるので、store の宛先だけを見たいケースでは
# make_stage の後に差し替える。
HELPER=""

# 呼ばれたことを記録するフェイク。VS Code の helper と askpass は「ホスト側の
# 資格情報」を返す敵対的な役として置く。どちらが返した資格情報で確定したかが
# 出力から判別できるよう、値を分けてある。
# shellcheck disable=SC2016 # 単引用符は意図的。ここの $1 は生成されるフェイク
# スクリプトの側の引数であって、このシェルで展開してはいけない。
make_stage() {
	local dir="$1"
	mkdir -p "$dir/repo" "$dir/secrets"

	# 自前 helper は /run/secrets と自分の絶対パスをハードコードしているため、
	# shim のテストと同じく tmpdir 配下へ sed で差し替えたコピーを実行する。
	HELPER="$dir/${CFG_VALUE1##*/}"
	sed -e "s#/run/secrets#$dir/secrets#g" -e "s#$CFG_VALUE1#$HELPER#g" \
		"$TOKEN_HELPER_SRC" >"$HELPER"
	chmod +x "$HELPER"

	# git-auth-check も同じ絶対パスを期待値として持つので、同じ差し替えを施す。
	# /run/secrets も差し替えないと、値の非漏洩テストが実在しないパスを見て
	# 素通りする。
	sed -e "s#/run/secrets#$dir/secrets#g" -e "s#$CFG_VALUE1#$HELPER#g" \
		"$AUTH_CHECK_SRC" >"$dir/git-auth-check"
	chmod +x "$dir/git-auth-check"

	{
		printf '#!/bin/sh\n'
		printf 'echo "HELPER($1)" >> "%s/log"\n' "$dir"
		printf 'if [ "$1" = get ]; then echo username=host-user; echo password=HOST-PW; fi\n'
		printf 'exit 0\n'
	} >"$dir/helper.sh"

	# VS Code が統合ターミナルの environ へ注入してくる askpass の代役。ホスト側
	# の資格情報を返す = 乗っ取りが成立した状態を再現する。
	{
		printf '#!/bin/sh\n'
		printf 'echo "ASKPASS" >> "%s/log"\n' "$dir"
		printf 'case "$1" in\n'
		printf 'Username*) echo "host-user" ;;\n'
		printf 'Password*) echo "HOST-PW-ASKPASS" ;;\n'
		printf 'esac\n'
	} >"$dir/askpass.sh"

	# store が届いたことだけを記録する差し替え用の helper。自前 helper は store に
	# 何も応答しないので、届いたこと自体はそれ単体では観測できない。
	{
		printf '#!/bin/sh\n'
		printf 'echo "MINE($1)" >> "%s/log"\n' "$dir"
		printf 'cat >/dev/null\n'
		printf 'exit 0\n'
	} >"$dir/mine-probe.sh"

	chmod +x "$dir/helper.sh" "$dir/askpass.sh" "$dir/mine-probe.sh"
	: >"$dir/log"

	# VS Code の Dev Containers 拡張が書くのと同じ形 — global の、URL スコープを
	# 持たない generic な helper。
	printf '[credential]\n\thelper = %s/helper.sh\n' "$dir" >"$dir/global.gitconfig"
	: >"$dir/system.gitconfig"
	git -C "$dir/repo" init -q
}

# run_git <stage> <イメージの設定: on|off> <git の引数...>
#
# テスト自身がこのイメージの上で走ることがあるため、環境から GIT_CONFIG_* と
# GIT_ASKPASS を必ず落としてから組み立てる。落とさないと「設定なし」の否定対照
# が、周囲の環境のおかげで緑になりうる。
#
# GIT_ASKPASS は on / off のどちらでも敵対的なものを設定する。イメージの設定が
# 効いていても効いていなくても askpass は environ にいる、というのが再現したい
# 状況そのものである。
run_git() {
	local dir="$1" cfg="$2"
	shift 2
	local -a e=(env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0
		-u GIT_CONFIG_KEY_1 -u GIT_CONFIG_VALUE_1 -u GIT_ASKPASS
		"GIT_CONFIG_SYSTEM=$dir/system.gitconfig"
		"GIT_CONFIG_GLOBAL=$dir/global.gitconfig"
		"GIT_ASKPASS=$dir/askpass.sh")
	if [ "$cfg" = on ]; then
		e+=("GIT_CONFIG_COUNT=$CFG_COUNT"
			"GIT_CONFIG_KEY_0=$CFG_KEY0" "GIT_CONFIG_VALUE_0=$CFG_VALUE0"
			"GIT_CONFIG_KEY_1=$CFG_KEY1" "GIT_CONFIG_VALUE_1=$HELPER")
	fi
	"${e[@]}" git -C "$dir/repo" "$@"
}

# fill <stage> <host> <on|off> [追加の入力行]
fill() {
	printf 'protocol=https\nhost=%s\n%s\n' "$2" "${4:-}" | run_git "$1" "$3" credential fill
}

approve() {
	printf 'protocol=https\nhost=github.com\nusername=x-access-token\npassword=TOKEN-FROM-SECRETS\n\n' |
		run_git "$1" "$2" credential approve
}

# --- B. 自前 helper が askpass の乗っ取りに勝つこと -------------------------------
echo "自前 helper と askpass 乗っ取り"

t="$(mktemp -d)"
make_stage "$t"
printf 'the-token' >"$t/secrets/GH_TOKEN"
out="$(fill "$t" github.com on 2>&1)"
log="$(cat "$t/log")"
if printf '%s\n' "$out" | grep -qx "password=the-token" &&
	printf '%s\n' "$out" | grep -qx "username=x-access-token" &&
	[ -z "$log" ]; then
	ok "VS Code 相当の helper と敵対的な askpass が両方あっても自前 helper だけが呼ばれる"
else
	ng "VS Code 相当の helper と敵対的な askpass が両方あっても自前 helper だけが呼ばれる (log=$log out=$out)"
fi
rm -rf "$t"

# 否定対照 1。設定を外せば global の helper が先に確定し、ホスト側の資格情報で
# 認証が通る。これが出ないなら上の ok は「フェイクがそもそも動いていない」ことを
# 見ているだけになる。
t="$(mktemp -d)"
make_stage "$t"
printf 'the-token' >"$t/secrets/GH_TOKEN"
out="$(fill "$t" github.com off 2>&1)"
log="$(cat "$t/log")"
if printf '%s\n' "$log" | grep -q "^HELPER(get)" &&
	printf '%s\n' "$out" | grep -qx "password=HOST-PW"; then
	ok "否定対照: 設定を外すと VS Code 相当の helper がホスト資格情報で確定させる"
else
	ng "否定対照: 設定を外すと VS Code 相当の helper がホスト資格情報で確定させる (log=$log out=$out)"
fi
rm -rf "$t"

# 否定対照 2。helper を一本も持たない状態にすると、environ の askpass が答えて
# ホスト側の資格情報で通る。これが askpass 乗っ取りそのもので、helper 側で固定
# する理由でもある。
t="$(mktemp -d)"
make_stage "$t"
printf 'the-token' >"$t/secrets/GH_TOKEN"
: >"$t/global.gitconfig"
out="$(fill "$t" github.com off 2>&1)"
log="$(cat "$t/log")"
if printf '%s\n' "$log" | grep -qx "ASKPASS" &&
	printf '%s\n' "$out" | grep -qx "password=HOST-PW-ASKPASS"; then
	ok "否定対照: helper が無ければ敵対的な askpass がホスト資格情報で確定させる"
else
	ng "否定対照: helper が無ければ敵対的な askpass がホスト資格情報で確定させる (log=$log out=$out)"
fi
rm -rf "$t"

# --- C. 認証成功後の store の宛先 --------------------------------------------------
# git は認証に成功すると、設定されている **全ての** helper へ store を呼ぶ。VS Code
# の helper が一覧に残っていると、/run/secrets の fine-scoped なトークンがそこへ
# 書き戻る。dev では書き戻り先がホストの資格情報ストアになるため、コンテナ内
# tmpfs に閉じるはずのトークンがホストへ出る。
echo "認証成功後の store"

t="$(mktemp -d)"
make_stage "$t"
# 自前 helper は store に何も応答しないので、届いたことを見るために記録用へ
# 差し替える。ここで見たいのは helper の中身ではなく git の配布先である。
HELPER="$t/mine-probe.sh"
approve "$t" on >/dev/null 2>&1
log="$(cat "$t/log")"
if printf '%s\n' "$log" | grep -q "^MINE(store)" &&
	! printf '%s\n' "$log" | grep -q "^HELPER"; then
	ok "store は自前 helper にだけ届き、VS Code 相当の helper には届かない"
else
	ng "store は自前 helper にだけ届き、VS Code 相当の helper には届かない (log=$log)"
fi
rm -rf "$t"

t="$(mktemp -d)"
make_stage "$t"
approve "$t" off >/dev/null 2>&1
log="$(cat "$t/log")"
if printf '%s\n' "$log" | grep -q "^HELPER(store)"; then
	ok "否定対照: 設定を外すと store が VS Code 相当の helper へ届く"
else
	ng "否定対照: 設定を外すと store が VS Code 相当の helper へ届く (log=$log)"
fi
rm -rf "$t"

# --- D. URL に username が埋まっている場合 -----------------------------------------
# ホストの gitconfig の insteadOf が copyGitConfig で持ち込まれると、remote の URL
# に username が埋まった状態で認証が走る。その username が採用されると、helper が
# 返すトークンと組にならず認証の主体がずれる。
echo "URL に username が埋まっている場合"

t="$(mktemp -d)"
make_stage "$t"
printf 'the-token' >"$t/secrets/GH_TOKEN"
out="$(fill "$t" github.com on 'username=someone' 2>&1)"
if printf '%s\n' "$out" | grep -qx "username=x-access-token" &&
	printf '%s\n' "$out" | grep -qx "password=the-token" &&
	! printf '%s\n' "$out" | grep -qx "username=someone"; then
	ok "入力に username があっても自前 helper が返す username が使われる"
else
	ng "入力に username があっても自前 helper が返す username が使われる (out=$out)"
fi
rm -rf "$t"

# 否定対照。設定を外せば入力の username がそのまま残り、ホスト側の helper の
# 資格情報と組になる。
t="$(mktemp -d)"
make_stage "$t"
printf 'the-token' >"$t/secrets/GH_TOKEN"
out="$(fill "$t" github.com off 'username=someone' 2>&1)"
if ! printf '%s\n' "$out" | grep -qx "username=x-access-token"; then
	ok "否定対照: 設定を外すと自前 helper の username は使われない"
else
	ng "否定対照: 設定を外すと自前 helper の username は使われない (out=$out)"
fi
rm -rf "$t"

# --- E. 打ち消しと積み直しの及ぶ範囲 -----------------------------------------------
echo "打ち消しの範囲"

# github.com 以外のホストまで巻き込むと、利用側が自分で設定した helper を黙って
# 壊す。gitlab.com では VS Code の helper がそのまま残るのが正しい。
t="$(mktemp -d)"
make_stage "$t"
printf 'the-token' >"$t/secrets/GH_TOKEN"
out="$(fill "$t" gitlab.com on 2>&1)"
log="$(cat "$t/log")"
if printf '%s\n' "$log" | grep -q "^HELPER(get)" &&
	printf '%s\n' "$out" | grep -qx "password=HOST-PW"; then
	ok "URL 限定: gitlab.com では既存の helper が残る"
else
	ng "URL 限定: gitlab.com では既存の helper が残る (log=$log out=$out)"
fi
rm -rf "$t"

# prod で効く側面。checkout 済みの信頼しないコードが .git/config に
# credential.helper を仕込むと、次の entrypoint 自身の fetch で呼ばれ、まだ破棄
# 前の GH_TOKEN を受け取れる。環境変数の設定は local を含む全ての設定ファイルを
# 読んだ後に適用されるため、local に仕込まれた helper にも打ち消しが及ぶ。
t="$(mktemp -d)"
make_stage "$t"
printf 'the-token' >"$t/secrets/GH_TOKEN"
: >"$t/global.gitconfig"
git -C "$t/repo" config credential.helper "$t/helper.sh"
out="$(fill "$t" github.com on 2>&1)"
log="$(cat "$t/log")"
if [ -z "$log" ] && printf '%s\n' "$out" | grep -qx "password=the-token"; then
	ok ".git/config に仕込まれた helper も呼ばれない"
else
	ng ".git/config に仕込まれた helper も呼ばれない (log=$log out=$out)"
fi
rm -rf "$t"

t="$(mktemp -d)"
make_stage "$t"
printf 'the-token' >"$t/secrets/GH_TOKEN"
: >"$t/global.gitconfig"
git -C "$t/repo" config credential.helper "$t/helper.sh"
fill "$t" github.com off >/dev/null 2>&1
log="$(cat "$t/log")"
if printf '%s\n' "$log" | grep -q "^HELPER(get)"; then
	ok "否定対照: 設定を外すと .git/config の helper が呼ばれる"
else
	ng "否定対照: 設定を外すと .git/config の helper が呼ばれる (log=$log)"
fi
rm -rf "$t"

# 環境変数ではなく /etc/gitconfig に同じ打ち消しを書く案を退けた理由の回帰。
# git は system -> global の順に読み、空値で捨てた後に global の helper が積み
# 直されるため、system に書いた打ち消しは効かない。ここが緑でなくなったら、
# 環境変数をやめて /etc/gitconfig へ移せる可能性がある (git の挙動が変わった
# ということ)。
t="$(mktemp -d)"
make_stage "$t"
printf 'the-token' >"$t/secrets/GH_TOKEN"
printf '[credential "https://github.com"]\n\thelper =\n' >"$t/system.gitconfig"
out="$(fill "$t" github.com off 2>&1)"
log="$(cat "$t/log")"
if printf '%s\n' "$log" | grep -q "^HELPER(get)" &&
	printf '%s\n' "$out" | grep -qx "password=HOST-PW"; then
	ok "system に書いた打ち消しは global の helper に負ける"
else
	ng "system に書いた打ち消しは global の helper に負ける (log=$log out=$out)"
fi
rm -rf "$t"

# --- F. git-credential-gh-token 単体 -----------------------------------------------
echo "git-credential-gh-token"

t="$(mktemp -d)"
make_stage "$t"
printf 'the-token' >"$t/secrets/GH_TOKEN"
out="$(printf 'protocol=https\nhost=github.com\n\n' | "$HELPER" get 2>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qx "username=x-access-token" &&
	printf '%s\n' "$out" | grep -qx "password=the-token"; then
	ok "トークンあり: username と password を返す"
else
	ng "トークンあり: username と password を返す (rc=$rc out=$out)"
fi

# トークンの値は stderr へ出さない。stderr は端末やログに残る。
err="$(printf 'protocol=https\nhost=github.com\n\n' | "$HELPER" get 2>&1 1>/dev/null)"
if [ -z "$err" ]; then
	ok "トークンあり: stderr に何も出さない (値が漏れない)"
else
	ng "トークンあり: stderr に何も出さない (値が漏れない) (err=$err)"
fi
rm -rf "$t"

# 不在と空は「返せない」という同じ結果になる。非ゼロ終了だと git は次の helper や
# askpass へ黙ってフォールスルーするので、stdout の quit=1 で連鎖を止める。
check_unavailable() {
	local label="$1" t out err rc
	t="$(mktemp -d)"
	make_stage "$t"
	case "$label" in
	空) : >"$t/secrets/GH_TOKEN" ;;
	esac
	out="$(printf 'protocol=https\nhost=github.com\n\n' | "$HELPER" get 2>/dev/null)"
	rc=$?
	err="$(printf 'protocol=https\nhost=github.com\n\n' | "$HELPER" get 2>&1 1>/dev/null)"
	if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qx "quit=1" &&
		! printf '%s\n' "$out" | grep -q "^password=" && [ -n "$err" ]; then
		ok "トークン$label: quit=1 を出し、理由を stderr に出し、password は出さず rc=0"
	else
		ng "トークン$label: quit=1 を出し、理由を stderr に出し、password は出さず rc=0 (rc=$rc out=$out err=$err)"
	fi
	rm -rf "$t"
}

check_unavailable 不在
check_unavailable 空

# 存在・非空だが読めない場合に「空の password」を返すと、空値での認証試行が通る
# 経路になる。ここも quit=1 で止める。root で走ると chmod 000 でも読めてしまい
# 検証にならないため skip する。
if [ "$IS_ROOT" -eq 1 ]; then
	skip "トークンが読めない (mode 000): quit=1 になる (root のため skip)"
else
	t="$(mktemp -d)"
	make_stage "$t"
	printf 'unreadable-token' >"$t/secrets/GH_TOKEN"
	chmod 000 "$t/secrets/GH_TOKEN"
	out="$(printf 'protocol=https\nhost=github.com\n\n' | "$HELPER" get 2>/dev/null)"
	rc=$?
	if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qx "quit=1" &&
		! printf '%s\n' "$out" | grep -q "^password="; then
		ok "トークンが読めない (mode 000): 空の password ではなく quit=1"
	else
		ng "トークンが読めない (mode 000): 空の password ではなく quit=1 (rc=$rc out=$out)"
	fi
	rm -rf "$t"
fi

# get 以外は no-op。store / erase に応答すると、この helper が書き戻し先になれる
# かのように見えるが、実体は /run/secrets の読み取り専用である。
t="$(mktemp -d)"
make_stage "$t"
printf 'the-token' >"$t/secrets/GH_TOKEN"
noop_ok=1
for op in store erase ""; do
	out="$("$HELPER" $op </dev/null 2>&1)"
	rc=$?
	if [ "$rc" -ne 0 ] || [ -n "$out" ]; then
		noop_ok=0
		ng "get 以外は何も出さず rc=0 (op=${op:-なし} rc=$rc out=$out)"
	fi
done
if [ "$noop_ok" -eq 1 ]; then
	ok "store / erase / 引数なし: 何も出さず rc=0"
fi
rm -rf "$t"

# --- G. トークン不在時に、失敗が失敗として現れること -------------------------------
# quit=1 が連鎖を止めていることの確認。止まっていなければ、トークンが無い状態でも
# 敵対的な askpass が答えて認証が「成功」してしまう。
echo "トークン不在時の失敗の形"

t="$(mktemp -d)"
make_stage "$t"
out="$(fill "$t" github.com on 2>&1)"
rc=$?
log="$(cat "$t/log")"
if [ "$rc" -ne 0 ] && [ -z "$log" ] &&
	! printf '%s\n' "$out" | grep -q "HOST-PW"; then
	ok "トークンが無ければ git は失敗し、敵対的な askpass は呼ばれない"
else
	ng "トークンが無ければ git は失敗し、敵対的な askpass は呼ばれない (rc=$rc log=$log out=$out)"
fi
rm -rf "$t"

t="$(mktemp -d)"
make_stage "$t"
: >"$t/global.gitconfig"
out="$(fill "$t" github.com off 2>&1)"
rc=$?
log="$(cat "$t/log")"
if [ "$rc" -eq 0 ] && printf '%s\n' "$log" | grep -qx "ASKPASS" &&
	printf '%s\n' "$out" | grep -qx "password=HOST-PW-ASKPASS"; then
	ok "否定対照: 設定を外すとトークンが無くても敵対的な askpass で成功してしまう"
else
	ng "否定対照: 設定を外すとトークンが無くても敵対的な askpass で成功してしまう (rc=$rc log=$log out=$out)"
fi
rm -rf "$t"

# --- H. git-auth-check ---------------------------------------------------------------
# 実効 helper のパスを、想定どおりのときも含めて常に1行で報告する側。加えて、
# イメージが GIT_CONFIG_COUNT 系で行っている固定が生きているかどうかの別も
# 報告に付く。rc は常に 0 で、シェルの起動を止めない。
echo "git-auth-check"

run_check() {
	local dir="$1" cfg="$2"
	local -a e=(env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0
		-u GIT_CONFIG_KEY_1 -u GIT_CONFIG_VALUE_1
		"GIT_CONFIG_SYSTEM=$dir/system.gitconfig"
		"GIT_CONFIG_GLOBAL=$dir/global.gitconfig")
	if [ "$cfg" = on ]; then
		e+=("GIT_CONFIG_COUNT=$CFG_COUNT"
			"GIT_CONFIG_KEY_0=$CFG_KEY0" "GIT_CONFIG_VALUE_0=$CFG_VALUE0"
			"GIT_CONFIG_KEY_1=$CFG_KEY1" "GIT_CONFIG_VALUE_1=$HELPER")
	fi
	"${e[@]}" sh "$dir/git-auth-check"
}

t="$(mktemp -d)"
make_stage "$t"
out="$(run_check "$t" on 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] &&
	printf '%s\n' "$out" | grep -q "$HELPER"; then
	ok "実効 helper が自前 helper と一致: パスを1行報告して rc=0"
else
	ng "実効 helper が自前 helper と一致: パスを1行報告して rc=0 (rc=$rc out=$out)"
fi
# 否定対照: 以前の「一致なら何も出さない」仕様への逆行を検出する。
if [ -n "$out" ]; then
	ok "否定対照: 一致していても出力が空にならない"
else
	ng "否定対照: 一致していても出力が空にならない"
fi
rm -rf "$t"

# 別の helper が勝っている場合。イメージの固定 (GIT_CONFIG_*) は生きていない
# ので、実効 helper の値によらず「外れている」の別が読めるはずである。
t="$(mktemp -d)"
make_stage "$t"
other="$(run_check "$t" off 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$other" | grep -q "$t/helper.sh"; then
	ok "実効 helper が別物: 生き残った helper のパスを報告して rc=0"
else
	ng "実効 helper が別物: 生き残った helper のパスを報告して rc=0 (rc=$rc out=$other)"
fi
rm -rf "$t"

# helper が一本も無い場合。実効 helper の値は上のケースと違うが、固定が外れて
# いること自体は同じく報告に読めるはずである。
t="$(mktemp -d)"
make_stage "$t"
: >"$t/global.gitconfig"
none="$(run_check "$t" off 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ -n "$none" ]; then
	ok "実効 helper が空でも rc=0 で1行報告する"
else
	ng "実効 helper が空でも rc=0 で1行報告する (rc=$rc out=$none)"
fi
rm -rf "$t"

# イメージ固定が外れている (cfg=off) 場合、実効 helper が別物でも空でも、
# 報告からその別が読める必要がある。固定が生きている場合の報告 ($out) とは
# 区別できることも併せて見る。
if printf '%s\n' "$other" | grep -q "外れている" &&
	printf '%s\n' "$none" | grep -q "外れている" &&
	! printf '%s\n' "$out" | grep -q "外れている"; then
	ok "イメージ固定が外れていれば報告にその別が付く (実効 helper が別物でも空でも)"
else
	ng "イメージ固定が外れていれば報告にその別が付く (other=$other none=$none out=$out)"
fi
if [ -n "$other" ] && [ -n "$none" ] && [ "$other" != "$none" ]; then
	ok "helper が空の場合と別物の場合で報告の文面が違う"
else
	ng "helper が空の場合と別物の場合で報告の文面が違う"
fi

# 部分的な上書き (a): README が案内する形。イメージの 5 変数はそのままに、
# COUNT を増やして利用側のスロットを追加する。スロット 0/1 は無傷なので
# 固定は生きているままのはずである (COUNT の完全一致を求めると誤って
# 「外れている」になる、というのがこの回帰の対象)。
t="$(mktemp -d)"
make_stage "$t"
extended="$(env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 \
	-u GIT_CONFIG_KEY_1 -u GIT_CONFIG_VALUE_1 \
	"GIT_CONFIG_SYSTEM=$t/system.gitconfig" \
	"GIT_CONFIG_GLOBAL=$t/global.gitconfig" \
	"GIT_CONFIG_COUNT=3" \
	"GIT_CONFIG_KEY_0=$CFG_KEY0" "GIT_CONFIG_VALUE_0=$CFG_VALUE0" \
	"GIT_CONFIG_KEY_1=$CFG_KEY1" "GIT_CONFIG_VALUE_1=$HELPER" \
	"GIT_CONFIG_KEY_2=credential.helper" "GIT_CONFIG_VALUE_2=" \
	sh "$t/git-auth-check" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$extended" | grep -q "$HELPER" &&
	! printf '%s\n' "$extended" | grep -q "外れている"; then
	ok "利用側が案内どおりに COUNT を増やして足しても固定は生きている扱いになる"
else
	ng "利用側が案内どおりに COUNT を増やして足しても固定は生きている扱いになる (rc=$rc out=$extended)"
fi
rm -rf "$t"

# 部分的な上書き (b): COUNT は 2 のままキー側だけが別物にすり替わっている。
# 5 変数のうち 1 本でも想定と違えば固定は外れている扱いになるはずである。
t="$(mktemp -d)"
make_stage "$t"
tampered="$(env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 \
	-u GIT_CONFIG_KEY_1 -u GIT_CONFIG_VALUE_1 \
	"GIT_CONFIG_SYSTEM=$t/system.gitconfig" \
	"GIT_CONFIG_GLOBAL=$t/global.gitconfig" \
	"GIT_CONFIG_COUNT=$CFG_COUNT" \
	"GIT_CONFIG_KEY_0=$CFG_KEY0" "GIT_CONFIG_VALUE_0=$CFG_VALUE0" \
	"GIT_CONFIG_KEY_1=credential.helper" "GIT_CONFIG_VALUE_1=$HELPER" \
	sh "$t/git-auth-check" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$tampered" | grep -q "外れている"; then
	ok "5本のうち1本だけ別物にすり替わっていても固定は外れている扱いになる"
else
	ng "5本のうち1本だけ別物にすり替わっていても固定は外れている扱いになる (rc=$rc out=$tampered)"
fi
rm -rf "$t"

# 報告文は、このリポジトリの外の人間が読んでも意味が通る必要がある。参照先が
# 手元に無い記号を混ぜないことの回帰確認 (tests/shipped-symbols.test.sh と同じ
# 趣旨を、実際に出た文字列に対して見る)。
if ! printf '%s\n%s\n' "$other" "$none" | grep -qE '§|\b[A-Z][0-9]+\b'; then
	ok "報告文に参照先の無い記号が出ない"
else
	ng "報告文に参照先の無い記号が出ない"
fi

# 資格情報の値は報告に現れない。GH_TOKEN の中身に目印を仕込み、一致・別物の
# いずれの報告にも現れないことを見る (git-auth-check は helper のパスと
# GIT_CONFIG_* しか扱わず、トークンの値そのものには触れない設計)。
t="$(mktemp -d)"
make_stage "$t"
marker="AUTH_CHECK_MARKER_$$"
printf '%s' "$marker" >"$t/secrets/GH_TOKEN"
matched="$(run_check "$t" on 2>&1)"
mismatched="$(run_check "$t" off 2>&1)"
rm -rf "$t"
if ! printf '%s\n%s\n' "$matched" "$mismatched" | grep -q "$marker"; then
	ok "報告に注入した値が出ない"
else
	ng "報告に注入した値が出ない (matched=$matched mismatched=$mismatched)"
fi

# --- result --------------------------------------------------------------------

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
