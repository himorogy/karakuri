# karakuri.sh — ホスト側の呼び出し規約をまとめたシェル関数ファイル
#
# ============================================================================
# これは source して使うファイルであって、実行するファイルではない。
# 利用側の .zshrc / .bashrc に 1 行だけ書く:
#
#   . ~/.config/karakuri/images/runtime-base/templates/host/karakuri.sh
#
# 置き場所は dev container へ bind mount される workspace の外にすること。
# workspace はホストに bind mount されているため、そこへ置くと dev
# container の中で常駐する LLM エージェントがこのファイルを書き換えられる。
# ここで組み立てているのは broker（鍵の取り出し）の呼び出しと prod の起動
# そのものなので、書き換えられれば「鍵を別の場所へ複製してから正規 broker を
# 呼ぶ」も「別のイメージで prod を起動する」も仕込める。broker と起動
# スクリプトをホストの固定パスへ置く理由（それぞれの冒頭に書いてある）が、
# その呼び出し規約であるこのファイルにもそのまま当たる。
# ============================================================================
#
# なぜ関数ファイルなのか: ここに入っているものは、broker の項目名の付け方・
# compose project 名の付け方・対話 prod 作業の二段構え・port forwarding の
# ControlPath の規約と、どれも karakuri 側が決めた規約である。規約を決めた
# 側が呼び出しも配れば、利用者の .zshrc へ規約を書き写す必要がなくなり、
# 規約が変わったときに追随すべき場所が一箇所で済む。
#
# 逆に、環境そのもの（bw の在処・org 名・compose ファイルの配置先）は
# karakuri からは決められないので、環境変数として利用側に残す。
#
# --- 環境変数 -----------------------------------------------------------------
#
#   KARAKURI_BW_BIN        bw 実行ファイルの絶対パス。未設定なら broker 側の
#                          既定（PATH 解決）に任せる
#   KARAKURI_ORG           GitHub org の既定値。<org>/<repo> の org を省いた
#                          ときに補われる
#   KARAKURI_PROD_COMPOSE  全プロジェクトで 1 枚を共有する compose.prod.yaml の
#                          配置先。KARAKURI_PROD_COMPOSE_DIR が設定されている
#                          ときは使われない
#   KARAKURI_PROD_COMPOSE_DIR
#                          プロジェクトごとの compose ファイルを集めた
#                          ディレクトリ。使うのは <repo>.yaml（無ければ
#                          <repo>.yml）。KARAKURI_PROD_COMPOSE より優先される。
#                          prod 系の関数は、この 2 つのどちらかが要る
#   KARAKURI_PROD_INSTALL  タスクの前に走らせる install コマンド。
#                          既定は `pnpm install --frozen-lockfile`。
#                          空文字を設定すると install 段を省く
#   KARAKURI_PROD_RUN      タスク名の前に置くコマンド。既定は `pnpm`
#                          （`npm run` / `make` などに差し替えられる）
#   KARAKURI_TOOL_DIR      prod-run.sh / dev-inject.sh / broker を探す
#                          ディレクトリ。既定はこのファイルが置かれている
#                          ディレクトリで、見つからなければ PATH を引く。
#                          通常は設定しなくてよい（既に値があれば source
#                          しても上書きしないので、置き場所を変えたときは
#                          シェルを開き直すか、unset してから source し直す）
#
# --- 提供する関数 ---------------------------------------------------------------
#
#   karakuri-port-forward <name>                    port forwarding を張り直す
#   karakuri-clean-port-forward [name...]           port forwarding の後始末
#   karakuri-loopback <install|add|remove|list> [args...]   /etc/hosts と loopback alias の設定（sudo が要る）
#   karakuri-dev-inject <project>                   dev container へ鍵を注入
#   karakuri-dock -p <compose-project> [-s <service>] [-w <workspace>] [up]
#                                                    dev container を使える状態にしてから入る
#                                                    （起動 → 未注入なら注入 → port forwarding → 対話シェル）
#   karakuri-prod-run <org/repo> <sha> <task> [args...]
#   karakuri-prod-exec <org/repo> <sha> <cmd> [args...]
#   karakuri-prod-base <org/repo> <sha>             対話作業の土台を起動
#   karakuri-prod-shell <repo>                      土台へ入る
#   karakuri-image-digest <tag>                     タグ → image: 行の完成形
#   karakuri-check-image <tag>                      compose の digest と照合
#   karakuri-broker-command <dev|prod> <project>    broker 実行ファイルのパスを出す（差し替え点）
#   karakuri-broker-env <dev|prod> <project>        broker へ渡す環境変数を出す（差し替え点）
#   karakuri-help                                   この一覧と環境変数の現在値を出す
#
# 上の一覧は karakuri-help と読み手が違う: こちらはソースを開いた人が
# 関数を追加・削除したときに真っ先に直す目次、karakuri-help はシェルを
# 開いたまま（ソースを見ずに）引ける対話用の一覧で、環境変数の現在値も
# 出す点がこちらには無い。関数を増減させたときはここと karakuri-help の
# 両方を直すこと（2 箇所で止めているのは、この一覧はテキストの目次として
# 見出しの直後という読みやすい位置に置きたく、実装の中に埋めると読み手が
# 増減を追いにくくなるため）。
#
# 名前が長いのは、source される側が `pf` や `prod-run` のような一般的な名前を
# 取ると利用者の既存の関数を黙って覆ってしまうため。短縮はファイル末尾の
# alias の例を .zshrc へ写して各自で付ける（長い名前は短くできるが、先に
# 短い名前を取られると利用者は元に戻せない）。
#
# --- 実装上の規律 ---------------------------------------------------------------
#
# トップレベルに `set -euo pipefail` を書かない。source される側がシェル
# オプションを触ると、利用者の対話シェルがそのまま巻き添えになる（例えば
# `set -e` が残ると、対話で打ったコマンドが 1 つ失敗しただけでシェルごと
# 終了する）。同じ理由で関数の内部でも `set -e` は使わず、戻り値を毎回
# 明示的に検査する。関数からの脱出は `exit` ではなく `return` で行う
# （`exit` は利用者のシェルを閉じてしまう）。
#
# bash と zsh の両方で動かす。配列は `arr+=(...)` と `"${arr[@]}"` だけを
# 使い、添字を直接書かない（zsh の配列は既定で 1 始まりで、bash と食い違う）。
# 文字列を語に割る必要がある箇所は、パラメータ展開の分割挙動が両者で違う
# （zsh は既定で分割しない）ため、`eval` による配列代入で揃える。

# --- このファイル自身の場所を覚える -------------------------------------------
# prod-run.sh / dev-inject.sh / broker はこのファイルの隣に置かれている
# （配布物として一式で来る）ことを既定とし、無ければ PATH を引く。
# 「PATH へ追加する」「~/.local/bin へ symlink する」のどちらの置き方でも
# 動くようにするための吸収であり、利用者にどちらかを強制しないための実装。
#
# 自分自身のパスの取り方がシェルで違う。bash は BASH_SOURCE、zsh は source
# されたファイルのパスが $0 に入る。
if [ -z "${KARAKURI_TOOL_DIR:-}" ]; then
	if [ -n "${BASH_SOURCE:-}" ]; then
		_karakuri_self="${BASH_SOURCE[0]}"
	else
		_karakuri_self="$0"
	fi
	KARAKURI_TOOL_DIR="$(cd "$(dirname "$_karakuri_self")" 2>/dev/null && pwd)"
	unset _karakuri_self
fi

# --- 内部ヘルパー ---------------------------------------------------------------
# 接頭辞 `_karakuri_` の関数と変数は内部用。利用者が呼ぶことは想定していない
# （補完で `karakuri-` を打ったときに一覧へ出ないよう、区切りも `-` ではなく
# `_` にしてある）。

# _karakuri_tool <name> — 実行するスクリプトの在処を stdout に出す。
_karakuri_tool() {
	if [ -n "${KARAKURI_TOOL_DIR:-}" ] && [ -x "${KARAKURI_TOOL_DIR}/$1" ]; then
		printf '%s\n' "${KARAKURI_TOOL_DIR}/$1"
		return 0
	fi
	if command -v "$1" >/dev/null 2>&1; then
		command -v "$1"
		return 0
	fi
	echo "karakuri: cannot find '$1'. Put it next to karakuri.sh, or on PATH, or point KARAKURI_TOOL_DIR at the directory that holds it" >&2
	return 1
}

