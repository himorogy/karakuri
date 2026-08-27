#!/usr/bin/env bash
#
# loopback-setup.sh — loopback alias と /etc/hosts の管理コマンド（macOS）
#
# ============================================================================
# このファイルを dev workspace の中から実行するな。
# dev container に bind mount されるディレクトリの外（ホストの固定パス）に
# 置いたものを使え。理由は dev-inject.sh / karakuri.sh の冒頭と同じで、
# しかもこちらの方が直接的である: このスクリプトは sudo を伴って走り、
# root 所有の /etc/hosts と /Library/LaunchDaemons を書き換える。
# workspace 内に置いたまま人間がホストで sudo 付きで実行する運用にすると、
# dev container の中で常駐する LLM エージェントがこのファイルを書き換え、
# 次に人間が打った 1 回で任意のコマンドを root で走らせられる。
# ============================================================================
#
# 何のためのものか
# ----------------
# コンテナ内のサービスへはホストから SSH port forwarding で到達する
# （images/devcontainer-base/PORT-FORWARDING.md）。転送の bind 先を
# プロジェクトごとに別の loopback アドレスにすると、プロジェクト間で
# ポート番号を使い回せる（4588 を同時に 3 つ開けても衝突しない）。
#
# ところが macOS では、127.0.0.1 以外の loopback アドレスは
# `ifconfig lo0 alias <addr> up` で明示的に有効化しない限り bind できず、
# 張った結果は再起動で消える。この 2 つを人間が覚えている構成にすると、
# 「再起動した日だけ port forwarding が張れない」という、原因の見えない
# 壊れ方をする。ここで配っているのは、その一手間を設定ファイル 1 枚と
# LaunchDaemon 1 つに落として、起動のたびに再現させるための道具である。
#
# どのアドレスをどのプロジェクトに割り当てるかは決めない
# ------------------------------------------------------
# このツールは「言われたアドレスを張る」だけで、割り当ての規則は持たない。
# 127.0.1.x を 1 プロジェクトずつ使うのも、サービス種別で 127.0.2.x を
# 分けるのも、単なる流儀である。ツールが決め打つと、その流儀に合わない
# 使い方をする人はツールごと使えなくなる（そして各自が sudo ifconfig を
# 手で打つ運用へ戻る）。割り当ての記録は各プロジェクトの
# .devcontainer/README.md 側に置くこと。
#
# シェルオプションについて
# ------------------------
# karakuri.sh には「トップレベルに set -euo pipefail を書かない」という
# 規律があるが、あれは source されるファイル（＝利用者の対話シェルそのもの
# にオプションが残る）に当たる規律である。このファイルは独立した実行
# スクリプトで、オプションが効く範囲はこのプロセスの中だけなので、
# 素直に設定してよい。むしろ設定しない方が危ない: 下で /etc/hosts を
# 組み立て直しており、途中のコマンドが失敗したことを見落としたまま
# 次の行へ進むと、欠けた内容で /etc/hosts を上書きすることになる。

set -euo pipefail

# glob を止める。/etc/hosts の管理ブロックの中身や設定ファイルの行を語に
# 割る箇所があり、そこに `*` が紛れていると（手で編集できるファイルなので
# 有り得る）カレントディレクトリのファイル名へ化ける。このスクリプトは
# glob を一切使わないので、丸ごと止めて構わない。
set -f

# --- 定数 ---------------------------------------------------------------------
# 配置先は全部ここに集めてある。install が置く先と、add / remove / list が
# 読む先が同じであることを、1 画面で確かめられるようにするため。
CONF_DIR="/etc/karakuri"
CONF="${CONF_DIR}/loopback-aliases"
DAEMON_DIR="/usr/local/libexec"
DAEMON_PATH="${DAEMON_DIR}/karakuri-loopback-aliases"
PLIST_PATH="/Library/LaunchDaemons/com.karakuri.loopback-aliases.plist"
HOSTS="/etc/hosts"
HOSTS_BAK="/etc/hosts.karakuri.bak"

# 設定ファイルの退避先。/etc/hosts と同じく 1 世代だけ持つ。
# 設定ファイルは「手で編集してよい」と雛形の中で明言しており、利用者の
# 覚え書き（どのアドレスがどのプロジェクトか）が入っている前提のファイル
# である。こちらが組み立て直して被せる以上、/etc/hosts にだけ退避があって
# こちらに無いのは筋が通らない。退避先を CONF から導いているのは、
# CONF_DIR を変えたときに置き去りにならないようにするため。
CONF_BAK="${CONF}.bak"

# 対応 OS は macOS と Windows(Git Bash) の 2 つで、Linux は対象にしない
# （images/runtime-base/README.md）。非対応の Linux を含めないので、
# 「Darwin かどうか」の二値だけで足り、非 Darwin は Windows だけになる。
#
# lo0 の alias と、それに依存する /etc/hosts の管理ブロックは macOS 固有の
# 迂回策である。Windows は 127.0.0.0/8 全体を最初から bind でき、Git Bash の
# /etc/hosts は Windows 側の名前解決に使われないので書き換えても効かない。
# したがって非 macOS では何もせず、その旨を示して終了する。ここより先は
# すべて macOS 側の処理として書ける。
if [ "$(uname -s)" != "Darwin" ]; then
	printf 'karakuri-loopback: macOS only, doing nothing. lo0 aliasing and the managed /etc/hosts block work around macOS requiring an explicit alias for any loopback address other than 127.0.0.1; Windows binds 127.0.0.0/8 already, and its Git Bash /etc/hosts is not consulted by Windows name resolution. No changes were made.\n' >&2
	exit 0
fi

ROOT_GROUP="wheel"

# /etc/hosts の中で、このツールが書き換えてよい範囲を囲むマーカー。
# 文字列そのものが契約なので、変えると既存のブロックが「見えないブロック」
# になって二重に書かれる。変更するときは移行手順込みで考えること。
HOSTS_BEGIN="# BEGIN karakuri (managed) — do not edit by hand"
HOSTS_END="# END karakuri"

# 配布物（loopback/ ディレクトリ）はこのスクリプトの隣にある前提で、
# 自分自身のパスから引く。PATH に入れても ~/.local/bin から symlink しても
# 動くように、というのが karakuri.sh 側の方針だが、こちらは symlink 越しの
# 解決までは面倒を見ない（install のときにファイルが見つからなければ、
# その旨を名指しで報告して止まる）。
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SELF_DIR}/loopback"

# --- 出力ヘルパー -------------------------------------------------------------
# 名乗りは karakuri-loopback で揃える。利用者が打つのは karakuri.sh の
# 関数名（karakuri-loopback）であって、ファイル名ではないため。
_err() {
	printf 'karakuri-loopback: %s\n' "$1" >&2
}

_die() {
	_err "$1"
	exit 1
}

# --- 一時ファイル -------------------------------------------------------------
# /etc/hosts と設定ファイルは、組み立て終えたものを一度に被せる形で更新する
# （途中経過を見せない）。その組み立て先が一時ファイル。用途ごとに変数を
# 分けてあり、掃除はまとめて行う:
#
#   _tmp    組み立て先（これから被せる中身）
#   _snap   /etc/hosts の写し。行番号の算出も head/tail もバックアップも
#           すべてこの 1 枚から取る（下の「3 パスの読み直し」の項を参照）
#   _csnap  設定ファイルの写し。同じ理由と、書き戻す直前の突合に使う
#   _staged sudo install で置いた「差し替え前の新ファイル」。root 所有なので
#           掃除にも sudo が要る（普通の一時ファイルと同じには消せない）
_tmp=""
_snap=""
_csnap=""
_staged=""

_newtemp() {
	mktemp "${TMPDIR:-/tmp}/karakuri-loopback.XXXXXX"
}

_mktemp() {
	_tmp="$(_newtemp)"
}

_rmtemp() {
	if [ -n "$_tmp" ]; then
		rm -f "$_tmp"
	fi
	_tmp=""
	return 0
}

