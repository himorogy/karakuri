#!/usr/bin/env bash
#
# Tests for loopback-setup.sh and the LaunchDaemon it installs
# (host/loopback/karakuri-loopback-aliases).
#
# macOS も root 権限も無いところで走る（dev container は Linux で、
# /etc は触らせない）。やり方は 2 つ:
#
#   1. sudo / install / launchctl / ifconfig / uname を PATH 先頭のフェイクへ
#      差し替える。特権操作は全部 `sudo` を通るので、フェイク sudo の記録が
#      空かどうかを見れば「特権操作が 1 つも走っていない」を直接言える。
#   2. 実装は配置先を定数（CONF_DIR / DAEMON_DIR / PLIST_PATH / HOSTS /
#      HOSTS_BAK）で持っており、環境変数では差し替えられない。実装を書き換える
#      わけにはいかないので、テストごとに一時ディレクトリへ写しを作り、その
#      5 行だけを sed で偽の root（$ROOT）配下へ向ける。写しを作る側なので
#      配布物の loopback/ ディレクトリも隣に置き直す（install の探索経路を
#      そのまま通すため）。
#
# このテストは実機の /etc/hosts・/etc/karakuri・/Library/LaunchDaemons を
# 一切読み書きしない。ifconfig も launchctl も呼ばれない。
#
set -uo pipefail

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

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
HOST_DIR="$TEST_DIR/../host"
LOOPBACK_SETUP_SH="$HOST_DIR/loopback-setup.sh"
LOOPBACK_DIST_DIR="$HOST_DIR/loopback"
DAEMON_SRC="$LOOPBACK_DIST_DIR/karakuri-loopback-aliases"
PLIST_SRC="$LOOPBACK_DIST_DIR/com.karakuri.loopback-aliases.plist"

# 実装と同じ文字列。マーカーは契約なので、ここが実装とずれたらテストは
# 「ブロックが見つからない」形で落ちる（それが正しい落ち方）。
HOSTS_BEGIN="# BEGIN karakuri (managed) — do not edit by hand"
HOSTS_END="# END karakuri"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

FAKE_BIN_DIR="$WORKDIR/bin"
mkdir -p "$FAKE_BIN_DIR"

# --- 割り込みフック --------------------------------------------------------------
# 「読んでから書くまでの間に、別のプロセスが同じファイルへ書いた」を再現する
# ための仕掛け。実装は /etc/hosts と設定ファイルを 1 度だけ写しへ取り、被せる
# 直前に実物と突き合わせて、変わっていたら中止する。その突合が本当に効いて
# いるかは、突合の前に外から書いてみるほかに確かめようが無い。
#
# どこで割り込むかは、実装が呼ぶコマンドの「何回目か」で指定する:
#
#   RACE_ON_SUDO=1  最初の sudo（＝最初の特権操作）の直前
#   RACE_ON_WC=2    2 回目の wc（＝マーカーの行番号を数え終えた直後、
#                   その行番号で本文を切り出す直前）
#   RACE_ON_TAIL=1  最初の tail（＝設定ファイルの末尾改行を見た直後、
#                   突合して書き戻す直前）
#
# RACE_TARGET へ RACE_LINE を、RACE_WHERE=prepend なら先頭に、既定では末尾に
# 入れる。prepend を用意してあるのは、行番号をずらす割り込みを作るため。
cat >"$FAKE_BIN_DIR/karakuri-race-hook" <<'RACE_HOOK'
#!/usr/bin/env bash
# usage: karakuri-race-hook <呼び出し元のフェイク名>
name="$1"
var="RACE_ON_$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
want="${!var:-}"
[ -n "$want" ] || exit 0
[ -n "${RACE_TARGET:-}" ] || exit 0
counter="${RACE_COUNTER:?}.${name}"
n=0
if [ -f "$counter" ]; then n="$(cat "$counter")"; fi
n=$((n + 1))
printf '%s\n' "$n" >"$counter"
[ "$n" = "$want" ] || exit 0
if [ "${RACE_WHERE:-append}" = "prepend" ]; then
	printf '%s\n' "${RACE_LINE:?}" | cat - "$RACE_TARGET" >"${RACE_TARGET}.race"
	mv "${RACE_TARGET}.race" "$RACE_TARGET"
else
	printf '%s\n' "${RACE_LINE:?}" >>"$RACE_TARGET"
fi
exit 0
RACE_HOOK
chmod +x "$FAKE_BIN_DIR/karakuri-race-hook"

# --- フェイク sudo --------------------------------------------------------------
# 呼ばれた引数を 1 行 1 呼び出しで記録してから、sudo を剥がして本体を実行する。
# 実行まで通すのは、$ROOT 配下の偽の /etc を実際に組み立てさせるため（install や
# mv はそのまま走ってよい。書き込み先は一時ディレクトリの中しかない）。
# 記録があること／無いことが、そのまま「特権操作をしたか」の判定になる。
#
# `-n`（パスワードを聞かずに諦める）は剥がしてから実行する。実装は終了時の
# 掃除だけでこれを使う。記録には剥がす前の引数をそのまま残す。
cat >"$FAKE_BIN_DIR/sudo" <<'FAKE_SUDO'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SUDO_LOG:?}"
"$(dirname "$0")/karakuri-race-hook" sudo
if [ "${1:-}" = "-n" ]; then shift; fi
exec "$@"
FAKE_SUDO
chmod +x "$FAKE_BIN_DIR/sudo"

# --- フェイク install -----------------------------------------------------------
# -o root -g wheel は非 root では通らないので、所有者の指定は捨てて中身の
# 配置とモードだけを再現する。引数そのものは上のフェイク sudo が丸ごと
# 記録しているので、「どんな所有者・モードを指定したか」の検査はそちらで行う。
cat >"$FAKE_BIN_DIR/install" <<'FAKE_INSTALL'
#!/usr/bin/env bash
mode=""
dir_mode=0
args=()
while [ "$#" -gt 0 ]; do
	case "$1" in
	-d)
		dir_mode=1
		shift
		;;
	-o | -g)
		shift 2
		;;
	-m)
		mode="$2"
		shift 2
		;;
	*)
		args+=("$1")
		shift
		;;
	esac
done
if [ "$dir_mode" -eq 1 ]; then
	mkdir -p "${args[@]}" || exit 1
	if [ -n "$mode" ]; then chmod "$mode" "${args[@]}" || exit 1; fi
	exit 0
fi
src="${args[0]}"
dst="${args[1]}"
mkdir -p "$(dirname "$dst")" || exit 1
cp "$src" "$dst" || exit 1
if [ -n "$mode" ]; then chmod "$mode" "$dst" || exit 1; fi
exit 0
FAKE_INSTALL
chmod +x "$FAKE_BIN_DIR/install"

# --- フェイク launchctl ---------------------------------------------------------
# bootout / bootstrap の終了コードを別々に制御する。実装は「bootout の失敗は
# 正常な経路なので握り、bootstrap の失敗は set -e で止める」という組み立てに
# なっており、その分岐だけをここで再現する。
cat >"$FAKE_BIN_DIR/launchctl" <<'FAKE_LAUNCHCTL'
#!/usr/bin/env bash
case "${1:-}" in
bootout) exit "${FAKE_LAUNCHCTL_BOOTOUT_RC:-0}" ;;
bootstrap) exit "${FAKE_LAUNCHCTL_BOOTSTRAP_RC:-0}" ;;
esac
exit 0
FAKE_LAUNCHCTL
chmod +x "$FAKE_BIN_DIR/launchctl"

# --- フェイク ifconfig ----------------------------------------------------------
# 引数を 1 行 1 呼び出しで記録する。daemon 側のテストでは sudo を通らない
# （launchd が root で直に呼ぶ形なので実装も sudo を付けない）ため、記録は
# sudo とは別のファイルに取る。
#
#   FAKE_LO0_INET          `ifconfig lo0`（引数 1 個）の出力。list が読む。
#   FAKE_IFCONFIG_FAIL_ADDRS  空白区切り。含まれるアドレスの呼び出しだけ失敗する。
#   FAKE_IFCONFIG_RC       上に当たらなかった呼び出しの終了コード。
cat >"$FAKE_BIN_DIR/ifconfig" <<'FAKE_IFCONFIG'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${IFCONFIG_LOG:?}"
if [ "$#" -eq 1 ]; then
	if [ -n "${FAKE_LO0_INET:-}" ]; then
		printf '%s\n' "$FAKE_LO0_INET"
	fi
	exit 0
fi
for a in ${FAKE_IFCONFIG_FAIL_ADDRS:-}; do
	case " $* " in
	*" $a "*) exit 1 ;;
	esac
done
exit "${FAKE_IFCONFIG_RC:-0}"
FAKE_IFCONFIG
chmod +x "$FAKE_BIN_DIR/ifconfig"

# --- フェイク uname -------------------------------------------------------------
# 実装が見るのは `uname -s` だけ。既定は Darwin にしておき、非 macOS の
# 経路を見るテストだけ FAKE_UNAME_S=Linux を張る。
cat >"$FAKE_BIN_DIR/uname" <<'FAKE_UNAME'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_UNAME_S:-Darwin}"
FAKE_UNAME
chmod +x "$FAKE_BIN_DIR/uname"

# --- 素通しのフェイク（mv / wc / tail / grep）-------------------------------------
# この 4 つは実装が普通に使うコマンドで、置き換えたいのは挙動ではなく
# 「その呼び出しの瞬間」である。既定では上の割り込みフックを呼んでから本物へ
# そのまま渡す。本物の場所を決め打たずに済ませるため、PATH の先頭
# （＝このフェイク置き場）を外してから exec する。
#
#   mv    FAKE_MV_FAIL=1 で失敗する。差し替えの途中で落ちたときに、置きかけの
#         ファイルが残らないこと（trap の掃除）を見るため。
#   wc    行番号を数え終えた瞬間に割り込むため。
#   tail  設定ファイルの末尾改行を見た瞬間に割り込むため。
#   grep  FAKE_GREP_RC=2 で「読めなかった」を作るため。grep の 2 は
#         「見つからなかった」(1) とは別物で、実装はこれを区別する。
for tool in mv wc tail; do
	cat >"$FAKE_BIN_DIR/$tool" <<FAKE_PASSTHROUGH