# _karakuri_parse_repo <spec> — <org>/<repo> を割って _karakuri_org と
# _karakuri_repo に置く。
#
# 引数 1 個で受けるのは、位置引数を省略可能にしないため。`<org> <repo> <sha>`
# と `<repo> <sha>` を引数の個数で見分ける形にすると、打ち損じ（引数の抜け）が
# エラーではなく「別の解釈」になり、そのまま別のリポジトリを prod で流す。
# スラッシュの有無なら曖昧性がない。
_karakuri_parse_repo() {
	_karakuri_org=""
	_karakuri_repo=""
	case "$1" in
	*/*/*)
		echo "karakuri: '$1' contains more than one '/'. Pass <org>/<repo> (or just <repo> when KARAKURI_ORG is set)" >&2
		return 1
		;;
	*/*)
		_karakuri_org="${1%%/*}"
		_karakuri_repo="${1#*/}"
		;;
	*)
		if [ -z "${KARAKURI_ORG:-}" ]; then
			echo "karakuri: '$1' has no '/' and KARAKURI_ORG is not set, so the org cannot be filled in. Pass <org>/<repo>, or set KARAKURI_ORG to the org you use most" >&2
			return 1
		fi
		_karakuri_org="$KARAKURI_ORG"
		_karakuri_repo="$1"
		;;
	esac

	if [ -z "$_karakuri_org" ] || [ -z "$_karakuri_repo" ]; then
		echo "karakuri: '$1' is not a valid <org>/<repo> (one side of the '/' is empty)" >&2
		return 1
	fi
	return 0
}