_cleanup() {
	_rmtemp
	if [ -n "$_snap" ]; then
		rm -f "$_snap"
	fi
	_snap=""
	if [ -n "$_csnap" ]; then
		rm -f "$_csnap"
	fi
	_csnap=""

	# 差し替え直前の新ファイル（例: /etc/hosts.karakuri.new）は root 所有で、
	# mv が終わる前に落ちるとそこに残る。残したままにすると、次に何が起きたか
	# 分からない人が /etc の中に見慣れないファイルを見つけることになるので、
	# ここで消す。存在するときだけ sudo を呼ぶのは、正常な失敗経路（引数の
	# 検証で弾かれた等）で終了 trap がパスワードを聞き始めないため。-n を
	# 付けて聞かずに諦めるのも同じ理由で、ここに来ている時点で直前に sudo を
	# 通しているので資格情報は残っており、通常は消える。
	if [ -n "$_staged" ] && [ -e "$_staged" ]; then
		sudo -n rm -f "$_staged" 2>/dev/null || true
	fi
	_staged=""
	return 0
}

# 正常終了でも異常終了でも消す。組み立て途中の /etc/hosts の写しを
# /tmp に置き去りにしない（内容そのものは秘密ではないが、次に走ったときに
# 古い写しを掴む余地を残さない）。
trap _cleanup EXIT
# シグナルで殺されたときは EXIT trap が走らないので、明示的に exit へ
# 落として EXIT trap を通す。128 + シグナル番号が慣例の終了コード。
#
# HUP も捕る。このスクリプトは sudo のパスワード待ちで止まることがあり、
# そこで端末（ターミナルのタブ、ssh の接続）を閉じると HUP が飛ぶ。
# 捕っていないと、一時ファイルと _staged の両方が置き去りになる。
# 実際にはこれが一番起きやすい中断であって、INT/TERM より優先度が低い
# 理由は無い。
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# --- 原子的な差し替え -----------------------------------------------------------
# _atomic_replace <src> <dst> — <dst> の中身を <src> のものに差し替える。
#
# 元はここが `sudo cp "$_tmp" "$HOSTS"` で、「mv は一時ファイル側の所有者・
# パーミッション・ACL を持ち込むから cp を使う」と書いてあった。あの判断は
# 誤りだったので撤回する。cp は dst を truncate してから書くので、その 1 行の
# 途中で中断（電源断、kill -9）されると /etc/hosts が欠けた状態で残り、
# ホストの名前解決が全面的に止まる。しかも壊れたことは「なぜかネットワークが
# 動かない」という形でしか見えない。
#
# 属性の心配は install(1) に所有者・group・モードを明示すれば消える。つまり
# cp を選ぶ理由だった問題は別の方法で解けるのに対し、truncate の隙間は
# cp を使う限り消せない。そこで、dst と同じディレクトリ（＝同じファイル
# システム）に属性を明示した新ファイルを作り、mv で差し替える。同一 fs 内の
# mv は rename(2) なので、dst が「無い」あるいは「欠けている」状態を他の
# プロセスが観測する瞬間が無い。
#
# 捨てたものは ACL である。rename(2) で入れ替わる以上、dst に付いていた ACL は
# 引き継がれない。/etc/hosts に ACL を付ける運用は事実上無く、あったとしても
# 失われたことは `ls -le` で見えて手で戻せる。中断で名前解決が止まる方は
# 見えず、戻す手段も（バックアップから手で書くしかない）重い。天秤の傾きが
# 桁違いなので、ACL を捨てて中断耐性を取る。
#
# 失敗を `set -e` に任せず 1 つずつ見ているのは、この関数の呼び出し元
# （_hosts_write）が `_hosts_write ... || exit 1` の形で呼ばれるためである。
# bash は `||` の左側にある関数の中では set -e を効かせない。任せたままだと、
# mv が失敗しても下の `_staged=""` まで進み、掃除の対象から外れた置きかけの
# ファイルを /etc に残したまま、成功として返る。
_atomic_replace() {
	local src="$1" dst="$2"

	# 新ファイルは dst の隣に置く。/tmp から mv するとファイルシステムを
	# またぐことがあり、そのときの mv は cp + unlink に化けて上の保証が消える。
	_staged="${dst}.karakuri.new"
	sudo install -o root -g "$ROOT_GROUP" -m 0644 "$src" "$_staged" ||
		_die "could not stage the new ${dst} as '${_staged}'. ${dst} is unchanged"
	sudo mv "$_staged" "$dst" ||
		_die "could not move '${_staged}' onto ${dst}. ${dst} is unchanged — the staged file is removed on the way out"
	# mv が済んだ時点で、このパスは掃除の対象ではなくなる（消すと dst が消える）。
	_staged=""
	return 0
}

# --- usage --------------------------------------------------------------------
usage() {
	cat >&2 <<'EOF'
Usage: karakuri-loopback <command> [args...]

  install                     Install the LaunchDaemon and the config file (run once, then after upgrades)
  add <addr> [hostname...]    Alias <addr> on lo0, remember it, and map the hostnames to it in /etc/hosts
  remove <addr|hostname>      Undo an 'add'. An address removes the alias, the config line and its hosts entry;
                              a hostname only drops that name from /etc/hosts
  list                        Show the config file, the aliases currently on lo0 and the managed /etc/hosts block

This tool is macOS only. On any other OS it exits immediately without
touching anything (you would not see this text — that happens before the
command is even parsed).

install / add / remove change root-owned files (/etc/karakuri, /etc/hosts,
/Library/LaunchDaemons), so they run sudo and will ask for your password.

Which address belongs to which project is yours to decide; this tool only
plumbs the address you name. Record the assignment in the project's
.devcontainer/README.md.

When run directly, the file is loopback-setup.sh; karakuri.sh exposes it as
the shell function karakuri-loopback.
EOF
	exit "${1:-1}"
}

# --- 検証 ---------------------------------------------------------------------
# 正規表現をいったん変数に入れてから [[ =~ ]] に渡す。macOS の /bin/bash は
# いまだに 3.2 で、パターンを直書きすると引用の扱いが後の版と食い違う
# （3.2 ではクォートしたパターンがリテラル比較になる）。変数越しなら
# どちらの版でも正規表現として扱われる。

# _looks_like_addr <arg> — その引数が「アドレスのつもりで打たれたか」を見る。
#
# 4 つの数字を . で繋いだ形なら、値が範囲外でもアドレスとして扱い、
# _check_addr に判定させる。ホスト名の規則（英数字と . と -）は
# `10.0.0.1` のような文字列も通してしまうので、先にこちらで拾わないと
# 「アドレスを打ったつもりが、存在しないホスト名の削除として黙って
# 成功する」が起きる。判定と検査を分けてあるのはこのためで、ここは
# 「どちらのつもりで打たれたか」だけを見る。
#
# 使うのは remove の引数の振り分けと、_check_hostname（ホスト名の位置に
# アドレスが来ていないか）と、管理ブロックの行の見分け（アドレス行か、
# 利用者が置いたコメント行か）の 3 箇所。同じ「アドレスの形か」の判定を
# それぞれで書き直すと、片方だけ緩い規則が残る。
_looks_like_addr() {
	local re='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
	[[ "$1" =~ $re ]]
}

