#!/usr/bin/env bash
#
# broker-bitwarden.sh — Bitwarden CLI を使った broker の参照実装
#
# broker は差し替え可能である。以下の契約さえ満たせば、macOS Keychain
# （broker-macos-keychain.sh）や 1Password CLI 等、別の実装に差し替えてよい。
#
# --- broker 契約 --------------------------------------------------------------
#   1. dotenv 形式（KEY=value の行）を stdout に出力する
#   2. 保管中の実体が不揮発ストレージ上で平文でない
#   3. 取得時に認可（マスターパスワード等のプロンプト）が働く
#   4. 非対話環境で認可を得られない場合は非ゼロ終了する
#   5. stdout 以外へ secret を出さない
#
# Bitwarden CLI での充足:
#   2 … ローカルの vault キャッシュ（data.json）は暗号化されている。lock は
#       このファイルを消すのではなく、復号に使うセッション鍵を失効させる
#   3 … `bw unlock` がマスターパスワードを対話プロンプトで要求する
#   4 … プロンプトを出せない環境では `bw unlock` が非ゼロ終了する
#
# ⚠️ BW_SESSION をシェルに export して常駐させる運用はこの契約の外である。
#    セッションが生きている間、同一ユーザーで走る任意のプロセスが無認可で
#    vault を読めるようになり、取得時の認可（契約 3）が実質消える。この
#    スクリプトは呼ばれるたびに unlock し、終了時に必ず lock する。
#
# --- セットアップ（初回のみ） --------------------------------------------------
#
#   bw login                      # アカウントへのログイン（初回のみ）
#   bw sync                       # vault キャッシュの更新
#
#   Bitwarden 側に Secure Note を 1 項目作り、名前を「env/<project>/<環境>」の
#   ように付ける（例: env/radwisp/dev）。中身は dotenv 形式のテキスト全文
#   （複数行の KEY=value をまとめたもの）。この項目名を、呼ぶ側で
#   BROKER_BW_ITEM として渡す。
#
#   注意: 項目の内容を Bitwarden 側で更新した後は `bw sync` を実行しないと、
#   ローカルの vault キャッシュが古いまま旧値を返す。
#
# --- 使い方 -------------------------------------------------------------------
#
#   # 項目名を都度渡す（項目名は秘匿情報ではないので環境変数でよい）
#   BROKER_BW_ITEM=env/radwisp/dev \
#     DEV_BROKER=~/.local/bin/broker-bitwarden.sh DEV_COMPOSE_PROJECT=... dev-inject.sh
#
#   # またはプロジェクト別に 1 行のラッパーを置いて固定する
#   #   ~/.local/bin/radwisp-dev-broker:
#   #     #!/usr/bin/env bash
#   #     BROKER_BW_ITEM=env/radwisp/dev exec "$HOME/.local/bin/broker-bitwarden.sh"
#
set -euo pipefail

# 項目名にデフォルト値は持たせない。決め打ちの名前を置くと、複数プロジェクトを
# 同一ホストで扱う際に取り違えて別プロジェクトの鍵束を注入してしまう事故を
# 機構的に防げなくなる。
if [ -z "${BROKER_BW_ITEM:-}" ]; then
	echo "broker-bitwarden: BROKER_BW_ITEM is required (the Bitwarden item name that holds the dotenv text, e.g. env/<project>/dev)" >&2
	exit 1
fi

# ここでマスターパスワードのプロンプトが出る（stderr / tty 経由。stdout には
# セッション鍵だけが出るので変数に受け、dotenv 出力と混ざらないようにする）。
# 非対話環境ではプロンプトを出せず非ゼロ終了する。
session=$(bw unlock --raw)

# 取得の成否によらず、このスクリプトを抜けるときには必ず lock する。
# lock の失敗で本来の終了コードを上書きしない。
trap 'BW_SESSION="$session" bw lock >/dev/null 2>&1 || true' EXIT

# bw の失敗（項目が見つからない・同名項目が複数ある、等）を必ず非ゼロで
# 伝播させる。bw 自身の診断メッセージは stderr へ出るのでそのまま流れる。
# secret を含みうる stdout だけを変数に取り込む。
if dotenv="$(BW_SESSION="$session" bw get notes "$BROKER_BW_ITEM")"; then
	rc=0
else
	rc=$?
fi

if [ "$rc" -ne 0 ]; then
	echo "broker-bitwarden: bw get notes failed (exit ${rc}) for item '${BROKER_BW_ITEM}'; see the 'bw' diagnostic above, if any" >&2
	exit "$rc"
fi

# 空は「項目はあるが中身が空」という事故的な状態。パイプの先の取込側も空を
# 検出して落ちるが、原因に近いここで先に止めた方が切り分けが早い。
if [ -z "$dotenv" ]; then
	echo "broker-bitwarden: bitwarden item '${BROKER_BW_ITEM}' returned an empty note" >&2
	exit 1
fi

# stdout に出すのはここだけ。取り出した値をファイル・ログ・他のディスク
# リプタへ書く経路は用意しない。
printf '%s\n' "$dotenv"