# _karakuri_plain_name <label> <value> — プロジェクト名・リポジトリ名として
# そのまま使える形かを見る。`/` を含む値をそのまま compose project 名や
# コンテナ名の一部にすると、別プロジェクトを指す名前が静かに出来上がる。
_karakuri_plain_name() {
	case "$2" in
	"")
		echo "karakuri: $1 is empty" >&2
		return 1
		;;
	*/*)
		echo "karakuri: $1 '$2' must not contain '/' — pass just the repository name here (this name becomes the compose project name)" >&2
		return 1
		;;
	esac
	return 0
}

# _karakuri_split <string> — 文字列をシェルの語として割り、_karakuri_argv に
# 置く。`KARAKURI_PROD_RUN="npm run"` のように複数語の設定を配列へ戻すため。
#
# eval を使うのは、bash と zsh で分割の既定が違うため（zsh はパラメータ展開の
# 結果を分割しない）。ここで割るのは利用者自身が設定した環境変数であり、
# 外から来る文字列ではない。引用符もそのまま効くので `make -f "my file"` の
# ような設定も書ける。
_karakuri_split() {
	_karakuri_argv=()
	[ -n "$1" ] || return 0
	eval "_karakuri_argv=($1)" || {
		echo "karakuri: could not parse '$1' as shell words" >&2
		return 1
	}
	return 0
}

# _karakuri_shquote <string> — 文字列をシングルクォートで包んで stdout に出す。
# sh -c に渡す文字列を組み立てるときに、各語をこれで包む。
_karakuri_shquote() {
	_karakuri_q_in="$1"
	_karakuri_q_out=""
	while [ -n "$_karakuri_q_in" ]; do
		case "$_karakuri_q_in" in
		*\'*)
			# シングルクォートは、いったん閉じて \' を挟んでから開き直す。
			_karakuri_q_out="${_karakuri_q_out}${_karakuri_q_in%%\'*}'\\''"
			_karakuri_q_in="${_karakuri_q_in#*\'}"
			;;
		*)
			_karakuri_q_out="${_karakuri_q_out}${_karakuri_q_in}"
			_karakuri_q_in=""
			;;
		esac
	done
	printf "'%s'" "$_karakuri_q_out"
	unset _karakuri_q_in _karakuri_q_out
}

# --- broker 依存部（差し替え点） ------------------------------------------------
# broker は差し替え可能であるというのが契約（各 broker の冒頭を参照）なので、
# broker 固有の知識はこの 2 つの関数だけに閉じ込める。他の broker を使う
# 利用者は、このファイルを source した後に同名の関数を再定義すればよい
# （後から定義した方が勝つ）。他の関数はここが返すものしか見ない。
#
# 既定は Bitwarden broker。項目名の並べ方は「共有 → 全プロジェクト共通の
# 個人 → プロジェクト個人」で、同名の鍵は後から来た値が勝つ（取込側の挙動）。
# つまり右にあるものほど強い。

# karakuri-broker-command <dev|prod> <project> — broker 実行ファイルのパスを
# stdout に出す。引数は、プロジェクトごとに別の broker を使う実装のために
# 渡してある（既定の実装は使わない）。
karakuri-broker-command() {
	_karakuri_tool broker-bitwarden.sh
}

# karakuri-broker-env <dev|prod> <project> — broker へ渡す環境変数を
# `NAME=VALUE` の行として stdout に出す。1 行 1 変数。
karakuri-broker-env() {
	if [ -n "${KARAKURI_BW_BIN:-}" ]; then
		printf 'BROKER_BW_BIN=%s\n' "$KARAKURI_BW_BIN"
	fi

	case "$1" in
	dev)
		# 全プロジェクト共通の個人項目（SSH 公開鍵など）を挟むのは dev だけ。
		printf 'BROKER_BW_ITEM=env/%s/shared/dev,env/_common/dev,env/%s/dev\n' "$2" "$2"
		;;
	prod)
		printf 'BROKER_BW_ITEM=env/%s/shared/prod,env/%s/prod\n' "$2" "$2"
		;;
	*)
		echo "karakuri-broker-env: unknown kind '$1' (expected 'dev' or 'prod')" >&2
		return 1
		;;
	esac
	return 0
}

# _karakuri_broker_env_into <dev|prod> <project> — 上の出力を、呼び出し元が
# 用意した配列 _karakuri_env へ追記する。
#
# 環境変数を export せずに配列へ溜めて `env` へ渡すのは、これが利用者の
# 対話シェルの中で走るため。export すると BROKER_BW_ITEM が以降ずっと
# 残り、次に別プロジェクトを触ったときに古い項目名が効いてしまう。
_karakuri_broker_env_into() {
	_karakuri_be_out="$(karakuri-broker-env "$1" "$2")" || {
		unset _karakuri_be_out
		return 1
	}

	while IFS= read -r _karakuri_be_line; do
		[ -n "$_karakuri_be_line" ] || continue
		# `env` は `NAME=VALUE` に見えない語を「実行するコマンド」として
		# 扱う。差し替えた broker が形式を外したときに、それが「別の
		# コマンドの実行」になるのは危険なので、渡す前に形を確かめる。
		case "$_karakuri_be_line" in
		[A-Za-z_]*=*) ;;
		*)
			echo "karakuri: karakuri-broker-env produced a line that is not NAME=VALUE: '${_karakuri_be_line}'" >&2
			unset _karakuri_be_out _karakuri_be_line
			return 1
			;;
		esac
		_karakuri_env+=("$_karakuri_be_line")
	done <<EOF
${_karakuri_be_out}
EOF

	unset _karakuri_be_out _karakuri_be_line
	return 0
}

# --- port forwarding -----------------------------------------------------------
# ~/.ssh/config 側の規約（ControlPath を ~/.ssh/cm-%n にする・接続先の Host を
# devc-<project> と書く）に依存している。config そのものはプロジェクトごとに
# 転送するポートが違うので、ここでは生成も配布もしない。

# _karakuri_ssh_host <name> — devc- 接頭辞を補う。既に付いている場合はその
# まま使う（利用者が config に書いた名前をそのまま打てるように）。
_karakuri_ssh_host() {
	case "$1" in
	devc-*) printf '%s\n' "$1" ;;
	*) printf '%s\n' "devc-$1" ;;
	esac
}

# _karakuri_check_loopback <host> — その host の LocalForward が bind しようと
# している 127.x のアドレスが lo0 に載っているかを、ssh を起こす前に見る。
# 載っていないものがあれば、直し方（karakuri-loopback add）を添えて 1 を返す。
#
# macOS だけの問題である。Linux は 127.0.0.0/8 の全体が最初から自分宛てとして
# bind でき、alias を足す作業自体が無い。macOS は 127.0.0.1 以外の loopback
# アドレスを `ifconfig lo0 alias` で明示的に有効化しないと bind できず、しかも
# それは再起動で消える。~/.ssh/config 側は ExitOnForwardFailure yes なので
# ssh は正しく失敗するのだが、出るメッセージは
# `bind: Can't assign requested address` で、何を直せばよいかがそこからは
# 分からない。実際に足りないのは alias 1 本、というところまでをここで言う。
#
# 検査は fail open にしてある。`ssh -G` が失敗したときも、localforward の行が
# 1 つも読めなかったときも、何も言わずに 0 を返して先へ進む。`ssh -G` の出力は
# OpenSSH の版に依存しうる（キーワードの綴り・アドレスの囲み方が変わりうる）
# ので、こちらの読み取りが外れたときに port forwarding そのものが止まると、
# 本来動く環境で動かなくなる。この検査は「失敗したときの説明を良くする」ため
# のものであって、転送の可否を決める権限は持たせない。
_karakuri_check_loopback() {
	[ "$(uname -s 2>/dev/null)" = "Darwin" ] || return 0

	# `ssh -G` は Host ブロックや Match を解決した後の実効設定を、小文字の
	# キーワードで出す。1 行は `localforward [127.0.1.1]:4519 [localhost]:4519`
	# の形になる。config を自分で読むと Host の照合・Include・多重定義まで
	# 自前で持つことになるので、解決は ssh 自身にやらせる。
	local cfg
	cfg="$(ssh -G "$1" 2>/dev/null)" || return 0

	# 2 番目のフィールド（bind 側）は角括弧で囲まれているので、`:` で切る前に
	# 取り除く。残りの先頭要素が 127. で始まるものを集める。IPv6
	# （`[::1]:4519`）は角括弧を外すと先頭要素が空になり、unix socket の
	# パスは角括弧も `127.` の接頭辞も持たないので、どちらもここで自然に
	# 外れる。同じアドレスへ何本転送していても言うことは 1 回でよいので
	# sort -u で潰す。
	local addrs
	addrs="$(printf '%s\n' "$cfg" |
		awk '$1 == "localforward" { addr = $2; gsub(/[][]/, "", addr); split(addr, f, ":"); if (f[1] ~ /^127\./) print f[1] }' |
		sort -u)"
	[ -n "$addrs" ] || return 0

	# ifconfig が読めなかったときも fail open。ここで「読めない＝載っていない」
	# と解釈すると、全アドレスについて嘘の警告を出したうえで転送を止める。
	local lo
	lo="$(ifconfig lo0 2>/dev/null)" || return 0
	[ -n "$lo" ] || return 0

	local addr missing=0
	while IFS= read -r addr; do
		[ -n "$addr" ] || continue
		# 末尾の空白まで含めて照合する。`inet 127.0.1.1` だけで見ると
		# 127.0.1.10 が載っているときに 127.0.1.1 も載っていることになる。
		# なお 127.0.0.1 は lo0 に必ず出るので、特別扱いは要らずここを通る。
		case "$lo" in
		*"inet $addr "*) continue ;;
		esac
		echo "karakuri-port-forward: loopback alias ${addr} is not on lo0, so the forward cannot bind. Run: karakuri-loopback add ${addr}" >&2
		missing=1
	done <<EOF
${addrs}
EOF

	[ "$missing" -eq 0 ] || return 1
	return 0
}

# karakuri-port-forward <name> — port forwarding を張り直す。
#
# 「張る」ではなく「張り直す」なのは、コンテナを作り直した後の再接続が
# 主な用途だから。古い master が残ったままだと、新しいコンテナへ繋いだ
# つもりで死んだセッションを使い続けることになる。先に必ず落とす。
karakuri-port-forward() {
	if [ "$#" -ne 1 ]; then
		echo "Usage: karakuri-port-forward <name>   (ssh host devc-<name>, or the full host alias)" >&2
		return 1
	fi

	local host
	host="$(_karakuri_ssh_host "$1")"

	# loopback alias の検査は、古い master を落とすより前に置く。落としてから
	# 失敗すると、それまで生きていた転送まで巻き添えで消える。「張り直しに
	# 失敗した」だけで済むはずのものが「打ったせいで繋がらなくなった」になる。
	_karakuri_check_loopback "$host" || return 1

	# 生きていれば落とす。生きていなければ何も起きない（失敗は無視する）。
	# -n は「stdin を /dev/null にする」指定。制御コマンドに stdin は要らず、
	# 付けておけば下の clean-pf のようにループの中で呼んでも、ループが
	# 読んでいる入力を ssh が横取りしない。
	ssh -n -O exit "$host" >/dev/null 2>&1
	# 落とせなかった／プロセスだけ先に消えた場合に socket ファイルだけが
	# 残る。残骸があると次の接続がそこへ繋ぎに行って失敗するので消す。
	rm -f "${HOME}/.ssh/cm-${host}"

	# ssh -fN は背面へ回った後も端末の stderr を掴み続ける。転送先の dev
	# サーバが落ちている状態でブラウザが再接続を繰り返すと、
	# `connect_to localhost port 4301: failed.` が端末に延々と出続け、
	# karakuri-clean-port-forward で殺すまで止まらない。転送そのものは壊れておらず、
	# dev サーバを起動し直せばそのまま復活するので、転送を畳むのは過剰な
	# 対処である。畳まずに黙らせるには、出力先を端末から外すしかない。
	#
	# 以後の転送エラーはこの 1 本のログに溜まる。読みたいときは
	# `tail -f "${XDG_STATE_HOME:-$HOME/.local/state}/karakuri/port-forward-<host>.log"`。
	# host ごとにファイルを分けてあるので、どのコンテナの転送が転んでいるかは
	# ファイル名で分かる。
	local log_dir log
	log_dir="${XDG_STATE_HOME:-$HOME/.local/state}/karakuri"
	log="${log_dir}/port-forward-${host}.log"

	# ログが置けないなら、ログ分離だけをあきらめて従来どおり端末へ出す。
	# ここで止めると「ログが取れない」という副次的な事情で port forwarding
	# そのものが失敗することになり、目的（転送を張る）に対して代償が大きい。
	if ! mkdir -p "$log_dir" 2>/dev/null; then
		log=""
	fi

	if [ -z "$log" ]; then
		if ssh -fN "$host"; then
			return 0
		fi
	else
		if ssh -fN "$host" 2>>"$log"; then
			return 0
		fi
		# 失敗したときだけログの末尾を見せる。原因（コンテナ側 sshd が
		# 起動していない・bind できない等）を書いているのは ssh 自身の
		# メッセージであり、それをログへ回した結果、下の一般的な文言しか
		# 利用者に見えなくなるのでは分離した意味が無い。
		tail -n 20 "$log" >&2 2>/dev/null
	fi

	echo "karakuri-port-forward: 'ssh -fN ${host}' failed. Check that the container is up and that ~/.ssh/config has a Host entry for '${host}'" >&2
	return 1
}

# karakuri-clean-port-forward [name...] — port forwarding の後始末。
#
# 名前を指定しなければ、ControlPath の規約（~/.ssh/cm-<host>）に沿って
# devc- で始まるものを全部畳む。cm-* まで広げると、この規約と無関係な
# 利用者自身の ssh 多重化まで巻き添えにするので広げない。
karakuri-clean-port-forward() {
	local host sock

	if [ "$#" -gt 0 ]; then
		for host in "$@"; do
			host="$(_karakuri_ssh_host "$host")"
			ssh -n -O exit "$host" >/dev/null 2>&1
			rm -f "${HOME}/.ssh/cm-${host}"
		done
		return 0
	fi

	# glob をそのまま for に書かないのは、一致が 0 件のときの挙動が
	# シェルで違うため（bash はパターン文字列をそのまま渡し、zsh は
	# エラーにする）。find なら 0 件は 0 行になるだけで揃う。
	find "${HOME}/.ssh" -maxdepth 1 -name 'cm-devc-*' 2>/dev/null |
		while IFS= read -r sock; do
			host="${sock##*/}"
			host="${host#cm-}"
			ssh -n -O exit "$host" >/dev/null 2>&1
			rm -f "$sock"
		done
	return 0
}