# _check_addr <addr> — 張ってよいアドレスかを見る。
_check_addr() {
	local addr="$1"

	# 127.0.0.1 は拒否する。lo0 には常に載っているので alias は要らず、
	# 受け入れると /etc/hosts の管理ブロックに 127.0.0.1 の行を作ることに
	# なる。あのアドレスには既定の `127.0.0.1 localhost` 行があり、同じ
	# アドレスの割り当てが 2 箇所（既定行と管理ブロック）に分かれた状態は、
	# 後で名前が引けなくなったときに追う場所を増やすだけである。
	if [ "$addr" = "127.0.0.1" ]; then
		_err "127.0.0.1 is not managed here: it is always on lo0, so it needs no alias, and putting it in the managed /etc/hosts block would split it across two places. If you use the VS Code auto-forwarding (which can only bind 127.0.0.1), add the line '127.0.0.1 <name>' to /etc/hosts yourself"
		return 1
	fi

	# 先頭オクテットは 127 に固定。第 2 以降は 0〜255 の 10 進数で、
	# 先頭 0 の桁埋め（127.0.1.010 など）は弾く。inet_aton は先頭 0 の
	# オクテットを 8 進として読むため、桁埋めを許すと設定ファイルに
	# 書かれている文字列と lo0 に実際に載るアドレスが食い違う
	# （010 は 8 進の 8）。読んだままが載る、という状態を保つ。
	local re='^127\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$'
	if [[ ! "$addr" =~ $re ]]; then
		_err "'${addr}' is not a loopback address this tool manages. Pass four decimal octets starting with 127 (for example 127.0.1.1); no leading zeros"
		return 1
	fi

	# o1 は上の正規表現により必ず 127 なので見ない（受け取っているのは、
	# read の最後の変数に残りが全部入る挙動を避けるため）。
	local o1 o2 o3 o4 o
	# shellcheck disable=SC2034 # o1 は捨てる。受け取らないと o3 に残りが入る
	IFS=. read -r o1 o2 o3 o4 <<<"$addr"
	for o in "$o2" "$o3" "$o4"; do
		if [ "$o" -gt 255 ]; then
			_err "'${addr}' has an octet greater than 255"
			return 1
		fi
	done
	return 0
}

# _check_hostname <name> — /etc/hosts に書いてよい名前かを見る。
#
# 長さの上限 253 は FQDN の上限（RFC 1035 の 255 バイト表現から、根の
# ラベルと長さバイトを引いた値）。ここで見ているのは「hosts ファイルに
# 書ける形か」であって名前解決の可否ではないので、これ以上は絞らない。
_check_hostname() {
	local name="$1"
	local re='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'

	if [ "${#name}" -gt 253 ]; then
		_err "hostname '${name}' is longer than 253 characters"
		return 1
	fi

	# ホスト名の位置にアドレスを書かせない。上の正規表現は英数字と . と -
	# を通すので `10.0.0.1` も素通りし、`add 127.0.1.5 10.0.0.1` が
	# `127.0.1.5 10.0.0.1` という行を作れてしまう。しかもその行は消せない:
	# `remove 10.0.0.1` は _looks_like_addr が先に拾ってアドレスとして
	# _check_addr に渡すので拒否され、ホスト名としては二度と指定できない。
	# 作れるが消せない状態を作らない、というのがここの目的である。
	# 判定は remove 側と同じ _looks_like_addr を使う（同じ「アドレスの形」の
	# 規則を 2 箇所に書かない）。
	if _looks_like_addr "$name"; then
		_err "'${name}' looks like an address, not a hostname. The hostname positions of 'add' take names only — if you meant to alias another address, run a separate 'karakuri-loopback add ${name}'"
		return 1
	fi

	# 予約された名前は拒否する。`add 127.0.1.1 localhost` は管理ブロックに
	# 2 つ目の localhost 行を作る。/etc/hosts は先に一致した行が勝つので、
	# 既定の `127.0.0.1 localhost` が生きたまま、こちらの行だけが効かない
	# ものとして残る。これは _check_addr が 127.0.0.1 を拒否して避けている
	# 「同じ名前が 2 箇所に分かれる」状態そのもので、名前の側から入られたら
	# 同じことである。broadcasthost（255.255.255.255）も同じ理由で拒否する。
	case "$name" in
	localhost | broadcasthost)
		_err "'${name}' is reserved by the default ${HOSTS} entries: adding it here would create a second line for a name that already resolves, and only the first match wins. Pick a name of your own (for example '<project>.test')"
		return 1
		;;
	esac

	if [[ ! "$name" =~ $re ]]; then
		_err "'${name}' is not a usable hostname: use letters, digits, '-' and '.', starting and ending with a letter or digit"
		return 1
	fi
	return 0
}

# --- 設定ファイル -------------------------------------------------------------
# 読み方は daemon（loopback/karakuri-loopback-aliases）と揃える: 1 行 1
# アドレス、# で始まる行は飛ばす、2 番目以降のフィールドは無視する。
# 読み方が食い違うと、list が見せるものと起動時に実際に張られるものが
# ずれ、そのずれは再起動するまで誰にも見えない。

# _conf_addrs [file] — 設定ファイルに書かれているアドレスを 1 行 1 件で出す。
# 引数を取れるようにしてあるのは、書き換えの経路が「読んだ写しだけを見る」
# 形になっているため（下の _conf_snapshot の項）。省略時は実物を読む。
_conf_addrs() {
	local f="${1:-$CONF}"
	[ -f "$f" ] || return 0
	awk '$1 ~ /^#/ { next } NF > 0 { print $1 }' "$f"
}

# _conf_has <addr> [file] — 既に書かれているか。
_conf_has() {
	local addr="$1" f="${2:-$CONF}" a
	while IFS= read -r a; do
		[ "$a" = "$addr" ] && return 0
	done <<<"$(_conf_addrs "$f")"
	return 1
}

# _conf_snapshot — 設定ファイルの写しを 1 枚取り、$_csnap に残す。
#
# 読んだ内容と書き戻す土台を同じ 1 枚にするためのもの。元の組み立ては
# 「実物を読む → sudo のパスワード待ちで数秒〜数十秒止まる → 実物へ書く」
# で、その待ちの間に別の端末で `karakuri-loopback add` を打たれると、
# あちらの追記が黙って消えていた。
_conf_snapshot() {
	[ -r "$CONF" ] || _die "cannot read ${CONF}"
	_csnap="$(_newtemp)"
	cat "$CONF" >"$_csnap" || _die "cannot read ${CONF}"
	return 0
}

# _conf_replace <組み立てたファイル> — 設定ファイルを差し替える。
_conf_replace() {
	local src="$1"

	[ -n "$_csnap" ] || _die "internal error: _conf_replace was called without a snapshot of ${CONF}"

	# 読んだ時点から変わっていたら、何も書かずに中止する。ロックは掛けない:
	# ここで守りたいのは「別の書き手の変更を黙って捨てない」ことだけで、
	# それには書く直前の突合で足りる。ロックを持ち込むと、sudo のパスワード
	# 待ちで止まっているプロセスがロックを握り続ける形になり、別の端末が
	# 理由の見えないまま待たされる。失敗させて打ち直させる方が読める。
	if ! cmp -s "$_csnap" "$CONF"; then
		_die "${CONF} changed while this command was running — another 'karakuri-loopback' run or a hand edit got there first. Nothing was written; run the same command again"
	fi

	# 退避は /etc/hosts と同じく 1 世代だけ。退避元が写しなのは意図的で、
	# 直前の突合を通っている以上これは実物と同じ内容であり、かつ
	# 「退避したもの」と「書き換えの土台にしたもの」が必ず一致する。
	sudo install -o root -g "$ROOT_GROUP" -m 0644 "$_csnap" "$CONF_BAK" ||
		_die "could not write the backup ${CONF_BAK}. ${CONF} is unchanged"
	_atomic_replace "$src" "$CONF"
	return 0
}

# _conf_append <addr> — 設定ファイルの末尾にアドレスを 1 行足す。
#
# 元は `printf '%s\n' "$addr" | sudo tee -a "$CONF"` だった。tee -a は既存の
# 内容が改行で終わっているかを見ない。雛形の最終行はコメントなので、末尾の
# 改行が落ちていると `…書くこと。127.0.1.1` という 1 行になり、daemon も
# _conf_addrs もそれをコメントとして読み飛ばす。add は成功と表示し ifconfig も
# 通るのに、再起動でアドレスが消え、log にも何も出ない。手で編集してよいと
# 明言しているファイルなのだから、末尾改行が無い状態は普通に起こる。
# /etc/hosts 側（_hosts_write）には同じ配慮が最初から入っていた。揃える。
_conf_append() {
	local addr="$1"

	_mktemp
	cat "$_csnap" >"$_tmp"
	# `$(...)` は末尾の改行を落とすので、最後の 1 バイトを取って空に見えれば
	# 改行だった、と判定できる。空ファイルには足さない（先頭に空行を作らない）。
	if [ -s "$_csnap" ] && [ -n "$(tail -c 1 "$_csnap")" ]; then
		printf '\n' >>"$_tmp"
	fi
	printf '%s\n' "$addr" >>"$_tmp"

	_conf_replace "$_tmp"
	_rmtemp
	return 0
}

