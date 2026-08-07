#!/usr/bin/env bash
#
# broker-macos-keychain.sh — macOS Keychain を使った broker の参照実装
#
# broker は差し替え可能である。ここで定義する契約さえ満たせば、Bitwarden CLI
# （broker-bitwarden.sh）や 1Password CLI（`op read`）等、別の実装に差し替えて
# よい。どの broker を標準とするかは未決事項である。これはあくまで macOS
# 向けの一実装。
#
# --- broker 契約 --------------------------------------------------------------
#   1. dotenv 形式（KEY=value の行）を stdout に出力する
#   2. 保管中の実体が不揮発ストレージ上で平文でない
#   3. 取得時に OS レベルの認可（パスワード / Touch ID プロンプト）が働く
#   4. 非対話環境で認可を得られない場合は非ゼロ終了する
#   5. stdout 以外へ secret を出さない
#
# --- セットアップ（初回のみ、対話的に実行する） -------------------------------
#
#   Keychain の対話プロンプト（-w）は 1 行しか受け付けない。複数行の dotenv を
#   そのまま渡そうとすると、全体が 1 行に潰れて「最初の変数の値の一部」として
#   取り込まれる（実測）。そこで dotenv 全文を base64 で 1 行に畳んでから
#   格納し、このスクリプトが取り出し時に復元する。
#
#   1. dotenv 全文を base64 にしてクリップボードへ。端末でそのまま実行し、
#      KEY=value を行ごとに打ち込んで（またはパスワードマネージャから貼って）
#      最後に Ctrl-D。stdin 入力なのでシェル履歴に残らず、ファイルにも
#      書かない:
#
#        base64 | pbcopy
#        GH_TOKEN=xxxx
#        DOTENV_PRIVATE_KEY_PROD=xxxx
#        ^D
#
#   2. Keychain へ登録。プロンプトが出たら base64 の 1 行を貼り付ける:
#
#        security add-generic-password \
#          -s "<project>-prod-env" \
#          -a "$(whoami)" \
#          -T "" \
#          -w
#
#      -T "" は「この項目を無認可で読めるアプリを無しにする」指定。これを
#      省くと項目を作成したアプリが信頼リストに入り、以後の取り出しが
#      認可プロンプトなしで通ることがある。取得のたびに認可を求めるのが
#      この broker の契約なので、明示的に空にしておく。
#
#   3. クリップボードに base64（= secret 本体）が残っているので空にする。
#      クリップボード履歴ツールを使っている場合はそちらの履歴からも消すこと:
#
#        pbcopy < /dev/null
#
#   -s に渡した文字列を、このスクリプトを呼ぶ側で BROKER_KEYCHAIN_SERVICE
#   として渡す（例: `BROKER_KEYCHAIN_SERVICE="<project>-prod-env"
#   PROD_BROKER=... prod-run.sh ...` や、プロジェクト別の 1 行ラッパーで
#   export する）。
#
#   登録後、Keychain Access.app（macOS 15 以降は Spotlight で
#   「キーチェーンアクセス」。「パスワード」App には generic password は
#   表示されない）でこの項目を開き「アクセス制御」タブから ACL を選べる。
#   実務上の選択肢はおおむね次の二つ:
#
#     - 都度確認 / Touch ID を要求する — アクセスのたびにユーザー
#       プレゼンスの確認が入る。broker 契約 3 が求めているのはこちら。
#
#     - 「常に許可」 — 一度許可すると以降は無確認でアクセスできる。
#
#   ⚠️ 「常に許可」を選ぶと、この項目の暗号化は実質的な認証境界としては
#   機能しなくなる。同一ホストユーザーの権限で走る任意のプロセスが、
#   認証プロンプトなしにこの secret を取り出せるようになるためである。
#   dev container からは直接は呼べない（Docker socket が
#   無く、コンテナ内 UID もホストユーザーとは別の名前空間にある）が、
#   コンテナ脱獄・ホストとの連携機能の突破・dev が書いたホスト側スクリプト
#   のいずれかを経由すれば決定的な穴になる。可能な限り「常に許可」は避け、
#   都度確認または Touch ID（ユーザープレゼンス必須）を選ぶこと。最終的な
#   選択は運用者の裁量に委ねるが、そのリスクは上記の通り。
#
set -euo pipefail

# サービス名にデフォルト値は持たせない。決め打ちの名前を置くと、複数
# プロジェクトを同一ホストで扱う際に取り違えて別プロジェクトの鍵束を
# 注入してしまう事故を機構的に防げなくなる。
if [ -z "${BROKER_KEYCHAIN_SERVICE:-}" ]; then
	echo "broker-macos-keychain: BROKER_KEYCHAIN_SERVICE is required (the -s value used at 'security add-generic-password' setup time)" >&2
	exit 1
fi

# security の失敗（項目が見つからない・ユーザーが認可を拒否した・
# 非対話環境で確認ダイアログを出せない、等）を必ず非ゼロで伝播させる
# （broker 契約 4）。`if cmd; then ... else rc=$?; fi` の形にするのは、
# `set -e` 下でも代入の成否をこちらで判定してから続きの処理を書ける
# ようにするため（if の条件式は -e の対象外）。
# security 自身の診断メッセージ（項目なし・キャンセル等の定型文で、
# secret 本体を含まない）はコマンド置換の対象外（標準エラーのみ）なので
# そのままこのスクリプトの標準エラーへ流れる。secret を含みうる標準出力
# だけを変数に取り込む。
if b64="$(security find-generic-password -s "${BROKER_KEYCHAIN_SERVICE}" -w)"; then
	rc=0
else
	rc=$?
fi

if [ "$rc" -ne 0 ]; then
	echo "broker-macos-keychain: security find-generic-password failed (exit ${rc}) for service '${BROKER_KEYCHAIN_SERVICE}'; see the 'security' diagnostic above, if any" >&2
	exit "$rc"
fi

if [ -z "$b64" ]; then
	echo "broker-macos-keychain: keychain item '${BROKER_KEYCHAIN_SERVICE}' returned an empty value" >&2
	exit 1
fi

# 格納形式は base64（上記セットアップ手順）。復号に失敗した場合は、平文の
# まま格納した項目である可能性が高いので、直し方まで含めて案内する。
# エラーメッセージに取り出した値そのものは出さない。
if ! dotenv="$(printf '%s' "$b64" | base64 --decode 2>/dev/null)"; then
	echo "broker-macos-keychain: keychain item '${BROKER_KEYCHAIN_SERVICE}' is not valid base64. Store the dotenv text base64-encoded — the interactive -w prompt accepts only a single line, so a multi-line dotenv must be folded first. See the setup notes at the top of this script." >&2
	exit 1
fi

if [ -z "$dotenv" ]; then
	echo "broker-macos-keychain: keychain item '${BROKER_KEYCHAIN_SERVICE}' decoded to an empty value" >&2
	exit 1
fi

# stdout に出すのはここだけ。取り出した値をファイル・ログ・他のディスク
# リプタへ書く経路は用意しない。
printf '%s\n' "$dotenv"