# karakuri-loopback <install|add|remove|list> [args...] — loopback alias と
# /etc/hosts の設定。loopback-setup.sh を呼ぶだけの薄いラッパー。
#
# この関数だけが sudo を要求する。karakuri.sh が提供する他の関数はどれも
# 特権を要らない（ssh を張る・docker を叩く・broker を呼ぶ、のいずれも
# 利用者の権限で足りる）ので、ここは例外だと明示しておく。loopback-setup.sh
# は LaunchDaemon の配置と /etc/karakuri/loopback-aliases・/etc/hosts の編集を
# するため、内部で sudo を使う。
#
# 例外を 1 つ作ってでもこの形にしたのは、日常操作の側に sudo を持ち込まない
# ため。alias の付与を karakuri-port-forward の中でやれば「転送を張るたびにパスワードを
# 聞かれる」ことになり、聞かれ慣れた利用者は中身を読まずに通すようになる。
# 特権が要るのは設定作業（一度やれば再起動を跨いで残る）だけなので、そこを
# この 1 つの関数に閉じ込め、毎日打つ karakuri-port-forward は特権なしのまま残した。
#
# サブコマンド名の検査はここではしない。同じ規則を 2 箇所に持つと片方だけが
# 古くなる（karakuri-prod-run が sha を検査しないのと同じ判断）。引数 0 個の
# ときもそのまま渡し、usage はスクリプト側に出させる。
karakuri-loopback() {
	local setup
	setup="$(_karakuri_tool loopback-setup.sh)" || return 1

	# 環境変数は渡さない。karakuri-dev-inject などと違って broker も compose も
	# 関与せず、このスクリプトが読むのは自分の引数と /etc の状態だけである。
	"$setup" "$@"
}

# --- dev ------------------------------------------------------------------------

# karakuri-dev-inject <project> — 起動済みの dev container へ鍵を注入する。
#
# コンテナ内の /run/secrets は tmpfs なので、コンテナを起動するたびに 1 回
# 実行する（再実行は上書きなので、迷ったら打ち直してよい）。
karakuri-dev-inject() {
	if [ "$#" -ne 1 ]; then
		echo "Usage: karakuri-dev-inject <project>" >&2
		return 1
	fi

	local project="$1"
	_karakuri_plain_name "project" "$project" || return 1

	local dev_inject broker
	dev_inject="$(_karakuri_tool dev-inject.sh)" || return 1
	broker="$(karakuri-broker-command dev "$project")" || return 1

	local -a _karakuri_env
	_karakuri_env=()
	_karakuri_broker_env_into dev "$project" || return 1

	# compose project 名は「<project>-dev」。dev-inject.sh はこの名前から
	# 注入先コンテナを引く（コンテナ名の決め打ちはプロジェクト複製時の
	# 直し忘れがそのまま別プロジェクトへの注入事故になるため使わない）。
	env "${_karakuri_env[@]}" \
		"DEV_BROKER=${broker}" \
		"DEV_COMPOSE_PROJECT=${project}-dev" \
		"$dev_inject"
}

# _karakuri_dock_inject <compose-project> [service] — karakuri-dock が
# `--secrets-ok` の失敗時にだけ呼ぶ注入経路。
#
# karakuri-dev-inject とは別にしてあるのは、DEV_COMPOSE_PROJECT に渡す値が
# 違うため。karakuri-dev-inject は `<project>-dev` を組み立てるが、
# karakuri-dock の `-p` は compose project 名そのものなので、ここでは
# 変換をかけずそのまま使う（dock.sh が compose project 名の組み立てを
# やめたのと同じ理由で、呼び出し側が渡した値をそのまま使う）。
#
# DEV_BROKER が空かどうかはここでは検査しない。dev-inject.sh 自身が
# 必須環境変数の欠落を検査して名指しするので、同じ検査をここにも置くと
# 片方だけ直したときに食い違う。
_karakuri_dock_inject() {
	local project="$1" service="$2"
	local dev_inject broker
	dev_inject="$(_karakuri_tool dev-inject.sh)" || return 1
	broker="$(karakuri-broker-command dev "$project")" || return 1

	local -a _karakuri_env
	_karakuri_env=()
	_karakuri_broker_env_into dev "$project" || return 1

	local -a _karakuri_dev_env
	_karakuri_dev_env=("DEV_BROKER=${broker}" "DEV_COMPOSE_PROJECT=${project}")
	[ -z "$service" ] || _karakuri_dev_env+=("DEV_SERVICE=${service}")

	env "${_karakuri_env[@]}" "${_karakuri_dev_env[@]}" "$dev_inject"
}

# karakuri-dock -p <compose-project> [-s <service>] [-w <workspace>] [up] —
# dev container を使える状態にしてから入る: 起動 → 未注入なら注入 →
# port forwarding → 対話シェル。`up` を付けると、入る手前（対話シェルを
# 開く前）で止まる。
#
# `-p` に渡す値は compose project 名そのもの（dock.sh 側の規約と同じ）。
# ssh の Host（`devc-<compose-project>`）にも、注入先の DEV_COMPOSE_PROJECT
# にも変換をかけずこの値をそのまま使う。`<project>-dev` のような規約の
# 組み立ては呼び出し側（利用者の `dock` 関数、~/.ssh/config の HostName）に
# 委ねてあり、ここではもう行わない。
#
# `dock.sh` を対話シェルなしで 2 回呼ぶのは、コンテナの起動状態を変えずに
# secret の有無だけを見る `--secrets-ok` と、起動だけを行う
# `--ensure-running` の役目が分かれているため（`dock.sh` 冒頭のコメント
# 参照）。
#
# port forwarding を張るかどうかは `ssh -G <host>` の実効設定に
# `localforward` があるかで決める。config を自分で読み直さないので、
# `Host *` や `Include` まで込みで ssh 自身の解決結果に従う。転送を
# 持たないホストへは張りに行かず、飛ばしたこととその理由を stderr に
# 1 行出す（黙って飛ばすと `.ssh/config` への `LocalForward` の書き忘れに
# 気づけない）。
#
# pf の失敗の扱いは `up` の有無で変える。`up` は対話シェルを開かないので
# 転送の成否をそのまま返す。`up` 無しは警告に留めて入る（転送が張れない
# ことと、コンテナで作業を始められることは別である）。
karakuri-dock() {
	local usage="Usage: karakuri-dock -p <compose-project> [-s <service>] [-w <workspace>] [up]"
	local project="" service="" workspace="" up=0

	while [ "$#" -gt 0 ]; do
		case "$1" in
		-p)
			if [ "$#" -lt 2 ]; then
				echo "karakuri-dock: -p requires a value" >&2
				echo "$usage" >&2
				return 1
			fi
			project="$2"
			shift 2
			;;
		-s)
			if [ "$#" -lt 2 ]; then
				echo "karakuri-dock: -s requires a value" >&2
				echo "$usage" >&2
				return 1
			fi
			service="$2"
			shift 2
			;;
		-w)
			if [ "$#" -lt 2 ]; then
				echo "karakuri-dock: -w requires a value" >&2
				echo "$usage" >&2
				return 1
			fi
			workspace="$2"
			shift 2
			;;
		up)
			up=1
			shift
			;;
		-h | --help)
			echo "$usage" >&2
			return 0
			;;
		*)
			echo "karakuri-dock: unexpected argument: $1" >&2
			echo "$usage" >&2
			return 1
			;;
		esac
	done

	if [ -z "$project" ]; then
		echo "$usage" >&2
		return 1
	fi

	local dock
	dock="$(_karakuri_tool dock.sh)" || return 1

	local -a dock_argv
	dock_argv=(-p "$project")
	[ -z "$service" ] || dock_argv+=(-s "$service")
	[ -z "$workspace" ] || dock_argv+=(-w "$workspace")

	"$dock" "${dock_argv[@]}" --ensure-running || return 1

	if ! "$dock" "${dock_argv[@]}" --secrets-ok; then
		_karakuri_dock_inject "$project" "$service" || return 1
	fi

	local host
	host="$(_karakuri_ssh_host "$project")"

	if ssh -G "$host" 2>/dev/null | grep -q '^localforward '; then
		if ! karakuri-port-forward "$project"; then
			if [ "$up" -eq 1 ]; then
				return 1
			fi
			echo "karakuri-dock: port forwarding to '${host}' failed — continuing without it" >&2
		fi
	else
		echo "karakuri-dock: '${host}' has no LocalForward in ~/.ssh/config — skipping port forwarding" >&2
	fi

	if [ "$up" -eq 1 ]; then
		return 0
	fi

	"$dock" "${dock_argv[@]}"
}