# --- /etc/hosts ---------------------------------------------------------------
# ここが一番慎重に扱う面である。/etc/hosts は Docker Desktop をはじめ他の
# ツールも書き込むファイルで、しかも壊すと名前解決が丸ごと止まる。
# 規律は 3 つ:
#
#   1. マーカーで囲んだ範囲の外は 1 バイトも変えない
#   2. 書き換える前に必ず退避を取る
#   3. マーカーの対応が壊れていたら、直さずに止めて人間に返す
#   4. 1 回の実行では /etc/hosts を 1 度しか読まない
#
# 4 が要るのは、他のプロセスが同時に書くからである。元の組み立ては、
# マーカーの行番号を grep で決めた後、head と tail が実物をもう一度ずつ
# 読み直していた（3 パス）。その間に Docker Desktop が 1 行足せば行番号が
# ずれ、管理ブロックの外を巻き込んで切り貼りすることになる。今は最初に
# 写しを 1 枚取り（_hosts_snapshot）、行番号の算出も head も tail も
# 退避もすべてその 1 枚から取る。写しと実物がずれていないことは、被せる
# 直前に 1 度だけ確かめる（_hosts_write の cmp）。
#
# 3 が要るのは、壊れ方の推測が要るからである。開始マーカーだけがある状態は
# 「終了マーカーを消してしまった」のかもしれないし「他のツールが範囲ごと
# 持って行った」のかもしれない。前者だと思って末尾までを管理範囲とみなすと、
# 後者だったときに無関係な行を消す。読み手が誰かは分からないが、少なくとも
# ここで推測しないでおけば、消えていないものを消さずに済む。

# _count_lines <text> — 空文字列を 0 行として数える。
# `printf '%s\n' "" | wc -l` は 1 を返すので、そのままでは使えない。
_count_lines() {
	if [ -z "$1" ]; then
		printf '0\n'
		return 0
	fi
	printf '%s\n' "$1" | wc -l | tr -d ' '
}

# _hosts_snapshot — /etc/hosts の写しを 1 枚取り、$_snap に残す。
# 以降、このコマンドが /etc/hosts の中身として見るのはこの 1 枚だけである。
_hosts_snapshot() {
	[ -r "$HOSTS" ] || _die "cannot read ${HOSTS}"
	_snap="$(_newtemp)"
	cat "$HOSTS" >"$_snap" || _die "cannot read ${HOSTS}"
	return 0
}

# _hosts_marker_lines <marker> — マーカーに完全一致する行の行番号を出す。
# -x -F で「行まるごとの固定文字列一致」に絞る。マーカーには括弧や `-` が
# 含まれるので、正規表現として解釈させない。
#
# grep の終了コードは 3 通りある。0 が「見つかった」、1 が「無かった」、
# 2 以上が「読めない・I/O が失敗した」である。元は `2>/dev/null || true` で
# 3 つとも同じ扱いにしていたが、それだと 2 のときに「マーカーが無い」と
# 読める空文字列が返り、_hosts_bounds が "0 0"（ブロックが無い）を返して
# 既存のブロックを見落とし、末尾に 2 つ目のブロックを作る。壊れ方として
# 一番たちが悪いのは、失敗が成功の顔をして別の結果になることなので、
# 1 と 2 は分けて、2 はその場で止める。
_hosts_marker_lines() {
	local out rc=0

	out="$(grep -n -x -F -e "$1" "$_snap")" || rc=$?
	case "$rc" in
	0)
		printf '%s\n' "$out" | cut -d: -f1
		;;
	1)
		# 見つからなかっただけ。何も出さずに成功で返す。
		;;
	*)
		_err "could not search ${HOSTS} for the marker line '${1}' (grep exited ${rc}). Refusing to touch the file — reading it must succeed before anything is written"
		return 1
		;;
	esac
	return 0
}

# _hosts_bounds — 管理ブロックの開始行と終了行を "<begin> <end>" で出す。
# ブロックが無ければ "0 0"。対応が壊れていれば報告して非ゼロで返る。
_hosts_bounds() {
	local begins ends nb ne b e

	[ -n "$_snap" ] || _die "internal error: _hosts_bounds was called without a snapshot of ${HOSTS}"

	# 読めなかった場合（grep の 2）はここで諦める。`|| return 1` を明示して
	# いるのは、command substitution の失敗を set -e に拾わせる形だと、
	# 「なぜ止まったか」がこの行を読んだだけでは分からないため。
	begins="$(_hosts_marker_lines "$HOSTS_BEGIN")" || return 1
	ends="$(_hosts_marker_lines "$HOSTS_END")" || return 1
	nb="$(_count_lines "$begins")"
	ne="$(_count_lines "$ends")"

	if [ "$nb" -eq 0 ] && [ "$ne" -eq 0 ]; then
		printf '0 0\n'
		return 0
	fi

	if [ "$nb" -ne 1 ] || [ "$ne" -ne 1 ]; then
		_err "${HOSTS} has ${nb} begin marker(s) and ${ne} end marker(s); exactly one of each (or neither) is required. Refusing to touch the file — fix it by hand so that a single '${HOSTS_BEGIN}' line is followed by a single '${HOSTS_END}' line"
		return 1
	fi

	b="$begins"
	e="$ends"
	if [ "$b" -ge "$e" ]; then
		_err "${HOSTS} has its end marker (line ${e}) before its begin marker (line ${b}). Refusing to touch the file — fix the order by hand"
		return 1
	fi

	printf '%s %s\n' "$b" "$e"
	return 0
}

# _hosts_body <begin> <end> — マーカーの内側の行を出す（空なら何も出さない）。
# 行番号を決めた写しと同じ写しから切り出す。実物を読み直すと、行番号を
# 決めた時点との間に他のプロセスが書いた分だけずれる。
_hosts_body() {
	local b="$1" e="$2"
	if [ "$b" -eq 0 ]; then
		return 0
	fi
	if [ "$((e - b))" -le 1 ]; then
		return 0
	fi
	sed -n "$((b + 1)),$((e - 1))p" "$_snap"
}