#!/usr/bin/env bash
"\$(dirname "\$0")/karakuri-race-hook" $tool
if [ "$tool" = "mv" ] && [ "\${FAKE_MV_FAIL:-0}" = "1" ]; then
	echo "mv: fake failure" >&2
	exit 1
fi
PATH="\${PATH#*:}"
exec $tool "\$@"
FAKE_PASSTHROUGH
	chmod +x "$FAKE_BIN_DIR/$tool"
done

cat >"$FAKE_BIN_DIR/grep" <<'FAKE_GREP'
#!/usr/bin/env bash
if [ -n "${FAKE_GREP_RC:-}" ]; then
	exit "$FAKE_GREP_RC"
fi
PATH="${PATH#*:}"
exec grep "$@"
FAKE_GREP
chmod +x "$FAKE_BIN_DIR/grep"

# --- サンドボックス --------------------------------------------------------------
# テストごとに、偽の root（$ROOT）と、その配下を指すよう書き換えた実装の写しを
# 作る。書き換えるのは定数の 5 行だけで、ロジックには触れない。
SANDBOX_N=0
ROOT=""
SCRIPT=""
DAEMON_SCRIPT=""
SRC_DIR=""
CONF=""
CONF_BAK=""
HOSTS=""
HOSTS_BAK=""
DAEMON_PATH=""
PLIST_PATH=""

# new_sandbox [no-dist] — no-dist を渡すと配布物（loopback/）を置かない。
new_sandbox() {
	SANDBOX_N=$((SANDBOX_N + 1))
	local base="$WORKDIR/sandbox-$SANDBOX_N"
	ROOT="$base/root"
	SRC_DIR="$base/host/loopback"
	mkdir -p "$ROOT/etc" "$base/host"

	CONF="$ROOT/etc/karakuri/loopback-aliases"
	CONF_BAK="$ROOT/etc/karakuri/loopback-aliases.bak"
	HOSTS="$ROOT/etc/hosts"
	HOSTS_BAK="$ROOT/etc/hosts.karakuri.bak"
	DAEMON_PATH="$ROOT/usr/local/libexec/karakuri-loopback-aliases"
	PLIST_PATH="$ROOT/Library/LaunchDaemons/com.karakuri.loopback-aliases.plist"

	SCRIPT="$base/host/loopback-setup.sh"
	# HOSTS_BAK を HOSTS より先に並べる。sed の ERE は最長一致だが、
	# 順序に依存しない形で書いておく方が読み手に優しい。
	sed -E "s#^(CONF_DIR|DAEMON_DIR|PLIST_PATH|HOSTS_BAK|HOSTS)=\"/#\1=\"${ROOT}/#" \
		"$LOOPBACK_SETUP_SH" >"$SCRIPT"
	chmod +x "$SCRIPT"

	# daemon 本体も同じ理由で写しを取る。あちらは CONF を定数で持ち、
	# ifconfig を絶対パス（/sbin/ifconfig）で呼ぶので、両方を差し替える。
	DAEMON_SCRIPT="$base/karakuri-loopback-aliases"
	rewrite_daemon "$DAEMON_SRC" "$DAEMON_SCRIPT"
	chmod +x "$DAEMON_SCRIPT"

	# 配布物（install が読んで配置する側）の写しも $ROOT 配下を指すよう
	# 直す。install は配置の前に「daemon が読む設定ファイル」と「plist が
	# 起動する program」を自分の定数と突き合わせるので、ここだけ実物の
	# 絶対パスのままにすると、実機では一致している組が不一致として弾かれる。
	# 実機の状態に近いのは、3 つとも同じ場所を指しているこちらである。
	# （突合そのものを見るテストは、あとで写しを配布物のまま戻して行う。）
	if [ "${1:-}" != "no-dist" ]; then
		mkdir -p "$SRC_DIR"
		rewrite_daemon "$DAEMON_SRC" "$SRC_DIR/karakuri-loopback-aliases"
		rewrite_plist "$PLIST_SRC" "$SRC_DIR/com.karakuri.loopback-aliases.plist"
	fi

	SUDO_LOG="$base/sudo.log"
	IFCONFIG_LOG="$base/ifconfig.log"
	: >"$SUDO_LOG"
	: >"$IFCONFIG_LOG"
	export SUDO_LOG IFCONFIG_LOG

	export FAKE_UNAME_S="Darwin"
	export FAKE_LAUNCHCTL_BOOTOUT_RC=0
	export FAKE_LAUNCHCTL_BOOTSTRAP_RC=0
	export FAKE_IFCONFIG_RC=0
	export FAKE_IFCONFIG_FAIL_ADDRS=""
	export FAKE_LO0_INET=""
	export FAKE_MV_FAIL=0
	export FAKE_GREP_RC=""

	# 割り込みフックは既定で止めておく。RACE_COUNTER はサンドボックスごとに
	# 別にして、前のテストの回数が残らないようにする。
	RACE_COUNTER="$base/race"
	export RACE_COUNTER
	export RACE_ON_SUDO="" RACE_ON_WC="" RACE_ON_TAIL=""
	export RACE_TARGET="" RACE_LINE="" RACE_WHERE="append"
}

# rewrite_daemon <src> <dst> — daemon の写しを $ROOT 配下向けに直す。
# 設定ファイルのパスと、呼び出す ifconfig の絶対パスの 2 つ。
rewrite_daemon() {
	sed -e "s#^CONF=/etc/karakuri/loopback-aliases\$#CONF=${CONF}#" \
		-e "s#/sbin/ifconfig lo0 alias#${FAKE_BIN_DIR}/ifconfig lo0 alias#" \
		"$1" >"$2"
}

# rewrite_plist <src> <dst> — plist の写しの ProgramArguments を $ROOT 配下へ。
rewrite_plist() {
	sed -e "s#<string>/usr/local/libexec/karakuri-loopback-aliases</string>#<string>${DAEMON_PATH}</string>#" \
		"$1" >"$2"
}

# seed_conf [addr...] — install を経ずに設定ファイルを用意する。
seed_conf() {
	mkdir -p "$(dirname "$CONF")"
	printf '# karakuri loopback aliases\n' >"$CONF"
	local a
	for a in "$@"; do
		printf '%s\n' "$a" >>"$CONF"
	done
}

# 素の macOS の /etc/hosts に、他ツール（Docker Desktop）の行を足したもの。
# 管理ブロックの外にこれだけの行があっても 1 バイトも動かない、を見るための土台。
HOSTS_PREAMBLE='##
# Host Database
#
# localhost is used to configure the loopback interface
##
127.0.0.1 localhost
255.255.255.255 broadcasthost
::1 localhost
# Added by Docker Desktop
192.168.65.2 host.docker.internal'

HOSTS_TRAILER='# Added by some other tool
203.0.113.9 other.example'

# seed_hosts <text> — /etc/hosts の写しを丸ごと置く（末尾に改行を足す）。
seed_hosts() {
	mkdir -p "$(dirname "$HOSTS")"
	printf '%s\n' "$1" >"$HOSTS"
}

# seed_hosts_with_block <body> — 前置き・管理ブロック・後置きの 3 段で置く。
seed_hosts_with_block() {
	seed_hosts "$(printf '%s\n%s\n%s\n%s\n%s' \
		"$HOSTS_PREAMBLE" "$HOSTS_BEGIN" "$1" "$HOSTS_END" "$HOSTS_TRAILER")"
}

# hosts_outside <file> — マーカーの外側の行だけを出す。
# 前後の比較に使う。行の追加・削除・順序変更のどれが起きてもここが変わる。
hosts_outside() {
	awk -v b="$HOSTS_BEGIN" -v e="$HOSTS_END" '
		$0 == b { inside = 1; next }
		$0 == e { inside = 0; next }
		!inside { print }
	' "$1"
}

# hosts_block <file> — マーカーの内側の行だけを出す。
hosts_block() {
	awk -v b="$HOSTS_BEGIN" -v e="$HOSTS_END" '
		$0 == e { inside = 0; next }
		inside { print }
		$0 == b { inside = 1 }
	' "$1"
}

# --- 実行ヘルパー ---------------------------------------------------------------
# run_case <argv...> — PATH 先頭のフェイク群で、書き換えた loopback-setup.sh の
# 写しを走らせる。結果は CASE_RC / CASE_STDOUT / CASE_STDERR に残す。
CASE_RC=0
CASE_STDOUT=""
CASE_STDERR=""
run_case() {
	local out err
	out="$(mktemp)"
	err="$(mktemp)"
	if PATH="$FAKE_BIN_DIR:$PATH" bash "$SCRIPT" "$@" >"$out" 2>"$err"; then
		CASE_RC=0
	else
		CASE_RC=$?
	fi
	CASE_STDOUT="$(cat "$out")"
	CASE_STDERR="$(cat "$err")"
	rm -f "$out" "$err"
}

# run_daemon — 配布物側（karakuri-loopback-aliases）の写しを走らせる。
# こちらは launchd から root で直に呼ばれるものなので sudo は挟まない。
run_daemon() {
	local out err
	out="$(mktemp)"
	err="$(mktemp)"
	if PATH="$FAKE_BIN_DIR:$PATH" sh "$DAEMON_SCRIPT" >"$out" 2>"$err"; then
		CASE_RC=0
	else
		CASE_RC=$?
	fi
	CASE_STDOUT="$(cat "$out")"
	CASE_STDERR="$(cat "$err")"
	rm -f "$out" "$err"
}

# assert_no_privileged_ops <ラベル> — フェイク sudo の記録が空であること。
assert_no_privileged_ops() {
	if [ ! -s "$SUDO_LOG" ]; then
		ok "$1: no privileged operation was attempted"
	else
		ng "$1: privileged operations ran ($(tr '\n' ';' <"$SUDO_LOG"))"
	fi
}

# assert_sudo_line <行> <ラベル> — フェイク sudo の記録に完全一致の行があること。
assert_sudo_line() {
	if grep -qxF -- "$1" "$SUDO_LOG"; then
		ok "$2"
	else
		ng "$2 (sudo log: $(tr '\n' ';' <"$SUDO_LOG"))"
	fi
}

