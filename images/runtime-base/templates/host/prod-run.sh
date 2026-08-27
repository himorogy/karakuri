#!/usr/bin/env bash
#
# prod-run.sh — prod container 起動ラッパー
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
#
# 同じ理由から、compose ファイルのパスもこのファイル自身の場所からの
# リポジトリ相対推測をしない。PROD_COMPOSE_FILE で毎回明示的に受け取る。
# ============================================================================
#
# 使い方は usage() を参照（引数なしで実行すると表示される）。
#
# デバッグ用の -x / --verbose フラグは意図的に用意していない。broker の
# 出力（secret そのもの）が通るのはこのスクリプト内の一箇所（下記パイプ）
# だけであり、`set -x` を有効にする経路を残すと、その区間だけ無効化する
# 実装ミスひとつで secret がトレース出力に落ちる。「そもそも仕込まない」
# 方を選ぶ。

set -euo pipefail

# MSYS_NO_PATHCONV=1 は Git Bash(MSYS2) のパス変換を止める。先頭が `/` の
# 引数（`"$@"` に渡すタスクの引数がコンテナ内の絶対パスであるとき）を
# Windows パスへ変換されると、コンテナ内で解決できないパスに化ける
# （dock.sh で確認済みの不具合と同型）。dock.sh と同じくスクリプト冒頭で
# export する形に寄せている。prod-run.sh は独立したプロセスとして起動
# されるので、この export は呼び出し元のシェルへは漏れない。broker が受け
# 取る項目名は環境変数（PROD_BROKER 等）で渡るため、この変換の対象外。
# `-f "$PROD_COMPOSE_FILE"`（ホスト側のパス）の変換もこの export で止まる
# が、その当否は実測待ちの別論点として扱い、ここでは形を変えない。
export MSYS_NO_PATHCONV=1

# --- pipefail が無いと何が起きるか -------------------------------------------
# broker が認可失敗（Touch ID 拒否・非対話環境で確認ダイアログを出せない、
# 等）で非ゼロ終了しても、パイプの最終要素は docker であり、docker が
# たとえば usage エラーではなく 0 を返せば、bash 既定の $?（パイプ最後の
# コマンドのものだけを見る）はパイプ全体を成功とみなしてしまう。
# secret が一切注入されないまま `docker compose run` 経由で prod
# コマンドが走る、という最悪のケースを起動前に止めるための必須設定である。
# secret の欠落を沈黙した成功にしない、というのがこの構成全体の要求であり、
# entrypoint 側の非空検証は第二の防波堤に過ぎない。ここで止められるものは
# ここで止める。

usage() {
	cat <<'EOF'
Usage: prod-run.sh <command> [args...]

Required environment:
  PROD_COMPOSE_FILE  compose.prod.yaml へのパス
  PROD_BROKER        dotenv 形式を stdout に出す broker コマンド。
                     引数は取れない（単一の実行ファイルとして呼ばれる）。
                     引数が要る broker はラッパースクリプトに包むこと。
  GIT_REPO           clone 元 URL
  GIT_REF            実行対象の ref。完全な 40 桁 commit sha を要求する
                     （既定で拒否。下記 PROD_ALLOW_MUTABLE_REF 参照）

Optional environment:
  PROD_ALLOW_MUTABLE_REF
                     1 を指定すると、GIT_REF が完全な commit sha でなくて
                     も警告付きで実行を続ける（タグの署名検証は未実装な
                     ので、署名タグであっても保証は得られない。危険を
                     理解した上でのみ使うこと）

Example:
  PROD_COMPOSE_FILE=~/.config/acme/compose.prod.yaml \
  PROD_BROKER="$HOME/.local/bin/acme-broker" \
  GIT_REPO=https://github.com/acme/app.git \
  GIT_REF=1234567890abcdef1234567890abcdef12345678 \
  prod-run.sh dotenvx run --strict --no-armor -f .env.prod -- pnpm deploy

dotenvx は pnpm の外側に置くこと。`pnpm run` は node_modules/.bin を
PATH の先頭に積むため、プロジェクトがローカルに dotenvx を持っていると
script 内の dotenvx がイメージの shim に勝ち、鍵が注入されない。

--strict と --no-armor は必須:
  --strict    dotenvx は復号に失敗しても非ゼロ終了せず、暗号文をその
              まま値として注入して rc=0 を返す（実測: FOO=encrypted:...
              のままアプリが起動し、deploy は成功と報告される）。
              --strict を付けると鍵が無い状態で確実に rc=1 になる。
  --no-armor  dotenvx 2.x は既定で Dotenvx Armor（ホスト型サービス）を
              有効にしており、ネットワークへ出る経路になりうる。prod は
              決定性に価値がある層なので切る。
EOF
}

