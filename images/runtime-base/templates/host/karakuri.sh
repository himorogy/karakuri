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
#   KARAKURI_PROD_COMPOSE  compose.prod.yaml の配置先（prod 系の関数で必須）
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
#   karakuri-pf <name>                              port forwarding を張り直す
#   karakuri-clean-pf [name...]                     port forwarding の後始末
#   karakuri-dev-inject <project>                   dev container へ鍵を注入
#   karakuri-prod-run <org/repo> <sha> <task> [args...]
#   karakuri-prod-exec <org/repo> <sha> <cmd> [args...]
#   karakuri-prod-base <org/repo> <sha>             対話作業の土台を起動
#   karakuri-prod-shell <repo>                      土台へ入る
#   karakuri-image-digest <tag>                     タグ → image: 行の完成形
#   karakuri-check-image <tag>                      compose の digest と照合
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

# karakuri-pf <name> — port forwarding を張り直す。
#
# 「張る」ではなく「張り直す」なのは、コンテナを作り直した後の再接続が
# 主な用途だから。古い master が残ったままだと、新しいコンテナへ繋いだ
# つもりで死んだセッションを使い続けることになる。先に必ず落とす。
karakuri-pf() {
	if [ "$#" -ne 1 ]; then
		echo "Usage: karakuri-pf <name>   (ssh host devc-<name>, or the full host alias)" >&2
		return 1
	fi

	local host
	host="$(_karakuri_ssh_host "$1")"

	# 生きていれば落とす。生きていなければ何も起きない（失敗は無視する）。
	# -n は「stdin を /dev/null にする」指定。制御コマンドに stdin は要らず、
	# 付けておけば下の clean-pf のようにループの中で呼んでも、ループが
	# 読んでいる入力を ssh が横取りしない。
	ssh -n -O exit "$host" >/dev/null 2>&1
	# 落とせなかった／プロセスだけ先に消えた場合に socket ファイルだけが
	# 残る。残骸があると次の接続がそこへ繋ぎに行って失敗するので消す。
	rm -f "${HOME}/.ssh/cm-${host}"

	if ssh -fN "$host"; then
		return 0
	fi
	echo "karakuri-pf: 'ssh -fN ${host}' failed. Check that the container is up and that ~/.ssh/config has a Host entry for '${host}'" >&2
	return 1
}