# ==============================================================================
# install
# ==============================================================================

# --- 2 回打っても同じ結果になる ------------------------------------------------
echo "install is idempotent"
new_sandbox
seed_hosts "$HOSTS_PREAMBLE"

run_case install
first_rc="$CASE_RC"
first_conf="$(cat "$CONF" 2>/dev/null)"
first_tree="$(cd "$ROOT" && find . -type f | sort)"

run_case install
second_conf="$(cat "$CONF" 2>/dev/null)"
second_tree="$(cd "$ROOT" && find . -type f | sort)"

if [ "$first_rc" -eq 0 ] && [ "$CASE_RC" -eq 0 ]; then
	ok "install exits zero on both the first and the second run"
else
	ng "install exited $first_rc then $CASE_RC (stderr: $CASE_STDERR)"
fi

if [ "$first_tree" = "$second_tree" ] && [ -n "$first_tree" ]; then
	ok "the second install leaves exactly the same set of files"
else
	ng "the second install changed the installed file set"
fi

if [ "$first_conf" = "$second_conf" ]; then
	ok "the second install leaves the config file byte-identical"
else
	ng "the second install rewrote the config file"
fi

case "$CASE_STDOUT" in
*"kept"*) ok "the second install reports that it kept the existing config file" ;;
*) ng "the second install did not report keeping the config (stdout: $CASE_STDOUT)" ;;
esac

# --- 既にある設定ファイルは上書きしない ----------------------------------------
echo "install keeps an existing config file"
new_sandbox
seed_conf "127.0.1.1" "127.0.2.7"
conf_before="$(cat "$CONF")"

run_case install

if [ "$CASE_RC" -eq 0 ]; then
	ok "install exits zero when the config file already exists"
else
	ng "install exited $CASE_RC with an existing config (stderr: $CASE_STDERR)"
fi

if [ "$(cat "$CONF")" = "$conf_before" ]; then
	ok "install does not overwrite the addresses already in the config file"
else
	ng "install overwrote the existing config file (now: $(cat "$CONF"))"
fi

# 設定済みのアドレスはその場で張り直される（再起動を待たせない）。
for addr in 127.0.1.1 127.0.2.7; do
	assert_sudo_line "ifconfig lo0 alias $addr up" \
		"install re-aliases $addr from the existing config file"
done

# --- daemon 本体と plist の配置（所有者・モードの引数） -------------------------
echo "install places the daemon and the plist with the right ownership and mode"
new_sandbox

run_case install

assert_sudo_line "install -d -o root -g wheel -m 0755 $ROOT/etc/karakuri" \
	"the config directory is created root:wheel 0755"
assert_sudo_line "install -d -o root -g wheel -m 0755 $ROOT/usr/local/libexec" \
	"the libexec directory is created root:wheel 0755"
assert_sudo_line "install -o root -g wheel -m 0755 $SRC_DIR/karakuri-loopback-aliases $DAEMON_PATH" \
	"the daemon is installed root:wheel 0755"
assert_sudo_line "install -o root -g wheel -m 0644 $SRC_DIR/com.karakuri.loopback-aliases.plist $PLIST_PATH" \
	"the plist is installed root:wheel 0644"

# 雛形の設定ファイルは一時ファイル経由なので、名前は決め打てない。
if grep -qE "^install -o root -g wheel -m 0644 .+ $CONF\$" "$SUDO_LOG"; then
	ok "the config file template is installed root:wheel 0644"
else
	ng "the config file was not installed with root:wheel 0644"
fi

if [ -f "$DAEMON_PATH" ] && [ -f "$PLIST_PATH" ] && [ -f "$CONF" ]; then
	ok "the daemon, the plist and the config file all land on disk"
else
	ng "install did not place all three files"
fi

if [ "$(stat -c '%a' "$DAEMON_PATH")" = "755" ] && [ "$(stat -c '%a' "$PLIST_PATH")" = "644" ]; then
	ok "the placed daemon is 0755 and the placed plist is 0644"
else
	ng "the placed files have unexpected modes"
fi

# 比べる相手は $SRC_DIR の写し（＝この sandbox での「配布物」）。実物の
# 配布物と比べていたのを直したのは、写しの側が $ROOT 配下を指すように
# 書き換えられているためで、install が中身をいじらないことを見る目的は同じ。
if cmp -s "$SRC_DIR/karakuri-loopback-aliases" "$DAEMON_PATH"; then
	ok "the placed daemon is a verbatim copy of the distributed one"
else
	ng "the placed daemon differs from the distributed one"
fi

if cmp -s "$SRC_DIR/com.karakuri.loopback-aliases.plist" "$PLIST_PATH"; then
	ok "the placed plist is a verbatim copy of the distributed one"
else
	ng "the placed plist differs from the distributed one"
fi

# --- bootout が失敗しても bootstrap へ進む -------------------------------------
echo "a failing launchctl bootout does not stop the bootstrap"
new_sandbox
export FAKE_LAUNCHCTL_BOOTOUT_RC=1

run_case install

if [ "$CASE_RC" -eq 0 ]; then
	ok "install exits zero even though bootout failed (nothing was loaded yet)"
else
	ng "install exited $CASE_RC after a failing bootout (stderr: $CASE_STDERR)"
fi

assert_sudo_line "launchctl bootout system $PLIST_PATH" \
	"bootout is attempted before bootstrap"
assert_sudo_line "launchctl bootstrap system $PLIST_PATH" \
	"bootstrap runs even after bootout failed"

# --- bootstrap が失敗しても install は最後まで行き、非ゼロで返す -----------------
# bootout は launchd が job を落とし終える前に戻ることがあり、直後の
# bootstrap が "already bootstrapped" で落ちる。そこで set -e に止めさせると、
# plist と daemon は配置済みなのに alias の復元が済んでいない状態で終わる。
echo "a failing bootstrap still leaves a usable machine, and says so"
new_sandbox
seed_conf "127.0.1.1" "127.0.2.7"
export FAKE_LAUNCHCTL_BOOTSTRAP_RC=1

run_case install

if [ "$CASE_RC" -ne 0 ]; then
	ok "install bootstrap: a failing bootstrap does make install exit non-zero"
else
	ng "install bootstrap: a failing bootstrap was swallowed (install exited 0)"
fi

# 止まらずに最後まで行くこと。ここが元の壊れ方（set -e が即死させる）との差。
for addr in 127.0.1.1 127.0.2.7; do
	assert_sudo_line "ifconfig lo0 alias $addr up" \
		"install bootstrap: $addr is still raised after the bootstrap failed"
done

case "$CASE_STDERR" in
*"already"*"bootout system/com.karakuri.loopback-aliases"*)
	ok "install bootstrap: the error names the likely cause and the exact next command"
	;;
*) ng "install bootstrap: the error did not name the next step (stderr: $CASE_STDERR)" ;;
esac

case "$CASE_STDERR" in
*"not loaded"*"after the next reboot"*)
	ok "install bootstrap: the summary says what is still missing"
	;;
*) ng "install bootstrap: the summary did not say the daemon is not loaded (stderr: $CASE_STDERR)" ;;
esac

if [ -f "$DAEMON_PATH" ] && [ -f "$PLIST_PATH" ]; then
	ok "install bootstrap: the daemon and the plist are in place even though the bootstrap failed"
else
	ng "install bootstrap: install stopped before placing its files"
fi

# --- 配布物が無いときは何も置かずに失敗する ------------------------------------
echo "install refuses to run without the loopback/ payload"
new_sandbox no-dist

run_case install

if [ "$CASE_RC" -ne 0 ]; then
	ok "a missing loopback/ directory causes non-zero exit"
else
	ng "a missing loopback/ directory did not cause non-zero exit"
fi

case "$CASE_STDERR" in
*"cannot find"*"karakuri-loopback-aliases"*) ok "the error names the file it could not find" ;;
*) ng "the error did not name the missing file (stderr: $CASE_STDERR)" ;;
esac

assert_no_privileged_ops "missing payload"

if [ ! -e "$ROOT/etc/karakuri" ] && [ ! -e "$DAEMON_PATH" ] && [ ! -e "$PLIST_PATH" ]; then
	ok "nothing is placed when the payload is missing"
else
	ng "something was placed even though the payload was missing"
fi

# ==============================================================================
# add
# ==============================================================================

# --- アドレスとホスト名が設定ファイルと /etc/hosts の両方に入る -----------------
echo "add records the address in the config file and the names in /etc/hosts"
new_sandbox
seed_conf
seed_hosts "$HOSTS_PREAMBLE"

run_case add 127.0.1.5 app.test api.app.test

if [ "$CASE_RC" -eq 0 ]; then
	ok "add exits zero on the happy path"
else
	ng "add exited $CASE_RC (stderr: $CASE_STDERR)"
fi

if grep -qxF -- "127.0.1.5" "$CONF"; then
	ok "the address is appended to the config file"
else
	ng "the address is not in the config file ($(cat "$CONF"))"
fi

if [ "$(hosts_block "$HOSTS")" = "127.0.1.5 app.test api.app.test" ]; then
	ok "both hostnames land on one line inside the managed block"
else
	ng "unexpected managed block: $(hosts_block "$HOSTS")"
fi

assert_sudo_line "ifconfig lo0 alias 127.0.1.5 up" "the alias is raised on lo0 right away"

# ホスト名は設定ファイルには書かない（/etc/hosts が名前の権威）。
if grep -q "app.test" "$CONF"; then
	ng "the config file records hostnames as well as the address"
else
	ok "the config file records the address only, not the hostnames"
fi

# --- 同じ引数で 2 回打っても設定ファイルの行が重複しない ------------------------
echo "add is idempotent"
new_sandbox
seed_conf
seed_hosts "$HOSTS_PREAMBLE"

run_case add 127.0.1.5 app.test
run_case add 127.0.1.5 app.test

if [ "$CASE_RC" -eq 0 ]; then
	ok "the second add exits zero"
else
	ng "the second add exited $CASE_RC (stderr: $CASE_STDERR)"
