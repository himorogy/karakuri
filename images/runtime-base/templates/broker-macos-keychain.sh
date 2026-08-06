#!/usr/bin/env bash
#
# broker-macos-keychain.sh — macOS Keychain を使った broker の参照実装
#
# broker は差し替え可能である。ここで定義する契約さえ満たせば、1Password
# CLI（`op read`）や Bitwarden CLI（`bw get`）等、別の実装に差し替えて
# よい。どの broker を標準とするかは未決事項である。これはあくまで macOS
# 向けの一実装。
#
# --- broker 契約 --------------------------------------------------------------
#   1. dotenv 形式（KEY=value の行）を stdout に出力する
#   2. 保管中の実体が不揮発ストレージ上で平文でない
#   3. 取得時に OS レベルの認可（パスワード / Touch ID プロンプト）が働く
#   4. 非対話環境で認可を得られない場合は非ゼロ終了する
#
# --- セットアップ（初回のみ、対話的に実行する） -------------------------------
#
#   security add-generic-password \
#     -s "<project>-prod-env" \
#     -a "$(whoami)" \
#     -w
#
#   -s に渡した文字列を、このスクリプトを呼ぶ側で PROD_KEYCHAIN_SERVICE
#   として渡す（例: `PROD_KEYCHAIN_SERVICE="<project>-prod-env" prod-run.sh
#   ...` や、prod-run.sh を呼ぶさらに外側のラッパーで export する）。
#   -w を付けて実行すると、値の入力を対話的なプロンプト（シェル履歴に
#   平文が残らない）で求められる。求められる値は「dotenv 形式のテキスト
#   全文」（複数行の KEY=value をまとめたもの）で、それを 1 項目として
#   丸ごと Keychain に格納する。
#
#   登録後、Keychain Access.app でこの項目を開き「アクセス制御」タブから
#   ACL を選べる。実務上の選択肢はおおむね次の二つ:
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
# プロジェクトを同一ホストで扱う際に取り違えて別プロジェクトの prod 鍵を
# 注入してしまう事故を機構的に防げなくなる。
if [ -z "${PROD_KEYCHAIN_SERVICE:-}" ]; then
	echo "broker-macos-keychain: PROD_KEYCHAIN_SERVICE is required (the -s value used at 'security add-generic-password' setup time)" >&2
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
if dotenv="$(security find-generic-password -s "${PROD_KEYCHAIN_SERVICE}" -w)"; then
	rc=0
else
	rc=$?
fi

if [ "$rc" -ne 0 ]; then
	echo "broker-macos-keychain: security find-generic-password failed (exit ${rc}) for service '${PROD_KEYCHAIN_SERVICE}'; see the 'security' diagnostic above, if any" >&2
	exit "$rc"
fi

# 空文字は「項目はあるが値が空」という事故的な状態。パイプの先の
# entrypoint も空 secret を検出して落ちるが、broker 側で先に止めておいた
# 方が問題の切り分けが早い。secret の欠落が沈黙した成功にならないように
# するのがこの構成全体の要求であり、検出は早い段でも遅い段でもよいので
# はなく、原因に近い段で出す方が運用中に読める。
if [ -z "$dotenv" ]; then
	echo "broker-macos-keychain: keychain item '${PROD_KEYCHAIN_SERVICE}' returned an empty value" >&2
	exit 1
fi

# stdout に出すのはここだけ。取り出した値をファイル・ログ・他のディスク
# リプタへ書く経路は用意しない。
printf '%s\n' "$dotenv"
