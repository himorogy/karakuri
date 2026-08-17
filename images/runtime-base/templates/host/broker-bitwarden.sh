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
#   bw CLI のインストールは native 実行ファイルを推奨する。broker はホスト側で
#   最も特権的な部品（マスターパスワードを握り、全鍵束を stdout に出す）で
#   あり、その取得経路は狭く・固定的に保つ。npm 版（npm install -g
#   @bitwarden/cli）は install 時に postinstall スクリプトが走り、依存木が
#   深く、update で黙って版が動く。native 版は単一ファイルで、版は自分で
#   上げるまで動かない:
#
#     # bitwarden/clients の GitHub Releases（cli-v* タグ）から取得し、
#     # リリースアセットの SHA-256 と照合してから固定パスへ置く
#     curl -LO https://github.com/bitwarden/clients/releases/download/cli-v<VER>/bw-macos-<VER>.zip
#     shasum -a 256 bw-macos-<VER>.zip     # 照合
#     unzip bw-macos-<VER>.zip && mv bw ~/.local/bin/bw && chmod +x ~/.local/bin/bw
#     xattr -d com.apple.quarantine ~/.local/bin/bw   # 初回実行が隔離で止まる場合
#
#   npm 版を使う場合は、取得物のハッシュ照合と版の固定を自分で行うこと
#   （nodenv 等の環境では node 版ごとのインストールになり、node を
#   切り替えると消える点にも注意）。
#
#   bw login                       # アカウントへのログイン（初回のみ）
#   bw sync                        # vault キャッシュの更新（初回の取得分）
#
#   Bitwarden 側に Secure Note を 1 項目作り、名前を「env/<project>/<環境>」の
#   ように付ける（例: env/radwisp/dev）。中身は dotenv 形式のテキスト全文
#   （複数行の KEY=value をまとめたもの）。この項目名を、呼ぶ側で
#   BROKER_BW_ITEM として渡す。
#
#   このスクリプトは取得の直前に `bw sync` を 1 回実行するので、項目の内容を
#   Bitwarden 側で更新した後にローカルの vault キャッシュが古いまま旧値を
#   返す、という事故は通常は起きない（sync が失敗した場合を除く。下記）。
#   `BROKER_BW_SYNC=0` を設定すると sync をしない。
#
# --- 使い方 -------------------------------------------------------------------
#
#   # 項目名を都度渡す（項目名は秘匿情報ではないので環境変数でよい）
#   BROKER_BW_ITEM=env/radwisp/dev \
#     DEV_BROKER=~/.local/bin/broker-bitwarden.sh DEV_COMPOSE_PROJECT=... dev-inject.sh
#
#   # 複数項目のマージ: カンマ区切りで並べる。unlock は 1 回だけ（マスター
#   # パスワードのプロンプトも 1 回）で、並び順のまま連結して出力する。
#   # 取込側は同名の鍵を後から来た値で上書きするため、「チーム共有の鍵束を
#   # 先に・個人の鍵束を後に」並べると個人側が勝つ:
#   BROKER_BW_ITEM=env/radwisp/shared/dev,env/radwisp/dev ...
#   #（この規約上、項目名にカンマは使えない）
#
#   # またはプロジェクト別に 1 行のラッパーを置いて固定する
#   #   ~/.local/bin/radwisp-dev-broker:
#   #     #!/usr/bin/env bash
#   #     BROKER_BW_ITEM=env/radwisp/shared/dev,env/radwisp/dev \
#   #       exec "$HOME/.local/bin/broker-bitwarden.sh"
#
set -euo pipefail

# bw の実体は BROKER_BW_BIN で絶対パス指定できる（既定は PATH 解決）。
# PATH 任せだと、バージョンマネージャの shim 等、PATH 上で先に来たものが
# 勝つ。broker が呼ぶバイナリは固定的であってほしいので、上記の固定パスへ
# 置いた native 版を使う場合はここで名指しする:
#   BROKER_BW_BIN="$HOME/.local/bin/bw"
bw_bin="${BROKER_BW_BIN:-bw}"

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
session=$("$bw_bin" unlock --raw)