fi

if [ "$(grep -cxF -- "127.0.1.5" "$CONF")" = "1" ]; then
	ok "the address appears exactly once in the config file"
else
	ng "the address is duplicated in the config file ($(cat "$CONF"))"
fi

if [ "$(hosts_block "$HOSTS")" = "127.0.1.5 app.test" ]; then
	ok "the managed block still holds exactly one line"
else
	ng "the managed block was duplicated: $(hosts_block "$HOSTS")"
fi

case "$CASE_STDOUT" in
*"already"*) ok "the second add reports that the entry is already there" ;;
*) ng "the second add did not report the existing entry (stdout: $CASE_STDOUT)" ;;
esac

# --- 同じアドレスへの 2 つ目のホスト名は同じ行にマージされる --------------------
echo "a second hostname for the same address merges into the same line"
new_sandbox
seed_conf
seed_hosts "$HOSTS_PREAMBLE"

run_case add 127.0.1.5 a.test
run_case add 127.0.1.5 b.test

if [ "$(hosts_block "$HOSTS")" = "127.0.1.5 a.test b.test" ]; then
	ok "the second hostname is appended to the existing address line"
else
	ng "the second hostname did not merge: $(hosts_block "$HOSTS")"
fi

if [ "$(grep -cxF -- "127.0.1.5" "$CONF")" = "1" ]; then
	ok "the config file still lists the address once"
else
	ng "the config file gained a duplicate address ($(cat "$CONF"))"
fi

# 同じ名前を別のアドレスへ移そうとしたら止まる（先に一致した行が勝つ
# /etc/hosts で、名前が 2 箇所に割れた状態を作らないため）。
run_case add 127.0.2.9 a.test

if [ "$CASE_RC" -ne 0 ]; then
	ok "moving a name to another address without removing it first is refused"
else
	ng "a name was silently mapped to a second address"
fi

case "$CASE_STDERR" in
*"already mapped to 127.0.1.5"*) ok "the refusal names the address that already owns it" ;;
*) ng "the refusal did not name the current owner (stderr: $CASE_STDERR)" ;;
esac

# --- 不正なアドレスは全部拒否され、特権操作が 1 つも走らない --------------------
echo "add rejects addresses it does not manage"
for bad in 10.0.0.1 127.0.0.1 127.0.0.256 abc; do
	new_sandbox
	seed_conf
	seed_hosts "$HOSTS_PREAMBLE"

	run_case add "$bad" app.test

	if [ "$CASE_RC" -ne 0 ]; then
		ok "'$bad' causes non-zero exit"
	else
		ng "'$bad' was accepted"
	fi

	case "$CASE_STDERR" in
	*"$bad"*) ok "'$bad' is named in the error message" ;;
	*) ng "'$bad': the error message did not name it (stderr: $CASE_STDERR)" ;;
	esac

	assert_no_privileged_ops "'$bad'"

	if [ "$(cat "$CONF")" = "# karakuri loopback aliases" ]; then
		ok "'$bad' leaves the config file untouched"
	else
		ng "'$bad' changed the config file ($(cat "$CONF"))"
	fi
done

# --- 不正なホスト名は拒否される --------------------------------------------------
echo "add rejects hostnames it cannot write to /etc/hosts"
LONG_HOSTNAME="$(head -c 254 /dev/zero | tr '\0' 'a')"
for bad in "-lead.test" "bad name" "$LONG_HOSTNAME"; do
	new_sandbox
	seed_conf
	seed_hosts "$HOSTS_PREAMBLE"

	run_case add 127.0.1.5 "$bad"

	label="$bad"
	if [ "${#label}" -gt 20 ]; then
		label="a hostname of ${#bad} characters"
	fi

	if [ "$CASE_RC" -ne 0 ]; then
		ok "$label causes non-zero exit"
	else
		ng "$label was accepted"
	fi

	assert_no_privileged_ops "$label"
done

# --- 設定ファイルが無いなら先に install しろと言って失敗する ---------------------
echo "add before install tells you to install first"
new_sandbox
seed_hosts "$HOSTS_PREAMBLE"

run_case add 127.0.1.5 app.test

if [ "$CASE_RC" -ne 0 ]; then
	ok "add without a config file causes non-zero exit"
else
	ng "add without a config file did not cause non-zero exit"
fi

case "$CASE_STDERR" in
*"install"*) ok "the error tells you to run install first" ;;
*) ng "the error did not mention install (stderr: $CASE_STDERR)" ;;
esac

assert_no_privileged_ops "add before install"

# ==============================================================================
# remove
# ==============================================================================

# --- アドレス指定: 設定ファイル・/etc/hosts・alias の 3 つが消える ---------------
echo "remove <addr> drops the config line, the hosts entry and the alias"
new_sandbox
seed_conf "127.0.1.5" "127.0.2.7"
seed_hosts_with_block "$(printf '127.0.1.5 app.test\n127.0.2.7 other.test')"

run_case remove 127.0.1.5

if [ "$CASE_RC" -eq 0 ]; then
	ok "remove <addr> exits zero"
else
	ng "remove <addr> exited $CASE_RC (stderr: $CASE_STDERR)"
fi

if grep -qxF -- "127.0.1.5" "$CONF"; then
	ng "the address is still in the config file ($(cat "$CONF"))"
else
	ok "the address is dropped from the config file"
fi

if grep -qxF -- "127.0.2.7" "$CONF"; then
	ok "the other address is left in the config file"
else
	ng "removing one address dropped the other one too ($(cat "$CONF"))"
fi

if [ "$(hosts_block "$HOSTS")" = "127.0.2.7 other.test" ]; then
	ok "only the removed address' line leaves the managed block"
else
	ng "unexpected managed block after remove: $(hosts_block "$HOSTS")"
fi

assert_sudo_line "ifconfig lo0 -alias 127.0.1.5" "the alias is taken off lo0"

# --- ホスト名指定: その名前だけが消え、行に他の名前が残れば行は残る -------------
echo "remove <hostname> drops only that name"
new_sandbox
seed_conf "127.0.1.5"
seed_hosts_with_block "127.0.1.5 a.test b.test"

run_case remove a.test

if [ "$CASE_RC" -eq 0 ]; then
	ok "remove <hostname> exits zero"
else
	ng "remove <hostname> exited $CASE_RC (stderr: $CASE_STDERR)"
fi

if [ "$(hosts_block "$HOSTS")" = "127.0.1.5 b.test" ]; then
	ok "the address line survives with the remaining name"
else
	ng "unexpected managed block after removing a name: $(hosts_block "$HOSTS")"
fi

# --- ホスト名指定では alias も設定ファイルの行も残る -----------------------------
# 同じアドレスを、こちらからは見えない別のプロジェクトが使っている
# かもしれないため。アドレスを消すのは、利用者がアドレスを名指ししたときだけ。
if grep -qxF -- "127.0.1.5" "$CONF"; then
	ok "removing a name leaves the address in the config file"
else
	ng "removing a name also dropped the address from the config file"
fi

if grep -q -- "-alias" "$SUDO_LOG"; then
	ng "removing a name also took the alias off lo0"
else
	ok "removing a name does not touch the lo0 alias"
fi

case "$CASE_STDOUT" in
*"still aliased"*) ok "the output says the address is still aliased and still listed" ;;
*) ng "the output did not mention the surviving alias (stdout: $CASE_STDOUT)" ;;
esac

# 最後の名前を消したら、名前の無いアドレス行は残さない。
run_case remove b.test

if [ -z "$(hosts_block "$HOSTS")" ]; then
	ok "the address line goes away once its last name is removed"
else
	ng "an address line with no names was left behind: $(hosts_block "$HOSTS")"
fi

# --- 存在しない対象を消しても壊れない --------------------------------------------
echo "removing something that is not there is harmless"
new_sandbox
seed_conf "127.0.1.5"
seed_hosts_with_block "127.0.1.5 app.test"
cp "$HOSTS" "$WORKDIR/hosts.snapshot"
conf_before="$(cat "$CONF")"
export FAKE_IFCONFIG_RC=1 # 張られていないアドレスへの -alias は実機でも失敗する

run_case remove 127.0.9.9

if [ "$CASE_RC" -eq 0 ]; then
	ok "removing an unknown address exits zero"
else
	ng "removing an unknown address exited $CASE_RC (stderr: $CASE_STDERR)"
fi

if cmp -s "$HOSTS" "$WORKDIR/hosts.snapshot" && [ "$(cat "$CONF")" = "$conf_before" ]; then
	ok "removing an unknown address leaves both files byte-identical"
else
	ng "removing an unknown address modified a file"
fi

run_case remove nosuch.test

if [ "$CASE_RC" -eq 0 ]; then
	ok "removing an unknown hostname exits zero"
else
	ng "removing an unknown hostname exited $CASE_RC (stderr: $CASE_STDERR)"
fi

if cmp -s "$HOSTS" "$WORKDIR/hosts.snapshot" && [ "$(cat "$CONF")" = "$conf_before" ]; then
	ok "removing an unknown hostname leaves both files byte-identical"
else
	ng "removing an unknown hostname modified a file"
fi

case "$CASE_STDOUT" in
*"not in the managed block"*) ok "the output explains that the name is not in the managed block" ;;
*) ng "the output did not explain the no-op (stdout: $CASE_STDOUT)" ;;
esac

# ==============================================================================
# /etc/hosts の保護
# ==============================================================================

# --- 管理ブロックの外は 1 行も動かない ------------------------------------------
echo "lines outside the managed block are never touched"
for step in add-existing-block add-no-block remove-addr remove-name; do
	new_sandbox
	seed_conf "127.0.1.5"

	case "$step" in
	add-no-block) seed_hosts "$(printf '%s\n%s' "$HOSTS_PREAMBLE" "$HOSTS_TRAILER")" ;;
	*) seed_hosts_with_block "$(printf '127.0.1.5 app.test\n127.0.2.7 other.test')" ;;
	esac

	outside_before="$(hosts_outside "$HOSTS")"

	case "$step" in
	add-existing-block) run_case add 127.0.1.5 extra.test ;;
	add-no-block) run_case add 127.0.1.5 app.test ;;
	remove-addr) run_case remove 127.0.2.7 ;;
	remove-name) run_case remove app.test ;;
	esac

	if [ "$(hosts_outside "$HOSTS")" = "$outside_before" ]; then
		ok "$step: every line outside the markers survives unchanged and in order"
	else
		ng "$step: lines outside the markers changed"
	fi
