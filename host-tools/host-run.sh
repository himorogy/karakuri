#!/usr/bin/env bash
#
# host-run.sh — ホストで実行するコマンドへ秘密を渡す
#
# ============================================================================
# このファイルを dev workspace の中から実行するな。
# dev container に bind mount されるディレクトリの外（ホストの固定パス）に
# 置いたものを使え。karakuri 自体を clone して使う場合、その clone は
# bind mount されないので、そこから実行してよい。禁じているのは置き場所で
# あって、リポジトリの中にあること自体ではない。
#
# 理由: dev workspace はホストに bind mount されている。もしこのラッパーを
# workspace 内に置いたまま人間がホストで実行する運用にすると、dev
# container の中で常駐する LLM エージェントがこのファイルを書き換えられて
# しまう。正規 broker の呼び出しの前後に「鍵を別の場所へ複製する」コードを
# 仕込む、といった攻撃が構成上可能になる。broker と起動スクリプト自体を
# dev から到達不能なホストの固定パスに置くことで、この経路を構造的に断つ。
# ============================================================================
#
# broker を1回呼び、出力を environ へ取り込んでから "$@" を exec する。
# broker の項目名の組み立てはこのスクリプトの責務ではない。呼び出し側が
# HOST_BROKER にパスだけを渡す。
#
# 使い方は usage() を参照（引数なしで実行すると表示される）。
#
# デバッグ用の -x / --verbose フラグは意図的に用意していない。broker の
# 出力（secret そのもの）が通るのはこのスクリプト内の一箇所（下記パース）
# だけであり、`set -x` を有効にする経路を残すと、その区間だけ無効化する
# 実装ミスひとつで secret がトレース出力に落ちる。「そもそも仕込まない」
# 方を選ぶ。

set -uo pipefail

usage() {
	cat <<'EOF'
Usage: host-run.sh <cmd> [args...]

broker の dotenv 形式出力を environ へ取り込んでから <cmd> を exec する。

Required environment:
  HOST_BROKER  dotenv 形式を stdout に出す broker コマンドのパス。
               引数は取れない（単一の実行ファイルとして呼ばれる）。
               引数が要る broker はラッパースクリプトに包むこと。

Example:
  HOST_BROKER="$HOME/.local/bin/acme-host-broker" host-run.sh dotenvx run -f .env -- pnpm build
EOF
}

if [ "$#" -lt 1 ]; then
	usage >&2
	exit 1
fi

if [ -z "${HOST_BROKER:-}" ]; then
	echo "host-run: HOST_BROKER is not set" >&2
	usage >&2
	exit 1
fi

# --- 古い鍵の削除（broker を呼ぶ前） -------------------------------------------
# 利用者のログインシェルに別環境・別プロジェクトの DOTENV_PRIVATE_KEY* が
# export されていると、そのまま子プロセスへ継承される。dotenvx はファイル名
# の規約で鍵変数を選ぶため、サフィックスが衝突しない鍵が残っていても
# 誤った鍵として拾われうる。鍵違いは鍵無しより悪い（鍵無しは shim 側が
# 落とすが、鍵違いは dotenvx が rc=0 で暗号文を返す）ので、broker を呼ぶ
# より前にここで全て消しておく。
for _host_run_stale in "${!DOTENV_PRIVATE_KEY@}"; do
	unset "$_host_run_stale"
done
unset _host_run_stale

# --- broker を1回呼ぶ -----------------------------------------------------------
# secret はここでシェル変数へ代入せず、直接 export へ流す（下のパース段）。
# broker の stderr（認可プロンプト等）はそのまま端末へ通る。
host_run_broker_output="$("$HOST_BROKER")"
host_run_broker_rc=$?
if [ "$host_run_broker_rc" -ne 0 ]; then
	echo "host-run: broker failed (exit ${host_run_broker_rc})" >&2
	exit "$host_run_broker_rc"
fi

if [ -z "$host_run_broker_output" ]; then
	echo "host-run: broker produced no output" >&2
	exit 1
fi

# --- dotenv 形式の行単位パース --------------------------------------------------
# 取り込めない行は、その内容を出力へ一切反射させず、行番号だけを報告して
# 落ちる。broker の出力が壊れている場合、その行は secret 本体でありうる
# ため（images/runtime-base/bin/prod-entrypoint.sh の取り込みと同じ規律。
# ここでは /run/secrets へのファイル書き出しではなく environ への export
# が対象になる点と、ログの保持期間・可視範囲が違うため、実装は共有せず
# 別に持つ）。
#
# here-document ではなくプロセス置換にするのは、bash の here-document が
# 内容によってはディスク上の一時ファイル（/tmp/sh-thd.*）を経由するため。
# secret をディスクへ書かない、という不変条件をここで破らないための選択。
host_run_lineno=0
while IFS= read -r host_run_line || [ -n "$host_run_line" ]; do
	host_run_lineno=$((host_run_lineno + 1))

	case "$host_run_line" in
	'' | '#'*) continue ;;
	esac

	case "$host_run_line" in
	*=*) ;;
	*)
		echo "host-run: could not ingest broker output at line ${host_run_lineno}: missing '='" >&2
		exit 1
		;;
	esac

	host_run_k=${host_run_line%%=*}
	host_run_v=${host_run_line#*=}

	case "$host_run_k" in
	[A-Za-z_]*) ;;
	*)
		echo "host-run: could not ingest broker output at line ${host_run_lineno}: invalid key" >&2
		exit 1
		;;
	esac
	case "$host_run_k" in
	*[!A-Za-z0-9_]*)
		echo "host-run: could not ingest broker output at line ${host_run_lineno}: invalid key" >&2
		exit 1
		;;
	esac

	case "$host_run_v" in
	\"*\")
		host_run_v=${host_run_v#\"}
		host_run_v=${host_run_v%\"}
		;;
	\'*\')
		host_run_v=${host_run_v#\'}
		host_run_v=${host_run_v%\'}
		;;
	esac

	if [ -z "$host_run_v" ]; then
		echo "host-run: could not ingest broker output at line ${host_run_lineno}: empty value" >&2
		exit 1
	fi

	export "${host_run_k}=${host_run_v}"
done < <(printf '%s\n' "$host_run_broker_output")

unset host_run_broker_output host_run_broker_rc host_run_lineno host_run_line host_run_k host_run_v

# --- exec ------------------------------------------------------------------------
# シェルを経由しない。引数は逐語のまま子プロセスへ渡る。
exec "$@"