# 取得の成否によらず、このスクリプトを抜けるときには必ず lock する。
# lock の失敗で本来の終了コードを上書きしない。
trap 'BW_SESSION="$session" "$bw_bin" lock >/dev/null 2>&1 || true' EXIT

# 取得の直前に vault キャッシュを更新する。sync はセッションを要求するので
# unlock より後、複数項目でもプロンプトを増やさないよう get notes より前に
# 1 回だけ行う。BROKER_BW_SYNC=0 で無効化できる（オフライン環境で毎回
# sync を試みてタイムアウト待ちになるのを避けたい場合など）。
#
# 失敗しても止めない。ローカルキャッシュから取れる鍵も、それ自体は正当に
# 発行された鍵であり、Bitwarden 側で失効済みなら下流の認証失敗として
# 別途現れる。ここで止めると、ネットワークの無い場所では sync が必ず失敗し、
# prod 作業そのものが一切できなくなる。ただし黙って古いキャッシュへ
# フォールバックすると「鍵を回転したのに古い値が使われた」に誰も気付けない
# ので、警告は必ず出す。
#
# stdout は secret の搬送路そのものなので、bw sync 自身の出力
# （"Syncing complete." 等）が紛れ込まないよう捨てる。診断は stderr に
# 出るものなのでそのまま流す（get notes と同じ扱い）。
if [ "${BROKER_BW_SYNC:-1}" != "0" ]; then
	if ! BW_SESSION="$session" "$bw_bin" sync >/dev/null; then
		echo "broker-bitwarden: bw sync failed; continuing with the local vault cache, which may return stale values until the next successful sync (set BROKER_BW_SYNC=0 to skip this step)" >&2
	fi
fi

# カンマ区切りの各項目を並び順のまま取得して連結する。1 項目でも失敗
# （見つからない・同名複数・空）したら全体を非ゼロで止める — 部分的な
# 鍵束で先へ進むと、欠けた分が下流の認証失敗として遅れて出るだけなので、
# 原因（どの項目か）を名指しできるここで止める。bw 自身の診断メッセージは
# stderr へ出るのでそのまま流れる。secret を含みうる stdout だけを変数に
# 取り込む。
# 空の項目名（先頭・末尾・連続のカンマ）は分割前の文字列で検査する。
# read -a は末尾の区切り文字が作る空要素を黙って落とすため、分割後の
# 検査では「shared,」のような打ち損じを検出できない。
case "$BROKER_BW_ITEM" in
,* | *, | *,,*)
	echo "broker-bitwarden: BROKER_BW_ITEM contains an empty item name (stray comma?): '${BROKER_BW_ITEM}'" >&2
	exit 1
	;;
esac

dotenv=""
IFS=',' read -r -a items <<<"$BROKER_BW_ITEM"
for item in "${items[@]}"; do
	if chunk="$(BW_SESSION="$session" "$bw_bin" get notes "$item")"; then
		rc=0
	else
		rc=$?
	fi

	if [ "$rc" -ne 0 ]; then
		echo "broker-bitwarden: bw get notes failed (exit ${rc}) for item '${item}'; see the 'bw' diagnostic above, if any" >&2
		exit "$rc"
	fi

	# 空は「項目はあるが中身が空」という事故的な状態。パイプの先の取込側も
	# 空を検出して落ちるが、原因に近いここで先に止めた方が切り分けが早い。
	if [ -z "$chunk" ]; then
		echo "broker-bitwarden: bitwarden item '${item}' returned an empty note" >&2
		exit 1
	fi

	# note の末尾に改行が無くても項目間の境界が消えないよう、必ず改行で
	# 継ぎ足す（コマンド置換が末尾改行を剥がすので、二重にはならない）。
	dotenv="${dotenv}${chunk}
"
done

# stdout に出すのはここだけ。取り出した値をファイル・ログ・他のディスク
# リプタへ書く経路は用意しない。
printf '%s' "$dotenv"