done

# --- マーカーの対応が壊れていたら、直さずに止める --------------------------------
# 開始マーカーだけ／終了マーカーだけ／2 組ある／順序が逆、の 4 通り。
echo "broken markers make the tool refuse to touch /etc/hosts"
for shape in begin-only end-only two-pairs reversed; do
	new_sandbox
	seed_conf "127.0.1.5"

	case "$shape" in
	begin-only)
		seed_hosts "$(printf '%s\n%s\n127.0.1.5 app.test\n%s' \
			"$HOSTS_PREAMBLE" "$HOSTS_BEGIN" "$HOSTS_TRAILER")"
		;;
	end-only)
		seed_hosts "$(printf '%s\n127.0.1.5 app.test\n%s\n%s' \
			"$HOSTS_PREAMBLE" "$HOSTS_END" "$HOSTS_TRAILER")"
		;;
	two-pairs)
		seed_hosts "$(printf '%s\n%s\n127.0.1.5 app.test\n%s\n%s\n127.0.2.7 other.test\n%s\n%s' \
			"$HOSTS_PREAMBLE" "$HOSTS_BEGIN" "$HOSTS_END" \
			"$HOSTS_BEGIN" "$HOSTS_END" "$HOSTS_TRAILER")"
		;;
	reversed)
		seed_hosts "$(printf '%s\n%s\n127.0.1.5 app.test\n%s\n%s' \
			"$HOSTS_PREAMBLE" "$HOSTS_END" "$HOSTS_BEGIN" "$HOSTS_TRAILER")"
		;;
	esac

	cp "$HOSTS" "$WORKDIR/hosts.snapshot"

	run_case add 127.0.1.5 new.test

	if [ "$CASE_RC" -ne 0 ]; then
		ok "$shape: add causes non-zero exit"
	else
		ng "$shape: add did not cause non-zero exit"
	fi

	case "$CASE_STDERR" in
	*"Refusing to touch"*) ok "$shape: the error says it refuses to touch the file" ;;
	*) ng "$shape: the error did not say it refuses (stderr: $CASE_STDERR)" ;;
	esac

	if cmp -s "$HOSTS" "$WORKDIR/hosts.snapshot"; then
		ok "$shape: /etc/hosts is left byte-identical"
	else
		ng "$shape: /etc/hosts was rewritten despite the broken markers"
	fi

	assert_no_privileged_ops "$shape"

	if [ ! -e "$HOSTS_BAK" ]; then
		ok "$shape: no backup is written either (nothing was about to change)"
	else
		ng "$shape: a backup was written even though nothing was changed"
	fi
done

# --- 末尾に改行が無い /etc/hosts でもブロックが正しく新設される ------------------
echo "a /etc/hosts without a trailing newline still gets a well-formed block"
new_sandbox
seed_conf "127.0.1.5"
mkdir -p "$(dirname "$HOSTS")"
printf '%s' "$HOSTS_PREAMBLE" >"$HOSTS" # 末尾に改行を置かない

run_case add 127.0.1.5 app.test

if [ "$CASE_RC" -eq 0 ]; then
	ok "add exits zero against a file with no trailing newline"
else
	ng "add exited $CASE_RC against a file with no trailing newline (stderr: $CASE_STDERR)"
fi

if grep -qxF -- "192.168.65.2 host.docker.internal" "$HOSTS"; then
	ok "the last pre-existing line is not glued to the begin marker"
else
	ng "the last pre-existing line was mangled ($(tail -n 4 "$HOSTS" | tr '\n' '|'))"
fi

if grep -qxF -- "$HOSTS_BEGIN" "$HOSTS" && grep -qxF -- "$HOSTS_END" "$HOSTS"; then
	ok "both markers land on lines of their own"
else
	ng "the markers were not written as whole lines"
fi

if [ "$(hosts_block "$HOSTS")" = "127.0.1.5 app.test" ]; then
	ok "the new block holds exactly the entry that was added"
else
	ng "unexpected new block: $(hosts_block "$HOSTS")"
fi

if [ "$(hosts_outside "$HOSTS")" = "$HOSTS_PREAMBLE" ]; then
	ok "nothing outside the new block was added, dropped or reordered"
else
	ng "the content outside the new block changed"
fi

# --- 書き換え前にバックアップが作られる ------------------------------------------
echo "/etc/hosts is backed up before it is rewritten"
new_sandbox
seed_conf "127.0.1.5"
seed_hosts_with_block "127.0.2.7 other.test"
cp "$HOSTS" "$WORKDIR/hosts.snapshot"

run_case add 127.0.1.5 app.test

if [ -f "$HOSTS_BAK" ]; then
	ok "the backup file exists after a rewrite"
else
	ng "no backup was written"
fi

if cmp -s "$HOSTS_BAK" "$WORKDIR/hosts.snapshot"; then
	ok "the backup holds the pre-rewrite content, byte for byte"
else
	ng "the backup does not match the pre-rewrite content"
fi

# 退避も特権で取る。退避元は /etc/hosts の写し（一時ファイル）なので名前は
# 決め打てないが、属性を明示した install で置いていることは見ておく
# （cp だと退避先が既にあるときと無いときでモードが変わる）。
if grep -qE "^install -o root -g wheel -m 0644 .+ $HOSTS_BAK\$" "$SUDO_LOG"; then
	ok "the backup itself is taken under sudo, with the ownership and mode spelled out"
else
	ng "the backup was not installed as root:wheel 0644 (sudo log: $(tr '\n' ';' <"$SUDO_LOG"))"
fi

case "$CASE_STDOUT" in
*"backup"*) ok "the output tells you where the backup is" ;;
*) ng "the output did not mention the backup (stdout: $CASE_STDOUT)" ;;
esac

# ==============================================================================
# macOS 以外
# ==============================================================================

# --- 非 macOS ではサブコマンドを問わず、何も変更せず 0 で終わる ------------------
# 対応 OS は macOS と Windows(Git Bash) の 2 つで、非 Darwin は Windows だけに
# なる。lo0 alias も /etc/hosts の管理ブロックも macOS 固有の迂回策で、
# Windows では張る意味も書き換える意味も無い（Git Bash の /etc/hosts は
# Windows の名前解決に使われない）ため、判定を通った時点で即終了する。
# サブコマンドの解釈より前で止まることを、未知のサブコマンドと引数無しの
# 2 通りでも確かめる。
#
# 実装の判定は「Darwin かどうか」の二値なので Linux でも通るが、対応 OS と
# 宣言した Windows(Git Bash) の uname 出力（MINGW64_NT-* 系）でも同じ主張を
# 通しておく。
echo "non-macOS makes no changes for any subcommand, known or not"

# 引数を配列に集めてからまとめて渡す形（read -ra / "${argv[@]}"）は使わない。
# bash 4.4 未満（macOS の stock /bin/bash 3.2 が該当）では、set -u 下で
# 空配列を "${argv[@]}" 展開すると unbound variable になるとされている
# （この環境に 3.2 が無く、実機では未確認）。関数の "$@" を使えば配列を
# 経由しないので、この問題を避けられる。
_assert_non_macos_noop() {
	local uname_s="$1"
	shift
	local label="non-macOS(${uname_s}) '${*:-<no args>}'"
	local hosts_before

	new_sandbox
	seed_hosts "$HOSTS_PREAMBLE"
	export FAKE_UNAME_S="$uname_s"
	hosts_before="$(cat "$HOSTS")"

	run_case "$@"

	if [ "$CASE_RC" -eq 0 ]; then
		ok "$label exits zero"
	else
		ng "$label exited $CASE_RC (stderr: $CASE_STDERR)"
	fi

	assert_no_privileged_ops "$label"

	if [ ! -s "$IFCONFIG_LOG" ]; then
		ok "$label does not run ifconfig"
	else
		ng "$label ran ifconfig"
	fi

	if [ "$(cat "$HOSTS")" = "$hosts_before" ]; then
		ok "$label leaves /etc/hosts untouched"
	else
		ng "$label changed /etc/hosts"
	fi

	if [ ! -e "$CONF" ]; then
		ok "$label does not create the config file"
	else
		ng "$label created the config file"
	fi

	if [ -z "$CASE_STDOUT" ]; then
		ok "$label prints nothing on stdout"
	else
		ng "$label wrote to stdout ($CASE_STDOUT)"
	fi

	case "$CASE_STDERR" in
	*"macOS only"*) ok "$label names itself macOS only" ;;
	*) ng "$label did not say macOS only (stderr: $CASE_STDERR)" ;;
	esac
}

for uname_s in Linux MINGW64_NT-10.0-22631; do
	_assert_non_macos_noop "$uname_s" install
	_assert_non_macos_noop "$uname_s" add 127.0.1.5 app.test
	_assert_non_macos_noop "$uname_s" remove 127.0.1.5
	_assert_non_macos_noop "$uname_s" list
	_assert_non_macos_noop "$uname_s"
	_assert_non_macos_noop "$uname_s" no-such-command
	_assert_non_macos_noop "$uname_s" -h
done

# ==============================================================================
# daemon 本体（karakuri-loopback-aliases）
# ==============================================================================

# --- 設定ファイルの各行から ifconfig が呼ばれる ----------------------------------
echo "the daemon raises an alias for every address in the config file"
new_sandbox
seed_conf "127.0.1.1" "127.0.1.2" "127.0.2.7"

run_daemon

if [ "$CASE_RC" -eq 0 ]; then
	ok "the daemon exits zero"
else
	ng "the daemon exited $CASE_RC (stderr: $CASE_STDERR)"
fi

for addr in 127.0.1.1 127.0.1.2 127.0.2.7; do
	if grep -qxF -- "lo0 alias $addr up" "$IFCONFIG_LOG"; then
		ok "the daemon raises $addr"
	else
		ng "the daemon did not raise $addr"
	fi