# _hosts_write <body> — マーカーの内側を <body> で置き換える。
# ブロックが無ければファイル末尾に新設する。
_hosts_write() {
	local body="$1"
	local bounds b e

	[ -n "$_snap" ] || _die "internal error: _hosts_write was called without a snapshot of ${HOSTS}"

	bounds="$(_hosts_bounds)" || return 1
	b="${bounds%% *}"
	e="${bounds##* }"

	_mktemp

	if [ "$b" -eq 0 ]; then
		cat "$_snap" >"$_tmp"
		# 末尾が改行で終わっていないファイルにそのまま追記すると、
		# 最終行と開始マーカーが 1 行に繋がる。`$(...)` は末尾の改行を
		# 落とすので、最後の 1 バイトを取って空に見えれば改行だった、と
		# 判定できる。
		if [ -n "$(tail -c 1 "$_snap")" ]; then
			printf '\n' >>"$_tmp"
		fi
		{
			printf '%s\n' "$HOSTS_BEGIN"
			if [ -n "$body" ]; then
				printf '%s\n' "$body"
			fi
			printf '%s\n' "$HOSTS_END"
		} >>"$_tmp"
	else
		{
			# ブロックより前。b が 1 行目のときに `1,0p` を渡すと sed が
			# 行番号 0 を拒否するので、その場合は前置きが無いものとして飛ばす。
			if [ "$b" -gt 1 ]; then
				sed -n "1,$((b - 1))p" "$_snap"
			fi
			printf '%s\n' "$HOSTS_BEGIN"
			if [ -n "$body" ]; then
				printf '%s\n' "$body"
			fi
			printf '%s\n' "$HOSTS_END"
			# ブロックより後。終了行がファイル末尾なら 0 行になるだけで
			# エラーにはならない。
			sed -n "$((e + 1)),\$p" "$_snap"
		} >"$_tmp"
	fi

	# 被せる直前に、写しを取ってから実物が動いていないかを 1 度だけ確かめる。
	# 動いていたら何も書かずに止める。sudo のパスワード待ちを挟む以上、
	# 写しを取ってから被せるまでには数十秒あることがあり、その間に
	# Docker Desktop や別の端末が書けば、こちらが被せた瞬間にその分が消える。
	# 消したものは退避にも入らない（退避も写しから作るため）ので、黙って
	# 消えるより打ち直させる方がよい。
	if ! cmp -s "$_snap" "$HOSTS"; then
		_die "${HOSTS} changed while this command was running — another process (Docker Desktop, another 'karakuri-loopback' run, a hand edit) got there first. Nothing was written; run the same command again"
	fi

	# 退避は毎回上書きの 1 世代だけ。世代を持たせると、どれが「壊れる前」
	# なのかを選ぶ判断が要る。ここで守りたいのは「直前の 1 回で壊した」
	# 場合の戻し先であって、履歴ではない。
	#
	# 退避元が実物ではなく写しなのは、直前の cmp を通っている以上どちらでも
	# 同じ内容だからであり、かつ「退避した内容」と「切り貼りの土台にした
	# 内容」が定義上ずれないため。属性は install で明示する（cp だと
	# 退避先が既にあるときと無いときでモードが変わる）。
	#
	# ここも失敗を明示的に見る（呼び出し元が `|| exit 1` で呼ぶため、
	# この関数の中では set -e が効かない）。退避が取れないまま被せるのは、
	# 一番戻せない失敗の仕方である。
	sudo install -o root -g "$ROOT_GROUP" -m 0644 "$_snap" "$HOSTS_BAK" ||
		_die "could not write the backup ${HOSTS_BAK}. ${HOSTS} is unchanged"

	_atomic_replace "$_tmp" "$HOSTS"
	_rmtemp
	return 0
}

# 管理ブロックの中には、利用者が置いたコメント行（`# api は 127.0.2.7`）が
# 入り得る。ブロックの中は触るなと書いてあるのはマーカーの外の話で、中は
# こちらが組み立て直す領域だが、だからといって利用者の書いた行を消してよい
# ことにはならない。以下の 4 つは、先頭フィールドがアドレスの形をしていない
# 行を「アドレス行ではない」と見なして、読むときは無視し、書くときはそのまま
# 通す。判定は _looks_like_addr で、add / remove / hosts の見分けで同じ規則を
# 使う（コメント行の `#` を「アドレス」と読んで `already mapped to #` のような
# 報告を出さないため）。
#
# _body_has_name <body> <name> — ブロック内でその名前が使われているか。
_body_has_name() {
	local body="$1" name="$2" line laddr lrest w
	[ -n "$body" ] || return 1
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		read -r laddr lrest <<<"$line"
		_looks_like_addr "$laddr" || continue
		for w in $lrest; do
			[ "$w" = "$name" ] && return 0
		done
	done <<<"$body"
	return 1
}

# _body_addr_of_name <body> <name> — その名前が載っている行のアドレスを出す。
_body_addr_of_name() {
	local body="$1" name="$2" line laddr lrest w
	[ -n "$body" ] || return 0
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		read -r laddr lrest <<<"$line"
		_looks_like_addr "$laddr" || continue
		for w in $lrest; do
			if [ "$w" = "$name" ]; then
				printf '%s\n' "$laddr"
				return 0
			fi
		done
	done <<<"$body"
	return 0
}

# _body_add <body> <addr> <name>... — 新しいブロックの中身を出す。
#
# 同じアドレスの行が既にあれば、その行に足りない名前だけを足す（行を
# 増やさない）。
#
# 「その名前が既に別のアドレスに載っている」場合に止める検査は、ここには
# 置かない。cmd_add が特権操作へ入る前に同じ検査をしており、_body_add の
# 呼び出し元は cmd_add だけなので、ここに同じ規則を書いてもエラー文字列ごと
# 二重になるだけで一度も到達しない。到達しないコードは、次に規則を変える人が
# 片方だけ直しても誰も気付かない場所になる。検査は前（cmd_add）に 1 つだけ
# 置く、という形を残す。
#
# 管理ブロックの外にある同名の行は見ない。あそこは他のツールと利用者の
# 領分で、こちらが読んで判断に使うと「外を消してくれるはず」という期待を
# 生む。外は 1 バイトも触らない、という規律の方を優先する。
_body_add() {
	local body="$1" addr="$2"
	shift 2

	local -a names=()
	while [ "$#" -gt 0 ]; do
		names+=("$1")
		shift
	done

	# 名前が 1 つも無いなら /etc/hosts に書くことは無い（名前の無い行は
	# 何も解決しない）ので、そのまま返す。この早期脱出は防御でもある:
	# macOS の /bin/bash は 3.2 で、`set -u` 下の空配列 `"${arr[@]}"` は
	# unbound variable になる。下の for ループはここを通った後だけ走る。
	if [ "${#names[@]}" -eq 0 ]; then
		printf '%s\n' "$body"
		return 0
	fi

	local n out="" line laddr lrest found=0 w have
	if [ -n "$body" ]; then
		while IFS= read -r line; do
			# 空行は落とす。ブロックの中は「1 行 1 アドレス」だけにして
			# おくと、行数と管理対象の数が一致し、目で数えられる。
			[ -n "$line" ] || continue
			read -r laddr lrest <<<"$line"

			# アドレス行でない行（利用者のコメント）は原文のまま通す。
			if ! _looks_like_addr "$laddr"; then
				out="${out:+${out}
}${line}"
				continue
			fi

			if [ "$laddr" = "$addr" ]; then
				found=1
				for n in "${names[@]}"; do
					have=0
					for w in $lrest; do
						[ "$w" = "$n" ] && have=1
					done
					if [ "$have" -eq 0 ]; then
						lrest="${lrest:+${lrest} }${n}"
					fi
				done
				line="${laddr}${lrest:+ ${lrest}}"
			fi

			out="${out:+${out}
}${line}"
		done <<<"$body"
	fi

	if [ "$found" -eq 0 ]; then
		line="$addr"
		for n in "${names[@]}"; do
			line="${line} ${n}"
		done
		out="${out:+${out}
}${line}"
	fi

	printf '%s\n' "$out"
	return 0
}

# _body_remove_addr <body> <addr> — そのアドレスの行を丸ごと落とす。
# 先頭フィールドの完全一致でしか落とさないので、コメント行は素通りする。
_body_remove_addr() {
	local body="$1" addr="$2"
	local out="" line laddr lrest

	[ -n "$body" ] || return 0
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		read -r laddr lrest <<<"$line"
		[ "$laddr" = "$addr" ] && continue
		out="${out:+${out}
}${line}"
	done <<<"$body"

	printf '%s\n' "$out"
	return 0
}

# _body_remove_name <body> <name> — その名前だけを落とす。
# 行に他の名前が残るならアドレス行は残し、全部消えたら行ごと落とす。
_body_remove_name() {
	local body="$1" name="$2"
	local out="" line laddr lrest kept w

	[ -n "$body" ] || return 0
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		read -r laddr lrest <<<"$line"

		# アドレス行でない行は原文のまま通す。この判定が無いと、下の
		# 「名前が 1 つも残らなかった行は落とす」がフィールド 1 つの行を
		# 全部落とすので、利用者がブロックの中に置いた `# 4588 は api` の
		# ようなコメント行が、無関係な remove のたびに消えていた。
		# 消えたことは remove の出力にも出ない（消したのは名前だと言う）。
		if ! _looks_like_addr "$laddr"; then
			out="${out:+${out}
}${line}"
			continue
		fi

		kept=""
		for w in $lrest; do
			[ "$w" = "$name" ] && continue
			kept="${kept:+${kept} }${w}"
		done

		# 名前が 1 つも残らなかった行は落とす。アドレスだけの行を
		# /etc/hosts に残しても意味が無く（名前の無い行は何も解決しない）、
		# 「消したはずの名前の残骸」に見える。
		[ -n "$kept" ] || continue
		out="${out:+${out}
}${laddr} ${kept}"
	done <<<"$body"

	printf '%s\n' "$out"
	return 0
}

