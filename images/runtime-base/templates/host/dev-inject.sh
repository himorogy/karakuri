#!/usr/bin/env bash
#
# dev-inject.sh — dev container への鍵注入コマンド
#
# ============================================================================
# このファイルをリポジトリ内から実行するな。
# ~/.local/bin/ 等、dev workspace の外（ホストの固定パス）へコピーしてから
# 使え。
#
# 理由: dev workspace はホストに bind mount されている。もしこのスクリプトを
# workspace 内に置いたまま人間がホストで実行する運用にすると、dev
# container の中で常駐する LLM エージェントがこのファイルを書き換えられて
# しまう。正規 broker の呼び出しの前後に「鍵を別の場所へ複製する」コードを
# 仕込む、といった攻撃が構成上可能になる。broker と注入スクリプト自体を
# dev から到達不能なホストの固定パスに置くことで、この経路を構造的に断つ。
# ============================================================================
#
# これは起動ラッパーではない。dev container の起動は従来どおり IDE
# （devcontainer 拡張）が行い、このコマンドは起動済みのコンテナへ外から
# 鍵を注入するだけである。コンテナ内の /run/secrets は tmpfs にあり、
# 再作成だけでなく停止 → 再起動でも消える（tmpfs はコンテナ起動のたびに
# 新規マウントされる）ため、「コンテナを起動するたびに、起動後に 1 回」
# 実行するのが運用になる。再実行は同名の鍵の上書きになる（コンテナ内の
# 取込スクリプト側の挙動）。冪等なので、迷ったら打ち直してよい。
#
# 使い方は usage() を参照（引数を渡す・必須環境変数が欠けている場合に
# 表示される）。
#
# デバッグ用の -x / --verbose フラグは意図的に用意していない。broker の
# 出力（secret そのもの）が通るのはこのスクリプト内の一箇所（下記パイプ）
# だけであり、`set -x` を有効にする経路を残すと、その区間だけ無効化する
# 実装ミスひとつで secret がトレース出力に落ちる。「そもそも仕込まない」
# 方を選ぶ。

set -euo pipefail

# --- pipefail が無いと何が起きるか -------------------------------------------
# broker が認可失敗（Touch ID 拒否・非対話環境で確認ダイアログを出せない、
# 等）で非ゼロ終了しても、パイプの最終要素は docker であり、docker が 0 を
# 返せば、bash 既定の $?（パイプ最後のコマンドのものだけを見る）はパイプ
# 全体を成功とみなしてしまう。secret が一切注入されないまま「注入した
# つもり」になる事故を止めるための必須設定である。secret の欠落を沈黙した
# 成功にしない、というのがこの構成全体の要求であり、コンテナ内の取込
# スクリプトの検証（取込件数・非空）は第二の防波堤に過ぎない。ここで
# 止められるものはここで止める。

usage() {
	cat <<'EOF'
Usage: dev-inject.sh

引数は取らない。設定は環境変数で渡す。

Required environment:
  DEV_BROKER           dotenv 形式を stdout に出す broker コマンドのパス。
                       引数は取れない（単一の実行ファイルとして呼ばれる）。
                       引数が要る broker はラッパースクリプトに包むこと。
  DEV_COMPOSE_PROJECT  dev container を起動している compose の project 名。
                       注入先のコンテナはこの project 名から引く（コンテナ
                       名の決め打ちは、プロジェクト複製時の直し忘れがその
                       まま「別プロジェクトへの注入」事故になるため採らない）

Optional environment:
  DEV_SERVICE          注入先の compose service 名（既定: dev）

コンテナを起動するたびに、起動後に 1 回実行すること。コンテナ内の
/run/secrets は tmpfs にあり、再作成だけでなく停止 → 再起動でも消える
ため、起動のたびに注入し直す必要がある。再実行は上書きになるので、
何度打っても害はない。

Example:
  DEV_BROKER="$HOME/.local/bin/acme-dev-broker" \
  DEV_COMPOSE_PROJECT=acme \
  dev-inject.sh
EOF
}