done

if [ "$(wc -l <"$IFCONFIG_LOG")" -eq 3 ]; then
	ok "the daemon calls ifconfig exactly once per configured address"
else
	ng "the daemon made $(wc -l <"$IFCONFIG_LOG") ifconfig calls for 3 addresses"
fi

# --- 空行・# 行・行末のコメント --------------------------------------------------
# 設定ファイルは手で編集してよいことになっているので、この 3 つは通す必要がある。
# 最終行に改行が無い場合も読み落とさない（read の `|| [ -n "$line" ]`）。
echo "the daemon skips blank lines and comments, and reads the last line without a newline"
new_sandbox
mkdir -p "$(dirname "$CONF")"
printf '# a header comment\n\n127.0.1.1\n   # an indented comment\n\n127.0.1.2  # a trailing note\n127.0.1.3' >"$CONF"

run_daemon

if [ "$CASE_RC" -eq 0 ]; then
	ok "the daemon exits zero on a hand-edited config file"
else
	ng "the daemon exited $CASE_RC (stderr: $CASE_STDERR)"
fi

for addr in 127.0.1.1 127.0.1.2 127.0.1.3; do
	if grep -qxF -- "lo0 alias $addr up" "$IFCONFIG_LOG"; then
		ok "the daemon raises $addr from the hand-edited file"
	else
		ng "the daemon did not raise $addr from the hand-edited file"
	fi
done

if [ "$(wc -l <"$IFCONFIG_LOG")" -eq 3 ]; then
	ok "blank lines, comment lines and the trailing note produce no extra calls"
else
	ng "unexpected ifconfig calls: $(tr '\n' ';' <"$IFCONFIG_LOG")"
fi

# --- 127. で始まらないアドレスは ifconfig に渡らない ------------------------------
# ifconfig に渡る値の範囲が実装の 1 箇所で閉じている、というのがこの検査の的。
echo "the daemon never hands a non-loopback address to ifconfig"
new_sandbox
mkdir -p "$(dirname "$CONF")"
printf '10.0.0.1\n0.0.0.0\n192.168.65.2\n127.0.1.9\n' >"$CONF"

run_daemon

if [ "$CASE_RC" -eq 0 ]; then
	ok "the daemon exits zero despite the out-of-range lines"
else
	ng "the daemon exited $CASE_RC (stderr: $CASE_STDERR)"
fi

if [ "$(cat "$IFCONFIG_LOG")" = "lo0 alias 127.0.1.9 up" ]; then
	ok "only the 127.* address reaches ifconfig"
else
	ng "ifconfig saw: $(tr '\n' ';' <"$IFCONFIG_LOG")"
fi

for bad in 10.0.0.1 0.0.0.0 192.168.65.2; do
	case "$CASE_STDERR" in
	*"$bad"*) ok "the skipped address $bad is named on stderr" ;;
	*) ng "the skipped address $bad was not reported (stderr: $CASE_STDERR)" ;;
	esac
done

# --- 1 つ失敗しても残りは処理される ----------------------------------------------
echo "one failing ifconfig does not stop the rest"
new_sandbox
seed_conf "127.0.1.1" "127.0.1.2" "127.0.1.3"
export FAKE_IFCONFIG_FAIL_ADDRS="127.0.1.2"

run_daemon

if [ "$CASE_RC" -eq 0 ]; then
	ok "the daemon still exits zero when one address fails"
else
	ng "the daemon exited $CASE_RC after one failure (stderr: $CASE_STDERR)"
fi

for addr in 127.0.1.1 127.0.1.2 127.0.1.3; do
	if grep -qxF -- "lo0 alias $addr up" "$IFCONFIG_LOG"; then
		ok "$addr is still attempted"
	else
		ng "$addr was skipped after the earlier failure"
	fi
done

case "$CASE_STDERR" in
*"127.0.1.2"*failed*) ok "the failing address is named on stderr" ;;
*) ng "the failure was not reported (stderr: $CASE_STDERR)" ;;
esac

# --- 設定ファイルが無いときは何もせず 0 で終わる ---------------------------------
# install だけ済ませてまだ add していない状態は正常なので、log にエラーを
# 残さない（毎起動 1 行のエラーを読み飛ばす習慣を作らない）。
echo "the daemon is a silent no-op without a config file"
new_sandbox

run_daemon

if [ "$CASE_RC" -eq 0 ]; then
	ok "the daemon exits zero when the config file is absent"
else
	ng "the daemon exited $CASE_RC without a config file (stderr: $CASE_STDERR)"
fi

if [ ! -s "$IFCONFIG_LOG" ]; then
	ok "the daemon does not call ifconfig without a config file"
else
	ng "the daemon called ifconfig without a config file"
fi

if [ -z "$CASE_STDERR" ] && [ -z "$CASE_STDOUT" ]; then
	ok "the daemon says nothing when there is nothing to do"
else
	ng "the daemon produced output with no config file (stderr: $CASE_STDERR)"
fi

# ==============================================================================
# レビューで挙がった壊れ方が再発しないこと
#
# ここから下は、1 件ずつ「その壊れ方を起こす状況を作って、起きないこと」を
# 見る。上の節と重複する検査もあるが、あちらは仕様の記述で、こちらは特定の
# 壊れ方に対する見張りである。壊れ方の側から書いておかないと、仕様を書き
# 直したときに一緒に消える。
# ==============================================================================

# --- /etc/hosts の差し替えが原子的 ------------------------------------------------
# cp は dst を truncate してから書くので、その途中で落ちると /etc/hosts が
# 欠けた状態で残り、ホストの名前解決が全面的に止まる。同じディレクトリに
# 属性を明示した新ファイルを作って mv（＝同一 fs なら rename(2)）で差し替える。
echo "/etc/hosts is replaced by rename, never truncated in place"
new_sandbox
seed_conf "127.0.1.5"
seed_hosts_with_block "127.0.2.7 other.test"

run_case add 127.0.1.5 app.test

stage_line="$(grep -nE "^install -o root -g wheel -m 0644 .+ ${HOSTS}\.karakuri\.new\$" "$SUDO_LOG" | cut -d: -f1 | head -n 1)"
mv_line="$(grep -nxF -- "mv ${HOSTS}.karakuri.new $HOSTS" "$SUDO_LOG" | cut -d: -f1 | head -n 1)"

if [ -n "$stage_line" ]; then
	ok "hosts rename: the replacement is staged with its ownership and mode spelled out"
else
	ng "hosts rename: nothing was staged next to $HOSTS (sudo log: $(tr '\n' ';' <"$SUDO_LOG"))"
fi

if [ -n "$mv_line" ]; then
	ok "hosts rename: the staged file is moved onto $HOSTS"
else
	ng "hosts rename: no mv onto $HOSTS (sudo log: $(tr '\n' ';' <"$SUDO_LOG"))"
fi

if [ -n "$stage_line" ] && [ -n "$mv_line" ] && [ "$stage_line" -lt "$mv_line" ]; then
	ok "hosts rename: the file is fully written before it is moved into place"
else
	ng "hosts rename: the staging and the move are not in that order"
fi

# 置き場所が同じディレクトリであること。/tmp から mv すると fs をまたぎ得て、
# そのときの mv は cp + unlink に化けるので原子性が消える。
if [ "$(dirname "${HOSTS}.karakuri.new")" = "$(dirname "$HOSTS")" ]; then
	ok "hosts rename: the staged file sits in the same directory as its target"
else
	ng "hosts rename: the staged file is on a different path from its target"
fi

if grep -qE "^cp .+ $HOSTS\$" "$SUDO_LOG"; then
	ng "hosts rename: $HOSTS is still overwritten with a truncating cp"
else
	ok "hosts rename: nothing copies over $HOSTS in place"
fi

if [ ! -e "${HOSTS}.karakuri.new" ]; then
	ok "hosts rename: no staged file is left behind after a successful rewrite"
else
	ng "hosts rename: ${HOSTS}.karakuri.new survived the rewrite"
fi

# 差し替えの途中で落ちたとき: /etc/hosts は元のまま残り、置きかけの
# ファイルは trap が片付ける。
new_sandbox
seed_conf "127.0.1.5"
seed_hosts_with_block "127.0.2.7 other.test"
cp "$HOSTS" "$WORKDIR/hosts.snapshot"
export FAKE_MV_FAIL=1

run_case add 127.0.1.5 app.test

if [ "$CASE_RC" -ne 0 ]; then
	ok "hosts rename: a failing rename makes the command exit non-zero"
else
	ng "hosts rename: a failing rename was swallowed"
fi

if cmp -s "$HOSTS" "$WORKDIR/hosts.snapshot"; then
	ok "hosts rename: $HOSTS is still complete after the rename failed"
else
	ng "hosts rename: $HOSTS was damaged by a failed rename"
fi

if [ ! -e "${HOSTS}.karakuri.new" ]; then
	ok "hosts rename: the trap removes the staged file when the rename fails"
else
	ng "hosts rename: ${HOSTS}.karakuri.new was left in /etc"
fi
export FAKE_MV_FAIL=0

# --- /etc/hosts は 1 回しか読まない -----------------------------------------------
# マーカーの行番号を決めてから本文を切り出すまでの間に他のプロセスが書くと、
# 行番号がずれて管理ブロックの外を巻き込む。行番号を数え終えた直後
# （wc の 2 回目）に 1 行を先頭へ差し込み、表示される中身がずれないことを見る。
echo "the block is cut from the same bytes the line numbers came from"
new_sandbox
seed_conf "127.0.1.5"
seed_hosts_with_block "$(printf '127.0.1.5 app.test\n127.0.2.7 other.test')"
export RACE_ON_WC=2 RACE_TARGET="$HOSTS" RACE_WHERE="prepend"
export RACE_LINE="# squeezed in by another process"

run_case list

export RACE_ON_WC="" RACE_TARGET="" RACE_WHERE="append" RACE_LINE=""

case "$CASE_STDOUT" in
*"127.0.1.5 app.test"*"127.0.2.7 other.test"*)
	ok "hosts snapshot: both managed entries are shown even though the file shifted mid-read"
	;;