# 引数なしなら usage を出して終了する。コマンドを渡さずに
# `docker compose run prod` だけ起動しても、entrypoint の `exec "$@"` に
# 何も渡らず "no command given" で失敗するだけなので、ここで早期に弾いた
# 方が分かりやすい。
if [ "$#" -eq 0 ]; then
	usage >&2
	exit 1
fi

# --- 必須環境変数の検査（起動前に・欠けている変数名を名指しして） -----------
missing=()
[ -n "${PROD_COMPOSE_FILE:-}" ] || missing+=("PROD_COMPOSE_FILE")
[ -n "${PROD_BROKER:-}" ] || missing+=("PROD_BROKER")
[ -n "${GIT_REPO:-}" ] || missing+=("GIT_REPO")
[ -n "${GIT_REF:-}" ] || missing+=("GIT_REF")

if [ "${#missing[@]}" -gt 0 ]; then
	{
		printf 'prod-run: missing required environment variable(s): %s\n' "${missing[*]}"
		echo
		usage
	} >&2
	exit 1
fi

# --- GIT_REF: 完全な commit sha を既定で強制する ------------------------------
# 軽量タグ・ブランチ名は付け替え可能で、「明示された ref」としての強さが
# commit sha に劣る。dev container が prod の実行コードを書き換えうること
# （この構成が守るのは機密性であって整合性ではない）に対する唯一のゲートは
# deploy 前の人間のレビューであり、その前提は「レビューした対象と流したもの
# が一致する」ことなので、既定は拒否する。失敗の性質も違う — ブランチ名は
# 「押した瞬間に何を流したか分からず、後から再現もできない」のに対し、sha は
# 「古いかもしれないが既知で再現可能」である。タグの署名検証は未実装であり、
# 現状はタグを許容してもリスクが増えるだけなので「署名タグは正当な用途」と
# いう理由での許容はしない。危険を理解した上でブランチ運用を選ぶ場合だけ
# PROD_ALLOW_MUTABLE_REF=1 を明示する。
#
# ここでの検査は早期フィードバックのためのものであり、権威は
# prod-entrypoint.sh 側にある。このラッパーを迂回して
# 直接 `docker compose run` された場合でも、entrypoint 側の同じ検査が
# 効くため fail-closed は保たれる。
if ! [[ "$GIT_REF" =~ ^[0-9a-fA-F]{40}$ ]]; then
	if [ "${PROD_ALLOW_MUTABLE_REF:-}" = 1 ]; then
		echo "prod-run: WARNING: GIT_REF '$GIT_REF' is not a 40-character commit sha. A branch or lightweight tag can be repointed after the fact, so what you reviewed before deploying is no longer guaranteed to be what runs. PROD_ALLOW_MUTABLE_REF=1 is set, continuing anyway." >&2
	else
		echo "prod-run: GIT_REF '$GIT_REF' is not a 40-character commit sha. Pass the full sha so that the commit you reviewed is the commit that runs. Set PROD_ALLOW_MUTABLE_REF=1 to continue anyway (not recommended; tag signature verification is not implemented, so even a signed tag buys you nothing here)." >&2
		exit 1
	fi
fi