# 引数は受け付けない。secret の搬送路であるこのコマンドに引数の解釈を
# 持たせない（タイポがそのまま別の動作になる余地を残さない）。
if [ "$#" -ne 0 ]; then
	usage >&2
	exit 1
fi

# --- 必須環境変数の検査（欠けている変数名を名指しして） -----------------------
missing=()
[ -n "${DEV_BROKER:-}" ] || missing+=("DEV_BROKER")
[ -n "${DEV_COMPOSE_PROJECT:-}" ] || missing+=("DEV_COMPOSE_PROJECT")

if [ "${#missing[@]}" -gt 0 ]; then
	{
		printf 'dev-inject: missing required environment variable(s): %s\n' "${missing[*]}"
		echo
		usage
	} >&2
	exit 1
fi

service="${DEV_SERVICE:-dev}"

# --- 注入先コンテナの特定 -----------------------------------------------------
# compose の project 名 + service 名から container id を引く。該当が無い
# （起動していない）／複数ある（scale されている等で注入先を一意に決められ
# ない）場合は、broker を呼ぶ前に止める。
cid="$(docker compose -p "$DEV_COMPOSE_PROJECT" ps -q "$service")"

if [ -z "$cid" ]; then
	echo "dev-inject: no running container for service '${service}' in compose project '${DEV_COMPOSE_PROJECT}'. The dev container is not up — start it (the IDE / devcontainer extension does this) and run dev-inject once after each start" >&2
	exit 1
fi

if [ "$(printf '%s\n' "$cid" | wc -l)" -gt 1 ]; then
	echo "dev-inject: multiple containers match service '${service}' in compose project '${DEV_COMPOSE_PROJECT}' — cannot decide which one to inject into. Narrow it down (stop the extras, or point DEV_SERVICE / DEV_COMPOSE_PROJECT at a single container)" >&2
	exit 1
fi

# --- 注入 ---------------------------------------------------------------------
# secret は broker の stdout → パイプ → `docker exec -i` の stdin →
# コンテナ内の取込スクリプトという経路だけを流れる。ここでは一切 echo
# せず、secret の内容をシェル変数にも代入しない（変数に持たせると、その
# 変数がデバッグ出力やエラーメッセージへ漏れる経路が増える）。取込完了時に
# 書き込まれた鍵名（値は出ない）がコンテナ側から stderr へ 1 行返るので、
# 何が入ったかはそこで確認できる。
#
# broker と docker、どちらが失敗したのかを区別して報告するため、パイプ
# ラインを `if` の条件として実行する。`if` の条件式は `set -e` の対象外
# なので、ここでパイプが失敗してもスクリプトはまだ終了せず、両者の終了
# コードを個別に検査してから然るべきメッセージで終了できる。
if "$DEV_BROKER" | docker exec -i "$cid" /usr/local/bin/secrets-ingest.sh; then
	broker_rc=0
	docker_rc=0
else
	# PIPESTATUS は直前に実行したパイプラインの各要素の終了コードを保持
	# する配列。要素 0 が broker、要素 1 が docker exec。
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
	echo "dev-inject: docker exec failed (exit ${docker_rc}); broker received SIGPIPE (exit 141) because docker closed stdin first — docker is the root cause, not the broker" >&2
	exit "$docker_rc"
fi

# 上記以外で両方が非ゼロの場合は、どちらが「本当の」原因かを機械的には
# 決められないため、両方の終了コードを見せて broker 側の終了コードで
# 終了する（broker が secret 注入の入口であり、docker 側の失敗はその
# 結果として起きている可能性が高いため）。
if [ "$broker_rc" -ne 0 ] && [ "$docker_rc" -ne 0 ]; then
	echo "dev-inject: both broker (exit ${broker_rc}) and docker exec (exit ${docker_rc}) failed" >&2
	exit "$broker_rc"
fi

if [ "$broker_rc" -ne 0 ]; then
	echo "dev-inject: broker failed (exit ${broker_rc}); the container did not receive valid secrets" >&2
	exit "$broker_rc"
fi

if [ "$docker_rc" -ne 0 ]; then
	echo "dev-inject: docker exec failed (exit ${docker_rc})" >&2
	exit "$docker_rc"
fi

exit 0