# --- サブコマンド: install ------------------------------------------------------
# _check_payload_paths <daemon> <plist> — 配置先パスの二重定義を突き合わせる。
#
# 同じパスが 2 箇所に書かれている組が 2 つある:
#
#   設定ファイル  このスクリプトの $CONF と、daemon の中の CONF=
#   daemon 本体    このスクリプトの $DAEMON_PATH と、plist の ProgramArguments[0]
#
# どちらも、片方だけ変えても install は最後まで通り、bootstrap も成功する。
# 壊れていることが分かるのは次に再起動したとき（daemon が空のファイルを
# 読む／launchd が居ないファイルを起動しようとする）で、そのころには install を
# 打った記憶と結び付かない。定数を 1 箇所にまとめられない（配布物は独立した
# ファイルとして root で実行される）以上、せめて置く直前に突き合わせる。
#
# 突合は特権に入る前に済ませる。不一致は「配置してから気付く」より
# 「配置せずに止める」方が戻しやすい。
_check_payload_paths() {
	local src_daemon="$1" src_plist="$2"
	local daemon_conf plist_prog

	# daemon 側は POSIX sh の定数 1 行（CONF=/etc/karakuri/loopback-aliases）。
	daemon_conf="$(awk '/^CONF=/ { sub(/^CONF=/, ""); print; exit }' "$src_daemon")"
	[ -n "$daemon_conf" ] || _die "cannot find a 'CONF=' line in '${src_daemon}' — that does not look like the karakuri-loopback-aliases daemon. Refusing to install it"
	if [ "$daemon_conf" != "$CONF" ]; then
		_die "'${src_daemon}' reads its addresses from '${daemon_conf}', but this script writes them to '${CONF}'. Installing that pair would leave a daemon that never sees what 'karakuri-loopback add' records, and you would only notice after a reboot. Nothing was installed — make the two agree"
	fi

	# plist 側は ProgramArguments の最初の <string>。
	plist_prog="$(awk '
		/<key>ProgramArguments<\/key>/ { in_args = 1; next }
		in_args && /<string>/ {
			sub(/^[^<]*<string>/, "")
			sub(/<\/string>.*$/, "")
			print
			exit
		}
	' "$src_plist")"
	[ -n "$plist_prog" ] || _die "cannot find the ProgramArguments program in '${src_plist}' — that does not look like the com.karakuri.loopback-aliases plist. Refusing to install it"
	if [ "$plist_prog" != "$DAEMON_PATH" ]; then
		_die "'${src_plist}' runs '${plist_prog}', but this script installs the daemon to '${DAEMON_PATH}'. launchd would bootstrap a job pointing at a file that is not there, and you would only notice after a reboot. Nothing was installed — make the two agree"
	fi
	return 0
}

# 何度打ってもよい（配布物を更新したら打ち直す、が想定している使い方）。
# 上書きしないのは設定ファイルだけで、そこには利用者が足したアドレスが
# 入っているため。
cmd_install() {
	[ "$#" -eq 0 ] || usage 1

	# 特権に入る前に、置くものが揃っているかを一般ユーザー権限で確かめる。
	# sudo のパスワードを打たせてから「配布物が無い」と言うのは順序が悪い。
	local src_daemon="${SRC_DIR}/karakuri-loopback-aliases"
	local src_plist="${SRC_DIR}/com.karakuri.loopback-aliases.plist"
	[ -f "$src_daemon" ] || _die "cannot find '${src_daemon}'. The 'loopback' directory is expected next to this script — copy the whole host/ directory, not just this file"
	[ -f "$src_plist" ] || _die "cannot find '${src_plist}'. The 'loopback' directory is expected next to this script — copy the whole host/ directory, not just this file"
	_check_payload_paths "$src_daemon" "$src_plist"

	# sudo はスクリプト全体にかけない（`sudo loopback-setup.sh` を運用に
	# しない）。特権が要るのは下の install / launchctl / ifconfig だけで、
	# 引数の検証や配布物の存在確認は一般ユーザー権限でできる。全体を root で
	# 走らせると、検証の途中で作る一時ファイルまで root 所有になり、
	# 「読めるはずのものが読めない」種類の後始末が増える。
	sudo install -d -o root -g "$ROOT_GROUP" -m 0755 "$CONF_DIR"

	if [ -f "$CONF" ]; then
		printf 'config: kept %s (already there)\n' "$CONF"
	else
		# 雛形はコメントだけ。ここでアドレスを 1 つ書いておく親切は
		# しない: 書いた瞬間に「karakuri が 127.0.1.1 を使う」という
		# 規則が生まれ、割り当てを決めるのは開発者だという前提が崩れる。
		_mktemp
		cat >"$_tmp" <<'EOF'
# karakuri loopback aliases
#
# 1 行 1 アドレス。ここに並べたアドレスを、起動のたびに LaunchDaemon
# (com.karakuri.loopback-aliases) が `ifconfig lo0 alias <addr> up` で
# 張り直す。macOS では 127.0.0.1 以外の loopback アドレスは明示的に
# 張らないと bind できず、張った結果は再起動で消えるため。
#
# `karakuri-loopback add <addr>` が末尾に追記する。手で編集してもよい:
# 空行と # で始まる行は無視され、2 番目以降のフィールドも無視される
# （行末に覚え書きを書ける）。
#
# 受け付けるのは 127. で始まるアドレスだけ。それ以外の行は daemon が
# 理由を添えて読み飛ばす（/var/log/karakuri-loopback-aliases.log）。
#
# どのアドレスをどのプロジェクトに割り当てるかは、このファイルではなく
# 各プロジェクトの .devcontainer/README.md に書くこと。127.0.1.x を
# 使うか 127.0.2.x を使うかは流儀であって、ツールの決めごとではない。
EOF
		sudo install -o root -g "$ROOT_GROUP" -m 0644 "$_tmp" "$CONF"
		_rmtemp
		printf 'config: created %s\n' "$CONF"
	fi

	# /usr/local/libexec は素の macOS には無い。install -d は途中の
	# ディレクトリもまとめて作る。
	sudo install -d -o root -g "$ROOT_GROUP" -m 0755 "$DAEMON_DIR"
	sudo install -o root -g "$ROOT_GROUP" -m 0755 "$src_daemon" "$DAEMON_PATH"
	printf 'daemon: installed %s\n' "$DAEMON_PATH"

	sudo install -o root -g "$ROOT_GROUP" -m 0644 "$src_plist" "$PLIST_PATH"
	printf 'launchd: installed %s\n' "$PLIST_PATH"

	# 入れ直しに備えて、いったん外してから入れる。既に読み込まれている
	# 場合、bootstrap は「既にある」で失敗する。外す方の失敗（そもそも
	# 読み込まれていない）は正常な経路なので握る。
	#
	# `launchctl load -w` を使わないのは、あれが古い API で、失敗しても
	# 終了コードが 0 のことがあるため（plist の書式エラーが黙って通り、
	# 再起動して初めて「動いていない」と分かる）。bootout / bootstrap は
	# 失敗を非ゼロで返す。
	sudo launchctl bootout system "$PLIST_PATH" 2>/dev/null || true

	# bootstrap の失敗は set -e に任せない。bootout は launchd が job を
	# 落とし終える前に戻ることがあり、その直後の bootstrap は
	# "already bootstrapped" で落ちる。set -e にそこで止めさせると、plist と
	# daemon は配置済みなのに bootstrap も既存アドレスの復元も済んでいない
	# 状態で終わる。「install は何度打ってもよい」という前提が、まさに
	# 打ち直したくなる場面で崩れる。
	#
	# なので、ここでは握って何が起きたかと次の一手を返し、下の復元段までは
	# 必ず走らせる。ただし終了コードは 0 にしない: LaunchDaemon が読み込まれた
	# ことは確かめられておらず、成功として返すと「再起動したら消えた」に
	# 逆戻りする。やることはやったうえで、非ゼロで人間に返す。
	local bootstrap_failed=0
	if sudo launchctl bootstrap system "$PLIST_PATH"; then
		printf 'launchd: bootstrapped com.karakuri.loopback-aliases\n'
	else
		bootstrap_failed=1
		_err "'launchctl bootstrap system ${PLIST_PATH}' failed. The most likely reason is that the job is already bootstrapped: 'bootout' can return before launchd has finished unloading it. Check with 'sudo launchctl print system/com.karakuri.loopback-aliases'; if it is there, run 'sudo launchctl bootout system/com.karakuri.loopback-aliases' and then 'karakuri-loopback install' again. Carrying on with the addresses below so that they are usable right now"
	fi

	# 設定済みのアドレスを今この場で張る。plist は RunAtLoad なので
	# bootstrap した時点で daemon も走っているが、あちらの出力は log にしか
	# 出ない。同じことをここでもう一度やるのは、失敗を打った本人の端末に
	# 見せるためで、ifconfig alias は冪等なので二重に張っても害はない。
	# bootstrap が失敗していてもこの段は走らせる: LaunchDaemon が入って
	# いなくても、その場で使える状態にはしておく方が親切であり、install を
	# 打ち直す妨げにもならない（張り直しは冪等）。
	local addr count=0
	while IFS= read -r addr; do
		[ -n "$addr" ] || continue
		if sudo ifconfig lo0 alias "$addr" up; then
			printf 'lo0: alias %s is up\n' "$addr"
		else
			_err "'ifconfig lo0 alias ${addr} up' failed — the line for ${addr} in ${CONF} may be malformed"
		fi
		count=$((count + 1))
	done <<<"$(_conf_addrs)"

	if [ "$count" -eq 0 ]; then
		printf "config: no addresses yet — add one with 'karakuri-loopback add <addr> [hostname...]'\n"
	fi

	if [ "$bootstrap_failed" -eq 1 ]; then
		_err "install placed every file and raised every configured alias, but the LaunchDaemon is not loaded — the aliases above will be gone after the next reboot until the bootstrap above succeeds"
		return 1
	fi
	return 0
}