# --- 起動 ---------------------------------------------------------------------
# secret は broker の stdout → パイプ → `docker compose run` の stdin →
# entrypoint という経路だけを流れる。ここでは一切 echo せず、secret の
# 内容をシェル変数にも代入しない（変数に持たせると、その変数が
# デバッグ出力やエラーメッセージへ漏れる経路が増える）。
#
# -T は必須。stdin が secret の搬送路であり、pseudo-TTY の割り当てとは
# 両立しない。付け忘れると compose が TTY 確保を試みてパイプ入力を正しく
# 消費できない。
#
# broker と docker、どちらが失敗したのかを区別して報告するため、パイプ
# ラインを `if` の条件として実行する。`if` の条件式は `set -e` の対象外
# なので、ここでパイプが失敗してもスクリプトはまだ終了せず、両者の終了
# コードを個別に検査してから然るべきメッセージで終了できる。
if "$PROD_BROKER" | docker compose -f "$PROD_COMPOSE_FILE" run -T --rm prod "$@"; then
	broker_rc=0
	docker_rc=0
else
	# PIPESTATUS は直前に実行したパイプラインの各要素の終了コードを保持
	# する配列。要素 0 が broker、要素 1 が docker compose run。
	# `set -o pipefail` はパイプ全体の終了コードを「最後に失敗した要素の
	# もの」にまとめてしまい、broker と docker のどちらが落ちたかは
	# それだけでは分からない。両者を区別して報告するために配列の中身を
	# 直接見る。
	#
	# 配列全体を 1 回の代入でコピーすること。PIPESTATUS は「直近に実行
	# した foreground pipeline」を指す動的な変数で、単純コマンド 1 個
	# （ここでは bare な代入文も含む）を実行するたびにその実行結果
	# （長さ 1 の配列）で上書きされる。そのため
	# `broker_rc="${PIPESTATUS[0]}"` と `docker_rc="${PIPESTATUS[1]}"` を
	# 2 文に分けて書くと、1 文目の代入を実行した時点で PIPESTATUS が
	# 長さ 1 に潰れ、2 文目は存在しない要素を読むことになる（`set -u`
	# 下では unbound variable エラーで落ちる）。`pipe_status=(...)` の
	# ように 1 回の代入で配列ごと退避してから、退避した側を読む。
	pipe_status=("${PIPESTATUS[@]}")
	broker_rc="${pipe_status[0]}"
	docker_rc="${pipe_status[1]}"
fi

# --- 原因の切り分け（SIGPIPE を考慮する） -------------------------------------
# docker が起動エラー等で先に死んで stdin を閉じると、broker は書き込み中に
# SIGPIPE を受けて 141 で終了する。この場合 PIPESTATUS は
# (141, <docker の非ゼロ値>) になり、素朴に「broker を先に見る」実装だと
# 真の原因（docker）を隠して「broker failed (exit 141)」と誤報告してしまう。
# SIGPIPE は docker が先に落ちた結果であって原因ではないため、broker が 141
# かつ docker も非ゼロなら docker を原因として報告し、docker の終了コードで
# 終了する。
if [ "$broker_rc" -eq 141 ] && [ "$docker_rc" -ne 0 ]; then
	echo "prod-run: docker compose run failed (exit ${docker_rc}); broker received SIGPIPE (exit 141) because docker closed stdin first — docker is the root cause, not the broker" >&2
	exit "$docker_rc"
fi

# 上記以外で両方が非ゼロの場合は、どちらが「本当の」原因かを機械的には
# 決められないため、両方の終了コードを見せて broker 側の終了コードで
# 終了する（broker が secret 注入の入口であり、docker 側の失敗はその
# 結果として起きている可能性が高いため）。
if [ "$broker_rc" -ne 0 ] && [ "$docker_rc" -ne 0 ]; then
	echo "prod-run: both broker (exit ${broker_rc}) and docker compose run (exit ${docker_rc}) failed" >&2
	exit "$broker_rc"
fi

if [ "$broker_rc" -ne 0 ]; then
	echo "prod-run: broker failed (exit ${broker_rc}); docker compose run did not receive valid secrets" >&2
	exit "$broker_rc"
fi

if [ "$docker_rc" -ne 0 ]; then
	echo "prod-run: docker compose run failed (exit ${docker_rc})" >&2
	exit "$docker_rc"
fi

exit 0