# --- compose ファイルの解決 --------------------------------------------------------
# compose ファイルはプロジェクトごとに 1 枚持つ。置き場所ごとホスト上の git
# repo にして、どの dev container にも mount しない。理由はファイルの中身に
# ある: あれは prod の防御（read_only・tmpfs の記法・cap_drop・init）を宣言
# している当のものなので、dev container に常駐する LLM エージェントから到達
# できる場所に置くと、防御そのものが書き換えの対象になる。git で持つのは
# 改竄検知のためではなく（到達できないなら検知は要らない）、digest をいつ
# 上げたかの履歴を残すため。
#
# 全プロジェクトで 1 枚を共有する旧来の運用（KARAKURI_PROD_COMPOSE）も残す。
# 共有できる構成の利用者にディレクトリを作らせる理由が無く、切り替えは
# 環境変数の張り替えだけで済ませたいため。両方設定されているときは
# ディレクトリを勝たせる（どちらも明示的な設定なので警告は出さない。
# ディレクトリの方が後から入った、より具体的な指定である）。
#
# 解決規則をこの 3 つの関数に集約して、呼ぶ側には「どのファイルか」だけを
# 渡す。規則が散ると、片方だけが新しい運用に追随した状態が作れてしまう。

# _karakuri_compose_mode — どちらの運用かを stdout に出す（"dir" か "file"）。
# 優先順位を決めているのはここ 1 箇所だけ。
_karakuri_compose_mode() {
	if [ -n "${KARAKURI_PROD_COMPOSE_DIR:-}" ]; then
		printf 'dir\n'
		return 0
	fi
	if [ -n "${KARAKURI_PROD_COMPOSE:-}" ]; then
		printf 'file\n'
		return 0
	fi
	echo "karakuri: neither KARAKURI_PROD_COMPOSE_DIR nor KARAKURI_PROD_COMPOSE is set. Set KARAKURI_PROD_COMPOSE_DIR to the directory that holds one compose file per project (named <repo>.yaml), or set KARAKURI_PROD_COMPOSE to a single shared compose.prod.yaml. Keep either one outside every dev workspace" >&2
	return 1
}

# _karakuri_compose_for <repo> — その repo で使う compose ファイルのパスを
# stdout に出す。
#
# 拡張子を 2 つ見るのは、compose 自身が compose.yaml と compose.yml の
# どちらも受けるため。ただし両方あったらどちらかを選ばずに止める。片方を
# 編集したつもりでもう片方が使われる、という取り違えは、このファイルが
# 宣言しているものの性質上そのまま防御の抜けになる。
_karakuri_compose_for() {
	local repo="$1" mode
	mode="$(_karakuri_compose_mode)" || return 1

	if [ "$mode" = "file" ]; then
		printf '%s\n' "$KARAKURI_PROD_COMPOSE"
		return 0
	fi

	local yaml="${KARAKURI_PROD_COMPOSE_DIR}/${repo}.yaml"
	local yml="${KARAKURI_PROD_COMPOSE_DIR}/${repo}.yml"

	if [ -f "$yaml" ] && [ -f "$yml" ]; then
		echo "karakuri: both '${yaml}' and '${yml}' exist, so there is no way to tell which one is the compose file for '${repo}'. Remove or rename one of them" >&2
		return 1
	fi
	if [ -f "$yaml" ]; then
		printf '%s\n' "$yaml"
		return 0
	fi
	if [ -f "$yml" ]; then
		printf '%s\n' "$yml"
		return 0
	fi

	echo "karakuri: no compose file for '${repo}' under KARAKURI_PROD_COMPOSE_DIR — looked for '${yaml}' and '${yml}'. Add one there, or check the repository name you passed" >&2
	return 1
}

# _karakuri_compose_list — 一括で見るべき compose ファイルを 1 行 1 件で
# stdout に出す。ディレクトリ運用なら中の全ファイル、単一ファイル運用なら
# その 1 枚。digest の照合のように「repo を 1 つに決めずに全部を見る」側が使う。
#
# glob をそのまま展開せず find を使うのは、一致 0 件のときの挙動が bash と
# zsh で違うため（karakuri-clean-port-forward と同じ理由）。深さを 1 に切ってあるのは、
# あのディレクトリは git repo なので .git/ の中まで拾ってしまうから。
_karakuri_compose_list() {
	local mode
	mode="$(_karakuri_compose_mode)" || return 1

	if [ "$mode" = "file" ]; then
		printf '%s\n' "$KARAKURI_PROD_COMPOSE"
		return 0
	fi

	if [ ! -d "$KARAKURI_PROD_COMPOSE_DIR" ]; then
		echo "karakuri: KARAKURI_PROD_COMPOSE_DIR points at '${KARAKURI_PROD_COMPOSE_DIR}', which is not a directory" >&2
		return 1
	fi

	local found
	found="$(find "$KARAKURI_PROD_COMPOSE_DIR" -maxdepth 1 -type f \
		\( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | sort)"
	if [ -z "$found" ]; then
		echo "karakuri: KARAKURI_PROD_COMPOSE_DIR '${KARAKURI_PROD_COMPOSE_DIR}' holds no compose file (looked for *.yaml and *.yml directly under it). Add one named after the repository it belongs to" >&2
		return 1
	fi

	printf '%s\n' "$found"
	return 0
}

# --- prod -----------------------------------------------------------------------

# _karakuri_prod_call <org/repo> <sha> <argv...> — prod-run.sh を呼ぶ。
#
# COMPOSE_PROJECT_NAME をプロジェクトごとに振るのがここの要点。project 名を
# 指定しないと compose はファイルの所在から名前を導く。単一ファイル運用では
# どのプロジェクトの prod を起動しても同じ名前になり、ディレクトリ運用でも
# 導かれるのは置き場所の名前であってプロジェクト名ではない。そうなると、
# 起動済みコンテナを名前で引く操作（karakuri-prod-shell）が別プロジェクトの
# コンテナに一致する。
# 入った先には別プロジェクトの鍵が注入済みで、/src には別プロジェクトの
# コードが clone されている。
_karakuri_prod_call() {
	local spec="$1" sha="$2"
	shift 2

	# 呼ばれる側が置く 2 つをここで local にしておく（bash も zsh も動的
	# スコープなので、呼び出し先の代入はこの local に当たる）。利用者の
	# 対話シェルに変数を残さないため。
	local _karakuri_org _karakuri_repo
	_karakuri_parse_repo "$spec" || return 1
	local org="$_karakuri_org" repo="$_karakuri_repo"

	# 使う compose ファイルは repo から引く。どの環境変数が効いているかを
	# ここで場合分けしない（規則は _karakuri_compose_for の 1 箇所にある）。
	local compose
	compose="$(_karakuri_compose_for "$repo")" || return 1

	local prod_run broker
	prod_run="$(_karakuri_tool prod-run.sh)" || return 1
	broker="$(karakuri-broker-command prod "$repo")" || return 1

	local -a _karakuri_env
	_karakuri_env=()
	_karakuri_broker_env_into prod "$repo" || return 1

	# GIT_REF が完全な commit sha かどうかは prod-run.sh と entrypoint が
	# 見るので、ここでは重ねて検査しない（同じ規則を二箇所に持つと片方だけ
	# 古くなる）。
	env "${_karakuri_env[@]}" \
		"PROD_COMPOSE_FILE=${compose}" \
		"PROD_BROKER=${broker}" \
		"GIT_REPO=https://github.com/${org}/${repo}.git" \
		"GIT_REF=${sha}" \
		"COMPOSE_PROJECT_NAME=prod-${repo}" \
		"$prod_run" "$@"
}

# karakuri-prod-run <org/repo> <sha> <task> [task-args...] — タスクランナー
# 経由で prod のタスクを実行する。
#
# /src は tmpfs で毎回 clone し直すため、node_modules は存在しない。install を
# 毎回連結するのはこのため。install 段を省きたい場合は KARAKURI_PROD_INSTALL
# に空文字を設定する。
karakuri-prod-run() {
	if [ "$#" -lt 3 ]; then
		echo "Usage: karakuri-prod-run <org/repo> <40-char sha> <task> [task-args...]" >&2
		return 1
	fi

	local spec="$1" sha="$2"
	shift 2

	local install runner
	install="${KARAKURI_PROD_INSTALL-pnpm install --frozen-lockfile}"
	runner="${KARAKURI_PROD_RUN-pnpm}"

	if [ -z "$install" ]; then
		# 連結する相手が無いなら文字列にする理由も無い。配列のまま渡せば、
		# 空白を含む引数がコンテナの中で別の語に割れることが原理的に起きない。
		local -a _karakuri_argv
		_karakuri_split "$runner" || return 1
		_karakuri_prod_call "$spec" "$sha" "${_karakuri_argv[@]}" "$@"
		return
	fi

	# install 段とタスクを `&&` で繋ぐには、シェルに解釈させるしかない。
	# ここだけが文字列連結の面になる。各語をシングルクォートで包んでから
	# 連結し、空白やメタ文字を含む引数が prod 側で別のコマンドに化けない
	# ようにする。install と runner は利用者が設定したシェルの語なので
	# そのまま置く（`npm run` のような複数語の設定を壊さないため）。
	local script="${install} && ${runner}"
	local arg
	for arg in "$@"; do
		script="${script} $(_karakuri_shquote "$arg")"
	done

	_karakuri_prod_call "$spec" "$sha" sh -c "$script"
}