# --- サブコマンド: add ----------------------------------------------------------
cmd_add() {
	[ "$#" -ge 1 ] || usage 1

	local addr="$1"
	shift

	# 検証は全部先に済ませる。特権操作を始めてから 2 つ目のホスト名で
	# 弾かれると、alias だけ張られて /etc/hosts は元のまま、という中途半端な
	# 状態が残る。sudo を個々の操作に付ける形にしているのは、この「検証は
	# 一般ユーザー権限、変更は最小限の特権」の順序を書けるようにするため
	# でもある。
	_check_addr "$addr" || exit 1
	local n
	for n in "$@"; do
		_check_hostname "$n" || exit 1
	done

	[ -f "$CONF" ] || _die "no ${CONF}. Run 'karakuri-loopback install' first"

	# 読むものは全部、特権操作に入る前に写しへ取る。以降このコマンドが
	# 見る「設定ファイルの中身」と「/etc/hosts の中身」はこの 2 枚だけで、
	# 実物をもう一度読むのは被せる直前の突合だけである。
	_conf_snapshot

	# /etc/hosts の側で弾かれる条件（同じ名前が別のアドレスに載っている）も、
	# 特権操作に入る前にここで見ておく。alias を張った後で弾くと、
	# 「アドレスだけ張られて名前は付いていない」という中途半端な状態が
	# 残る。検査は前へ、変更は後ろへ。この検査はここにしか無い。
	local bounds b e old new
	if [ "$#" -gt 0 ]; then
		_hosts_snapshot
		bounds="$(_hosts_bounds)" || exit 1
		b="${bounds%% *}"
		e="${bounds##* }"
		old="$(_hosts_body "$b" "$e")"

		local owner
		for n in "$@"; do
			owner="$(_body_addr_of_name "$old" "$n")"
			if [ -n "$owner" ] && [ "$owner" != "$addr" ]; then
				_die "'${n}' is already mapped to ${owner} in the managed block of ${HOSTS}. Run 'karakuri-loopback remove ${n}' first if you want to move it to ${addr}"
			fi
		done
	fi

	if _conf_has "$addr" "$_csnap"; then
		printf 'config: %s already listed in %s\n' "$addr" "$CONF"
	else
		# 追記するのはアドレスだけで、ホスト名は書かない。書くと
		# `add <addr> <another-name>` のたびに古い覚え書きが残り、
		# 設定ファイルの記述と /etc/hosts の実態がずれる。名前がどこに
		# 割り当てられているかは /etc/hosts を見れば分かる。
		_conf_append "$addr"
		printf 'config: added %s to %s\n' "$addr" "$CONF"
	fi

	# 再起動を待たずに使えるようにする。既に張られている場合も ifconfig は
	# 成功するので、冪等性のために場合分けを足す必要はない。
	if sudo ifconfig lo0 alias "$addr" up; then
		printf 'lo0: alias %s is up\n' "$addr"
	else
		_die "'ifconfig lo0 alias ${addr} up' failed"
	fi

	[ "$#" -gt 0 ] || return 0

	# `local new="$(...)"` と 1 文で書かないこと。local 自身の終了コードが
	# 代入結果を上書きしてしまい、_body_add が非ゼロを返してもここは成功に
	# 見える（そのまま空の body で /etc/hosts を上書きする）。宣言と代入を
	# 分ける。今の _body_add は名前の衝突では返らないが、この書き方自体は
	# 「代入の失敗を握り潰さない」ための形なので残す。
	new="$(_body_add "$old" "$addr" "$@")" || exit 1

	if [ "$new" = "$old" ]; then
		printf 'hosts: %s already maps %s\n' "$HOSTS" "$*"
		return 0
	fi

	_hosts_write "$new" || exit 1
	printf 'hosts: %s now maps %s -> %s (backup: %s)\n' "$HOSTS" "$addr" "$*" "$HOSTS_BAK"
	return 0
}

# --- サブコマンド: remove -------------------------------------------------------
# アドレスを渡したときと、ホスト名を渡したときで、消す範囲が違う。
#
# ホスト名で消したときに、そのアドレスを使う行が 1 つも無くなったとしても、
# lo0 の alias と設定ファイルの行は残す。同じアドレスを別のプロジェクトが
# 使っている（そのプロジェクトは自分の名前を /etc/hosts の外に書いている、
# あるいは名前を使わず IP で叩いている）ことがあり得るからで、こちらから
# 見えないだけの利用者を、こちらの都合で切ることになる。alias を消すのは
# 利用者がアドレスを名指ししたときだけ、という規律にしておけば、
# 「消えすぎて壊れた」ではなく「残っているものを消し忘れた」の側に
# 倒れる。残っている alias は list ですぐ見つかり、実害も無い。
cmd_remove() {
	[ "$#" -eq 1 ] || usage 1

	local arg="$1"

	if _looks_like_addr "$arg"; then
		_check_addr "$arg" || exit 1
		_remove_addr "$arg"
		return 0
	fi

	_check_hostname "$arg" || exit 1
	_remove_name "$arg"
	return 0
}