*) ng "hosts snapshot: the managed block came out shifted (stdout: $CASE_STDOUT)" ;;
esac

case "$CASE_STDOUT" in
*"BEGIN karakuri"*) ng "hosts snapshot: the begin marker leaked into the block body" ;;
*) ok "hosts snapshot: the marker line itself is not mistaken for an entry" ;;
esac

case "$CASE_STDOUT" in
*"squeezed in by another process"*)
	ng "hosts snapshot: a line from outside the block was pulled into it"
	;;
*) ok "hosts snapshot: no line from outside the block is pulled in" ;;
esac

# --- grep の「読めなかった」を「無かった」と読まない -----------------------------
# 区別しないと、読めなかったときに「マーカーが無い」と判断して 2 つ目の
# 管理ブロックを末尾に足す。
echo "a grep that fails to read is not the same as a grep that finds nothing"
new_sandbox
seed_conf "127.0.1.5"
seed_hosts_with_block "127.0.2.7 other.test"
cp "$HOSTS" "$WORKDIR/hosts.snapshot"
export FAKE_GREP_RC=2

run_case add 127.0.1.5 app.test

export FAKE_GREP_RC=""

if [ "$CASE_RC" -ne 0 ]; then
	ok "marker search: a failed search causes non-zero exit"
else
	ng "marker search: a failed search was treated as success"
fi

case "$CASE_STDERR" in
*"grep exited 2"*) ok "marker search: the error says the search itself failed" ;;
*) ng "marker search: the error did not name the failed search (stderr: $CASE_STDERR)" ;;
esac

if cmp -s "$HOSTS" "$WORKDIR/hosts.snapshot"; then
	ok "marker search: $HOSTS is left byte-identical when the markers cannot be searched"
else
	ng "marker search: $HOSTS was rewritten after a failed search"
fi

if [ "$(grep -cxF -- "$HOSTS_BEGIN" "$HOSTS")" = "1" ]; then
	ok "marker search: no second managed block is appended"
else
	ng "marker search: the file now has $(grep -cxF -- "$HOSTS_BEGIN" "$HOSTS") begin markers"
fi

assert_no_privileged_ops "marker search: unreadable markers"

# --- 設定ファイルへの追記が末尾改行を確かめる -------------------------------------
# 雛形の最終行はコメントなので、末尾の改行が無いまま追記すると
# `…書くこと。127.0.1.1` になり、daemon も list もコメントとして読み飛ばす。
# add は成功と表示し ifconfig も通るのに、再起動で消え、log にも出ない。
echo "an address appended to a config file with no trailing newline lands on its own line"
new_sandbox
mkdir -p "$(dirname "$CONF")"
printf '# karakuri loopback aliases\n# the last line has no newline of its own' >"$CONF"

run_case add 127.0.1.5

if [ "$CASE_RC" -eq 0 ]; then
	ok "config newline: add exits zero against a config file with no trailing newline"
else
	ng "config newline: add exited $CASE_RC (stderr: $CASE_STDERR)"
fi

if grep -qxF -- "127.0.1.5" "$CONF"; then
	ok "config newline: the address is a line of its own, not glued to the last comment"
else
	ng "config newline: the address was glued to the previous line ($(tr '\n' '|' <"$CONF"))"
fi

if grep -q "newline of its own127" "$CONF"; then
	ng "config newline: the comment and the address ended up on one line"
else
	ok "config newline: the previous comment line survives unchanged"
fi

# 書けたことを daemon の側からも確かめる。ここが本当の被害（起動時に張られない）。
run_daemon

if grep -qxF -- "lo0 alias 127.0.1.5 up" "$IFCONFIG_LOG"; then
	ok "config newline: the daemon raises the address that add appended"
else
	ng "config newline: the daemon did not see the appended address"
fi

# --- daemon も 127.0.0.1 を名指しで読み飛ばす -------------------------------------
# `127.*` は 127.0.0.1 も受理するので、手で書かれると daemon だけが張り、
# list は「設定にあるのに lo0 に無い」と言い続ける。
echo "the daemon skips 127.0.0.1 the same way the front end refuses it"
new_sandbox
mkdir -p "$(dirname "$CONF")"
printf '127.0.0.1\n127.0.1.9\n' >"$CONF"

run_daemon

if [ "$CASE_RC" -eq 0 ]; then
	ok "daemon: the daemon exits zero with 127.0.0.1 in the config file"
else
	ng "daemon: the daemon exited $CASE_RC (stderr: $CASE_STDERR)"
fi

if [ "$(cat "$IFCONFIG_LOG")" = "lo0 alias 127.0.1.9 up" ]; then
	ok "daemon: 127.0.0.1 never reaches ifconfig"
else
	ng "daemon: ifconfig saw: $(tr '\n' ';' <"$IFCONFIG_LOG")"
fi

case "$CASE_STDERR" in
*"127.0.0.1"*"always on lo0"*)
	ok "daemon: the log says why 127.0.0.1 was skipped"
	;;
*) ng "daemon: the skip was not explained (stderr: $CASE_STDERR)" ;;
esac

# --- list が実行できない指示を出さない --------------------------------------------
echo "list never tells you to run an add that would be refused"
new_sandbox
seed_conf "127.0.0.1" "127.0.1.5"
seed_hosts "$HOSTS_PREAMBLE"
export FAKE_LO0_INET="	inet 127.0.0.1 netmask 0xff000000
	inet 127.0.1.5 netmask 0xff000000"

run_case list

case "$CASE_STDOUT" in
*"add 127.0.0.1"*)
	ng "list: list still suggests an add that add itself refuses"
	;;
*) ok "list: list does not suggest adding 127.0.0.1" ;;
esac

case "$CASE_STDOUT" in
*"127.0.0.1"*"not managed here"*)
	ok "list: list says instead that 127.0.0.1 is not managed here"
	;;
*) ng "list: list did not explain the 127.0.0.1 line (stdout: $CASE_STDOUT)" ;;
esac

case "$CASE_STDOUT" in
*"! 127.0.1.5"*) ng "list: the other address was wrongly flagged" ;;
*) ok "list: the address that is up is still reported as fine" ;;
esac

# --- ホスト名の位置にアドレスを書けない -------------------------------------------
# 通ると `127.0.1.5 10.0.0.1` という行ができ、しかも remove <name> では
# 二度と消せない（_looks_like_addr が先に拾ってアドレス扱いで拒否する）。
echo "an address in a hostname position is refused"
new_sandbox
seed_conf
seed_hosts "$HOSTS_PREAMBLE"
cp "$HOSTS" "$WORKDIR/hosts.snapshot"

run_case add 127.0.1.5 10.0.0.1

if [ "$CASE_RC" -ne 0 ]; then
	ok "add argument: 'add 127.0.1.5 10.0.0.1' causes non-zero exit"
else
	ng "add argument: an address was accepted as a hostname"
fi

case "$CASE_STDERR" in
*"looks like an address"*) ok "add argument: the error explains which argument is wrong" ;;
*) ng "add argument: the error did not explain the mistake (stderr: $CASE_STDERR)" ;;
esac

assert_no_privileged_ops "add argument: address as hostname"

if cmp -s "$HOSTS" "$WORKDIR/hosts.snapshot"; then
	ok "add argument: nothing is written to $HOSTS"
else
	ng "add argument: $HOSTS was changed anyway"
fi

# --- 予約されたホスト名を受理しない -----------------------------------------------
echo "reserved hostnames are refused"
for bad in localhost broadcasthost; do
	new_sandbox
	seed_conf
	seed_hosts "$HOSTS_PREAMBLE"

	run_case add 127.0.1.1 "$bad"

	if [ "$CASE_RC" -ne 0 ]; then
		ok "add reserved name: '$bad' causes non-zero exit"
	else
		ng "add reserved name: '$bad' was accepted (block: $(hosts_block "$HOSTS"))"
	fi

	case "$CASE_STDERR" in
	*"$bad"*reserved*) ok "add reserved name: the error says '$bad' is reserved" ;;
	*) ng "add reserved name: the error did not say '$bad' is reserved (stderr: $CASE_STDERR)" ;;
	esac

	assert_no_privileged_ops "add reserved name: '$bad'"
done

# --- 名前衝突の検査は 1 箇所だけ --------------------------------------------------
# 同じ規則とエラー文字列が _body_add にも書かれていた。呼び出し元は cmd_add
# だけなので到達せず、直すときに片方だけ直る場所になっていた。
echo "the name-collision rule lives in exactly one place"
occurrences="$(grep -c "is already mapped to" "$LOOPBACK_SETUP_SH")"
if [ "$occurrences" = "1" ]; then
	ok "add name collision: the refusal message appears once in the implementation"
else
	ng "add name collision: the refusal message appears $occurrences times"
fi

new_sandbox
seed_conf "127.0.1.5"
seed_hosts_with_block "127.0.1.5 a.test"

run_case add 127.0.2.9 a.test

if [ "$CASE_RC" -ne 0 ]; then
	ok "add name collision: moving a name to another address is still refused"
else
	ng "add name collision: the surviving check does not refuse the move"
fi

# 残した方の検査は特権操作の前にある（＝alias だけ張られた状態を作らない）。
assert_no_privileged_ops "add name collision: refused name move"

# --- 配置先パスの二重定義を install で突合する ------------------------------------
# 片方だけ変えても bootstrap は通り、次の起動で初めて「動いていない」と分かる。
echo "install refuses to place a payload whose paths do not match its own"
new_sandbox
cp "$DAEMON_SRC" "$SRC_DIR/karakuri-loopback-aliases" # 配布物のまま = 別の場所を指す

run_case install

if [ "$CASE_RC" -ne 0 ]; then
	ok "install payload: a daemon that reads another config file is refused"
else
	ng "install payload: the mismatched daemon was installed anyway"
fi

case "$CASE_STDERR" in
*"/etc/karakuri/loopback-aliases"*"$CONF"*)
	ok "install payload: the error names both paths that disagree"
	;;
*) ng "install payload: the error did not name both paths (stderr: $CASE_STDERR)" ;;
esac

assert_no_privileged_ops "install payload: mismatched daemon"