# karakuri-prod-exec <org/repo> <sha> <command> [args...] — タスクランナーを
# 挟まずに、渡したコマンドをそのまま prod で実行する。
#
# 引数は最後まで配列のまま運ぶ。文字列連結を挟まないので、引用の付け忘れが
# 別のコマンドの実行になる余地がない。install も走らないため、依存が要る
# ものは karakuri-prod-run を使うこと。
karakuri-prod-exec() {
	if [ "$#" -lt 3 ]; then
		echo "Usage: karakuri-prod-exec <org/repo> <40-char sha> <command> [args...]" >&2
		return 1
	fi

	local spec="$1" sha="$2"
	shift 2
	_karakuri_prod_call "$spec" "$sha" "$@"
}

# karakuri-prod-base <org/repo> <sha> — 対話 prod 作業の土台を起動する。
#
# 鍵の搬送路が stdin なので、`docker compose run` に対話 TTY は付けられない。
# 対話が要る作業（dryrun してから適用する等）は端末を 2 つ使う:
#
#   端末 1: karakuri-prod-base <org/repo> <sha>   … 土台。前面で動かす
#   端末 2: karakuri-prod-shell <repo>            … 土台へ入る
#
# 土台は前面で動かすこと。detach すると stdin を中継している compose
# クライアントごと消えるため、鍵の搬送路が失われる（broker は Broken pipe で
# 死に、コンテナ側は取込の行で停止する）。退出後は端末 1 を Ctrl-C で終了
# させれば、コンテナは --rm で回収される。
#
# sleep に時間を切ってあるのは、止め忘れがそのまま放置されないようにするため。
karakuri-prod-base() {
	if [ "$#" -ne 2 ]; then
		echo "Usage: karakuri-prod-base <org/repo> <40-char sha>   (then: karakuri-prod-shell <repo> from another terminal)" >&2
		return 1
	fi
	_karakuri_prod_call "$1" "$2" sleep 8h
}

# karakuri-prod-shell <repo> — 起動済みの土台へ入る。
#
# コンテナは compose の project 名から引く。該当が 0 件でも複数件でも止める。
# ここで「とりあえず 1 つ選ぶ」をやると、選んだことが利用者に見えないまま
# 別プロジェクトの prod へ入る。入った先には別プロジェクトの鍵が注入済みで、
# /src には別プロジェクトのコードがある。鍵を持つコンテナの特定を推測で
# 行わない、というのがこの構成全体の規律である。
#
# 「引く」のに `docker compose -p <project> -f <file> ps` は使わない。実機で
# 踏んだ不具合: compose.prod.yaml の `environment:` は `${GIT_REPO:?...}` /
# `${GIT_REF:?...}` を使っており、`ps` を含め compose ファイルを読む操作は
# すべて変数展開の対象になる。土台を起動した端末には GIT_REPO / GIT_REF が
# 渡っているが、後から shell を取りに来る別の端末にそれらを渡す理由がなく
# （渡す先の compose 呼び出しは `ps` で、コンテナを作りはしない）、未設定の
# まま `ps` を打つとそこで interpolation error になり、コンテナが実際に
# 動いていても引けなかった。
#
# 代わりに `docker ps` を compose 自身が付けるラベルで絞る。
# `com.docker.compose.project` と `com.docker.compose.service` は
# docker/compose が生成するコンテナに必ず付ける識別子で、project 名と
# service 名のどちらも compose ファイルの中身を一切読まずに厳密一致で
# 引ける（compose-go の labels.go で定義されている、compose v2 の
# 安定した公開仕様）。0 件・複数件で止める既存の規律はそのまま維持する
# （`docker ps -q` は稼働中のコンテナだけを返す点も、以前の
# `docker compose ps` と同じ）。これは以前の「名前から作った文字列で引いて
# head -1 で選ぶ」実装への逆戻りではない。ラベルは compose 自身が
# コンテナへ焼き込む識別子であり、こちらが名前を組み立てて一致を期待する
# ものではない。
#
# 副次的に、この関数はもう KARAKURI_PROD_COMPOSE を読まない。要求を残す
# 手もあったが、この関数が実際に依存しているのは compose ファイルではなく
# ラベルだけであり、使わない環境変数を必須にすると「この端末にも
# compose.prod.yaml を置く／揃える必要がある」という誤解を招く。他の
# prod 系関数（karakuri-prod-run 等）は実際に `docker compose run` を
# 起動する側なので、そちらは従来どおり必須のままにする。
karakuri-prod-shell() {
	if [ "$#" -ne 1 ]; then
		echo "Usage: karakuri-prod-shell <repo>   (the same repo name you passed to karakuri-prod-base)" >&2
		return 1
	fi

	local repo="$1"
	_karakuri_plain_name "repo" "$repo" || return 1

	local project="prod-${repo}"
	local cid
	cid="$(docker ps -q \
		--filter "label=com.docker.compose.project=${project}" \
		--filter "label=com.docker.compose.service=prod")" || {
		echo "karakuri-prod-shell: 'docker ps' failed" >&2
		return 1
	}

	if [ -z "$cid" ]; then
		echo "karakuri-prod-shell: no running container for service 'prod' in compose project '${project}'. The base is not up — start it in another terminal with 'karakuri-prod-base <org>/${repo} <sha>' and wait for the clone to finish" >&2
		return 1
	fi

	if [ "$(printf '%s\n' "$cid" | wc -l)" -gt 1 ]; then
		echo "karakuri-prod-shell: multiple containers match service 'prod' in compose project '${project}' — cannot decide which one to enter. Stop the extras (each base you start for '${repo}' adds one) and try again" >&2
		return 1
	fi

	docker exec -it -w /src "$cid" bash
}

# --- image の digest -------------------------------------------------------------
# compose ファイルは digest で pin する（タグは後から指す先を変えられる）。
# その digest をタグから引くのがここの 2 つ。
#
# compose ファイルを書き換える実装にはしない。あのファイルは prod の防御
# （read_only・tmpfs の記法・ulimits など）を宣言している中心で、機械的に
# 触る経路を作ると、パターンの取り違えが防御を消す形で現れる。貼るのは
# 人間の手で、貼った結果は人間の目を通す。

# _karakuri_compose_image_ref <file> — その compose ファイルに書かれている
# image の参照を stdout に出す。
#
# 読むファイルを引数で受けるのは、ディレクトリ運用では 1 枚に決まらないため
# （どのファイルを見るかを決めるのは _karakuri_compose_for / _karakuri_compose_list
# の側で、ここは渡された 1 枚を読むだけにする）。
_karakuri_compose_image_ref() {
	local file="$1"

	if [ ! -f "$file" ]; then
		echo "karakuri: '${file}' is not a file. Check that KARAKURI_PROD_COMPOSE (or KARAKURI_PROD_COMPOSE_DIR) points at the compose file you keep outside the dev workspace" >&2
		return 1
	fi

	local lines
	lines="$(grep -E '^[[:space:]]*image:[[:space:]]*[^[:space:]#]' "$file")"

	if [ -z "$lines" ]; then
		echo "karakuri: no 'image:' line in ${file}" >&2
		return 1
	fi
	if [ "$(printf '%s\n' "$lines" | wc -l)" -gt 1 ]; then
		echo "karakuri: ${file} has more than one 'image:' line — cannot tell which one pins the prod image. Check it by hand" >&2
		return 1
	fi

	# 行頭の `image:` を落としたあと、行末の YAML コメントも落とす。YAML の
	# 規則では、空白の後に続く `#` からが行末コメントで、クォートされた
	# スカラーの中の `#` はコメントではない。ここでは後者（クォート）は
	# 対応しない: docker image の参照文字列（レジストリ/名前/タグ/digest）
	# が取りうる文字集合に `#` は含まれないため、クォートしてまで書く動機が
	# なく、実機でも見た例がない。対応してしまうと、閉じクォートの位置を
	# 誤検出したときに digest の一部を切り落とすという、無対応より悪い
	# 失敗モードを自分で作り込むことになる。したがって「空白 + `#`
	# 以降を落とす」だけで足り、クォートは検査対象にしない。
	# `karakuri-image-digest` が吐く行にコメントは付かないが、利用者が
	# `# v1.2.2` のように手でメモを足す運用まで壊さないためにこの一段を足す。
	printf '%s\n' "$lines" |
		sed -e 's/^[[:space:]]*image:[[:space:]]*//' \
			-e 's/[[:space:]][[:space:]]*#.*$//' \
			-e 's/[[:space:]]*$//'
}