_remove_addr() {
	local addr="$1"
	local bounds b e old new

	# /etc/hosts から先に落とす。名前が残ったまま alias だけ消えると、
	# 名前は引けるのに繋がらないという、最も紛らわしい状態になる。
	#
	# /etc/hosts が読めない場合は止める。元はここだけ `if [ -r ... ]` で
	# 黙って hosts の段を飛ばしており、_remove_name（読めなければ _die）と
	# 挙動が食い違っていた。読めない理由は分からない（マウントの事故か、
	# 誰かがモードを変えたか）ので、分からないまま「hosts の行は消えて
	# いないが alias と設定ファイルの行は消えた」という半端な結果を残す
	# よりは、何もせず理由を返す方がよい。曖昧なら失敗させる、の側へ揃える。
	_hosts_snapshot
	bounds="$(_hosts_bounds)" || exit 1
	b="${bounds%% *}"
	e="${bounds##* }"
	old="$(_hosts_body "$b" "$e")"
	new="$(_body_remove_addr "$old" "$addr")"
	if [ "$new" != "$old" ]; then
		_hosts_write "$new" || exit 1
		printf 'hosts: dropped the %s entry from %s (backup: %s)\n' "$addr" "$HOSTS" "$HOSTS_BAK"
	else
		printf 'hosts: no %s entry in the managed block of %s\n' "$addr" "$HOSTS"
	fi

	if [ -f "$CONF" ]; then
		_conf_snapshot
	fi
	if [ -n "$_csnap" ] && _conf_has "$addr" "$_csnap"; then
		_mktemp
		awk -v a="$addr" '$1 == a { next } { print }' "$_csnap" >"$_tmp"
		_conf_replace "$_tmp"
		_rmtemp
		printf 'config: dropped %s from %s\n' "$addr" "$CONF"
	else
		printf 'config: %s was not listed in %s\n' "$addr" "$CONF"
	fi

	# 張られていないアドレスに -alias を打つと ifconfig は失敗する。
	# 「既に無い」は remove としては望んだ結果なので、握って報告に留める。
	if sudo ifconfig lo0 -alias "$addr" 2>/dev/null; then
		printf 'lo0: removed the alias %s\n' "$addr"
	else
		printf 'lo0: %s was not aliased\n' "$addr"
	fi
	return 0
}

_remove_name() {
	local name="$1"
	local bounds b e old new owner

	# 読めなければ止める（_hosts_snapshot がその場で _die する）。
	_hosts_snapshot

	bounds="$(_hosts_bounds)" || exit 1
	b="${bounds%% *}"
	e="${bounds##* }"
	old="$(_hosts_body "$b" "$e")"

	if ! _body_has_name "$old" "$name"; then
		printf "hosts: '%s' is not in the managed block of %s (nothing to do; entries outside the block are not ours to remove)\n" "$name" "$HOSTS"
		return 0
	fi

	owner="$(_body_addr_of_name "$old" "$name")"
	new="$(_body_remove_name "$old" "$name")"
	_hosts_write "$new" || exit 1
	printf "hosts: dropped '%s' from %s (backup: %s)\n" "$name" "$HOSTS" "$HOSTS_BAK"

	# 上の長いコメントのとおり、alias と設定ファイルの行はここでは消さない。
	# 消したいなら、そう打ってもらう。
	printf "lo0: %s is still aliased and still listed in %s — run 'karakuri-loopback remove %s' if you want the address gone too\n" "$owner" "$CONF" "$owner"
	return 0
}

# --- サブコマンド: list ---------------------------------------------------------
# 設定ファイル・lo0・/etc/hosts の 3 つを並べる。この 3 者はずれる:
# 設定ファイルに足したが再起動も add もしていない、手で ifconfig を打った、
# /etc/hosts だけ消した、のどれもが起こる。ずれていることが一目で分かる
# ことが、このサブコマンドの目的である（だから 3 つを別々の
# コマンドに分けない）。
cmd_list() {
	# 引数は取らない。install / add / remove は個数を検査しているのに
	# ここだけ検査が無く、`list foo` が黙って無視されていた。打ち間違いを
	# 黙って飲み込むと、利用者は「効いた」と思って別のところを疑い始める。
	[ "$#" -eq 0 ] || usage 1

	local conf_addrs="" lo_addrs=""

	conf_addrs="$(_conf_addrs)"

	# `inet` 行の 2 番目のフィールドがアドレス。127.0.0.1 は lo0 に
	# 必ず載っていて、このツールが管理する対象ではないので外す
	# （出すと毎回「設定ファイルに無い」印が付き、印そのものが
	# 意味を持たなくなる）。
	lo_addrs="$(ifconfig lo0 2>/dev/null | awk '$1 == "inet" && $2 ~ /^127\./ && $2 != "127.0.0.1" { print $2 }')"

	printf 'config (%s):\n' "$CONF"
	if [ ! -f "$CONF" ]; then
		printf "  (no config file — run 'karakuri-loopback install')\n"
	elif [ -z "$conf_addrs" ]; then
		printf '  (empty)\n'
	else
		local a
		while IFS= read -r a; do
			[ -n "$a" ] || continue

			# 127.0.0.1 は他の行と同じ土俵に乗せない。設定ファイルは手で
			# 編集してよいので書かれ得るが、lo0 の一覧からは（管理対象では
			# ないので）外してあり、そのまま突き合わせると毎回
			# 「listed but not up on lo0 — run "karakuri-loopback add 127.0.0.1"」
			# と出る。その add は _check_addr が拒否するので、実行できない
			# 指示を出し続けることになる。ここでは別の文言で「このツールでは
			# 管理しない」とだけ言う。daemon 側（karakuri-loopback-aliases）も
			# 同じ理由で同じ言い方をして読み飛ばす。
			#
			# 行そのものを出さない案は採らなかった: 出さないと、書いた本人は
			# 「なぜ効かないのか」を調べる手掛かりを 1 つも得られない。
			if [ "$a" = "127.0.0.1" ]; then
				printf '! %s   (not managed here: it is always on lo0, so there is nothing to alias — the LaunchDaemon skips this line too. Put "127.0.0.1 <name>" straight into %s if you need the name)\n' "$a" "$HOSTS"
				continue
			fi

			if _list_contains "$lo_addrs" "$a"; then
				printf '  %s\n' "$a"
			else
				printf '! %s   (listed but not up on lo0 — run "karakuri-loopback add %s")\n' "$a" "$a"
			fi
		done <<<"$conf_addrs"
	fi

	printf '\nlo0 aliases (127.*, excluding the built-in 127.0.0.1):\n'
	if [ -z "$lo_addrs" ]; then
		printf '  (none)\n'
	else
		local l
		while IFS= read -r l; do
			[ -n "$l" ] || continue
			if _list_contains "$conf_addrs" "$l"; then
				printf '  %s\n' "$l"
			else
				printf '! %s   (up on lo0 but not in the config file — it will be gone after a reboot)\n' "$l"
			fi
		done <<<"$lo_addrs"
	fi

	printf '\n%s (managed block):\n' "$HOSTS"
	if [ ! -r "$HOSTS" ]; then
		printf '  (cannot read %s)\n' "$HOSTS"
		return 0
	fi

	# 読むだけのコマンドだが、ここも写しから読む。実物を 3 回読む形だと、
	# 表示している最中に他のプロセスが書けば、行番号と中身がずれた
	# 「実在しない状態」を表示することになる。
	_hosts_snapshot

	# ここだけは bounds の失敗で止めない。list は読むだけのコマンドで、
	# マーカーが壊れているときこそ状況を見たい（そして _hosts_bounds は
	# 壊れ方を stderr へ説明している）。
	local bounds b e body
	if ! bounds="$(_hosts_bounds)"; then
		printf '  (markers are broken — see the message above)\n'
		return 0
	fi
	b="${bounds%% *}"
	e="${bounds##* }"
	body="$(_hosts_body "$b" "$e")"

	if [ "$b" -eq 0 ]; then
		printf '  (no managed block)\n'
	elif [ -z "$body" ]; then
		printf '  (empty)\n'
	else
		printf '%s\n' "$body" | sed 's/^/  /'
	fi
	return 0
}

# _list_contains <改行区切りのリスト> <値> — 完全一致で探す。
_list_contains() {
	local list="$1" want="$2" x
	[ -n "$list" ] || return 1
	while IFS= read -r x; do
		[ "$x" = "$want" ] && return 0
	done <<<"$list"
	return 1
}

# --- 入口 -----------------------------------------------------------------------
# 未知のサブコマンドは 1、-h / --help は 0 で終える。help を求めて打った人に
# 非ゼロを返すと、スクリプトから呼んだときにそこで止まる。
[ "$#" -ge 1 ] || usage 1

cmd="$1"
shift

case "$cmd" in
install) cmd_install "$@" ;;
add) cmd_add "$@" ;;
remove) cmd_remove "$@" ;;
list) cmd_list "$@" ;;
-h | --help | help) usage 0 ;;
*)
	_err "unknown command '${cmd}'"
	usage 1
	;;
esac