if [ ! -e "$DAEMON_PATH" ] && [ ! -e "$PLIST_PATH" ]; then
	ok "install payload: nothing is placed when the daemon disagrees"
else
	ng "install payload: something was placed despite the mismatch"
fi

new_sandbox
cp "$PLIST_SRC" "$SRC_DIR/com.karakuri.loopback-aliases.plist"

run_case install

if [ "$CASE_RC" -ne 0 ]; then
	ok "install payload: a plist that runs another program is refused"
else
	ng "install payload: the mismatched plist was installed anyway"
fi

case "$CASE_STDERR" in
*"/usr/local/libexec/karakuri-loopback-aliases"*"$DAEMON_PATH"*)
	ok "install payload: the error names both program paths that disagree"
	;;
*) ng "install payload: the error did not name both program paths (stderr: $CASE_STDERR)" ;;
esac

assert_no_privileged_ops "install payload: mismatched plist"

# --- 読んでから書くまでの間に割り込まれたら中止する --------------------------------
echo "a /etc/hosts that changed under us is not overwritten"
new_sandbox
seed_conf "127.0.1.5" # 既に載っているので設定ファイルは書かない = 最初の sudo は ifconfig
seed_hosts_with_block "127.0.2.7 other.test"
export RACE_ON_SUDO=1 RACE_TARGET="$HOSTS"
export RACE_LINE="192.0.2.1 injected.example"

run_case add 127.0.1.5 app.test

export RACE_ON_SUDO="" RACE_TARGET="" RACE_LINE=""

if [ "$CASE_RC" -ne 0 ]; then
	ok "hosts race: the command stops when $HOSTS changed under it"
else
	ng "hosts race: the command wrote over a file that had changed"
fi

case "$CASE_STDERR" in
*"changed while this command was running"*)
	ok "hosts race: the error says what happened and to run it again"
	;;
*) ng "hosts race: the error did not explain the abort (stderr: $CASE_STDERR)" ;;
esac

if grep -qxF -- "192.0.2.1 injected.example" "$HOSTS"; then
	ok "hosts race: the other writer's line is still there"
else
	ng "hosts race: the other writer's line was swallowed"
fi

if [ "$(hosts_block "$HOSTS")" = "127.0.2.7 other.test" ]; then
	ok "hosts race: the managed block is left exactly as it was"
else
	ng "hosts race: the managed block was rewritten anyway: $(hosts_block "$HOSTS")"
fi

if [ ! -e "$HOSTS_BAK" ] && [ ! -e "${HOSTS}.karakuri.new" ]; then
	ok "hosts race: neither a backup nor a staged file is left behind"
else
	ng "hosts race: the aborted rewrite left files behind"
fi

echo "a config file that changed under us is not overwritten"
new_sandbox
seed_conf
seed_hosts "$HOSTS_PREAMBLE"
cp "$HOSTS" "$WORKDIR/hosts.snapshot"
export RACE_ON_TAIL=1 RACE_TARGET="$CONF"
export RACE_LINE="127.0.7.7"

run_case add 127.0.1.9 app.test

export RACE_ON_TAIL="" RACE_TARGET="" RACE_LINE=""

if [ "$CASE_RC" -ne 0 ]; then
	ok "config race: the command stops when $CONF changed under it"
else
	ng "config race: the command wrote over a config file that had changed"
fi

if grep -qxF -- "127.0.7.7" "$CONF"; then
	ok "config race: the other writer's address survives in the config file"
else
	ng "config race: the other writer's address was swallowed ($(cat "$CONF"))"
fi

if grep -qxF -- "127.0.1.9" "$CONF"; then
	ng "config race: the aborted add wrote its address anyway"
else
	ok "config race: the aborted add wrote nothing"
fi

if cmp -s "$HOSTS" "$WORKDIR/hosts.snapshot"; then
	ok "config race: the aborted add did not get as far as $HOSTS"
else
	ng "config race: $HOSTS was changed by an add that aborted"
fi

if [ ! -e "$CONF_BAK" ] && [ ! -e "${CONF}.karakuri.new" ]; then
	ok "config race: no backup and no staged file are left next to the config file"
else
	ng "config race: the aborted config write left files behind"
fi

# --- list も引数の個数を検査する --------------------------------------------------
echo "list rejects arguments it does not take"
new_sandbox
seed_conf "127.0.1.5"
seed_hosts_with_block "127.0.1.5 app.test"

run_case list foo

if [ "$CASE_RC" -ne 0 ]; then
	ok "list args: 'list foo' causes non-zero exit"
else
	ng "list args: 'list foo' was silently ignored"
fi

case "$CASE_STDERR" in
*"Usage:"*) ok "list args: the usage is shown instead of a silent no-op" ;;
*) ng "list args: no usage was shown (stderr: $CASE_STDERR)" ;;
esac

# --- remove <name> がブロック内のコメント行を消さない ------------------------------
echo "comments inside the managed block survive a remove"
BLOCK_COMMENT="# app.test is the web front end; api is on 127.0.2.7"
new_sandbox
seed_conf "127.0.1.5"
seed_hosts_with_block "$(printf '%s\n127.0.1.5 app.test b.test' "$BLOCK_COMMENT")"

run_case remove app.test

if [ "$CASE_RC" -eq 0 ]; then
	ok "hosts comment: remove <name> exits zero with a comment in the block"
else
	ng "hosts comment: remove exited $CASE_RC (stderr: $CASE_STDERR)"
fi

if [ "$(hosts_block "$HOSTS")" = "$(printf '%s\n127.0.1.5 b.test' "$BLOCK_COMMENT")" ]; then
	ok "hosts comment: the comment line is kept verbatim and only the name is dropped"
else
	ng "hosts comment: unexpected block: $(hosts_block "$HOSTS" | tr '\n' '|')"
fi

# 最後の名前を消してアドレス行が消えても、コメントは残る。
run_case remove b.test

if [ "$(hosts_block "$HOSTS")" = "$BLOCK_COMMENT" ]; then
	ok "hosts comment: the comment outlives the address line it described"
else
	ng "hosts comment: the comment went away with the last name: $(hosts_block "$HOSTS" | tr '\n' '|')"
fi

# add も同じ。コメントを跨いで行を足しても原文のまま。
run_case add 127.0.2.7 api.test

if [ "$(hosts_block "$HOSTS")" = "$(printf '%s\n127.0.2.7 api.test' "$BLOCK_COMMENT")" ]; then
	ok "hosts comment: add keeps the comment line where it was"
else
	ng "hosts comment: add disturbed the comment: $(hosts_block "$HOSTS" | tr '\n' '|')"
fi

# --- remove の 2 経路が同じように失敗する -----------------------------------------
# 元は _remove_addr だけが「/etc/hosts が読めない」を黙って飛ばしていた。
echo "both remove paths refuse to work with an unreadable /etc/hosts"
new_sandbox
seed_conf "127.0.1.5"
# /etc/hosts を置かない

run_case remove 127.0.1.5
addr_rc="$CASE_RC"
addr_err="$CASE_STDERR"

run_case remove app.test
name_rc="$CASE_RC"
name_err="$CASE_STDERR"

if [ "$addr_rc" -ne 0 ] && [ "$name_rc" -ne 0 ]; then
	ok "remove: both 'remove <addr>' and 'remove <name>' exit non-zero"
else
	ng "remove: rc was $addr_rc for the address and $name_rc for the name"
fi

if [ "$addr_err" = "$name_err" ]; then
	ok "remove: both paths give the same reason"
else
	ng "remove: the two paths disagree ('$addr_err' vs '$name_err')"
fi

case "$addr_err" in
*"cannot read"*) ok "remove: the reason names the file it could not read" ;;
*) ng "remove: the reason did not name the file (stderr: $addr_err)" ;;
esac

if grep -qxF -- "127.0.1.5" "$CONF"; then
	ok "remove: 'remove <addr>' leaves the config file alone when it gives up"
else
	ng "remove: the config line was dropped even though the hosts step failed"
fi

assert_no_privileged_ops "remove: unreadable /etc/hosts"

# --- HUP でも一時ファイルを片付ける -----------------------------------------------
# sudo のパスワード待ちで端末を閉じると HUP が飛ぶ。実際に飛ばすと、待つ側の
# 都合でテストが不安定になるので、ここは trap が張られていることだけを見る。
echo "the cleanup also runs on SIGHUP"
if grep -qF "trap 'exit 129' HUP" "$LOOPBACK_SETUP_SH"; then
	ok "cleanup: HUP is trapped alongside INT and TERM"
else
	ng "cleanup: HUP is not trapped"
fi

# --- 設定ファイルも退避を取る -----------------------------------------------------
# 利用者の手書きコメントが入る前提のファイルなので、/etc/hosts と同じ扱いにする。
echo "the config file is backed up before it is rewritten"
new_sandbox
seed_conf "127.0.1.5"
printf '# a note the user wrote by hand\n' >>"$CONF"
cp "$CONF" "$WORKDIR/conf.snapshot"

run_case add 127.0.2.7

if [ -f "$CONF_BAK" ]; then
	ok "config backup: the config backup exists after a rewrite"
else
	ng "config backup: no config backup was written"
fi

if cmp -s "$CONF_BAK" "$WORKDIR/conf.snapshot"; then
	ok "config backup: the config backup holds the pre-rewrite content, byte for byte"
else
	ng "config backup: the config backup does not match the pre-rewrite content"
fi

if grep -qxF -- "# a note the user wrote by hand" "$CONF"; then
	ok "config backup: the hand-written comment survives the rewrite"
else
	ng "config backup: the hand-written comment was lost"
fi

# --- plist に StandardOutPath が無い理由が書いてある -------------------------------
echo "the plist explains why it has no StandardOutPath"
if grep -qF "StandardOutPath" "$PLIST_SRC"; then
	if grep -qE "^	<key>StandardOutPath</key>" "$PLIST_SRC"; then
		ng "plist: the plist now sets StandardOutPath without the daemon writing to stdout"
	else
		ok "plist: StandardOutPath appears only in the comment that explains its absence"
	fi
else
	ng "plist: the plist says nothing about StandardOutPath"
fi

# --- 結果 -----------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