# _karakuri_image_name <ref> — 参照からタグと digest を落として、イメージ名
# だけを stdout に出す。レジストリのポート番号（host:5000/name）を巻き込ま
# ないよう、最後の / より後ろだけを見てタグを落とす。
_karakuri_image_name() {
	local name="${1%%@*}"
	case "${name##*/}" in
	*:*) name="${name%:*}" ;;
	esac
	printf '%s\n' "$name"
}

# _karakuri_compose_image_name — 見るべき compose ファイル全部が同じイメージ名
# を指しているとき、その名前を stdout に出す。
#
# ディレクトリ運用では「どのファイルの image 名を使うか」が引数からは決まら
# ない。1 枚目を採るような選び方はしない: そこで選んだことは利用者に見えず、
# 別プロジェクトのイメージのタグを解決した digest を、当人は自分のプロジェクト
# のものだと思って貼る。揃っていれば曖昧さは無いので通し、揃っていなければ
# 止めて、完全な参照を打ってもらう（0 件・複数件・曖昧は必ず失敗させる、という
# このファイル全体の規律と同じ）。
_karakuri_compose_image_name() {
	local files
	files="$(_karakuri_compose_list)" || return 1

	local file ref name common="" common_file=""
	while IFS= read -r file; do
		[ -n "$file" ] || continue

		ref="$(_karakuri_compose_image_ref "$file")" || return 1
		name="$(_karakuri_image_name "$ref")"

		if [ -z "$common_file" ]; then
			common="$name"
			common_file="$file"
			continue
		fi
		if [ "$name" != "$common" ]; then
			echo "karakuri: the compose files do not all name the same image — ${common_file} says '${common}' but ${file} says '${name}', so a bare tag cannot be resolved. Pass the full <image>:<tag> reference instead" >&2
			return 1
		fi
	done <<EOF
${files}
EOF

	if [ -z "$common_file" ]; then
		echo "karakuri: found no compose file to read the image name from" >&2
		return 1
	fi

	printf '%s\n' "$common"
	return 0
}