# karakuri-clean-pf [name...] — port forwarding の後始末。
#
# 名前を指定しなければ、ControlPath の規約（~/.ssh/cm-<host>）に沿って
# devc- で始まるものを全部畳む。cm-* まで広げると、この規約と無関係な
# 利用者自身の ssh 多重化まで巻き添えにするので広げない。
karakuri-clean-pf() {
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

# --- prod -----------------------------------------------------------------------

# _karakuri_prod_call <org/repo> <sha> <argv...> — prod-run.sh を呼ぶ。
#
# COMPOSE_PROJECT_NAME をプロジェクトごとに振るのがここの要点。compose
# ファイルは全プロジェクトで 1 枚を共有できる設計なので、project 名を
# 指定しないと compose はファイルの所在から名前を導き、どのプロジェクトの
# prod を起動しても同じ名前になる。そうなると、起動済みコンテナを名前で
# 引く操作（karakuri-prod-shell）が別プロジェクトのコンテナに一致する。
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

	if [ -z "${KARAKURI_PROD_COMPOSE:-}" ]; then
		echo "karakuri: KARAKURI_PROD_COMPOSE is not set. Point it at the compose.prod.yaml you keep outside the dev workspace (for example ~/.config/${repo}/compose.prod.yaml)" >&2
		return 1
	fi

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
		"PROD_COMPOSE_FILE=${KARAKURI_PROD_COMPOSE}" \
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
karakuri-prod-shell() {
	if [ "$#" -ne 1 ]; then
		echo "Usage: karakuri-prod-shell <repo>   (the same repo name you passed to karakuri-prod-base)" >&2
		return 1
	fi

	local repo="$1"
	_karakuri_plain_name "repo" "$repo" || return 1

	if [ -z "${KARAKURI_PROD_COMPOSE:-}" ]; then
		echo "karakuri: KARAKURI_PROD_COMPOSE is not set. Point it at the compose.prod.yaml you keep outside the dev workspace (for example ~/.config/${repo}/compose.prod.yaml)" >&2
		return 1
	fi

	local project="prod-${repo}"
	local cid
	cid="$(docker compose -p "$project" -f "$KARAKURI_PROD_COMPOSE" ps -q prod)" || {
		echo "karakuri-prod-shell: 'docker compose -p ${project} ps' failed" >&2
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

# _karakuri_compose_image_ref — compose ファイルに書かれている image の
# 参照を stdout に出す。
_karakuri_compose_image_ref() {
	if [ -z "${KARAKURI_PROD_COMPOSE:-}" ]; then
		echo "karakuri: KARAKURI_PROD_COMPOSE is not set. Point it at the compose.prod.yaml you keep outside the dev workspace" >&2
		return 1
	fi
	if [ ! -f "$KARAKURI_PROD_COMPOSE" ]; then
		echo "karakuri: KARAKURI_PROD_COMPOSE points at '${KARAKURI_PROD_COMPOSE}', which is not a file" >&2
		return 1
	fi

	local lines
	lines="$(grep -E '^[[:space:]]*image:[[:space:]]*[^[:space:]#]' "$KARAKURI_PROD_COMPOSE")"

	if [ -z "$lines" ]; then
		echo "karakuri: no 'image:' line in ${KARAKURI_PROD_COMPOSE}" >&2
		return 1
	fi
	if [ "$(printf '%s\n' "$lines" | wc -l)" -gt 1 ]; then
		echo "karakuri: ${KARAKURI_PROD_COMPOSE} has more than one 'image:' line — cannot tell which one pins the prod image. Check it by hand" >&2
		return 1
	fi

	printf '%s\n' "$lines" | sed -e 's/^[[:space:]]*image:[[:space:]]*//' -e 's/[[:space:]]*$//'
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

	local current name
	current="$(_karakuri_compose_image_ref)" || return 1
	name="$(_karakuri_image_name "$current")"
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
karakuri-check-image() {
	if [ "$#" -ne 1 ]; then
		echo "Usage: karakuri-check-image <tag>   (or a full <image>:<tag> reference)" >&2
		return 1
	fi

	local ref current expected
	ref="$(_karakuri_image_ref "$1")" || return 1
	current="$(_karakuri_compose_image_ref)" || return 1

	# digest が入っていない（タグ pin のまま）ときと、テンプレートの
	# プレースホルダが残っているときは、レジストリへ問い合わせる前に止める。
	# どちらも「照合できる状態になっていない」であって、照合の結果が
	# 不一致なのとは原因が違う。同じメッセージにすると直し方を誤る。
	local current_digest=""
	case "$current" in
	*@*) current_digest="${current#*@}" ;;
	esac
	if ! printf '%s' "$current_digest" | grep -qE '^sha256:[0-9a-f]{64}$'; then
		echo "karakuri-check-image: ${KARAKURI_PROD_COMPOSE} does not pin a resolved digest (it says '${current}'). Run 'karakuri-image-digest $1' and paste the result over that line" >&2
		return 1
	fi

	local current_name expected_name
	current_name="$(_karakuri_image_name "$current")"
	expected_name="$(_karakuri_image_name "$ref")"
	if [ "$current_name" != "$expected_name" ]; then
		echo "karakuri-check-image: ${KARAKURI_PROD_COMPOSE} pins image '${current_name}', but '$1' resolves to '${expected_name}' — these are different images, so their digests cannot be compared" >&2
		return 1
	fi

	expected="$(_karakuri_resolve_digest "$ref")" || return 1

	if [ "$current_digest" = "$expected" ]; then
		printf '%s pins %s@%s (matches %s)\n' "$KARAKURI_PROD_COMPOSE" "$current_name" "$current_digest" "$ref"
		return 0
	fi

	echo "karakuri-check-image: digest mismatch. ${KARAKURI_PROD_COMPOSE} pins ${current_digest}, but ${ref} is now ${expected}. Run 'karakuri-image-digest $1' and paste the result over the image: line if the move is intended" >&2
	return 1
}

# --- 推奨する alias の例 ---------------------------------------------------------
#
# 短い名前は利用者の側で付ける。下をそのまま .zshrc / .bashrc へ写せば、
# これまでの短い名前のまま使える（alias は関数にも効き、引数もそのまま渡る）。
#
#   alias pf='karakuri-pf'
#   alias clean-pf='karakuri-clean-pf'
#   alias dev-inject='karakuri-dev-inject'
#   alias prod-run='karakuri-prod-run'
#   alias prod-exec='karakuri-prod-exec'
#   alias prod-base='karakuri-prod-base'
#   alias prod-shell='karakuri-prod-shell'
#
# 環境変数の設定例:
#
#   export KARAKURI_BW_BIN="$HOME/.local/bin/bw"
#   export KARAKURI_ORG=acme
#   export KARAKURI_PROD_COMPOSE="$HOME/.config/acme/compose.prod.yaml"
