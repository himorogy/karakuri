#!/usr/bin/env bash
#
# broker-macos-keychain-set.sh — broker-macos-keychain.sh が読む Keychain 項目の登録・更新
#
# dotenv 全文を stdin から受け取り、base64 で 1 行に畳んで Keychain へ格納する。
# 手作業の「base64 | pbcopy → プロンプトへ貼り付け → クリップボード掃除」という
# 迂回をなくすためのセットアップ用ツール。クリップボードを一切経由しない。
#
# 使い方（初回登録・更新とも同じ）:
#
#   BROKER_KEYCHAIN_SERVICE=env/<project>/dev broker-macos-keychain-set.sh
#   （KEY=value を行ごとに入力し、最後に Ctrl-D。パスワードマネージャからの
#    貼り付けでも可。stdin 入力なのでシェル履歴には残らない）
#
# ファイルからの流し込み（< secrets.env）は勧めない。ホストの不揮発ディスクに
# 平文を置かないことがこの仕組み全体の前提であり、流し込み元ファイルがその
# 前提を破る。
#
# 実装メモ:
#   - secret を含む値はコマンドライン引数に載せない。argv は同一ユーザーの
#     任意のプロセスから ps で見える。`security -i`（対話モード）の stdin へ
#     コマンドごと流し込むことで、値が argv を一度も通らない。base64 の
#     文字集合（A-Za-z0-9+/=）は引用符・空白を含まないため、コマンド文字列
#     への埋め込みで壊れない。
#   - -U により既存項目は上書き更新になる（「already exists」で止まらない）。
#     ただし ACL（アクセス制御）は既存項目のものがそのまま維持される。ACL を
#     作り直したい場合は、いったん削除してから登録し直す:
#       security delete-generic-password -s "<service>"
#   - -T "" は「この項目を無認可で読めるアプリを無しにする」指定（新規作成時
#     のみ効く）。取得のたびに認可プロンプトを出すという broker の契約を
#     守るためのもの。
#   - dotenv として妥当かどうかの検査はここでは行わない。何を正しい dotenv と
#     見なすかの判定はコンテナ側の取込スクリプト 1 実装に集約してあり、ここに
#     軽い複製を置くと判定が二つに割れる。壊れた内容を入れた場合は、注入時に
#     取込側が行番号つきで音を立てて落ちる。
#
set -euo pipefail

if [ -z "${BROKER_KEYCHAIN_SERVICE:-}" ]; then
	echo "broker-macos-keychain-set: BROKER_KEYCHAIN_SERVICE is required (the service name the broker will read back)" >&2
	exit 1
fi

# サービス名は security -i へ流すコマンド文字列に埋め込むため、引用符等が
# 混ざるとコマンドとして壊れる。壊れた名前で黙って別の何かが起きるより、
# 使える文字を狭く固定して先に落とす。
case "$BROKER_KEYCHAIN_SERVICE" in
*[!A-Za-z0-9/._-]*)
	echo "broker-macos-keychain-set: BROKER_KEYCHAIN_SERVICE may only contain A-Za-z0-9 / . _ - (got: '${BROKER_KEYCHAIN_SERVICE}')" >&2
	exit 1
	;;
esac

if [ -t 0 ]; then
	echo "broker-macos-keychain-set: type the dotenv lines (KEY=value, one per line), then press Ctrl-D:" >&2
fi

b64="$(base64)"

if [ -z "$b64" ]; then
	echo "broker-macos-keychain-set: empty input; nothing stored" >&2
	exit 1
fi

acct="$(whoami)"

printf 'add-generic-password -U -s "%s" -a "%s" -T "" -w "%s"\n' \
	"$BROKER_KEYCHAIN_SERVICE" "$acct" "$b64" | security -i

# 取得時の認可プロンプトが「項目 ACL の確認」と「partition list の確認」の
# 2 層で 2 回出ることを実測した。partition list は macOS Sierra 以降の
# 第 2 認可層で、どの署名元のツールがこの項目に触れるかを持つ（CLI 作成は
# apple-tool:、GUI 作成は apple: が付き、もう一方からのアクセスに追加の
# 確認が出る）。両方を載せておくと、broker の取得時プロンプトは項目 ACL の
# 1 回だけになる（実測）。ACL の都度確認は残るので、取得のたびに認可を
# 求めるという broker の契約は弱まらない。
# この設定コマンド自体はキーチェーンのパスワードを 1 回要求する。
echo "broker-macos-keychain-set: setting the partition list so retrieval prompts once, not twice (you will be asked for the keychain password)" >&2
security set-generic-password-partition-list -S apple-tool:,apple: \
	-s "$BROKER_KEYCHAIN_SERVICE" -a "$acct" >/dev/null

# security -i（対話モード）が内部コマンドの失敗を終了コードへ反映しない
# 可能性を考慮し、格納の成否は broker で読み戻して確かめるよう案内する
# （認可プロンプトが 1 回出る）。値は端末に出さない。
echo "broker-macos-keychain-set: stored item '${BROKER_KEYCHAIN_SERVICE}' (dotenv folded to base64)" >&2
echo "broker-macos-keychain-set: verify with: BROKER_KEYCHAIN_SERVICE='${BROKER_KEYCHAIN_SERVICE}' broker-macos-keychain.sh >/dev/null && echo ok" >&2