# _karakuri_image_ref <tag> — 利用者が打った 1 引数を完全な参照にする。
# `/` を含むならそのまま参照として扱い、含まないなら compose ファイルに
# 書かれているイメージ名のタグとして扱う（判定にスラッシュを使うのは
# <org>/<repo> と同じ理由）。
_karakuri_image_ref() {
	case "$1" in
	*/*)
		printf '%s\n' "$1"
		return 0
		;;
	esac

	local name
	name="$(_karakuri_compose_image_name)" || return 1
	printf '%s:%s\n' "$name" "$1"
}

# _karakuri_resolve_digest <ref> — レジストリに問い合わせて digest を出す。
_karakuri_resolve_digest() {
	local digest
	digest="$(docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}')" || {
		echo "karakuri: could not resolve '$1'. Check the tag exists and that you are logged in to the registry" >&2
		return 1
	}

	case "$digest" in
	sha256:*) ;;
	*)
		echo "karakuri: unexpected digest for '$1': '${digest}'" >&2
		return 1
		;;
	esac

	printf '%s\n' "$digest"
}

# karakuri-image-digest <tag> — タグから digest を引き、compose ファイルへ
# 貼れる形の 1 行を出力する。出力は行頭から始まるので、貼り付け先の
# インデントには手で合わせること。
karakuri-image-digest() {
	if [ "$#" -ne 1 ]; then
		echo "Usage: karakuri-image-digest <tag>   (or a full <image>:<tag> reference)" >&2
		return 1
	fi

	local ref digest
	ref="$(_karakuri_image_ref "$1")" || return 1
	digest="$(_karakuri_resolve_digest "$ref")" || return 1

	printf 'image: %s@%s\n' "$(_karakuri_image_name "$ref")" "$digest"
}

# karakuri-check-image <tag> — compose ファイルに書かれている digest が、
# 指定タグの現在の digest と一致するかを見る。読むだけで、書き換えはしない。
#
# clone した配布物の版ずれは git status で見えるが、compose ファイルは
# clone の外にあるので git では見えない。そこを見るのがこの関数。
#
# ディレクトリ運用では、repo を指定させずにディレクトリの中を全部見る。
# 引数に repo を取る形にすると、貼り忘れているプロジェクトを見つけるために
# 「どれを貼り忘れたか」を先に知っている必要があり、順序が逆になる。全部を
# 一覧で出せば、古い digest のまま残っているプロジェクトがその場で分かる。
# 1 件目の不一致で止めないのもこのため（止めた先はいつまでも見えない）。
karakuri-check-image() {
	if [ "$#" -ne 1 ]; then
		echo "Usage: karakuri-check-image <tag>   (or a full <image>:<tag> reference)" >&2
		return 1
	fi

	local ref expected_name files
	ref="$(_karakuri_image_ref "$1")" || return 1
	expected_name="$(_karakuri_image_name "$ref")"
	files="$(_karakuri_compose_list)" || return 1

	local file current current_digest current_name expected="" bad=0
	while IFS= read -r file; do
		[ -n "$file" ] || continue

		current="$(_karakuri_compose_image_ref "$file")" || {
			bad=1
			continue
		}

		# digest が入っていない（タグ pin のまま）ときと、テンプレートの
		# プレースホルダが残っているときは、レジストリへ問い合わせる前に
		# 止める。どちらも「照合できる状態になっていない」であって、照合の
		# 結果が不一致なのとは原因が違う。同じメッセージにすると直し方を誤る。
		current_digest=""
		case "$current" in
		*@*) current_digest="${current#*@}" ;;
		esac
		if ! printf '%s' "$current_digest" | grep -qE '^sha256:[0-9a-f]{64}$'; then
			echo "karakuri-check-image: ${file} does not pin a resolved digest (it says '${current}'). Run 'karakuri-image-digest $1' and paste the result over that line" >&2
			bad=1
			continue
		fi

		current_name="$(_karakuri_image_name "$current")"
		if [ "$current_name" != "$expected_name" ]; then
			echo "karakuri-check-image: ${file} pins image '${current_name}', but '$1' resolves to '${expected_name}' — these are different images, so their digests cannot be compared" >&2
			bad=1
			continue
		fi

		# レジストリへ問い合わせるのは、照合できるファイルが最初に見つかった
		# ときの 1 回だけ。答えはファイルによらず同じなので繰り返す意味が無く、
		# 「1 枚も照合できる状態になっていない」ときに問い合わせないという
		# 元からの性質もこの置き方で保たれる。
		if [ -z "$expected" ]; then
			expected="$(_karakuri_resolve_digest "$ref")" || return 1
		fi

		if [ "$current_digest" = "$expected" ]; then
			printf '%s pins %s@%s (matches %s)\n' "$file" "$current_name" "$current_digest" "$ref"
			continue
		fi

		echo "karakuri-check-image: digest mismatch. ${file} pins ${current_digest}, but ${ref} is now ${expected}. Run 'karakuri-image-digest $1' and paste the result over the image: line if the move is intended" >&2
		bad=1
	done <<EOF
${files}
EOF

	[ "$bad" -eq 0 ]
}

# --- ヘルプ -----------------------------------------------------------------------

# _karakuri_help_env <name> <必須/任意> <現在値> <説明> — karakuri-help の
# 環境変数 1 行を stdout に出す。現在値が空文字なら "(unset)" と表示する。
#
# 「必須/任意」と現在値を別引数にしてあるのは、KARAKURI_PROD_INSTALL /
# KARAKURI_PROD_RUN のように「未設定」と「空文字を設定」を区別しないと
# 意味が変わる変数があり（karakuri-prod-run 側を参照）、その 2 つだけは
# この共通ヘルパーを使わず個別に組み立てるため。
_karakuri_help_env() {
	printf '  %s (%s): %s\n' "$1" "$2" "${3:-(unset)}"
	printf '      %s\n' "$4"
}

# karakuri-help — 提供している関数と環境変数を一覧する。引数は取らない。
#
# 経緯: 手がかりが「末尾の alias 例のコメント」と `karakuri-` の補完しか
# 無く、実機で「今どの環境変数が効いているか分からない」を踏んだ。
# ソースを開かなくても対話シェルの中だけで完結させたいので、環境変数は
# 説明だけでなく現在値も出す。
#
# 現在値を出してよい理由: ここに出すのは bw の在処・org 名・compose
# ファイルの配置先であって、どれも秘密ではない。broker が返す鍵や
# BROKER_BW_ITEM の中身はここでは絶対に出さない（項目名自体は秘密では
# ないが、それを見せるのは karakuri-broker-env の役目であってここではない
# — この関数はあくまで「karakuri.sh 自身が読む環境変数」だけを見る）。
#
# 関数一覧の 1 行説明はファイル先頭の「提供する関数」一覧とほぼ同じ文言に
# なるが、二重管理とは考えていない。あちらはソースを開いた人向けの目次、
# こちらは対話シェルから引く実行時ヘルプで、読み手も入手手段も違う。
# 本当に重複していたのはこの下にあった alias 例の環境変数の説明文（対話
# 利用者向けという点でここと読み手が同じだった）で、そちらは削り、
# ここへ一本化した。
karakuri-help() {
	cat <<'FUNCS'
karakuri.sh が提供する関数:

  karakuri-port-forward <name>
      port forwarding を張り直す
  karakuri-clean-port-forward [name...]
      port forwarding の後始末（省略時は devc-* を全部畳む）
  karakuri-loopback <install|add|remove|list> [args...]
      /etc/hosts と loopback alias を設定する（alias は macOS のみ。この関数だけ sudo が要る）
  karakuri-dev-inject <project>
      起動済みの dev container へ鍵を注入する
  karakuri-dock -p <compose-project> [-s <service>] [-w <workspace>] [up]
      dev container を使える状態にしてから入る（起動 → 未注入なら注入 → port forwarding → 対話シェル。up で入る手前で止まる）
      ssh の ProxyCommand には dock.sh の絶対パスが要る（同じファイルの --stdio モード）
  karakuri-prod-run <org/repo> <sha> <task> [task-args...]
      install を挟んでタスクランナー経由で prod のタスクを実行する
  karakuri-prod-exec <org/repo> <sha> <cmd> [args...]
      install を挟まず、渡したコマンドをそのまま prod で実行する
  karakuri-prod-base <org/repo> <sha>
      対話 prod 作業の土台を起動する（前面で動かし、別端末から karakuri-prod-shell で入る）
  karakuri-prod-shell <repo>
      起動済みの土台へ入る
  karakuri-image-digest <tag>
      タグから digest を引き、compose ファイルへ貼れる image: 行を出す
  karakuri-check-image <tag>
      compose に pin された digest と、タグの現在の digest を照合する
  karakuri-broker-command <dev|prod> <project>
      broker 実行ファイルのパスを出す（差し替え点。既定は Bitwarden broker）
  karakuri-broker-env <dev|prod> <project>
      broker へ渡す環境変数を出す（差し替え点）
  karakuri-help
      この一覧を出す

FUNCS

	printf '環境変数（bw の在処・org 名・compose ファイルの配置先。秘密は含まない）:\n\n'

	_karakuri_help_env "KARAKURI_BW_BIN" "任意" "${KARAKURI_BW_BIN:-}" \
		"bw 実行ファイルの絶対パス。未設定なら broker 側の既定（PATH 解決）に任せる"

	_karakuri_help_env "KARAKURI_ORG" "任意" "${KARAKURI_ORG:-}" \
		"<org>/<repo> の org を省いたときに補う。org を複数横断して扱うなら設定しないこと（設定すると、別 org のつもりで打った bare <repo> が黙って KARAKURI_ORG 側の org へ解決される）"

	# この 2 つは「どちらか一方が要る」関係なので、必須/任意の欄にも現在値の
	# 隣にもその条件を書く。片方だけを見て「未設定だから壊れている」と読む
	# 誤りを避けるため。
	_karakuri_help_env "KARAKURI_PROD_COMPOSE" "KARAKURI_PROD_COMPOSE_DIR が無いとき prod 系の関数で必須" "${KARAKURI_PROD_COMPOSE:-}" \
		"全プロジェクトで 1 枚を共有する compose.prod.yaml の配置先。KARAKURI_PROD_COMPOSE_DIR が設定されていれば、そちらが優先されこの値は使われない"

	_karakuri_help_env "KARAKURI_PROD_COMPOSE_DIR" "KARAKURI_PROD_COMPOSE が無いとき prod 系の関数で必須" "${KARAKURI_PROD_COMPOSE_DIR:-}" \
		"プロジェクトごとの compose ファイルを集めたディレクトリ。使うのは <repo>.yaml（無ければ <repo>.yml、両方あればエラー）。KARAKURI_PROD_COMPOSE より優先される。karakuri-check-image はこのディレクトリの中を全部見る"

	if [ "${KARAKURI_PROD_INSTALL+set}" = "set" ]; then
		if [ -z "$KARAKURI_PROD_INSTALL" ]; then
			printf '  KARAKURI_PROD_INSTALL (任意): (empty — install 段を省く設定)\n'
		else
			printf '  KARAKURI_PROD_INSTALL (任意): %s\n' "$KARAKURI_PROD_INSTALL"
		fi
	else
		printf '  KARAKURI_PROD_INSTALL (任意): (unset — 既定 "pnpm install --frozen-lockfile" を使う)\n'
	fi
	printf '      タスクの前に走らせる install コマンド。空文字を設定すると install 段を省く\n'

	if [ "${KARAKURI_PROD_RUN+set}" = "set" ]; then
		printf '  KARAKURI_PROD_RUN (任意): %s\n' "$KARAKURI_PROD_RUN"
	else
		printf '  KARAKURI_PROD_RUN (任意): (unset — 既定 "pnpm" を使う)\n'
	fi
	printf '      タスク名の前に置くコマンド（"npm run" 等の複数語も設定できる）\n'

	_karakuri_help_env "KARAKURI_TOOL_DIR" "任意" "${KARAKURI_TOOL_DIR:-}" \
		"prod-run.sh / dev-inject.sh / broker を探すディレクトリ。通常は設定しなくてよい"

	return 0
}

# --- 推奨する alias の例 ---------------------------------------------------------
#
# 短い名前は利用者の側で付ける。下をそのまま .zshrc / .bashrc へ写せば、
# これまでの短い名前のまま使える（alias は関数にも効き、引数もそのまま渡る）。
#
#   alias pf='karakuri-port-forward'
#   alias clean-pf='karakuri-clean-port-forward'
#   alias dev-inject='karakuri-dev-inject'
#   alias prod-run='karakuri-prod-run'
#   alias prod-exec='karakuri-prod-exec'
#   alias prod-base='karakuri-prod-base'
#   alias prod-shell='karakuri-prod-shell'
#
# karakuri-dock は compose project 名・service 名・workspace を引数で
# 受け取るだけで、`<project>-dev` のような規約を組み立てない（この点だけは
# alias ではなく短い関数にする。alias は引数をそのまま渡す口しか持たず、
# `-p "$1-dev"` のような組み立てができない）。配らないのは、汎用的な
# `dock` という名前を利用者のシェルへ勝手に持ち込まないため:
#
#   dock() { karakuri-dock -p "$1-dev" -w "/workspaces/$1" "${@:2}" }
#
# 環境変数の設定例:
#
#   export KARAKURI_BW_BIN="$HOME/.dev-broker/bw"
#   export KARAKURI_ORG=acme
#   export KARAKURI_PROD_COMPOSE_DIR="$HOME/.config/acme/compose"   # <repo>.yaml を並べる
#
# 全プロジェクトで 1 枚を共有していた頃の書き方も残してある:
#
#   export KARAKURI_PROD_COMPOSE="$HOME/.config/acme/compose.prod.yaml"
#
# 各変数の意味・必須/任意・現在値は karakuri-help を実行して見ること
# （ここに説明文を書くと、karakuri-help の説明文と 2 箇所を直す羽目になる。
# KARAKURI_ORG の「複数 org を横断するなら設定しない」という注意も含めて
# karakuri-help 側に一本化した）。
