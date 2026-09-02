#!/usr/bin/env bash
# =============================================================================
# verify-docker.sh — docker が要る検証項目の実行ハーネス
#
# images/runtime-base の設計 (docs/prod-secret-isolation-design.md) には
# docker / docker compose の実挙動に依存する未検証の前提がいくつも残っている
# (同ファイル §10、images/runtime-base/verification-record.md 参照)。この
# dev container には docker が無い — これは設計の前提条件そのものであり
# (dev container は Docker socket を持たない)、外さない。そのためこの
# スクリプトは docker のあるホストで実行する前提で書く。CI (ubuntu-latest)
# でも手元の macOS ホストでも同じスクリプトが走ることを狙っており、
# jq のような macOS に既定で入っていないツールには依存しない。
#
# 測定 (MEASURE) と表明 (ASSERT) を明確に分ける:
#
#   - MEASURE: 未確定の設計判断 (§4.2 の tmpfs 短縮形、/src の tmpfs 化) を
#     確定させるための観測。pass/fail 判定はしない。観測した事実をそのまま
#     出力する。個々のケースが失敗 (docker が非ゼロ終了する等) しても、
#     それ自体が観測結果なのでスクリプト全体は止めない。
#   - ASSERT: 設計上こうあるべきと確定している性質。落ちたらスクリプトは
#     最後に非ゼロ終了する (CI のジョブを赤くする)。個々の ASSERT が
#     失敗しても他の ASSERT / MEASURE の実行は続ける。
#
# 個々のケースの失敗でスクリプト自体が即死しないよう、判定はすべて
# measure() / assert() ヘルパーに閉じ込め、対象コマンドは
# `if value="$(cmd)"; then …` の形 (if の条件式は set -e の対象外) で
# 呼び出す。トップレベルの set -e はセットアップ (bare repo 作成、compose
# ファイル生成) だけを対象にしており、そこが失敗するのは環境が壊れている
# ことを意味するので素直に落ちてよい。
#
# 使い方:
#   RUNTIME_BASE_IMAGE=runtime-base:verify bash verify-docker.sh
#   bash verify-docker.sh runtime-base:verify
#
# pnpm test からは呼ばない (docker 前提のため)。ルート package.json の
# verify:docker スクリプトから直接叩く。
# =============================================================================
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: verify-docker.sh [image]

イメージ参照は第 1 引数か環境変数 RUNTIME_BASE_IMAGE で与える。

  bash verify-docker.sh runtime-base:verify
  RUNTIME_BASE_IMAGE=runtime-base:verify bash verify-docker.sh

docker と docker compose v2 (docker compose、ハイフン無し) が必要。
EOF
}

IMG="${1:-${RUNTIME_BASE_IMAGE:-}}"
if [ -z "$IMG" ]; then
	usage >&2
	exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
	echo "verify-docker: docker が見つからない。このスクリプトは docker のあるホストで実行すること。" >&2
	exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
	echo "verify-docker: docker compose (v2) が見つからない。" >&2
	exit 1
fi

# --- 記録用グローバル状態 ------------------------------------------------------
MEAS_LOG=()
ASSERT_LOG=()
ASSERT_PASS=0
ASSERT_FAIL=0

# measure <id> <label> <fn> [args...]
#
# <fn> の標準出力 (2>&1 で標準エラーも合流) を「観測事実」として記録する。
# <fn> が非ゼロ終了しても、それ自体が観測結果でありうるため
# (例: 「uid=1000,gid=1000,mode=0755 形がそもそも受け付けられるか」は
# 受け付けられなかった場合の docker のエラー出力こそが知りたい値)、
# ここでは pass/fail の判定を一切行わない。
#
# `if value="$("$@" 2>&1)"; then :; fi` は if の条件式なので、"$@" が
# 非ゼロ終了しても (このヘルパー自身の) set -e は発火しない。command
# substitution は対象コマンドの終了コードに関わらず標準出力を捕捉するため、
# 失敗時でも value には出力が残る。
measure() {
	local id="$1" label="$2"
	shift 2
	local value line
	if value="$("$@" 2>&1)"; then :; fi
	line="$(printf '%-3s %-70s : %s' "$id" "$label" "$value")"
	MEAS_LOG+=("$line")
	printf '%s\n' "$line"
}

# assert <id> <desc> <fn> [args...]
#
# <fn> が exit 0 なら ok、非ゼロなら FAIL として記録する。ここも同じ
# `if out="$("$@" 2>&1)"` の形で set -e から保護し、1 個のケースの失敗が
# スクリプト全体を落とさないようにする。最終的な非ゼロ終了は summary の
# 末尾でまとめて行う。
assert() {
	local id="$1" desc="$2"
	shift 2
	local out rc line
	rc=0
	out="$("$@" 2>&1)" || rc=$?
	if [ "$rc" -eq 0 ]; then
		line="$(printf 'ok   %s %s' "$id" "$desc")"
		ASSERT_PASS=$((ASSERT_PASS + 1))
	else
		line="$(printf 'FAIL %s %s (rc=%s) %s' "$id" "$desc" "$rc" "$out")"
		ASSERT_FAIL=$((ASSERT_FAIL + 1))
	fi
	ASSERT_LOG+=("$line")
	printf '%s\n' "$line"
}

# --- ハーネス前提の健全性ゲート ---------------------------------------------------
#
# 「全体に対する要求」: 個々のケースの失敗が「ハーネスの都合」(bare repo
# のマウント不備など、セットアップ段階の問題) なのか「測定対象の性質」
# (docker/dotenvx/git 自体の挙動) なのかを出力から区別できるようにする。
# バグ1 が典型例で、$SCRATCH がコンテナへ bind mount されていないと
# bare repo への fetch が全滅し、同じ git エラーが 10 箇所以上に並んで
# 読み取りに手間取った。
#
# HARNESS_GIT_OK は「bare repo がコンテナ内から実際に fetch/checkout
# できるか」の前提が生きているかを表すグローバルフラグ。preflight (M1
# セクション開始前) で一度だけ実測して確定させ、0 なら以降の bare repo
# fetch 依存ケース (M1 の compose 経由分 / M2 / M6 / A5 / A6 / A10 /
# A16 / B1〜B4) を実行せず SKIPPED として記録する。A11 (GIT_REF 未指定) は
# compose のパース時点で失敗が確定するため fetch の成否と無関係、A17 (broker
# 失敗の伝播) も broker 自体が secrets を一切渡さず失敗する経路なので
# fetch の成否と無関係 — この 2 つはゲートの対象に含めない。A35 (named
# volume の /src を tmpfs 自己検査が止める) と A36 (/run が tmpfs でない
# 構成) も、entrypoint が fetch より前の自己検査で終わる経路なので同様に
# ゲートの対象に含めない。A19〜A34 (出荷
# compose.prod.yaml の構造検証) は docker (compose config) は使うが bare
# repo は使わないため、そもそもこのゲートの対象にならない。
HARNESS_GIT_OK=1

# measure_git <id> <label> <fn> [args...]
# 前提が壊れていれば実行せず SKIPPED を記録する measure() のラッパー。
measure_git() {
	if [ "$HARNESS_GIT_OK" -eq 0 ]; then
		local id="$1" label="$2" line
		line="$(printf '%-3s %-70s : %s' "$id" "$label" "SKIPPED (harness setup failed: bare repo unreachable from container)")"
		MEAS_LOG+=("$line")
		printf '%s\n' "$line"
		return 0
	fi
	measure "$@"
}

# assert_git <id> <desc> <fn> [args...]
# 前提が壊れていれば実行せず SKIP を記録する assert() のラッパー。SKIP は
# ASSERT_PASS にも ASSERT_FAIL にもカウントしない (ハーネス側の不備を
# 測定対象の合否として扱わないため)。
assert_git() {
	if [ "$HARNESS_GIT_OK" -eq 0 ]; then
		local id="$1" desc="$2" line
		line="$(printf 'SKIP %s %s (harness setup failed: bare repo unreachable from container)' "$id" "$desc")"
		ASSERT_LOG+=("$line")
		printf '%s\n' "$line"
		return 0
	fi
	assert "$@"
}

# --- 後片付け -------------------------------------------------------------------
# 個々のテストが作る named volume / container は各テスト関数の中で
# --rm や明示的な docker volume rm を使って自己完結的に片付ける (measure /
# assert は command substitution 経由でサブシェル実行になるため、テスト
# 関数の中でグローバルな配列に登録する方式は使えない)。ここでのトップ
# レベルの trap は SCRATCH ディレクトリの削除だけを担う。
SCRATCH="$(mktemp -d)"
cleanup() {
	rm -rf "$SCRATCH" 2>/dev/null || true
}
trap cleanup EXIT

# コンテナへ bind mount する compose ファイル側の ${SCRATCH_DIR} 補間用。
# docker compose はファイルをパースする時点で「docker compose を起動した
# シェルの環境」を見て ${...} を展開するため (compose_run() のコメント
# 参照)、ここで export しておけば以降の全 docker compose 呼び出しで
# 単一の SCRATCH パスがそのままコンテナ内パスとしても使える
# (ホスト側とコンテナ側でパスを分けない = GIT_REPO の file:// URL を
# そのまま使い回せる、というバグ1の直し方に合わせている)。
export SCRATCH_DIR="$SCRATCH"

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPTS_DIR="$SCRATCH/scripts"
mkdir -p "$SCRIPTS_DIR"

echo "=== setup ==="
echo "image: $IMG"
echo "repo root: $REPO_ROOT"
echo "scratch: $SCRATCH"

# --- テスト用 bare repo ---------------------------------------------------------
# GIT_REPO に file:// URL を渡すことで、ネットワークにもトークンにも依存
# せず fetch/checkout の経路をコンテナ内から実際に走らせられる
# (images/runtime-base/tests/entrypoint.test.sh と同じ考え方)。2 コミット
# 用意するのは M6 (N-1: ref 汚染) が「別コミットへのローカルタグ」を必要と
# するため。
TEST_BARE_DIR="$SCRATCH/test-bare.git"
TEST_WORK_DIR="$SCRATCH/test-work"
git init -q --bare "$TEST_BARE_DIR"
git init -q "$TEST_WORK_DIR"
git -C "$TEST_WORK_DIR" config user.email "verify@example.com"
git -C "$TEST_WORK_DIR" config user.name "verify"
printf 'hello\n' >"$TEST_WORK_DIR/file.txt"
git -C "$TEST_WORK_DIR" add file.txt
git -C "$TEST_WORK_DIR" commit -q -m commit1
git -C "$TEST_WORK_DIR" remote add origin "$TEST_BARE_DIR"
git -C "$TEST_WORK_DIR" push -q origin HEAD:refs/heads/main
TEST_COMMIT="$(git -C "$TEST_WORK_DIR" rev-parse HEAD)"
printf 'world\n' >"$TEST_WORK_DIR/file.txt"
git -C "$TEST_WORK_DIR" commit -q -am commit2
git -C "$TEST_WORK_DIR" push -q origin HEAD:refs/heads/main
TEST_COMMIT2="$(git -C "$TEST_WORK_DIR" rev-parse HEAD)"

# --- このリポジトリ自身の bare mirror (M2: pnpm install --frozen-lockfile 用) ---
# pnpm-lock.yaml を持つ実在のリポジトリで frozen-lockfile install が
# read_only + tmpfs 下で完走するかを見るため、テスト材料にはこのリポジトリ
# 自身を使う (タスク指示のとおり)。
SELF_BARE_DIR="$SCRATCH/self-bare.git"
git clone -q --bare --no-hardlinks "$REPO_ROOT" "$SELF_BARE_DIR"
SELF_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"

# バグ1: GitHub Actions の actions/checkout は detached HEAD で checkout
# する。REPO_ROOT が detached HEAD の場合、そこから作った bare clone は
# refs/heads/* を一切持たない (detached HEAD 自体は clone 先の HEAD には
# なるが、どの refs/heads/* にも属さない)。prod-entrypoint.sh の
# `git fetch --tags --prune origin` は既定 refspec
# (+refs/heads/*:refs/remotes/origin/*) なので、ブランチ ref が無ければ
# 何も fetch されず、コンテナ内の repo に SELF_COMMIT が存在しないまま
# `checkout --detach` が `fatal: reference is not a tree` で落ちる
# (M2 全滅の原因)。SELF_COMMIT を指すブランチ ref を明示的に作って
# fetch 対象にする。test bare repo (TEST_BARE_DIR) が影響を受けないのは
# push 時に明示的に refs/heads/main を作っているため。
#
# `git branch -f` ではなく `update-ref` を使う: bare repo に対する
# ref 操作そのもの (HEAD やカレントブランチの状態に依存しない、単なる
# refs/heads/main の作成/更新) であることを明確にするため。
git --git-dir="$SELF_BARE_DIR" update-ref refs/heads/main "$SELF_COMMIT"

echo "test bare repo: $TEST_BARE_DIR (commit1=$TEST_COMMIT commit2=$TEST_COMMIT2)"
echo "self bare repo: $SELF_BARE_DIR (commit=$SELF_COMMIT)"

# バグ1: 次に同じ問題 (bare repo にブランチ ref が無くて fetch が全滅する)
# が起きたら、この show-ref の出力を見れば一目で分かるようにしておく。
echo "test bare repo refs (git --git-dir=$TEST_BARE_DIR show-ref):"
git --git-dir="$TEST_BARE_DIR" show-ref || echo "(show-ref: refs が無い)"
echo "self bare repo refs (git --git-dir=$SELF_BARE_DIR show-ref):"
git --git-dir="$SELF_BARE_DIR" show-ref || echo "(show-ref: refs が無い)"

# --- コンテナ (uid 1000) から $SCRATCH 配下を読めるようにする -------------------
# バグ1: $SCRATCH はランナーのユーザー (ubuntu-latest では通常 uid 1001 の
# "runner"。dev container の node と同じ uid 1000 とは限らない) の所有で
# 作られる一方、コンテナは uid 1000 で走る。素の bind mount (:ro) だけでは
# 「コンテナから見えるが、そのユーザーには読めない」状態になりうるため、
# world 読み取り + 実行 (traverse) 権限を明示的に付与する。
#
# 加えて、file:// fetch は git-upload-pack をコンテナ内で起動するが、
# git 2.35+ の safe.directory (CVE-2022-24765 対策) は「実行ユーザーと
# リポジトリ所有者の uid が一致しない」bare repo を "detected dubious
# ownership" として拒否する。$SCRATCH はランナーのユーザー所有で、コンテナは
# uid 1000 で走るため必ず踏む (2026-08-06 の CI 1 回目で実測)。
#
# GIT_CONFIG_COUNT / GIT_CONFIG_KEY_0 / GIT_CONFIG_VALUE_0 で
# safe.directory を渡しても**効かない**。git は safe.directory を
# protected configuration (system / global) からしか読まない。-c や
# GIT_CONFIG_* はコマンドライン相当のスコープとして扱われ、意図的に無視
# される — そうしないと、信頼できないリポジトリ自身がこの検査を無効化
# できてしまうため。CI 1 回目はこれで preflight ごと落ちた。
#
# 効くのは GIT_CONFIG_GLOBAL で、これは「global スコープの config ファイル
# の場所」を差し替えるので safe.directory が読まれる。読み取り専用で
# マウント済みの $SCRATCH 上に置き、各コンテナへ環境変数で渡す。
#
# なお、この dubious ownership 自体はハーネス固有の事情である。実運用の
# GIT_REPO は https URL であり、ローカルの所有者検査は関与しない。
chmod -R a+rX "$SCRATCH"

SAFE_GITCONFIG="$SCRATCH/gitconfig-safe"
cat >"$SAFE_GITCONFIG" <<'EOF'
[safe]
	directory = *
EOF
chmod a+r "$SAFE_GITCONFIG"
export SAFE_GITCONFIG

# --- compose ファイル生成 --------------------------------------------------------
# templates/host/compose.prod.yaml は変更しない (rev.5 確定後にオーケストレーターが
# 直す)。ここでは検証用の一時コピーを mktemp 配下に生成する。プレースホルダ
# __IMAGE__ を実イメージ参照へ sed で差し替える方式は、entrypoint.test.sh /
# shim.test.sh の「テストごとに一意な tmpdir へ sed で書き換えたコピーを使う」
# スタイルを踏襲している。
#
# quoted heredoc (<<'EOS') を使う理由: compose ファイルの中身には
# ${GIT_REPO:?GIT_REPO is required} のような、docker compose 自身に展開させ
# たい ${...} 構文が含まれる。unquoted heredoc だとこのスクリプト自身の
# シェルがその場で展開しようとし、GIT_REPO 未設定なら `:?` でこのスクリプト
# 自体が即座に落ちてしまう。

# --- A: 出荷 templates/host/compose.prod.yaml の構造検証 (docker が要る、jq を使う) --
#
# 下の compose-current.yaml 等は全て自前生成物であり、実際に配布する
# templates/host/compose.prod.yaml 自身は一度も検証されていなかった。自前生成物
# とのずれ (tmpfs のオプション、read_only、user、ulimits、logging 等) が
# 入り込んでも検出できない。
#
# 最初の実装は js-yaml で YAML テキストをパースしていたが、js-yaml はこの
# リポジトリの直接依存ではなく node_modules/.pnpm 配下の transitive
# dependency でしかない。このスクリプトを実際に実行する CI
# (runtime-base-verify.yml) は docker イメージのビルドと検証だけを目的と
# しており `pnpm install` を一切行わないため node_modules 自体が存在せず、
# A19〜A34 相当のケースが「js-yaml が見つからない」で恒常的に FAIL する
# ことが分かった (この dev container で node_modules/.pnpm を使って実際に
# 確認済み。CI では未確認だが、CI が pnpm install をしないこと自体は
# runtime-base-verify.yml を読んで確認済み)。
#
# 依存を増やす (CI に pnpm install を足す) のではなく無くす方向で直す:
# `docker compose -f <file> config --format json` + `jq` に置き換える。
# このスクリプトは元から docker 前提であり (冒頭で docker / docker compose
# の存在を必須にしている)、jq は ubuntu-latest ランナーに標準で入って
# いる。加えて `docker compose config` は「compose が実際にどう解釈するか」
# を返すため、YAML のテキストを見るより強い検査になる — ファイルを消費する
# 当のパーサで検証できる。
#
# `config` は `${GIT_REPO:?…}` / `${GIT_REF:?…}` を実際に補間するため、
# 実行のたびにダミー値を GIT_REPO / GIT_REF として渡す (下の
# compose_prod_config()。compose_run() と同じ「コマンドの前置きで環境変数
# を渡す」形)。ダミー値は明らかにダミーだと分かる文字列にして、万一出力に
# 紛れ込んでも実在のリポジトリと誤認しないようにする。
#
# A19〜A34 は docker さえあれば動き、bare repo は要らない。preflight
# (bare repo の到達性、この下の「harness preflight」参照) の成否には
# 一切依存させない — 常に assert() を使い、assert_git() は使わない。
if ! command -v jq >/dev/null 2>&1; then
	echo "verify-docker: jq が見つからない。A19〜A34 (出荷 compose.prod.yaml の構造 ASSERT) は jq が前提。" >&2
	exit 1
fi

COMPOSE_PROD_YAML="$REPO_ROOT/images/runtime-base/templates/host/compose.prod.yaml"

# compose_prod_config
# 出荷ファイルを `docker compose config --format json` で解決した JSON を
# 標準出力へ返す。GIT_REPO/GIT_REF はダミー値 (`:?` の補間さえ通ればよく、
# config はパースと変数展開だけを行い、コンテナは起動しないので実際に
# fetch できる値である必要はない)。
compose_prod_config() {
	GIT_REPO="verify-dummy-git-repo-do-not-use" GIT_REF="verify-dummy-git-ref-do-not-use" \
		docker compose -f "$COMPOSE_PROD_YAML" config --format json
}

# tmpfs_entries_or_fail
# services.prod.tmpfs を `docker compose config` の JSON から取り出し、
# 想定した「文字列の配列 (短縮記法 "<path>:<opts>" のまま)」であることを
# 確認してから、その JSON 配列 (compact 1 行) を標準出力へ返す。
#
# 未確認: `docker compose config --format json` が tmpfs エントリを
# object 形 (例: {target: "/src", tmpfs: {size: ...}}) へ正規化する
# 可能性を、docker の無いこの環境では実行して確認できていない。
# compose-spec のドキュメント上、`tmpfs:` はサービスの短縮記法であって
# `volumes:` のような長形式スキーマ (type/source/target/...) を持たない
# ため文字列のまま残る可能性が高いと考えているが未確認のままにしている。
# 仮に object 形へ正規化されていた場合、uid=/gid=/exec のような
# compose-spec の tmpfs 長形式に存在しないオプションがどこに (あるいは
# 消えて) 現れるかは全くの未知数なので、それを推測でパースして「たまたま
# 一致したことにする」よりも、想定と違う形が来た時点でここで明確な
# メッセージ付きで失敗させる方が安全と判断した。
tmpfs_entries_or_fail() {
	local json entries
	json="$(compose_prod_config)" || return 1
	entries="$(printf '%s' "$json" | jq -c '.services.prod.tmpfs // []')"
	if ! printf '%s' "$entries" | jq -e '[.[] | type] | all(. == "string")' >/dev/null 2>&1; then
		echo "services.prod.tmpfs が想定した文字列配列 (短縮記法) でない (docker compose config が object 形へ正規化した可能性。要確認・要更新): $entries" >&2
		return 1
	fi
	printf '%s\n' "$entries"
}

# --- B: 出荷 templates/host/compose.prod.yaml からの最小派生 (docker が要る) --------
#
# A が構造の表明 (静的パース) であるのに対し、B は実際にコンテナを起動して
# entrypoint が完走することを見る。「派生」であって「書き直し」ではない —
# 出荷ファイルそのものを cp して sed で書き換える。加えてよい変更は次の
# 3 点だけ (タスク指示のとおり):
#   1. image: を実イメージ参照 ($IMG) へ差し替える (プレースホルダ digest は
#      実在しないため pull できない)。
#   2. bare repo (file:// URL) を読むための bind mount を volumes: として
#      追加する ($SCRATCH を読み取り専用で)。
#   3. GIT_CONFIG_GLOBAL を environment: に追加する (safe.directory 対策。
#      compose-current.yaml 等、他の compose ファイルと同じ値)。
# 他は一切変えない。sed 置換のたびに「置換が実際に効いたか」を grep で検証
# してから先へ進む — 効かないまま素通りすると、B が「出荷ファイルを検証して
# いる」つもりで実は壊れた/変化していないファイルを検証してしまう。
COMPOSE_SHIPPED="$SCRATCH/compose-shipped.yaml"
cp "$COMPOSE_PROD_YAML" "$COMPOSE_SHIPPED"

# 変更 1/3: image:
# 出荷ファイルの image: 行は単独行 (`    image: ghcr.io/...`) なので行全体を
# 置換する。$IMG 自体は展開させたいので二重引用符の sed スクリプトを使う。
sed -i "s#^\(    image:\).*#\1 $IMG#" "$COMPOSE_SHIPPED"
if grep -q 'REPLACE_WITH_ACTUAL_DIGEST' "$COMPOSE_SHIPPED"; then
	echo "verify-docker: compose-shipped.yaml の image: 置換が効いていない (プレースホルダが残っている)。B の派生セットアップが壊れている。" >&2
	exit 1
fi
if ! grep -qF "    image: $IMG" "$COMPOSE_SHIPPED"; then
	echo "verify-docker: compose-shipped.yaml の image: が期待どおりに書き換わっていない。B の派生セットアップが壊れている。" >&2
	exit 1
fi

# 変更 2/3: GIT_CONFIG_GLOBAL を environment: に追加。
# `GIT_REF: ...` の行は出荷ファイルに一箇所しか無い (services.prod.environment
# 直下) ので、その直後に 1 行差し込む。単引用符で丸ごと囲み、${SAFE_GITCONFIG}
# はこのスクリプトのシェルに展開させず、docker compose 自身の展開に委ねる
# (他の compose-*.yaml と同じ書き方)。sed の s/// 置換テキスト中で改行を
# 挿入するには、埋め込む改行の直前にバックスラッシュを置く古典的な書き方が
# 要る (GNU/BSD どちらの sed でも動く移植性のためのイディオム)。
# SC2016: 単引用符は意図的。${SAFE_GITCONFIG} はこのスクリプトのシェルではなく
# docker compose に展開させたい。
# shellcheck disable=SC2016
sed -i 's/^\(      GIT_REF: .*\)$/\1\
      GIT_CONFIG_GLOBAL: ${SAFE_GITCONFIG}/' "$COMPOSE_SHIPPED"
# shellcheck disable=SC2016
if ! grep -qF '      GIT_CONFIG_GLOBAL: ${SAFE_GITCONFIG}' "$COMPOSE_SHIPPED"; then
	echo "verify-docker: compose-shipped.yaml への GIT_CONFIG_GLOBAL 追加が効いていない。B の派生セットアップが壊れている。" >&2
	exit 1
fi

# 変更 3/3: bare repo 用の bind mount を volumes: として追加。
# `    read_only: true` の直前に差し込む (services.prod 直下、他のトップ
# レベルキーと同じ 4-space インデント)。${SCRATCH_DIR} も同様に展開させない。
# SC2016: 単引用符は意図的 (上と同じ理由)。
# shellcheck disable=SC2016
sed -i 's/^\(    read_only: true\)$/    volumes:\
      - ${SCRATCH_DIR}:${SCRATCH_DIR}:ro\
\1/' "$COMPOSE_SHIPPED"
# shellcheck disable=SC2016
if ! grep -qF '      - ${SCRATCH_DIR}:${SCRATCH_DIR}:ro' "$COMPOSE_SHIPPED"; then
	echo "verify-docker: compose-shipped.yaml への bind mount 追加が効いていない。B の派生セットアップが壊れている。" >&2
	exit 1
fi

echo
echo "=== B: 出荷 compose.prod.yaml からの派生 diff (許される変更は image: / bind mount 追加 / GIT_CONFIG_GLOBAL 追加の 3 点のみ) ==="
diff -u "$COMPOSE_PROD_YAML" "$COMPOSE_SHIPPED" || true

# compose-current.yaml: templates/host/compose.prod.yaml と同一の tmpfs 記法
# (uid=1000,gid=1000,mode=...) + /src は named volume。M1 (compose 経由の
# uid= 形式受け入れ確認) / M6 (named volume 再利用時の N-1 / N-2) / A11 /
# A17 で使う。
# バグ1: bare repo (file:// URL) をコンテナ内の git から見えるように
# $SCRATCH をそのまま (ホスト側パス=コンテナ内パス) 読み取り専用で
# bind mount する。read_only: true は追加の bind mount を妨げない。
# GIT_CONFIG_GLOBAL は git の safe.directory を全許可にした config を
# global スコープとして読ませる (dubious ownership 対策。GIT_CONFIG_* 形式
# では効かない理由は $SCRATCH の chmod 直前のコメント参照)。
cat >"$SCRATCH/compose-current.yaml" <<'EOS'
volumes:
  prod-src:

services:
  prod:
    image: __IMAGE__
    entrypoint: ["/usr/local/bin/prod-entrypoint.sh"]
    working_dir: /src
    environment:
      GIT_REPO: ${GIT_REPO:?GIT_REPO is required}
      GIT_REF:  ${GIT_REF:?GIT_REF is required}
      GIT_CONFIG_GLOBAL: ${SAFE_GITCONFIG}
    volumes:
      - prod-src:/src
      - ${SCRATCH_DIR}:${SCRATCH_DIR}:ro
    read_only: true
    user: "1000:1000"
    tmpfs:
      - /run:uid=1000,gid=1000,mode=0755
      - /tmp:uid=1000,gid=1000,mode=1777
      - /out:uid=1000,gid=1000,mode=0755
      - /home/node:uid=1000,gid=1000,mode=0755
    ulimits:
      core: 0
    logging:
      driver: "none"
EOS
sed -i "s#__IMAGE__#$IMG#" "$SCRATCH/compose-current.yaml"

# compose-flat.yaml: 設計書 §4.2 が書いている「素の短縮形」
# (`tmpfs: ["/run", "/tmp", "/out", "/home/node"]`)。M1 の本題。tmpfs の
# 記法そのものは素の形のまま残す (M1 が測りたいのはこの形の挙動) が、
# bare repo を見るための bind mount と safe.directory はバグ1の対象な
# ので他の compose ファイルと同様に入れる。
cat >"$SCRATCH/compose-flat.yaml" <<'EOS'
volumes:
  prod-src:

services:
  prod:
    image: __IMAGE__
    entrypoint: ["/usr/local/bin/prod-entrypoint.sh"]
    working_dir: /src
    environment:
      GIT_REPO: ${GIT_REPO:?GIT_REPO is required}
      GIT_REF:  ${GIT_REF:?GIT_REF is required}
      GIT_CONFIG_GLOBAL: ${SAFE_GITCONFIG}
    volumes:
      - prod-src:/src
      - ${SCRATCH_DIR}:${SCRATCH_DIR}:ro
    read_only: true
    user: "1000:1000"
    tmpfs:
      - /run
      - /tmp
      - /out
      - /home/node
    ulimits:
      core: 0
    logging:
      driver: "none"
EOS
sed -i "s#__IMAGE__#$IMG#" "$SCRATCH/compose-flat.yaml"

# compose-src-tmpfs.yaml: M9-a/M9-b 専用 (bugfix で用途を絞った。旧: M2 も
# これを使っていた)。/src の tmpfs に `exec` を明示しない「現状形」で、M9-e
# (exec 付き) との比較対象という意味そのものが測定内容なので、ここに exec を
# 足してはならない (M9-d と同じ理由。M9 セクションのコメント参照: 「M9-e が
# exec 付き tmpfs で測り直す…M9-b はそのまま残す (exec を付ける前後の比較の
# ため)」)。
#
# prod-entrypoint.sh の自己検査 (rev.6 / codex 指摘 #6) は /src が noexec だと
# secrets 取込の直後で exit 1 するため、この compose を経由する呼び出しは
# 毎回そこで止まり、以降の git checkout / pnpm install には到達しない。
# M9-a/M9-b にとってはそれ自体が観測結果 (noexec だと動かない) だが、M2/M6 は
# tmpfs /src の他の性質 (df サイズ、git 操作の完走、ref 汚染が消えるか) を
# 見たいのであって noexec 自体を測りたいわけではないため、M2/M6 は
# compose-src-tmpfs-exec.yaml (下記) に切り替えた。
cat >"$SCRATCH/compose-src-tmpfs.yaml" <<'EOS'
services:
  prod:
    image: __IMAGE__
    entrypoint: ["/usr/local/bin/prod-entrypoint.sh"]
    working_dir: /src
    environment:
      GIT_REPO: ${GIT_REPO:?GIT_REPO is required}
      GIT_REF:  ${GIT_REF:?GIT_REF is required}
      GIT_CONFIG_GLOBAL: ${SAFE_GITCONFIG}
    volumes:
      - ${SCRATCH_DIR}:${SCRATCH_DIR}:ro
    read_only: true
    user: "1000:1000"
    tmpfs:
      - /run:uid=1000,gid=1000,mode=0755
      - /tmp:uid=1000,gid=1000,mode=1777
      - /out:uid=1000,gid=1000,mode=0755
      - /home/node:uid=1000,gid=1000,mode=0755
      - /src:uid=1000,gid=1000,mode=0755
    ulimits:
      core: 0
    logging:
      driver: "none"
EOS
sed -i "s#__IMAGE__#$IMG#" "$SCRATCH/compose-src-tmpfs.yaml"

# compose-src-tmpfs-exec.yaml: M9-e 用。compose-src-tmpfs.yaml と全く同じだが
# /src の tmpfs オプションに `exec` を明示している点だけが違う。CI 5 回目で
# M9-a / M9-b がともに rc=126 (tsup: Permission denied) で落ちた件 (M9 参照) の
# 原因を「/src の tmpfs に既定で付く noexec」と疑っており、M9-d でその実測を
# 取ったうえで、この compose ファイルで M9-b (案B) を exec 付きで測り直す。
#
# bugfix (prod-entrypoint.sh の /src noexec 自己検査追加に伴う変更): M2 と
# M6 の tmpfs /src ケースも、entrypoint を経由して git checkout /
# pnpm install / ref 汚染確認まで到達する必要があるため、この exec 付き
# ファイルを流用する (compose-src-tmpfs.yaml 側のコメント参照)。M2/M6 は
# 元々「uid=1000,gid=1000,mode=0755 形の /src tmpfs で実運用できるか」を
# 見る節であって exec の有無自体を比較する測定ではないため、exec を足しても
# 測定の意味は変わらない。
cat >"$SCRATCH/compose-src-tmpfs-exec.yaml" <<'EOS'
services:
  prod:
    image: __IMAGE__
    entrypoint: ["/usr/local/bin/prod-entrypoint.sh"]
    working_dir: /src
    environment:
      GIT_REPO: ${GIT_REPO:?GIT_REPO is required}
      GIT_REF:  ${GIT_REF:?GIT_REF is required}
      GIT_CONFIG_GLOBAL: ${SAFE_GITCONFIG}
    volumes:
      - ${SCRATCH_DIR}:${SCRATCH_DIR}:ro
    read_only: true
    user: "1000:1000"
    tmpfs:
      - /run:uid=1000,gid=1000,mode=0755
      - /tmp:uid=1000,gid=1000,mode=1777
      - /out:uid=1000,gid=1000,mode=0755
      - /home/node:uid=1000,gid=1000,mode=0755
      - /src:exec,uid=1000,gid=1000,mode=0755
    ulimits:
      core: 0
    logging:
      driver: "none"
EOS
sed -i "s#__IMAGE__#$IMG#" "$SCRATCH/compose-src-tmpfs-exec.yaml"

# compose-anon.yaml: M7 (匿名 volume の削除) 用の最小構成。GIT_REPO / GIT_REF
# も entrypoint も不要 (entrypoint を上書きして prod-entrypoint.sh を経由
# させない)。匿名 volume がひとつ増える設定だけがあればよい。
cat >"$SCRATCH/compose-anon.yaml" <<'EOS'
services:
  prod:
    image: __IMAGE__
    entrypoint: ["true"]
    volumes:
      - /anon-data
EOS
sed -i "s#__IMAGE__#$IMG#" "$SCRATCH/compose-anon.yaml"

# compose-run-volume.yaml: A36 用。secret の置き場 (/run) だけを tmpfs から
# 外し、ホスト側ディレクトリの bind mount に差し替えた構成。/src は tmpfs
# (exec 付き) のままにする — entrypoint の自己検査は /src を先に見るため、
# /src も named volume にすると /run 側の検査に到達しない。
#
# named volume ではなく bind mount にする理由: named volume は root 所有で
# 初期化されるため uid 1000 の `mkdir -p /run/secrets` が先に失敗し、自己
# 検査に到達するかどうか以前の話になる。ホスト側に uid 1000 が書ける
# ディレクトリを用意して差せば、少なくとも「secrets を書けるが tmpfs では
# ない」という、この検査が本当に想定している状況に近づけられる。
mkdir -p "$SCRATCH/run-bind"
chmod 0777 "$SCRATCH/run-bind"
cat >"$SCRATCH/compose-run-volume.yaml" <<'EOS'
services:
  prod:
    image: __IMAGE__
    entrypoint: ["/usr/local/bin/prod-entrypoint.sh"]
    working_dir: /src
    environment:
      GIT_REPO: ${GIT_REPO:?GIT_REPO is required}
      GIT_REF:  ${GIT_REF:?GIT_REF is required}
      GIT_CONFIG_GLOBAL: ${SAFE_GITCONFIG}
    volumes:
      - ${SCRATCH_DIR}/run-bind:/run
      - ${SCRATCH_DIR}:${SCRATCH_DIR}:ro
    read_only: true
    user: "1000:1000"
    tmpfs:
      - /tmp:uid=1000,gid=1000,mode=1777
      - /out:uid=1000,gid=1000,mode=0755
      - /home/node:uid=1000,gid=1000,mode=0755
      - /src:exec,uid=1000,gid=1000,mode=0755
    ulimits:
      core: 0
    logging:
      driver: "none"
EOS
sed -i "s#__IMAGE__#$IMG#" "$SCRATCH/compose-run-volume.yaml"

# --- tmpfs 自己検査を無効化した entrypoint のコピー (M1 の uid= 形 / M6 用) ----
#
# prod-entrypoint.sh に「/src と secret の置き場が tmpfs であること」の自己
# 検査が入った。これは named volume を /src に差したときのドリフト (前回実行
# が /src/.git/config に書き残した設定が、次回の entrypoint 自身の git 操作
# で発火する) への防壁で、A35 が実際に止まることを確認する。
#
# 一方 M6 は、まさにその「named volume だと N-1 / N-2 が再現する」ことの
# 実測記録であり、防壁が入って entrypoint が checkout 前に止まると測定自体
# が成立しなくなる (M6 は防壁の根拠なので記録として残したい)。M1 の uid= 形
# (/run stat) も compose-current.yaml 経由で /src が named volume なので
# 同じ理由で止まる。
#
# そこでこの 2 つだけは、自己検査の対象パスをどのマウントとも一致しない
# 番兵パスへ差し替えたコピーを entrypoint として使う (自己検査は「該当行
# なし」の WARNING を出して続行する)。entrypoint を経由しない形 (git 操作を
# 手で並べる) は採らない: N-2 が見たいのは「entrypoint 自身の
# fetch/checkout/reset/clean が fsmonitor を起動させるか」であり、entrypoint
# を外すと測定の意味が変わってしまうため。
#
# コピー元は作業ツリーの bin/ ではなくイメージの中身にする。両者がずれて
# いても、M1 / M6 が測るのは常に検証対象のイメージ側になる。
#
# sed が効かなかった場合 (entrypoint 側の書き方が変わった場合) は黙って
# 素通りさせず、ここで落とす。素通りすると M6 が「自己検査で止まった rc=1」
# を N-1 / N-2 の結果として記録してしまい、偽の測定になる。
ENTRYPOINT_IMAGE_COPY="$SCRIPTS_DIR/prod-entrypoint-image.sh"
ENTRYPOINT_NO_TMPFS_CHECK="$SCRIPTS_DIR/prod-entrypoint-no-tmpfs-check.sh"
if ! docker run --rm --entrypoint cat "$IMG" /usr/local/bin/prod-entrypoint.sh >"$ENTRYPOINT_IMAGE_COPY"; then
	echo "verify-docker: イメージから /usr/local/bin/prod-entrypoint.sh を取り出せなかった。M1 の uid= 形 / M6 の named volume ケースの前提が作れない。" >&2
	exit 1
fi
cp "$ENTRYPOINT_IMAGE_COPY" "$ENTRYPOINT_NO_TMPFS_CHECK"
sed -i 's#^\([[:space:]]*\)for mnt_target in .*#\1for mnt_target in /verify-tmpfs-self-check-disabled; do#' \
	"$ENTRYPOINT_NO_TMPFS_CHECK"
if grep -q 'for mnt_target in' "$ENTRYPOINT_IMAGE_COPY" &&
	! grep -q '/verify-tmpfs-self-check-disabled' "$ENTRYPOINT_NO_TMPFS_CHECK"; then
	echo "verify-docker: tmpfs 自己検査の無効化 (sed 置換) が効いていない。このまま進めると M6 が「自己検査で止まった結果」を N-1 / N-2 の測定として記録してしまうため停止する。" >&2
	exit 1
fi
# $SCRATCH への chmod -R a+rX はこのファイルを作る前に済んでいるため、
# コンテナ (uid 1000) から読める・実行できるよう個別に付け直す
# ($SAFE_GITCONFIG と同じ理由)。
chmod a+rx "$ENTRYPOINT_NO_TMPFS_CHECK"

echo
echo "=== M1 (uid= 形) / M6 (named volume) 用 entrypoint コピーの diff (tmpfs 自己検査の対象パスだけを番兵へ差し替えている) ==="
diff -u "$ENTRYPOINT_IMAGE_COPY" "$ENTRYPOINT_NO_TMPFS_CHECK" || true

# --- docker run 共通ラッパー (compose.prod.yaml と等価な docker run flags) -----
# compose を経由しない ASSERT の多く (A5, A7〜A10, A16 等) は、compose の
# パーサ挙動そのものではなく entrypoint / shim の挙動を見たいだけなので、
# docker run に直接 templates/host/compose.prod.yaml と同じオプションを渡す。
# これらは M1 で uid= 形式が実際に機能することが前提になる。M1 が否定的な
# 結果を出した場合、この関数を経由する ASSERT 群は同じ前提の上で失敗する
# ことになるが、それ自体が「uid= 形式が壊れている」という情報を運ぶので
# そのままにしておく。
#
# docker_prod_run <GIT_REPO> <GIT_REF> <stdin-payload> <cmd...>
#
# -v "$SCRATCH:$SCRATCH:ro" (バグ1): bare repo を作った先そのままの
# パスでコンテナへ bind mount する。ホスト側とコンテナ側でパスを分けない
# ことで、生成済みの GIT_REPO=file://$SCRATCH/... URL をそのまま使い回せる。
# GIT_CONFIG_GLOBAL (バグ1): git の safe.directory を全許可にした config を
# global スコープとして読ませる。GIT_CONFIG_COUNT/KEY_0/VALUE_0 の形式では
# 効かない (git は safe.directory を protected configuration からしか読ま
# ない。詳細は $SCRATCH の chmod 直前のコメント参照)。
docker_prod_run() {
	local repo="$1" ref="$2" stdin_payload="$3"
	shift 3
	# /src:exec (bugfix): prod-entrypoint.sh (rev.6 / codex 指摘 #6) は /src が
	# noexec だと自己検査で exit 1 する。ここで exec を明示しないと、entrypoint
	# を実際に経由する呼び出し (この関数、および preflight / A5 / A10) が
	# secrets 取込の直後で毎回落ち、後続の依存ケースが軒並み SKIPPED になる
	# (CI 11 回目で発火)。他の /run /tmp /out /home/node は自己検査の対象外
	# なので noexec のままでよい (B2 が「/run に noexec があること」を別途 assert
	# している)。
	printf '%s' "$stdin_payload" | docker run --rm -i \
		--read-only \
		--user 1000:1000 \
		--tmpfs /run:uid=1000,gid=1000,mode=0755 \
		--tmpfs /tmp:uid=1000,gid=1000,mode=1777 \
		--tmpfs /out:uid=1000,gid=1000,mode=0755 \
		--tmpfs /home/node:uid=1000,gid=1000,mode=0755 \
		--tmpfs /src:exec,uid=1000,gid=1000,mode=0755 \
		--ulimit core=0 \
		-v "$SCRATCH:$SCRATCH:ro" \
		-e GIT_REPO="$repo" -e GIT_REF="$ref" \
		-e GIT_CONFIG_GLOBAL="$SAFE_GITCONFIG" \
		--entrypoint /usr/local/bin/prod-entrypoint.sh \
		"$IMG" "$@"
}

# compose_run <compose-file> <project> <GIT_REPO> <GIT_REF> <run 引数...>
#
# GIT_REPO / GIT_REF は `docker compose run -e` ではなく、docker compose
# プロセス自身の環境変数として渡す。compose ファイルの
# `${GIT_REPO:?…}` 展開は compose がファイルをパースする時点で「docker
# compose を起動したシェルの環境」を見て行われるため、`run` に `-e` で
# 渡しても展開には間に合わない (それはコンテナの env には効くが、YAML
# 展開はその前に完了している必要がある)。prod-run.sh が
# `GIT_REPO=… GIT_REF=… bash prod-run.sh …` の形を取っているのと同じ理由。
compose_run() {
	local file="$1" proj="$2" repo="$3" ref="$4"
	shift 4
	GIT_REPO="$repo" GIT_REF="$ref" \
		docker compose -f "$file" -p "$proj" run "$@"
}

# compose_down <compose-file> <project>
compose_down() {
	docker compose -f "$1" -p "$2" down -v >/dev/null 2>&1 || true
}

# =============================================================================
# harness preflight: bare repo がコンテナから見えるか
#
# 「全体に対する要求」: 前提のセットアップ (bare repo が作れた・
# コンテナからマウント経由で見える) は測定に入る前に検査し、失敗して
# いたらそこで HARNESS ERROR を出して以降の依存ケースを SKIPPED として
# 記録する (同じ git エラーを何度も並べない)。docker_prod_run() は
# uid=1000,gid=1000,mode=0755 形の tmpfs を使うため、この preflight が
# 通れば M1 の flat 形 (raw tmpfs) 以外の全 fetch 依存ケースの前提は
# 生きている。flat 形自身の mkdir 可否は M1 が測る対象そのものなので
# ここでは判定しない。
# =============================================================================
echo
echo "=== harness preflight ==="
preflight_out=""
if preflight_out="$(docker_prod_run "file://$TEST_BARE_DIR" "$TEST_COMMIT" "FOO=bar" true 2>&1)"; then
	echo "ok: bare repo ($TEST_BARE_DIR) をコンテナ内 (docker_prod_run) から fetch/checkout できた"
else
	HARNESS_GIT_OK=0
	echo "HARNESS ERROR: bare repo ($TEST_BARE_DIR) がコンテナから読めない (docker_prod_run 経由)。以降の bare repo fetch 依存ケース (M1 の compose 経由分 / M2 / M6 と ASSERT A5, A6, A10, A16, B1, B2, B3, B4) は SKIPPED (harness setup failed) として記録し、個別には実行しない。"
	echo "--- preflight の生出力 ---"
	echo "$preflight_out"
fi

# =============================================================================
# M1: tmpfs の所有権 (最優先)
#
# 設計書 §4.2 は素の短縮形 `tmpfs: ["/run", …]` を書いているが、実装
# (templates/host/compose.prod.yaml) は「root:root で作られ USER node が
# /run/secrets を作れず落ちる」との判断で `uid=1000,gid=1000,mode=0755` へ
# 変えている。この判断の前提 — docker の tmpfs 既定 mode が 1777 で
# world-writable なので素の形でも通るのではないか — が未検証。
# =============================================================================
echo
echo "=== M1: tmpfs の所有権 ==="

m1_docker_version() { docker version; }
measure M1 "docker version" m1_docker_version

m1_compose_version() { docker compose version; }
measure M1 "docker compose version" m1_compose_version

# --- docker run: 素の短縮形 -----------------------------------------------------
m1_run_raw_stat() {
	docker run --rm --tmpfs /run "$IMG" stat -c '%a %U:%G' /run
}
measure M1 "docker run --tmpfs /run (素の形) の /run stat" m1_run_raw_stat

m1_run_raw_mkdir() {
	local out rc=0
	out="$(docker run --rm --tmpfs /run --user 1000:1000 "$IMG" \
		sh -c 'mkdir -p /run/secrets' 2>&1)" || rc=$?
	if [ "$rc" -eq 0 ]; then echo YES; else echo "NO (rc=$rc: $out)"; fi
}
measure M1 "docker run --tmpfs /run (素の形) で uid1000 が mkdir /run/secrets できたか" m1_run_raw_mkdir

m1_run_raw_mkdir_mode() {
	docker run --rm --tmpfs /run --user 1000:1000 "$IMG" \
		sh -c 'umask 077 && mkdir -p /run/secrets && stat -c %a /run/secrets'
}
measure M1 "↑成功時、umask 077 下で作られた /run/secrets の mode" m1_run_raw_mkdir_mode

# --- docker run: uid=/gid=/mode= 形式がそもそも受け付けられるか -----------------
# 推測: docker run --tmpfs の SRC:OPTIONS 記法は size / mode に加えて
# uid= / gid= もカーネルの tmpfs マウントオプションとしてそのまま透過する
# はずだが、docker/containerd の版によっては未対応で拒否される可能性がある
# ため、ここでは受理可否そのものを観測する (docker のあるホストでしか
# 確認できない)。
m1_run_uid_form() {
	docker run --rm --tmpfs /run:uid=1000,gid=1000,mode=0755 "$IMG" \
		stat -c '%a %U:%G' /run
}
measure M1 "docker run --tmpfs /run:uid=1000,gid=1000,mode=0755 が受理されるか + stat" m1_run_uid_form

# --- docker compose run: 両方の記法 (short syntax parser が同じ挙動か) ---------
m1_compose_flat_stat() {
	local proj="verify-m1-flat-$$"
	compose_run "$SCRATCH/compose-flat.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		-T --rm prod sh -c 'stat -c "%a %U:%G" /run' <<<"FOO=bar"
	compose_down "$SCRATCH/compose-flat.yaml" "$proj"
}
measure_git M1 "docker compose run (素の短縮形 tmpfs: [/run]) の /run stat" m1_compose_flat_stat

m1_compose_flat_mkdir() {
	local proj="verify-m1-flat-mkdir-$$" rc=0
	compose_run "$SCRATCH/compose-flat.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		-T --rm prod sh -c 'mkdir -p /run/secrets' <<<"FOO=bar" >/dev/null 2>&1 || rc=$?
	compose_down "$SCRATCH/compose-flat.yaml" "$proj"
	if [ "$rc" -eq 0 ]; then echo YES; else echo "NO (rc=$rc)"; fi
}
measure_git M1 "docker compose run (素の短縮形) で node が mkdir /run/secrets できたか" m1_compose_flat_mkdir

m1_compose_uid_stat() {
	local proj="verify-m1-uid-$$"
	# --entrypoint (bugfix: tmpfs 自己検査の追加に伴う変更): compose-current.yaml
	# は /src が named volume なので、素の entrypoint だと自己検査が secrets 取込
	# の直後に exit 1 し、この測定が見たい `stat /run` に到達しない。ここで
	# 測りたいのは compose が uid=/gid=/mode= 形を受理するかであって自己検査
	# ではないため、検査対象パスを番兵へ差し替えたコピーを使う (詳細は setup
	# の ENTRYPOINT_NO_TMPFS_CHECK のコメント)。
	compose_run "$SCRATCH/compose-current.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		--entrypoint "$ENTRYPOINT_NO_TMPFS_CHECK" \
		-T --rm prod sh -c 'stat -c "%a %U:%G" /run' <<<"FOO=bar"
	compose_down "$SCRATCH/compose-current.yaml" "$proj"
}
measure_git M1 "docker compose run (uid=1000,gid=1000,mode=0755 形) が受理されるか + /run stat" m1_compose_uid_stat

# --- /home/node を素の tmpfs (mode 1777) にした場合の影響 -----------------------
# $HOME が world-writable だと ssh / gh / npm が警告や拒否を出す実装がある。
m1_home_worldwritable() {
	docker run --rm --tmpfs /home/node --user 1000:1000 -e HOME=/home/node "$IMG" \
		sh -c '
			stat -c "%a %U:%G" /home/node
			echo "--- gh --version ---"
			gh --version 2>&1 | head -1
			echo "--- npm config get cache ---"
			npm config get cache 2>&1
		'
}
measure M1 "/home/node を素の tmpfs (mode 1777) にした場合の gh / npm の挙動" m1_home_worldwritable


# =============================================================================
# M2: /src の tmpfs 化 (最優先)
#
# named volume から tmpfs へ変更することが決まっている (ref 汚染と
# .git/config 持続攻撃を構造的に消すため、M6 参照)。ここでは実現可能性
# — read_only 下での git 操作の完走、pnpm install の完走、store の逃げ先、
# tmpfs 既定サイズ、RAM 使用量 — を測る。compose-src-tmpfs-exec.yaml
# (/src も uid=1000,gid=1000,mode=0755 の tmpfs、exec 付き) を使う。M1 で
# uid= 形式が拒否される結果が出た場合、この節の結果はその制約の上で読むこと。
#
# bugfix: 以前は exec を明示しない compose-src-tmpfs.yaml を使っていたが、
# prod-entrypoint.sh の /src noexec 自己検査 (rev.6) がここで先に exit 1 して
# しまい、この節が見たい git 操作 / pnpm install / tmpfs サイズのいずれにも
# 到達できなかった。M2 は exec の有無そのものを比較する測定ではない
# (それは M9-d/M9-e の役目) ので、exec 付きに切り替えても測定の意味は
# 変わらない。
# =============================================================================
echo
echo "=== M2: /src の tmpfs 化 ==="

m2_git_ops() {
	local proj="verify-m2-git-$$" rc=0 out
	out="$(compose_run "$SCRATCH/compose-src-tmpfs-exec.yaml" "$proj" "file://$SELF_BARE_DIR" "$SELF_COMMIT" \
		-T --rm prod sh -c 'test -f pnpm-lock.yaml && git rev-parse HEAD' <<<"FOO=bar" 2>&1)" || rc=$?
	compose_down "$SCRATCH/compose-src-tmpfs-exec.yaml" "$proj"
	if [ "$rc" -eq 0 ]; then
		echo "OK (git init+fetch+checkout+clean 完走。HEAD=$out)"
	else
		echo "FAILED (rc=$rc): $out"
	fi
}
measure_git M2 "read_only + tmpfs /src で git init/fetch/checkout/clean が完走するか" m2_git_ops

# pnpm install --frozen-lockfile。PNPM_HOME=/usr/local/share/pnpm は
# read_only なので store がどこへ落ちるかが焦点。
m2_pnpm_install() {
	local proj="verify-m2-pnpm-$$" rc=0 out
	# SC2016: 単引用符は意図的。この sh -c ブロックはコンテナ内で評価させる。
	# shellcheck disable=SC2016
	out="$(compose_run "$SCRATCH/compose-src-tmpfs-exec.yaml" "$proj" "file://$SELF_BARE_DIR" "$SELF_COMMIT" \
		-T --rm prod sh -c '
			set -e
			pnpm install --frozen-lockfile
			echo "--- pnpm store path ---"
			store="$(pnpm store path)"
			echo "$store"
			echo "--- du -sh \$store ---"
			du -sh "$store" 2>/dev/null || echo "du failed (store may not exist)"
		' <<<"FOO=bar" 2>&1)" || rc=$?
	compose_down "$SCRATCH/compose-src-tmpfs-exec.yaml" "$proj"
	if [ "$rc" -eq 0 ]; then
		echo "OK: $out"
	else
		echo "FAILED (rc=$rc): $out"
	fi
}
measure_git M2 "read_only + tmpfs /src で pnpm install --frozen-lockfile が完走するか、store の逃げ先" m2_pnpm_install

# tmpfs 既定サイズ。df -h /src は mount 直後の値 (install の有無に関わらず
# カーネルが割り当てる上限であって使用量ではない)。node_modules を含む
# 実運用に足りるかどうかは、この上限と M2 の du -sh /src (使用量) を突き合わせて
# 判断する。
m2_df_default_size() {
	local proj="verify-m2-df-$$" out rc=0
	out="$(compose_run "$SCRATCH/compose-src-tmpfs-exec.yaml" "$proj" "file://$SELF_BARE_DIR" "$SELF_COMMIT" \
		-T --rm prod df -h /src <<<"FOO=bar" 2>&1)" || rc=$?
	compose_down "$SCRATCH/compose-src-tmpfs-exec.yaml" "$proj"
	if [ "$rc" -eq 0 ]; then echo "$out"; else echo "FAILED (rc=$rc): $out"; fi
}
measure_git M2 "tmpfs /src の既定サイズ (df -h /src、size= 未指定)" m2_df_default_size

# ビルド成果物を /out に出す構成での /src + /out 合計 RAM 使用量。install
# 後の使用量を du -sh で見る。tmpfs 上の使用量はほぼそのまま RAM 使用量に
# 相当する (実ディスクを介さないため) が、正確な RSS ではなく du の近似値
# であることに注意。
m2_ram_usage() {
	local proj="verify-m2-ram-$$" rc=0 out
	out="$(compose_run "$SCRATCH/compose-src-tmpfs-exec.yaml" "$proj" "file://$SELF_BARE_DIR" "$SELF_COMMIT" \
		-T --rm prod sh -c '
			set -e
			pnpm install --frozen-lockfile >/dev/null 2>&1 || true
			mkdir -p /out
			echo dummy-build-artifact > /out/dummy
			du -sh /src /out 2>/dev/null
		' <<<"FOO=bar" 2>&1)" || rc=$?
	compose_down "$SCRATCH/compose-src-tmpfs-exec.yaml" "$proj"
	if [ "$rc" -eq 0 ]; then echo "$out"; else echo "FAILED (rc=$rc): $out"; fi
}
measure_git M2 "/src + /out 合計 RAM 使用量 (du -sh、pnpm install 後)" m2_ram_usage


# =============================================================================
# M9: pnpm store の置き場所 (CI 4 回目で発覚)
#
# CI 4 回目、read_only: true + tmpfs /src 構成で `pnpm install
# --frozen-lockfile` が `[ENOENT] ENOENT: no such file or directory,
# mkdir '/usr/local/share/pnpm/store'` で落ちた。イメージが
# ENV PNPM_HOME=/usr/local/share/pnpm を設定しており、pnpm の store は
# 既定で $PNPM_HOME/store。read_only 下ではそこを作れない。store を
# 書ける tmpfs へ逃がす必要があるが、置き場所に 2 案ある:
#
#   案 A: $HOME 配下 (/home/node/.local/share/pnpm/store)。/home/node は
#         /src とは別の tmpfs マウントになる。pnpm は store から
#         node_modules へハードリンクを張るが、マウントを跨ぐとハード
#         リンクは張れず copy にフォールバックするはずで、RAM を二重に
#         食う可能性がある (未確認、ここでの測定対象そのもの)。
#   案 B: /src 配下 (/src/.pnpm-store)。node_modules と同一 tmpfs
#         マウントになるのでハードリンクが効くはず。ただし working tree
#         の中に store を置くことになる。
#
# どちらも tmpfs なので run をまたいだキャッシュは無い (毎回全依存を
# 再ダウンロードする)。git clean -xdff は entrypoint 内で checkout 直後に
# 走り、pnpm install はその後なので、案 B でも同一 run 内で store が
# checkout の副作用で消えることはない。
#
# 合わせて、store-dir をイメージに焼き込む方法 (実運用でのデフォルト
# 変更手段) も確認する: コンテナ内で環境変数 (npm_config_store_dir) を
# 与えるだけで store-dir が変わるかを見る (M9-c、pnpm install は走らせない
# ので GIT_REPO 不要)。
#
# CI 5 回目の追記: M9-a / M9-b とも「依存の解決とリンクは成功 (added 174,
# done) したが、後続の prepare スクリプト (packages/enclave-env の
# `tsup` 実行) が `sh: 1: tsup: Permission denied` / rc=126 で落ちる」と
# いう同一の症状で終わった。store の場所 (案A/案B) と無関係に同じ症状が
# 出ていることから、原因は「/src の tmpfs マウントに既定で付く noexec」が
# 濃厚 (docker の tmpfs は既定で rw,nosuid,nodev,noexec)。noexec マウント
# 上の実行ファイルを exec すると EACCES になり、シェルは "Permission
# denied" と報告する — 症状と一致する。M2 で git 操作が通ったのは git が
# /usr/bin (イメージのルート fs、noexec の影響を受けない) にあるためで、
# 影響を受けるのは node_modules/.bin のように tmpfs 上に置かれた実行
# ファイルだけ、という仮説を立てている。
#
# この仮説を推測のまま対処するのではなく、M9-d で直接確認する:
#   - exec オプションを明示しない現状の /src tmpfs (compose-src-tmpfs.yaml
#     と同じ uid=,gid=,mode= 形) で mount 出力に noexec が実際に付くか、
#     自作の実行ファイルが動くか
#   - `exec` を明示した /src tmpfs (compose-src-tmpfs-exec.yaml) で同じ
#     2 点がどう変わるか
#   - /run /tmp /out /home/node の mount 出力も併せて出し、noexec の
#     付き方を横並びで見る
# そのうえで M9-e が、採用済みの案 B (store-dir=/src/.pnpm-store) を
# exec 付き tmpfs で測り直し、`pnpm install --frozen-lockfile` が
# prepare スクリプト (tsup build) まで完走するかを見る。M9-b はそのまま
# 残す (exec を付ける前後の比較のため)。M9-a は RAM が倍という結論が
# 既に出ているため exec 付きでは測り直さない。
#
# 全て MEASURE。pass/fail 判定はしない。1 ケースあたり pnpm install が
# 走るため、M9-a / M9-b / M9-e の 3 ケースに絞る (M9-c は store path の
# 確認のみ、M9-d は mount と自作スクリプトの実行確認のみで、どちらも
# pnpm install を走らせない)。
#
# 推測 (docker が無い環境のため未実行・未確認):
#   - `pnpm store path --store-dir <dir>` のようにサブコマンドの後ろに
#     --store-dir を置いても pnpm に受理されるはず、という前提で書いて
#     いる (他の pnpm グローバルオプションと同様のパーサ挙動を想定)。
#   - マウントを跨ぐハードリンク失敗時に pnpm が warn/info を出すという
#     前提で、pnpm install の出力から cross-device/EXDEV/hardlink を含む
#     行を拾っている。実際にそのような行が出るかは未確認。
#   - docker run/compose の `--tmpfs path:opts` / `tmpfs: [path:opts]` は
#     size= や mode= と同様に `exec` / `noexec` もカーネルの tmpfs マウント
#     オプションとしてそのまま透過するはず、という前提で M9-d /
#     compose-src-tmpfs-exec.yaml を書いている。ただし「ユーザーが
#     uid=/gid=/mode= だけを指定したとき、docker 既定の noexec がそのまま
#     残るのか、何らかの理由で置き換わるのか」は未確認 — これが M9-d で
#     直接確認したい点そのものであり、確認できるまでは仮説にとどまる。
#   - `pnpm config set store-dir <dir> --global` が書き込むファイルの
#     場所を `pnpm config list` / `--location` でどこまで表示できるかは
#     pnpm 側のフラグ対応を未確認のまま書いている (M9-c の追加測定)。
#     read_only 下では書き込み自体が失敗する可能性が高く、その場合は
#     エラー出力をそのまま記録する。
# =============================================================================
echo
echo "=== M9: pnpm store の置き場所 ==="

# M9-d: CI 5 回目の rc=126 (tsup: Permission denied) が「/src の tmpfs に
# 既定で付く noexec」によるものかを直接確認する。pnpm install は走らせず
# (docker run と mount / 自作スクリプトの実行確認だけなので軽い)、bare
# repo も使わないので measure_git ではなく measure を使う。
#
# 2 つの docker run を 1 つの measure() 呼び出しにまとめて出す (m1_home_
# worldwritable と同じスタイル)。前段の docker run が何らかの理由で
# 非ゼロ終了しても後段が実行されるよう、それぞれを `|| true` で個別に
# 保護する — 呼び出し元の測定表示 (MEAS_LOG) に片方だけ載って比較不能に
# なるのを避けるため。ただし通常は両方とも docker run 自体は 0 終了する
# はず: 内側の sh -c は `set -e` を使わず、自作スクリプトの実行が失敗
# (permission denied) しても最後の `echo "rc=$?"` まで到達してそこで
# 正常終了するため (m9a/m9b と同じ考え方)。
#
# SC2016: sh -c '...' 内の $ は意図的に単引用符でエスケープしている。
# コンテナ内の sh に渡して評価させたい文字列であって、このスクリプト
# 自身のシェルで展開させたいものではないため。
m9d_tmpfs_exec_diagnosis() {
	echo "=== (1) 現状形: /src:uid=1000,gid=1000,mode=0755 (exec 明示なし。compose-src-tmpfs.yaml と同じ形) ==="
	# shellcheck disable=SC2016
	docker run --rm --read-only --user 1000:1000 \
		--tmpfs /run:uid=1000,gid=1000,mode=0755 \
		--tmpfs /tmp:uid=1000,gid=1000,mode=1777 \
		--tmpfs /out:uid=1000,gid=1000,mode=0755 \
		--tmpfs /home/node:uid=1000,gid=1000,mode=0755 \
		--tmpfs /src:uid=1000,gid=1000,mode=0755 \
		--ulimit core=0 \
		"$IMG" sh -c '
			echo "--- mount | grep <path> (/src /run /tmp /out /home/node) ---"
			for p in /src /run /tmp /out /home/node; do
				echo "[$p]"
				mount | grep " $p " || echo "(mount 行が見つからない: $p)"
			done
			echo "--- /src に自作の実行ファイルを置いて実行 (exec オプション明示なし) ---"
			printf "#!/bin/sh\necho EXEC_OK\n" > /src/t.sh
			chmod +x /src/t.sh
			/src/t.sh
			echo "rc=$?"
		' 2>&1 || true
	echo
	echo "=== (2) exec 明示形: /src:exec,uid=1000,gid=1000,mode=0755 ==="
	# shellcheck disable=SC2016
	docker run --rm --read-only --user 1000:1000 \
		--tmpfs /run:uid=1000,gid=1000,mode=0755 \
		--tmpfs /tmp:uid=1000,gid=1000,mode=1777 \
		--tmpfs /out:uid=1000,gid=1000,mode=0755 \
		--tmpfs /home/node:uid=1000,gid=1000,mode=0755 \
		--tmpfs /src:exec,uid=1000,gid=1000,mode=0755 \
		--ulimit core=0 \
		"$IMG" sh -c '
			echo "--- mount | grep /src ---"
			mount | grep " /src " || echo "(mount 行が見つからない: /src)"
			echo "--- /src に自作の実行ファイルを置いて実行 (exec オプション明示あり) ---"
			printf "#!/bin/sh\necho EXEC_OK\n" > /src/t.sh
			chmod +x /src/t.sh
			/src/t.sh
			echo "rc=$?"
		' 2>&1 || true
}
measure M9 "M9-d: /src tmpfs の noexec 実測 (mount 出力 + 自作実行ファイル。exec 明示なし vs あり)" m9d_tmpfs_exec_diagnosis

# m9a_pnpm_case / m9b_pnpm_case は意図的にほぼ同じ内容 (STORE_DIR と
# それに伴う注記だけが違う)。M9-a と M9-b の出力を同じ形式で比較できる
# ことがこの測定の目的なので、共通ヘルパへ括り出さず並べて書く (M1 の
# raw 版 / uid= 版、M6 の named volume 版 / tmpfs 版と同じ書き方)。
#
# 各ケースの出力は測定表示 (MEAS_LOG) に載せると同時に、$SCRATCH 配下の
# ファイルにも書き出す。m9_summary (このセクション末尾) がそのファイルを
# 読んで 3 ケース比較のまとめ行を組み立てる。pnpm install をもう一度
# 走らせて二重に時間を食わないための工夫 (measure() は command
# substitution 経由でサブシェル実行になり、シェル変数はサブシェルを
# 抜けると消えるが、ファイルへの書き込みは残る)。
#
# SC2016: 各ケースの sh -c '...' 内の $ は意図的にすべて単引用符で
# エスケープしている。この文字列はコンテナ内の sh に渡され、そちら側で
# 評価させたいため (このスクリプト自身のシェルではない)。

m9a_pnpm_case() {
	local proj="verify-m9-a-$$" out rc=0
	# shellcheck disable=SC2016
	out="$(compose_run "$SCRATCH/compose-src-tmpfs.yaml" "$proj" "file://$SELF_BARE_DIR" "$SELF_COMMIT" \
		-T --rm prod sh -c '
			STORE_DIR="/home/node/.local/share/pnpm/store"
			human_kb() {
				n="$1"
				if [ "$n" -ge 1048576 ]; then printf "%sG" "$((n / 1048576))"
				elif [ "$n" -ge 1024 ]; then printf "%sM" "$((n / 1024))"
				else printf "%sK" "$n"
				fi
			}
			t0=$(date +%s)
			pnpm install --frozen-lockfile --store-dir "$STORE_DIR" >/tmp/m9-install.log 2>&1
			rc=$?
			t1=$(date +%s)
			echo "rc=$rc"
			echo "--- pnpm install 出力の末尾 (トラブル時の手がかり用) ---"
			tail -20 /tmp/m9-install.log
			echo "--- pnpm store path --store-dir $STORE_DIR ---"
			pnpm store path --store-dir "$STORE_DIR" 2>&1
			echo "--- du -sh (store 単体) ---"
			du -sh "$STORE_DIR" 2>&1 || echo "du failed (store may not exist)"
			store_kb=$(du -sk "$STORE_DIR" 2>/dev/null | cut -f1)
			echo "--- du -sh /src (node_modules 込み。store は別 tmpfs マウントなのでここには含まれない) ---"
			du -sh /src 2>&1
			src_kb=$(du -sk /src 2>/dev/null | cut -f1)
			mkdir -p /out
			echo dummy-build-artifact > /out/dummy
			echo "--- du -sh /out ---"
			du -sh /out 2>&1
			out_kb=$(du -sk /out 2>/dev/null | cut -f1)
			total_kb=$(( ${store_kb:-0} + ${src_kb:-0} + ${out_kb:-0} ))
			echo "--- 合計 (store + /src + /out。別マウントなので単純合算): ${total_kb:-0}K = $(human_kb "${total_kb:-0}") ---"
			echo "--- df -h /src ---"
			df -h /src 2>&1
			echo "--- df -h /home/node ---"
			df -h /home/node 2>&1
			echo "--- hardlink 判定: node_modules 内、リンク数 2 以上 (links+1) のファイル数 / 全ファイル数 ---"
			linked=$(find node_modules -type f -links +1 2>/dev/null | wc -l)
			totalf=$(find node_modules -type f 2>/dev/null | wc -l)
			echo "links+1=$linked total=$totalf"
			echo "--- pnpm install 出力中の cross-device / hardlink 関連行 ---"
			grep -iE "cross-device|exdev|hardlink" /tmp/m9-install.log || echo "(該当行なし)"
			echo "--- 所要時間 ---"
			echo "${t1}s - ${t0}s = $((t1 - t0))s"
			echo "M9_RC=$rc"
			echo "M9_STORE_KB=${store_kb:-0}"
			echo "M9_SRC_KB=${src_kb:-0}"
			echo "M9_OUT_KB=${out_kb:-0}"
			echo "M9_LINKED=$linked"
			echo "M9_TOTALF=$totalf"
			echo "M9_ELAPSED=$((t1 - t0))"
		' <<<"FOO=bar" 2>&1)" || rc=$?
	compose_down "$SCRATCH/compose-src-tmpfs.yaml" "$proj"
	if [ "$rc" -ne 0 ]; then
		out="$(printf 'HARNESS: compose_run 自体が非ゼロ終了 (rc=%s。pnpm install 個別の rc は本文中の rc= 行を見ること)\n%s' "$rc" "$out")"
	fi
	printf '%s\n' "$out" >"$SCRATCH/m9a-output.txt"
	printf '%s\n' "$out"
}
measure_git M9 "M9-a 案A: store-dir=/home/node/.local/share/pnpm/store (/src とは別 tmpfs マウント)" m9a_pnpm_case

m9b_pnpm_case() {
	local proj="verify-m9-b-$$" out rc=0
	# shellcheck disable=SC2016
	out="$(compose_run "$SCRATCH/compose-src-tmpfs.yaml" "$proj" "file://$SELF_BARE_DIR" "$SELF_COMMIT" \
		-T --rm prod sh -c '
			STORE_DIR="/src/.pnpm-store"
			human_kb() {
				n="$1"
				if [ "$n" -ge 1048576 ]; then printf "%sG" "$((n / 1048576))"
				elif [ "$n" -ge 1024 ]; then printf "%sM" "$((n / 1024))"
				else printf "%sK" "$n"
				fi
			}
			t0=$(date +%s)
			pnpm install --frozen-lockfile --store-dir "$STORE_DIR" >/tmp/m9-install.log 2>&1
			rc=$?
			t1=$(date +%s)
			echo "rc=$rc"
			echo "--- pnpm install 出力の末尾 (トラブル時の手がかり用) ---"
			tail -20 /tmp/m9-install.log
			echo "--- pnpm store path --store-dir $STORE_DIR ---"
			pnpm store path --store-dir "$STORE_DIR" 2>&1
			echo "--- du -sh (store 単体) ---"
			du -sh "$STORE_DIR" 2>&1 || echo "du failed (store may not exist)"
			store_kb=$(du -sk "$STORE_DIR" 2>/dev/null | cut -f1)
			echo "--- du -sh /src (node_modules + store 込み。store は /src の中にあるので二重計上に注意) ---"
			du -sh /src 2>&1
			src_kb=$(du -sk /src 2>/dev/null | cut -f1)
			mkdir -p /out
			echo dummy-build-artifact > /out/dummy
			echo "--- du -sh /out ---"
			du -sh /out 2>&1
			out_kb=$(du -sk /out 2>/dev/null | cut -f1)
			total_kb=$(( ${src_kb:-0} + ${out_kb:-0} ))
			echo "--- 合計 (/src + /out。store は既に /src の値に含まれているので別途は足さない): ${total_kb:-0}K = $(human_kb "${total_kb:-0}") ---"
			echo "--- df -h /src ---"
			df -h /src 2>&1
			echo "--- df -h /home/node ---"
			df -h /home/node 2>&1
			echo "--- hardlink 判定: node_modules 内、リンク数 2 以上 (links+1) のファイル数 / 全ファイル数 ---"
			linked=$(find node_modules -type f -links +1 2>/dev/null | wc -l)
			totalf=$(find node_modules -type f 2>/dev/null | wc -l)
			echo "links+1=$linked total=$totalf"
			echo "--- pnpm install 出力中の cross-device / hardlink 関連行 ---"
			grep -iE "cross-device|exdev|hardlink" /tmp/m9-install.log || echo "(該当行なし)"
			echo "--- 所要時間 ---"
			echo "${t1}s - ${t0}s = $((t1 - t0))s"
			echo "M9_RC=$rc"
			echo "M9_STORE_KB=${store_kb:-0}"
			echo "M9_SRC_KB=${src_kb:-0}"
			echo "M9_OUT_KB=${out_kb:-0}"
			echo "M9_LINKED=$linked"
			echo "M9_TOTALF=$totalf"
			echo "M9_ELAPSED=$((t1 - t0))"
		' <<<"FOO=bar" 2>&1)" || rc=$?
	compose_down "$SCRATCH/compose-src-tmpfs.yaml" "$proj"
	if [ "$rc" -ne 0 ]; then
		out="$(printf 'HARNESS: compose_run 自体が非ゼロ終了 (rc=%s。pnpm install 個別の rc は本文中の rc= 行を見ること)\n%s' "$rc" "$out")"
	fi
	printf '%s\n' "$out" >"$SCRATCH/m9b-output.txt"
	printf '%s\n' "$out"
}
measure_git M9 "M9-b 案B: store-dir=/src/.pnpm-store (/src と同一 tmpfs マウント)" m9b_pnpm_case

# M9-e: 採用済みの案 B (store-dir=/src/.pnpm-store) を、/src の tmpfs に
# `exec` を明示した compose-src-tmpfs-exec.yaml で測り直す。M9-b の内容を
# ほぼそのまま踏襲しつつ (STORE_DIR は同じ /src/.pnpm-store)、追加で
# 「/src 上に置かれた実行ファイルが実際に exec できるか」を確認する。
# 判定材料は node_modules/.bin の実体を 1 つ実行し、その終了コードを見る
# こと。noexec のマウント上の実行ファイルを exec すると EACCES になり、
# シェルは "Permission denied" と報告して rc=126 を返す — そこを名指しで
# 見る。
#
# 以前の判定材料は workspace 内のパッケージが持つ prepare スクリプト
# (tsup build) の生成物の有無だったが、そのパッケージを廃止した時点で
# 成立しなくなった (workspace に build/prepare を持つパッケージはもう
# 無い)。測定対象が消えたことを理由に「NO」を返し続ける測定は、測定が
# 無いより悪いので、間接的な問い (prepare が走ったか) をやめて直接聞く
# 形に差し替えた。
#
# SC2016: sh -c '...' 内の $ は意図的に単引用符でエスケープしている。
m9e_pnpm_case_exec() {
	local proj="verify-m9-e-$$" out rc=0
	# shellcheck disable=SC2016
	out="$(compose_run "$SCRATCH/compose-src-tmpfs-exec.yaml" "$proj" "file://$SELF_BARE_DIR" "$SELF_COMMIT" \
		-T --rm prod sh -c '
			STORE_DIR="/src/.pnpm-store"
			human_kb() {
				n="$1"
				if [ "$n" -ge 1048576 ]; then printf "%sG" "$((n / 1048576))"
				elif [ "$n" -ge 1024 ]; then printf "%sM" "$((n / 1024))"
				else printf "%sK" "$n"
				fi
			}
			t0=$(date +%s)
			pnpm install --frozen-lockfile --store-dir "$STORE_DIR" >/tmp/m9-install.log 2>&1
			rc=$?
			t1=$(date +%s)
			echo "rc=$rc"
			echo "--- pnpm install 出力の末尾 (トラブル時の手がかり用) ---"
			tail -20 /tmp/m9-install.log
			echo "--- pnpm store path --store-dir $STORE_DIR ---"
			pnpm store path --store-dir "$STORE_DIR" 2>&1
			echo "--- du -sh (store 単体) ---"
			du -sh "$STORE_DIR" 2>&1 || echo "du failed (store may not exist)"
			store_kb=$(du -sk "$STORE_DIR" 2>/dev/null | cut -f1)
			echo "--- du -sh /src (node_modules + store 込み。store は /src の中にあるので二重計上に注意) ---"
			du -sh /src 2>&1
			src_kb=$(du -sk /src 2>/dev/null | cut -f1)
			mkdir -p /out
			echo dummy-build-artifact > /out/dummy
			echo "--- du -sh /out ---"
			du -sh /out 2>&1
			out_kb=$(du -sk /out 2>/dev/null | cut -f1)
			total_kb=$(( ${src_kb:-0} + ${out_kb:-0} ))
			echo "--- 合計 (/src + /out。store は既に /src の値に含まれているので別途は足さない): ${total_kb:-0}K = $(human_kb "${total_kb:-0}") ---"
			echo "--- df -h /src ---"
			df -h /src 2>&1
			echo "--- df -h /home/node ---"
			df -h /home/node 2>&1
			echo "--- hardlink 判定: node_modules 内、リンク数 2 以上 (links+1) のファイル数 / 全ファイル数 ---"
			linked=$(find node_modules -type f -links +1 2>/dev/null | wc -l)
			totalf=$(find node_modules -type f 2>/dev/null | wc -l)
			echo "links+1=$linked total=$totalf"
			echo "--- pnpm install 出力中の cross-device / hardlink 関連行 ---"
			grep -iE "cross-device|exdev|hardlink" /tmp/m9-install.log || echo "(該当行なし)"
			echo "--- /src 上の実行ファイルが実際に exec できるか ---"
			echo "--- 判定材料: node_modules/.bin の実体を 1 つ実行し、その終了コードを見る ---"
			ls -la node_modules/.bin 2>&1 || echo "(ls に失敗 = node_modules/.bin が無い)"
			bin_name=""
			if [ -d node_modules/.bin ]; then
				if [ -e node_modules/.bin/biome ]; then
					bin_name="biome"
				else
					bin_name=$(ls -1 node_modules/.bin 2>/dev/null | head -1)
				fi
			fi
			if [ -z "$bin_name" ]; then
				echo "M9_E_EXEC=UNKNOWN (node_modules/.bin が無いか空。install が期待どおり完了していない)"
			else
				echo "--- 実行: ./node_modules/.bin/$bin_name --version (stdout/stderr はそのまま出す) ---"
				"./node_modules/.bin/$bin_name" --version 2>&1
				erc=$?
				echo "(exit code: $erc)"
				if [ "$erc" -eq 0 ]; then
					echo "M9_E_EXEC=YES ($bin_name)"
				elif [ "$erc" -eq 126 ]; then
					echo "M9_E_EXEC=NO (Permission denied = noexec。/src 上の実行ファイルが動いていない)"
				else
					echo "M9_E_EXEC=UNKNOWN (rc=$erc)"
				fi
			fi
			echo "--- pnpm install 出力中の tsup / Permission denied 関連行 (CI 5 回目の症状の再現有無) ---"
			grep -iE "tsup|permission denied" /tmp/m9-install.log || echo "(該当行なし)"
			echo "--- 所要時間 ---"
			echo "${t1}s - ${t0}s = $((t1 - t0))s"
			echo "M9_RC=$rc"
			echo "M9_STORE_KB=${store_kb:-0}"
			echo "M9_SRC_KB=${src_kb:-0}"
			echo "M9_OUT_KB=${out_kb:-0}"
			echo "M9_LINKED=$linked"
			echo "M9_TOTALF=$totalf"
			echo "M9_ELAPSED=$((t1 - t0))"
		' <<<"FOO=bar" 2>&1)" || rc=$?
	compose_down "$SCRATCH/compose-src-tmpfs-exec.yaml" "$proj"
	if [ "$rc" -ne 0 ]; then
		out="$(printf 'HARNESS: compose_run 自体が非ゼロ終了 (rc=%s。pnpm install 個別の rc は本文中の rc= 行を見ること)\n%s' "$rc" "$out")"
	fi
	printf '%s\n' "$out"
}
measure_git M9 "M9-e 案B + exec 明示: store-dir=/src/.pnpm-store、/src tmpfs に exec を付けた場合 (node_modules/.bin の実行確認込み)" m9e_pnpm_case_exec

# M9-c: store-dir をイメージに焼く方法の確認。pnpm install は走らせない
# (store path の確認だけで十分、とのタスク指示のとおり)。GIT_REPO/GIT_REF
# も bare repo fetch も使わないので、bare repo 到達性 (HARNESS_GIT_OK) と
# 無関係 — measure_git ではなく measure を使う。
#
# CI 5 回目の不具合: 元の実装は cwd を変えないまま `pnpm store path` を
# 実行しており、cwd は docker のデフォルト (イメージの WORKDIR 未設定=
# ルート `/`。root:root 755 で uid 1000 からは書けない) のままだった。
# `pnpm store path` は cwd にテンポラリファイルを作って書き込み可否を
# 確かめる実装になっており、これが EACCES で落ちて `M9_C_CHANGED=YES` が
# 誤判定されていた (両方エラーなのに文字列比較で「変わった」と誤認)。
# `-w /tmp` で cwd を書ける場所 (このコンテナは --read-only を付けず
# 素のまま起動しているため、イメージ既定の /tmp は通常 1777 で書ける) に
# 変え、両方の実行が実際にエラーなく完走したことを確認したうえで比較する。
# 片方でもエラーが残っていれば UNKNOWN として記録し、YES/NO のどちらとも
# 誤って報告しない。
m9c_store_dir_env() {
	local out
	# shellcheck disable=SC2016
	out="$(docker run --rm --user 1000:1000 -w /tmp "$IMG" sh -c '
			echo "--- 素の pnpm store path (環境変数なし。既定は \$PNPM_HOME/store のはず。cwd=/tmp に変更して書き込み不可による EACCES を避けている) ---"
			default_path=$(pnpm store path 2>&1)
			default_rc=$?
			echo "$default_path"
			echo "--- 素の pnpm config get store-dir ---"
			pnpm config get store-dir 2>&1
			echo "--- npm_config_store_dir=/home/node/.local/share/pnpm/store を与えた場合の pnpm store path ---"
			env_path=$(npm_config_store_dir=/home/node/.local/share/pnpm/store pnpm store path 2>&1)
			env_rc=$?
			echo "$env_path"
			echo "--- 同条件での pnpm config get store-dir ---"
			npm_config_store_dir=/home/node/.local/share/pnpm/store pnpm config get store-dir 2>&1
			echo "--- default_rc=$default_rc env_rc=$env_rc (両方 0 でなければ比較は判定不能) ---"
			if [ "$default_rc" -ne 0 ] || [ "$env_rc" -ne 0 ]; then
				echo "M9_C_CHANGED=UNKNOWN (エラーのため判定不能: default_rc=$default_rc env_rc=$env_rc)"
			elif [ "$default_path" != "$env_path" ]; then
				echo "M9_C_CHANGED=YES"
			else
				echo "M9_C_CHANGED=NO"
			fi
			echo
			echo "--- 追加測定: PNPM_HOME を変えず、pnpm config set store-dir --global の書き込み先 ---"
			echo "--- (read_only ではないコンテナだが、PNPM_HOME=/usr/local/share/pnpm はイメージのルート fs 上にあり、コンテナ起動時に書き込み権限が広げられていなければ失敗しうる。設定ファイルの実際の置き場所は pnpm のバージョン依存のため、ここではコマンドの成否と出力をそのまま記録するにとどめる) ---"
			# 推測: pnpm config set/list の --global / --location まわりの
			# 挙動は pnpm 9.x 系のドキュメントを基に書いているが、この
			# イメージに入っている pnpm の実バージョンでの挙動は docker が
			# 無いこの環境では確認できていない。
			if set_out=$(pnpm config set store-dir /home/node/.local/share/pnpm/store --global 2>&1); then
				echo "$set_out"
				echo "--- pnpm config list --global (設定がどこに反映されたか) ---"
				pnpm config list --global 2>&1
				echo "M9_C_GLOBAL_SET=OK"
			else
				set_rc=$?
				echo "$set_out"
				echo "M9_C_GLOBAL_SET=FAILED (rc=$set_rc)"
			fi
			echo
			echo "--- /usr/local/etc/npmrc (npm のグローバル設定ファイル) に store-dir= を書いた場合に効くかは、イメージ側の変更が要るためこの測定では確認していない (未確認・未実施) ---"
		' 2>&1)"
	printf '%s\n' "$out" >"$SCRATCH/m9c-output.txt"
	printf '%s\n' "$out"
}
measure M9 "M9-c: 環境変数 npm_config_store_dir だけで pnpm store path / config get store-dir が変わるか (cwd=/tmp に修正。pnpm install は走らせない)" m9c_store_dir_env

# M9 まとめ: M9-a / M9-b / M9-c の出力ファイル ($SCRATCH/m9{a,b,c}-output.txt。
# 上の 3 関数が pnpm install を再実行せず書き出したもの) を読み、一目で
# 比較できる 3 行にする。A と B の「合計」は二重計上を避けて計算する:
# 案 A は store が /src とは別マウントなので store+/src+/out を単純合算、
# 案 B は store が /src の中にあり /src の du に既に含まれているので
# /src+/out だけを合算する (store の値自体は比較用に別途表示する)。
#
# M9-d (mount/自作スクリプトの実行確認) と M9-e (exec 付き案B) はこの
# まとめには含めない — d は pnpm install を伴わず a/b/e と同じ形式の
# フィールドを持たないため、e は「exec を付けた後」を一つ増やすと
# a/b の 2 行比較という元の設計が崩れるため。d/e はそれぞれの
# measure() 呼び出しの出力をそのまま参照する。
m9_summary() {
	to_int() { case "$1" in '' | *[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }
	kb_to_human() {
		awk -v kb="$1" 'BEGIN {
			if (kb >= 1024*1024) { printf "%.1fG", kb/1024/1024 }
			else if (kb >= 1024) { printf "%.0fM", kb/1024 }
			else { printf "%dK", kb }
		}'
	}
	field() { grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-; }

	local a_file="$SCRATCH/m9a-output.txt" b_file="$SCRATCH/m9b-output.txt" c_file="$SCRATCH/m9c-output.txt"
	local a_line b_line c_line

	if [ -f "$a_file" ]; then
		local a_rc a_store_kb a_src_kb a_out_kb a_linked a_totalf a_elapsed a_total_kb
		a_rc="$(field "$a_file" M9_RC)"
		a_store_kb="$(to_int "$(field "$a_file" M9_STORE_KB)")"
		a_src_kb="$(to_int "$(field "$a_file" M9_SRC_KB)")"
		a_out_kb="$(to_int "$(field "$a_file" M9_OUT_KB)")"
		a_linked="$(field "$a_file" M9_LINKED)"
		a_totalf="$(field "$a_file" M9_TOTALF)"
		a_elapsed="$(field "$a_file" M9_ELAPSED)"
		a_total_kb=$((a_store_kb + a_src_kb + a_out_kb))
		a_line="$(printf 'A(別tmpfs) rc=%s store=%s /src=%s(node_modules込) 合計=%s(store+/src+/out、別マウントにつき単純合算) hardlink=%s/%s 所要=%ss' \
			"${a_rc:-?}" "$(kb_to_human "$a_store_kb")" "$(kb_to_human "$a_src_kb")" "$(kb_to_human "$a_total_kb")" \
			"${a_linked:-?}" "${a_totalf:-?}" "${a_elapsed:-?}")"
	else
		a_line="A(別tmpfs): SKIPPED (M9-a 未実行。harness preflight 失敗の可能性が高い)"
	fi

	if [ -f "$b_file" ]; then
		local b_rc b_store_kb b_src_kb b_out_kb b_linked b_totalf b_elapsed b_total_kb
		b_rc="$(field "$b_file" M9_RC)"
		b_store_kb="$(to_int "$(field "$b_file" M9_STORE_KB)")"
		b_src_kb="$(to_int "$(field "$b_file" M9_SRC_KB)")"
		b_out_kb="$(to_int "$(field "$b_file" M9_OUT_KB)")"
		b_linked="$(field "$b_file" M9_LINKED)"
		b_totalf="$(field "$b_file" M9_TOTALF)"
		b_elapsed="$(field "$b_file" M9_ELAPSED)"
		# store は /src の中にあるため /src の値に既に含まれる。合計へ
		# 二重に足さない (store 単体の値は比較用として別に表示するのみ)。
		b_total_kb=$((b_src_kb + b_out_kb))
		b_line="$(printf 'B(同tmpfs) rc=%s store=%s(/srcの値に含まれる) /src=%s(node_modules+store込) 合計=%s(/src+/out。storeは/srcに含まれるため加算しない) hardlink=%s/%s 所要=%ss' \
			"${b_rc:-?}" "$(kb_to_human "$b_store_kb")" "$(kb_to_human "$b_src_kb")" "$(kb_to_human "$b_total_kb")" \
			"${b_linked:-?}" "${b_totalf:-?}" "${b_elapsed:-?}")"
	else
		b_line="B(同tmpfs): SKIPPED (M9-b 未実行。harness preflight 失敗の可能性が高い)"
	fi

	if [ -f "$c_file" ]; then
		if grep -q '^M9_C_CHANGED=YES$' "$c_file"; then
			c_line="c: npm_config_store_dir で store path が変わる=YES"
		elif grep -q '^M9_C_CHANGED=NO$' "$c_file"; then
			c_line="c: npm_config_store_dir で store path が変わる=NO"
		elif grep -q '^M9_C_CHANGED=UNKNOWN' "$c_file"; then
			c_line="c: 判定不能 (default/env のいずれかがエラー終了。$c_file の M9_C_CHANGED=UNKNOWN 行を参照)"
		else
			c_line="c: 判定不能 (出力形式が想定と異なる。$c_file を直接参照)"
		fi
	else
		c_line="c: SKIPPED (M9-c 未実行)"
	fi

	# a_line / b_line / c_line は各分岐の中で既に "A(別tmpfs) rc=…" /
	# "B(同tmpfs) rc=…" / "c: …" の接頭辞を含めて組み立て済みなので、
	# ここでは接頭辞を重ねず並べるだけにする。
	printf '%s\n%s\n%s' "$a_line" "$b_line" "$c_line"
}
measure M9 "3 ケースのまとめ (A/B の合計は二重計上を避けて計算。詳細は各ケースの出力を参照)" m9_summary


# =============================================================================
# M10: prod で store-dir を既定にする手段 (最後の測定)
#
# read_only: true + tmpfs /src (exec 付き) で prod を動かし、pnpm store を
# /src/.pnpm-store (node_modules と同一 tmpfs) に置くことが M9 で確定した
# (ハードリンクが効き、RAM が案 A の半分になる)。残る問題は「store-dir を
# どうやって prod で既定にするか」— `pnpm install --store-dir <path>` の
# フラグは効くが (M9-b / M9-e で確認済み)、これを compose ファイルや
# entrypoint に焼くのはこのタスクのスコープ外 (templates/host/compose.prod.yaml /
# Dockerfile / prod-entrypoint.sh は変更しない)。設定ファイル側で既定化
# できないかを、フラグを一切渡さずに確認する。
#
# 既に判明していること (M9-c):
#   - 環境変数 npm_config_store_dir は効かない (store path が変わらなかった)
#   - `pnpm config set store-dir <path> --global` は効く (`pnpm config list
#     --global` に反映された。ただし M9-c はこのイメージの PNPM_HOME 配下
#     ルート fs への書き込みで検証しており、read_only + tmpfs /src の
#     組み合わせでは未検証)
#
# ここで測るのは、$HOME (/home/node) が tmpfs で read_only 下でも書ける、
# という性質を使って prod だけに効かせる 3 つの手段 (M10-a/b/c) と、実際に
# 効いた手段で --store-dir フラグなしの install が完走するか (M10-d)。
# compose-src-tmpfs-exec.yaml (/src が tmpfs + exec、read_only: true。M9-d/e
# で使ったのと同じファイル) を使う。狙いの値は /src/.pnpm-store/v11
# (pnpm store path は store-dir 直下に v11 を付けて返す。既定のままなら
# PNPM_HOME=/usr/local/share/pnpm を使うので /usr/local/share/pnpm/store/v11 —
# M9-c の実測どおり)。
#
# 全て MEASURE。pass/fail 判定はしない。pnpm install が走るのは M10-d の
# 1 ケースだけに絞る (M10-a/b/c は `pnpm store path` / `pnpm config get` /
# `pnpm config set` を見るだけで、いずれも install より遥かに軽い)。
#
# M10-a と M10-b は必ず別々のコンテナで実行する: 同じコンテナで両方
# 書いてしまうと、後で `pnpm store path` が変わった原因が $HOME/.npmrc と
# $HOME/.config/pnpm/rc のどちらなのか切り分けられなくなるため。
# compose_run() は呼び出すたびに新しいコンテナを起動するので、m10a/m10b/
# m10c/m10d をそれぞれ独立した関数にしておけば自然にこの要求を満たす
# (m9a/m9b/m9e と同じ考え方)。
#
# M10-d の「最初に効いた方法」の判定は、host 側 (このスクリプト自身) が
# $SCRATCH/m10{a,b,c}-output.txt (m10a/m10b/m10c が pnpm install を再実行
# せずに書き出したもの) を a → b → c の順で読み、最初に
# `M10_?_EFFECTIVE=YES` が付いたものを採用する。採用した方法の識別子
# (a/b/c) は `docker compose run -e M10D_METHOD=<method>` でコンテナへ渡し、
# コンテナ内の sh 側で case 分岐させる — bash 側で prep コマンド文字列を
# 組み立てて sh -c へ埋め込むよりも、GIT_REPO/GIT_REF 同様に環境変数で
# 渡すほうが誤引用のリスクが無く、この節の他ケースと同じ「sh -c '...' は
# 常に単引用符でまるごと囲む」書き方を崩さずに済む。三つとも NO
# (あるいは preflight 失敗で出力ファイルが無い) だった場合は
# `M10_D=SKIPPED (no working method)` を出し、install は走らせない。
#
# 推測 (docker が無い環境のため未実行・未確認):
#   - $HOME はこのイメージ内で uid 1000 実行時に /home/node へ解決される、
#     という前提で書いている。images/runtime-base/Dockerfile は ENV HOME=
#     を明示していない (base image node:24 が uid 1000 の "node" ユーザーを
#     home /home/node で作っている想定に依存)。compose-src-tmpfs(-exec).yaml
#     が /home/node へ tmpfs を割り当てているのもこの前提に沿っている
#     (M9-a のコメント参照)。もし $HOME が実際には空/未設定だった場合、
#     `$HOME/.npmrc` は `/.npmrc` に化けて read_only なルート fs への
#     書き込みになり失敗するはずで、これはこれで観測結果として記録される
#     (このため各ケースの冒頭で `echo "$HOME"` を出し、前提が崩れていた
#     場合にすぐ分かるようにしている)。
#   - `$HOME/.config/pnpm/rc` という設定ファイルの存在自体が未確認。pnpm
#     のドキュメント上、npm 形式の .npmrc とは別に独自の rc ファイルを
#     持つ可能性がある、というタスク指示の仮説をそのまま測定にしている。
#     実際には存在しない (pnpm config get store-dir が反映しない) 可能性が
#     高いことは織り込み済みで、その場合は M10_B_EFFECTIVE=NO がそのまま
#     結果になる。
#   - `pnpm config set store-dir <path>` (--global なし) が read_only 下で
#     どのファイルに書こうとするかは pnpm のバージョン依存の実装詳細で
#     あり未確認。$HOME/.npmrc と $HOME/.config/pnpm/rc の 2 箇所に加え、
#     working_dir である /src 直下の npmrc (プロジェクトスコープ) も
#     念のため見ておく (タスク指示の 2 箇所より広く見ているのは、書き先を
#     取り違えて UNKNOWN と誤判定するのを避けるため)。
#   - `docker compose run -e KEY=VALUE` でコンテナへ追加の環境変数を渡せる
#     という前提で M10-d を書いている (compose run のドキュメント上の
#     一般的な機能だが、このリポジトリの CI で使うバージョンでの実地
#     確認はできていない)。
# =============================================================================
echo
echo "=== M10: prod で store-dir を既定にする手段 ==="

# M10-a: $HOME/.npmrc に store-dir= を書く。
#
# SC2016: sh -c '...' 内の $ は意図的に単引用符でエスケープしている。
# コンテナ内の sh に渡して評価させたい文字列であって、このスクリプト
# 自身のシェルで展開させたいものではないため。
m10a_home_npmrc() {
	local proj="verify-m10-a-$$" out rc=0
	# shellcheck disable=SC2016
	out="$(compose_run "$SCRATCH/compose-src-tmpfs-exec.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		-T --rm prod sh -c '
			echo "--- \$HOME (前提の確認。/home/node のはず) ---"
			echo "$HOME"
			write_rc=0
			printf "store-dir=/src/.pnpm-store\n" > "$HOME/.npmrc" || write_rc=$?
			echo "--- \$HOME/.npmrc への書き込み rc=$write_rc ---"
			echo "--- cat \$HOME/.npmrc ---"
			cat "$HOME/.npmrc" 2>&1
			echo "--- pnpm store path (--store-dir フラグなし) ---"
			store_path=$(pnpm store path 2>&1)
			echo "$store_path"
			echo "--- pnpm config get store-dir ---"
			pnpm config get store-dir 2>&1
			case "$store_path" in
				/src/.pnpm-store*) echo "M10_A_EFFECTIVE=YES" ;;
				*) echo "M10_A_EFFECTIVE=NO" ;;
			esac
		' <<<"FOO=bar" 2>&1)" || rc=$?
	compose_down "$SCRATCH/compose-src-tmpfs-exec.yaml" "$proj"
	if [ "$rc" -ne 0 ]; then
		out="$(printf 'HARNESS: compose_run 自体が非ゼロ終了 (rc=%s)\n%s' "$rc" "$out")"
	fi
	printf '%s\n' "$out" >"$SCRATCH/m10a-output.txt"
	printf '%s\n' "$out"
}
measure_git M10 "M10-a: \$HOME/.npmrc に store-dir= を書き、フラグなしで pnpm store path が /src/.pnpm-store を指すか" m10a_home_npmrc

# M10-b: $HOME/.config/pnpm/rc に store-dir= を書く。M10-a とは別コンテナ
# (compose_run の呼び出しが別関数・別 project 名になっているので自然に
# 満たされる。M9-a/M9-b と同じ考え方)。
#
# SC2016: 上と同じ理由。
m10b_pnpm_rc() {
	local proj="verify-m10-b-$$" out rc=0
	# shellcheck disable=SC2016
	out="$(compose_run "$SCRATCH/compose-src-tmpfs-exec.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		-T --rm prod sh -c '
			echo "--- \$HOME (前提の確認。/home/node のはず) ---"
			echo "$HOME"
			mkdir_rc=0
			mkdir -p "$HOME/.config/pnpm" || mkdir_rc=$?
			write_rc=0
			printf "store-dir=/src/.pnpm-store\n" > "$HOME/.config/pnpm/rc" || write_rc=$?
			echo "--- mkdir \$HOME/.config/pnpm rc=$mkdir_rc、\$HOME/.config/pnpm/rc への書き込み rc=$write_rc ---"
			echo "--- cat \$HOME/.config/pnpm/rc ---"
			cat "$HOME/.config/pnpm/rc" 2>&1
			echo "--- pnpm store path (--store-dir フラグなし) ---"
			store_path=$(pnpm store path 2>&1)
			echo "$store_path"
			echo "--- pnpm config get store-dir ---"
			pnpm config get store-dir 2>&1
			case "$store_path" in
				/src/.pnpm-store*) echo "M10_B_EFFECTIVE=YES" ;;
				*) echo "M10_B_EFFECTIVE=NO" ;;
			esac
		' <<<"FOO=bar" 2>&1)" || rc=$?
	compose_down "$SCRATCH/compose-src-tmpfs-exec.yaml" "$proj"
	if [ "$rc" -ne 0 ]; then
		out="$(printf 'HARNESS: compose_run 自体が非ゼロ終了 (rc=%s)\n%s' "$rc" "$out")"
	fi
	printf '%s\n' "$out" >"$SCRATCH/m10b-output.txt"
	printf '%s\n' "$out"
}
measure_git M10 "M10-b: \$HOME/.config/pnpm/rc に store-dir= を書き、フラグなしで pnpm store path が /src/.pnpm-store を指すか (M10-a とは別コンテナ)" m10b_pnpm_rc

# M10-c: `pnpm config set store-dir <path>` (--global なし) が read_only 下で
# 成功するか、成功した場合どのファイルに書かれるかを見る。$HOME/.npmrc /
# $HOME/.config/pnpm/rc に加え、working_dir (/src) 直下の npmrc も
# 念のため確認する (どちらの想定にも当てはまらず UNKNOWN と誤判定するのを
# 避けるため)。
#
# SC2016: 上と同じ理由。
m10c_config_set() {
	local proj="verify-m10-c-$$" out rc=0
	# shellcheck disable=SC2016
	out="$(compose_run "$SCRATCH/compose-src-tmpfs-exec.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		-T --rm prod sh -c '
			if set_out=$(pnpm config set store-dir /src/.pnpm-store 2>&1); then
				set_rc=0
			else
				set_rc=$?
			fi
			echo "--- pnpm config set store-dir /src/.pnpm-store (--global なし) rc=$set_rc ---"
			echo "$set_out"
			echo "--- pnpm store path (--store-dir フラグなし) ---"
			store_path=$(pnpm store path 2>&1)
			echo "$store_path"
			echo "--- pnpm config get store-dir ---"
			pnpm config get store-dir 2>&1
			echo "--- ls -la \$HOME/.npmrc \$HOME/.config/pnpm/rc (どちらに書かれたか特定) ---"
			ls -la "$HOME/.npmrc" "$HOME/.config/pnpm/rc" 2>&1
			echo "--- ls -la /src/.npmrc (working_dir 直下。念のための追加確認) ---"
			ls -la /src/.npmrc 2>&1

			# CI 7 回目では上の候補 3 つがいずれも外れ、書き込み先が UNKNOWN の
			# まま残った。read_only: true 下で rc=0 だった以上、書けるのは tmpfs
			# のいずれか (/run /tmp /out /home/node /src) に限られる。候補の列挙を
			# 続けるのをやめ、マーカーより新しいファイルを直接探す。
			#
			# marker は set の「前」に作る必要があるが、この時点では既に実行済み
			# なので、別の値でもう一度 set して前後の差分を取る。設定は最後の実行
			# が勝つため、探索後に本来の値へ戻す。
			echo "--- 書き込み先の探索: marker より新しいファイルを tmpfs 上から探す ---"
			: > /tmp/.m10c-marker
			pnpm config set store-dir /src/.pnpm-store-probe >/dev/null 2>&1 || true
			find /home/node /src /tmp /run /out -newer /tmp/.m10c-marker -type f 2>/dev/null \
				| grep -v "/.m10c-marker$" | head -20
			echo "--- 上記のうち store-dir を含むものの中身 ---"
			find /home/node /src /tmp /run /out -newer /tmp/.m10c-marker -type f 2>/dev/null \
				| while read -r f; do
					if grep -q store-dir "$f" 2>/dev/null; then
						echo "[$f]"
						cat "$f"
					fi
				done
			pnpm config set store-dir /src/.pnpm-store >/dev/null 2>&1 || true

			wrote_to=UNKNOWN
			if [ -f "$HOME/.npmrc" ] && grep -q store-dir "$HOME/.npmrc" 2>/dev/null; then
				wrote_to="$HOME/.npmrc"
			elif [ -f "$HOME/.config/pnpm/rc" ] && grep -q store-dir "$HOME/.config/pnpm/rc" 2>/dev/null; then
				wrote_to="$HOME/.config/pnpm/rc"
			elif [ -f /src/.npmrc ] && grep -q store-dir /src/.npmrc 2>/dev/null; then
				wrote_to="/src/.npmrc"
			fi
			echo "M10_C_SET_RC=$set_rc"
			echo "M10_C_WROTE_TO=$wrote_to"
			case "$store_path" in
				/src/.pnpm-store*) echo "M10_C_EFFECTIVE=YES" ;;
				*) echo "M10_C_EFFECTIVE=NO" ;;
			esac
		' <<<"FOO=bar" 2>&1)" || rc=$?
	compose_down "$SCRATCH/compose-src-tmpfs-exec.yaml" "$proj"
	if [ "$rc" -ne 0 ]; then
		out="$(printf 'HARNESS: compose_run 自体が非ゼロ終了 (rc=%s)\n%s' "$rc" "$out")"
	fi
	printf '%s\n' "$out" >"$SCRATCH/m10c-output.txt"
	printf '%s\n' "$out"
}
measure_git M10 "M10-c: pnpm config set store-dir (--global なし) が read_only 下で成功するか、どこに書かれるか" m10c_config_set

# m10_pick_method: M10-a/b/c が書き出した $SCRATCH/m10{a,b,c}-output.txt を
# a → b → c の順で読み、最初に `M10_?_EFFECTIVE=YES` が付いたものの識別子
# (a/b/c) を返す。どれも無ければ "none"。docker を呼ばない純粋な host 側の
# 判定なので measure() を経由させず、m10d_install_case() から直接呼ぶ
# (m9_summary の field() ヘルパーと同じ考え方で、$SCRATCH 配下の出力
# ファイルをテキストとして読むだけ)。
m10_pick_method() {
	if [ -f "$SCRATCH/m10a-output.txt" ] && grep -q '^M10_A_EFFECTIVE=YES$' "$SCRATCH/m10a-output.txt"; then
		echo a
	elif [ -f "$SCRATCH/m10b-output.txt" ] && grep -q '^M10_B_EFFECTIVE=YES$' "$SCRATCH/m10b-output.txt"; then
		echo b
	elif [ -f "$SCRATCH/m10c-output.txt" ] && grep -q '^M10_C_EFFECTIVE=YES$' "$SCRATCH/m10c-output.txt"; then
		echo c
	else
		echo none
	fi
}

# M10-d: m10_pick_method() が選んだ方法で、--store-dir フラグなしの
# `pnpm install --frozen-lockfile` が完走するかを見る。pnpm-lock.yaml を
# 持つ実在のリポジトリが要るため、M10-a/b/c の TEST_BARE_DIR ではなく
# M9 と同じ SELF_BARE_DIR (このリポジトリ自身) を使う。
#
# 採用した方法の識別子はコンテナへ環境変数 M10D_METHOD として渡し、
# コンテナ内の sh 側で case 分岐させる (このファイル冒頭のコメント参照。
# bash 側で prep コマンド文字列を組み立てて sh -c へ差し込むより、
# GIT_REPO/GIT_REF と同じ「env 経由でコンテナへ渡す」やり方に揃えたほうが
# 誤引用のリスクが無い)。
#
# SC2016: 上と同じ理由。
m10d_install_case() {
	local method
	method="$(m10_pick_method)"

	if [ "$method" = none ]; then
		printf '%s\n' "M10_D=SKIPPED (no working method: M10-a/b/c のいずれも EFFECTIVE=YES にならなかった)"
		return 0
	fi

	local proj="verify-m10-d-$$" out rc=0
	# shellcheck disable=SC2016
	out="$(compose_run "$SCRATCH/compose-src-tmpfs-exec.yaml" "$proj" "file://$SELF_BARE_DIR" "$SELF_COMMIT" \
		-T --rm -e M10D_METHOD="$method" prod sh -c '
			case "$M10D_METHOD" in
				a) printf "store-dir=/src/.pnpm-store\n" > "$HOME/.npmrc" ;;
				b) mkdir -p "$HOME/.config/pnpm" && printf "store-dir=/src/.pnpm-store\n" > "$HOME/.config/pnpm/rc" ;;
				c) pnpm config set store-dir /src/.pnpm-store ;;
				*) : ;;
			esac
			echo "--- 採用した方法 (M10-a/b/c のうち最初に EFFECTIVE=YES だったもの): $M10D_METHOD ---"
			echo "--- pnpm install --frozen-lockfile (--store-dir フラグなし) ---"
			pnpm install --frozen-lockfile >/tmp/m10d-install.log 2>&1
			rc=$?
			echo "rc=$rc"
			echo "--- pnpm install 出力の末尾 (トラブル時の手がかり用) ---"
			tail -20 /tmp/m10d-install.log
			echo "--- \"Packages are hard linked\" / \"copied\" を含む行 (hardlink か copy かの一次判定) ---"
			grep -iE "hard linked|copied" /tmp/m10d-install.log || echo "(該当行なし)"
			echo "--- pnpm store path (--store-dir フラグなし) ---"
			pnpm store path 2>&1
			echo "--- hardlink 判定: node_modules 内、リンク数 2 以上 (links+1) のファイル数 / 全ファイル数 ---"
			linked=$(find node_modules -type f -links +1 2>/dev/null | wc -l)
			totalf=$(find node_modules -type f 2>/dev/null | wc -l)
			echo "links+1=$linked total=$totalf"
			echo "--- store の実際の場所 (du -sh /src/.pnpm-store) ---"
			du -sh /src/.pnpm-store 2>&1 || echo "du failed (store may not exist)"
			echo "M10_D_METHOD=$M10D_METHOD"
			echo "M10_D_RC=$rc"
			echo "M10_D_LINKED=$linked"
			echo "M10_D_TOTALF=$totalf"
		' <<<"FOO=bar" 2>&1)" || rc=$?
	compose_down "$SCRATCH/compose-src-tmpfs-exec.yaml" "$proj"
	if [ "$rc" -ne 0 ]; then
		out="$(printf 'HARNESS: compose_run 自体が非ゼロ終了 (rc=%s。pnpm install 個別の rc は本文中の rc= 行を見ること)\n%s' "$rc" "$out")"
	fi
	printf '%s\n' "$out" >"$SCRATCH/m10d-output.txt"
	printf '%s\n' "$out"
}
measure_git M10 "M10-d: 最初に効いた方法 (a→b→c の順) で --store-dir フラグなしの pnpm install --frozen-lockfile が完走するか" m10d_install_case

# M10 まとめ: M10-a/b/c/d の出力ファイルを読み、タスク指示の書式
# (a/b の YES/NO、c の書き込み先、d の rc/hardlink 比) で 1 ブロックに
# まとめる。m9_summary と同じ考え方で、$SCRATCH 配下のファイルをテキスト
# として読むだけの host 側処理なので measure_git ではなく measure を使う。
m10_summary() {
	field() { grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-; }

	local a_file="$SCRATCH/m10a-output.txt" b_file="$SCRATCH/m10b-output.txt"
	local c_file="$SCRATCH/m10c-output.txt" d_file="$SCRATCH/m10d-output.txt"
	local a_eff b_eff c_eff c_wrote d_summary

	if [ -f "$a_file" ]; then
		a_eff="$(field "$a_file" M10_A_EFFECTIVE)"
	else
		a_eff="SKIPPED (M10-a 未実行)"
	fi

	if [ -f "$b_file" ]; then
		b_eff="$(field "$b_file" M10_B_EFFECTIVE)"
	else
		b_eff="SKIPPED (M10-b 未実行)"
	fi

	if [ -f "$c_file" ]; then
		c_eff="$(field "$c_file" M10_C_EFFECTIVE)"
		c_wrote="$(field "$c_file" M10_C_WROTE_TO)"
	else
		c_eff="SKIPPED (M10-c 未実行)"
		c_wrote="-"
	fi

	if [ -f "$d_file" ]; then
		if grep -q '^M10_D=SKIPPED' "$d_file"; then
			d_summary="SKIPPED (no working method)"
		else
			local d_method d_rc d_linked d_totalf
			d_method="$(field "$d_file" M10_D_METHOD)"
			d_rc="$(field "$d_file" M10_D_RC)"
			d_linked="$(field "$d_file" M10_D_LINKED)"
			d_totalf="$(field "$d_file" M10_D_TOTALF)"
			d_summary="$(printf 'method=%s rc=%s hardlink=%s/%s' "${d_method:-?}" "${d_rc:-?}" "${d_linked:-?}" "${d_totalf:-?}")"
		fi
	else
		d_summary="SKIPPED (M10-d 未実行)"
	fi

	# shellcheck disable=SC2016
	printf 'M10 まとめ: a($HOME/.npmrc)=%s  b($HOME/.config/pnpm/rc)=%s\n            c(config set, 書き込み先=%s)=%s\n            d(効いた方法で install)=%s' \
		"${a_eff:-?}" "${b_eff:-?}" "${c_wrote:-?}" "${c_eff:-?}" "${d_summary}"
}
measure M10 "4 ケースのまとめ (書式はタスク指示のとおり)" m10_summary


# =============================================================================
# M3: dotenvx 2.x の環境変数注入 (最優先)
#
# dotenvx 2.0.0 は keyring 対応で run / config / get を
# @dotenvx/primitives 由来の共有 resolver 経由へ付け替えている。shim
# (shims/dotenvx) が依存する DOTENV_PRIVATE_KEY_* の env 注入経路が 2.19.2
# でも従来通り効くかが未検証 (images/runtime-base/Dockerfile のコメント
# 参照)。
#
# 推測: `dotenvx encrypt -f <file>` は既存の平文 KEY=value 行をその場で
# 暗号化し、同じディレクトリの .env.keys に DOTENV_PRIVATE_KEY_<NAME>=…
# を書き出す (NAME は -f のファイル名規約、.env.test → TEST)。同じ
# ディレクトリで複数ファイルを encrypt すると .env.keys に複数行が
# 積み上がる想定で M3-3 (複数鍵の同居) を組み立てている。この I/O 契約は
# CHANGELOG 上は確認したが実行はしていないため、docker のあるホストでの
# 初回実行時にここが崩れていないか出力を確認すること。
# =============================================================================
echo
echo "=== M3: dotenvx 2.x の環境変数注入 ==="

# 1. 環境変数 DOTENV_PRIVATE_KEY_TEST を直接与えて get / run が復号できるか
#    (shim を経由しない、/opt/tools/bin の実体を直接呼ぶ)。
m3_envvar() {
	docker run --rm --user 1000:1000 -e HOME=/tmp "$IMG" sh -c '
		set -e
		cd /tmp
		printf "FOO=bar\n" > .env.test
		/opt/tools/bin/dotenvx encrypt -f .env.test >/dev/null
		key="$(grep "^DOTENV_PRIVATE_KEY_TEST=" .env.keys | cut -d= -f2-)"
		rm -f .env.keys
		export DOTENV_PRIVATE_KEY_TEST="$key"
		echo "--- dotenvx get -f .env.test FOO ---"
		/opt/tools/bin/dotenvx get -f .env.test FOO
		echo "--- dotenvx run -f .env.test -- printenv FOO ---"
		/opt/tools/bin/dotenvx run -f .env.test -- printenv FOO
	' 2>&1
}
measure M3 "DOTENV_PRIVATE_KEY_TEST env var で get/run が復号できるか (shim 経由なし)" m3_envvar

# 2. shim 経由 (/run/secrets/DOTENV_PRIVATE_KEY_TEST にファイルを置き、env は
#    設定しない)。同時に、get 実行前後で ls -la が変わらない (ファイルを
#    作らない) ことも確認する。
m3_shimfile() {
	# バグ2: --tmpfs /run が無いと /run はイメージのルート fs 上の
	# root:root 755 ディレクトリのままで、uid 1000 は mkdir /run/secrets
	# できない (M1 が確定させた事実、素の tmpfs 既定 mode と同じ結果に
	# なる)。uid=1000,gid=1000,mode=0755 の tmpfs を明示して初めて
	# entrypoint 実運用時と同じ書き込み可能な /run/secrets になる。
	docker run --rm --user 1000:1000 -e HOME=/tmp \
		--tmpfs /run:uid=1000,gid=1000,mode=0755 \
		"$IMG" sh -c '
		set -e
		cd /tmp
		printf "FOO=bar\n" > .env.test
		/opt/tools/bin/dotenvx encrypt -f .env.test >/dev/null
		key="$(grep "^DOTENV_PRIVATE_KEY_TEST=" .env.keys | cut -d= -f2-)"
		rm -f .env.keys
		mkdir -p /run/secrets
		printf "%s" "$key" > /run/secrets/DOTENV_PRIVATE_KEY_TEST
		before="$(ls -la .)"
		echo "--- dotenvx get -f .env.test FOO (shim 経由) ---"
		dotenvx get -f .env.test FOO
		after="$(ls -la .)"
		if [ "$before" = "$after" ]; then
			echo "ls -la: 前後で差分なし (ファイルを作らない)"
		else
			echo "ls -la: 前後で差分あり"
			echo "before: $before"
			echo "after:  $after"
		fi
	' 2>&1
}
measure M3 "shim 経由 (/run/secrets ファイル) で get が復号できるか + ファイル増加なしの確認" m3_shimfile

# 3. 複数鍵の同居: _LOCAL と _TEST を同時に /run/secrets へ置き、-f .env.test
#    で正しい鍵が選ばれるか (dev container で _LOCAL + _DEVELOPMENT が同居
#    する想定と同型)。
m3_multikey() {
	# バグ2: m3_shimfile と同じ理由で --tmpfs /run:uid=... を明示する。
	docker run --rm --user 1000:1000 -e HOME=/tmp \
		--tmpfs /run:uid=1000,gid=1000,mode=0755 \
		"$IMG" sh -c '
		set -e
		cd /tmp
		printf "FOO=from-local\n" > .env.local
		printf "FOO=from-test\n" > .env.test
		/opt/tools/bin/dotenvx encrypt -f .env.local >/dev/null
		/opt/tools/bin/dotenvx encrypt -f .env.test >/dev/null
		key_local="$(grep "^DOTENV_PRIVATE_KEY_LOCAL=" .env.keys | cut -d= -f2-)"
		key_test="$(grep "^DOTENV_PRIVATE_KEY_TEST=" .env.keys | cut -d= -f2-)"
		rm -f .env.keys
		mkdir -p /run/secrets
		printf "%s" "$key_local" > /run/secrets/DOTENV_PRIVATE_KEY_LOCAL
		printf "%s" "$key_test" > /run/secrets/DOTENV_PRIVATE_KEY_TEST
		echo "--- dotenvx get -f .env.test FOO (期待値: from-test) ---"
		dotenvx get -f .env.test FOO
		echo "--- dotenvx get -f .env.local FOO (期待値: from-local) ---"
		dotenvx get -f .env.local FOO
	' 2>&1
}
measure M3 "DOTENV_PRIVATE_KEY_LOCAL + _TEST 同居時、-f .env.test が正しい鍵を選ぶか" m3_multikey


# =============================================================================
# M4: dotenvx 1.x で暗号化したファイルを 2.x が復号できるか
#
# 既存 4 repo は enclave-env の peer range ^1.63.0 下で運用中。runtime-base
# は dotenvx 2.19.2 を焼くため、1.x で暗号化された .env.* が 2.x でそのまま
# 読めるかが移行可否を左右する。
#
# 暗号化はランナー側 (コンテナ外) で npx @dotenvx/dotenvx@1.75.1 を使って
# 行う。ネットワークで npm レジストリから 1.75.1 を取得するため、CI /
# macOS ホストともに Node.js (npx) と npm レジストリへの到達性が前提。
# npx が無いホストでは SKIPPED として記録し、スクリプト自体は止めない。
# =============================================================================
echo
echo "=== M4: dotenvx 1.x → 2.x 互換性 ==="

m4_legacy_decrypt() {
	if ! command -v npx >/dev/null 2>&1; then
		echo "SKIPPED: npx が見つからない (Node.js 未インストール)"
		return 0
	fi
	local dir out rc=0
	dir="$SCRATCH/m4-legacy"
	mkdir -p "$dir"
	(
		cd "$dir"
		printf 'FOO=legacy-value\n' >.env.legacy
		npx --yes @dotenvx/dotenvx@1.75.1 encrypt -f .env.legacy
	) >"$dir/encrypt.log" 2>&1 || rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "FAILED: ランナー側での 1.75.1 暗号化に失敗 (rc=$rc): $(cat "$dir/encrypt.log")"
		return 0
	fi
	local key
	key="$(grep '^DOTENV_PRIVATE_KEY_LEGACY=' "$dir/.env.keys" | cut -d= -f2-)"
	if [ -z "$key" ]; then
		echo "FAILED: .env.keys に DOTENV_PRIVATE_KEY_LEGACY が見つからない: $(cat "$dir/.env.keys" 2>&1)"
		return 0
	fi
	# .env.keys は 2.x 側に持ち込まない (env var 経由の復号だけを見たいため。
	# .env.keys があると自動フォールバックで「env var が効いていなくても
	# 通ってしまう」誤検知になる)。
	rm -f "$dir/.env.keys" "$dir/encrypt.log"
	out="$(docker run --rm --user 1000:1000 -v "$dir:$dir:ro" -w "$dir" \
		-e DOTENV_PRIVATE_KEY_LEGACY="$key" \
		"$IMG" dotenvx get -f .env.legacy FOO 2>&1)" || rc=$?
	if [ "$rc" -eq 0 ] && [ "$out" = "legacy-value" ]; then
		echo "OK: 1.75.1 で暗号化したファイルを 2.19.2 が復号できた (FOO=$out)"
	else
		echo "FAILED (rc=$rc): $out"
	fi
}
measure M4 "dotenvx 1.75.1 で暗号化したファイルを 2.19.2 が DOTENV_PRIVATE_KEY_* env var で復号できるか" m4_legacy_decrypt


# =============================================================================
# M5: pnpm run 内側のローカル dotenvx に鍵が届くか
#
# `pnpm run <script>` は node_modules/.bin を PATH の先頭に積むため、
# プロジェクトがローカルに dotenvx を持つと shim に勝つ。ここでは
# ローカル dotenvx として /opt/tools/bin/dotenvx (shim の実体そのもの) を
# node_modules/.bin へシンボリックリンクする。これは「ローカルにも実体の
# dotenvx がある」状況を、npm レジストリからの追加インストールなしに
# 再現するための代用であり、実運用でプロジェクトが devDependencies に
# 持つ dotenvx とバイナリの出自は異なるが、PATH 解決とプロセス環境変数の
# 継承という M5 が見たい性質そのものには影響しない。
# =============================================================================
echo
echo "=== M5: pnpm run 内側のローカル dotenvx への鍵到達 ==="

m5_pnpm_local_dotenvx() {
	# バグ2: ケース B が /run/secrets へ書き込む (shim 経由の鍵注入) ため、
	# m3_shimfile と同じ理由で --tmpfs /run:uid=... を明示する。
	docker run --rm --user 1000:1000 \
		--tmpfs /run:uid=1000,gid=1000,mode=0755 \
		"$IMG" sh -c '
		set -e
		mkdir -p /tmp/proj/node_modules/.bin
		ln -s /opt/tools/bin/dotenvx /tmp/proj/node_modules/.bin/dotenvx
		cd /tmp/proj
		cat > package.json <<PKGJSON
{"name":"m5-test","version":"0.0.0","scripts":{"deploy":"dotenvx run -f .env.test -- printenv FOO"}}
PKGJSON
		printf "FOO=bar\n" > .env.test
		/opt/tools/bin/dotenvx encrypt -f .env.test >/dev/null
		key="$(grep "^DOTENV_PRIVATE_KEY_TEST=" .env.keys | cut -d= -f2-)"
		rm -f .env.keys

		echo "=== ケース A: pnpm deploy を直接呼ぶ (鍵はどこにも無い) ==="
		set +e
		out_a="$(pnpm run deploy 2>&1)"
		rc_a=$?
		set -e
		echo "rc=$rc_a"
		echo "$out_a"
		echo

		echo "=== ケース B: dotenvx run -f .env.test -- pnpm deploy (最上位に dotenvx、鍵は shim 経由) ==="
		mkdir -p /run/secrets
		printf "%s" "$key" > /run/secrets/DOTENV_PRIVATE_KEY_TEST
		set +e
		out_b="$(dotenvx run -f .env.test -- pnpm run deploy 2>&1)"
		rc_b=$?
		set -e
		echo "rc=$rc_b"
		echo "$out_b"
	' 2>&1
}
measure M5 "ケース A (直接 pnpm deploy、失敗が期待値) / ケース B (dotenvx run 経由、成功が期待値)" m5_pnpm_local_dotenvx


# =============================================================================
# M6: N-1 / N-2 が tmpfs 化で消えることの確認
#
# named volume での再現と、tmpfs にした場合の消滅の両方を測る。M6 全体を
# MEASURE として扱う理由: 「tmpfs にすれば N-1 / N-2 が構造的に消える」は
# 設計上の予想であって、tmpfs の実装細部 (compose の run ごとに本当に
# まっさらになるか等) に依存するため、ここで実際に踏んで確認しないと
# 確定できない。
# =============================================================================
echo
echo "=== M6: N-1 / N-2 と tmpfs 化 ==="

# --- N-1: ref 汚染 --------------------------------------------------------------
m6_n1_named_volume() {
	local proj="verify-m6-n1-$$" rc1=0 rc2=0 out2
	# --entrypoint (bugfix: tmpfs 自己検査の追加に伴う変更): 素の entrypoint は
	# named volume の /src を検出して checkout 前に exit 1 するため、N-1 の
	# 再現 (1st run で打ったタグが 2nd run に残っているか) に到達できない。
	# ここで残したいのは「named volume だと穴が残る」ことの実測記録なので、
	# 自己検査の対象パスだけを番兵へ差し替えたコピーを entrypoint に使う
	# (詳細は setup の ENTRYPOINT_NO_TMPFS_CHECK のコメント。防壁自体が
	# 効くことは A35 が別途 assert する)。
	compose_run "$SCRATCH/compose-current.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		--entrypoint "$ENTRYPOINT_NO_TMPFS_CHECK" \
		-T --rm prod sh -c "git tag v9.9.9 $TEST_COMMIT2" <<<"FOO=bar" >/dev/null 2>&1 || rc1=$?
	# PROD_ALLOW_MUTABLE_REF=1 (bugfix: D21 の追加に伴う変更): この測定は
	# GIT_REF にタグ (v9.9.9) を渡すことで成立するが、D21 以降 entrypoint は
	# 完全な commit sha 以外を既定で拒否するため、ref 解決に一度も到達せず
	# 「rc=1」だけが残る。tmpfs 側は期待どおりの rc に見えてしまうので質が悪い
	# — 意図した経路を通らずに期待値と一致する、この記録が繰り返し踏んできた
	# 偽の合格そのものである。脱出口を明示して tag 経路を実際に通す。
	# `-e` はコンテナの env に効く (compose ファイルの ${...} 補間とは別経路で、
	# パース時点を過ぎていても間に合う)。
	out2="$(compose_run "$SCRATCH/compose-current.yaml" "$proj" "file://$TEST_BARE_DIR" "v9.9.9" \
		--entrypoint "$ENTRYPOINT_NO_TMPFS_CHECK" \
		-e PROD_ALLOW_MUTABLE_REF=1 \
		-T --rm prod cat file.txt <<<"FOO=bar" 2>&1)" || rc2=$?
	compose_down "$SCRATCH/compose-current.yaml" "$proj"
	echo "1st run (commit1 を checkout 後、ローカルタグ v9.9.9 を commit2 に打つ): rc=$rc1"
	echo "2nd run (同じ volume、GIT_REF=v9.9.9、PROD_ALLOW_MUTABLE_REF=1): rc=$rc2 file.txt=$out2"
	echo "  読み方: file.txt が world なら汚染された ref (commit2) が解決された = N-1 再現。"
	echo "  hello (commit1) なら再現せず。'must be a full 40-character commit sha' が出ていたら"
	echo "  脱出口が届いておらず、この測定は N-1 を測れていない。"
}
measure_git M6 "named volume 再利用: ref 汚染 (N-1) が再現するか" m6_n1_named_volume

m6_n1_tmpfs() {
	local proj="verify-m6-n1-tmpfs-$$" rc1=0 rc2=0 out2
	# bugfix: exec なしの compose-src-tmpfs.yaml だと prod-entrypoint.sh の
	# /src noexec 自己検査で 1st run の checkout 前に落ち、この測定が見たい
	# 「tag を打った後の 2nd run で state が消えているか」に到達できない。
	# compose-src-tmpfs.yaml 自体は M9-a/M9-b 専用に残す (同ファイルのコメント
	# 参照) ので、ここは exec 付きの compose-src-tmpfs-exec.yaml を使う。
	compose_run "$SCRATCH/compose-src-tmpfs-exec.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		-T --rm prod sh -c "git tag v9.9.9 $TEST_COMMIT2" <<<"FOO=bar" >/dev/null 2>&1 || rc1=$?
	# PROD_ALLOW_MUTABLE_REF=1: m6_n1_named_volume と同じ理由 (D21 の sha ゲートを
	# 通さないと ref 解決に到達せず、この測定が N-1 を測れない)。tmpfs 側は
	# 特に紛らわしい — ゲートで落ちても「rc=1」になり、期待値と一致して見える。
	out2="$(compose_run "$SCRATCH/compose-src-tmpfs-exec.yaml" "$proj" "file://$TEST_BARE_DIR" "v9.9.9" \
		-e PROD_ALLOW_MUTABLE_REF=1 \
		-T --rm prod cat file.txt <<<"FOO=bar" 2>&1)" || rc2=$?
	compose_down "$SCRATCH/compose-src-tmpfs-exec.yaml" "$proj"
	echo "1st run: rc=$rc1"
	echo "2nd run (GIT_REF=v9.9.9、PROD_ALLOW_MUTABLE_REF=1。tmpfs なので /src は毎回まっさら): rc=$rc2 out=$out2"
	echo "  読み方: 'does not resolve to a commit' で落ちていれば、前回のタグが残っておらず"
	echo "  fail-closed になった = tmpfs 化が効いている。file.txt の中身が出ていたらタグが"
	echo "  残っている。'must be a full 40-character commit sha' なら脱出口が届いていない。"
}
measure_git M6 "tmpfs /src: ref 汚染 (N-1) が消えるか" m6_n1_tmpfs

# --- N-2: .git/config 持続 (core.fsmonitor) --------------------------------------
m6_n2_named_volume() {
	local proj="verify-m6-n2-$$" rc1=0 rc2=0 out2
	# --entrypoint: m6_n1_named_volume と同じ理由 (tmpfs 自己検査の迂回)。
	# N-2 は「entrypoint 自身の fetch/checkout/reset/clean が仕込まれた
	# fsmonitor を起動させるか」を見る測定なので、entrypoint を外す形での
	# 迂回は採れない。
	compose_run "$SCRATCH/compose-current.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		--entrypoint "$ENTRYPOINT_NO_TMPFS_CHECK" \
		-T --rm prod git config core.fsmonitor 'sh -c "echo FSMONITOR_RAN >> /tmp/fsmonitor-marker; exit 1"' \
		<<<"FOO=bar" >/dev/null 2>&1 || rc1=$?
	out2="$(compose_run "$SCRATCH/compose-current.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		--entrypoint "$ENTRYPOINT_NO_TMPFS_CHECK" \
		-T --rm prod cat /tmp/fsmonitor-marker <<<"FOO=bar" 2>&1)" || rc2=$?
	compose_down "$SCRATCH/compose-current.yaml" "$proj"
	echo "1st run (core.fsmonitor をローカルに仕込む): rc=$rc1"
	echo "2nd run (同じ GIT_REF で再実行。entrypoint 自身の fetch/checkout/reset/clean が fsmonitor を起動させたか): rc=$rc2 marker=$out2"
}
measure_git M6 "named volume 再利用: core.fsmonitor 持続 (N-2) が再現するか" m6_n2_named_volume

m6_n2_tmpfs() {
	local proj="verify-m6-n2-tmpfs-$$" rc1=0 rc2=0 out2
	# bugfix: m6_n1_tmpfs と同じ理由で exec 付き compose-src-tmpfs-exec.yaml に
	# 切り替える (compose-src-tmpfs.yaml は M9-a/M9-b 専用に残す)。
	compose_run "$SCRATCH/compose-src-tmpfs-exec.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		-T --rm prod git config core.fsmonitor 'sh -c "echo FSMONITOR_RAN >> /tmp/fsmonitor-marker; exit 1"' \
		<<<"FOO=bar" >/dev/null 2>&1 || rc1=$?
	out2="$(compose_run "$SCRATCH/compose-src-tmpfs-exec.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		-T --rm prod sh -c 'grep -c fsmonitor /src/.git/config 2>/dev/null || echo "0 (fresh .git/config)"' \
		<<<"FOO=bar" 2>&1)" || rc2=$?
	compose_down "$SCRATCH/compose-src-tmpfs-exec.yaml" "$proj"
	echo "1st run: rc=$rc1"
	echo "2nd run (tmpfs なので /src は毎回まっさらのはず): rc=$rc2 fsmonitor 設定の有無=$out2"
}
measure_git M6 "tmpfs /src: core.fsmonitor 持続 (N-2) が消えるか" m6_n2_tmpfs

# credential.helper 経由の GH_TOKEN 窃取の試み。難しければ core.fsmonitor
# だけでよいとタスク側の指示にあるとおり、ここでは試みた内容と結果を
# そのまま記録する。file:// transport は認証を必要としないため、git が
# そもそも credential.helper を呼ばない可能性が高いという仮説込みで見ること。
m6_n2_credential_helper() {
	local proj="verify-m6-n2-cred-$$" rc1=0 rc2=0 out2
	# --entrypoint: m6_n1_named_volume と同じ理由 (tmpfs 自己検査の迂回)。
	compose_run "$SCRATCH/compose-current.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		--entrypoint "$ENTRYPOINT_NO_TMPFS_CHECK" \
		-T --rm prod git config credential.helper '!cat /run/secrets/GH_TOKEN > /src/.stolen-token 2>/dev/null; echo done' \
		<<<"FOO=bar" >/dev/null 2>&1 || rc1=$?
	out2="$(compose_run "$SCRATCH/compose-current.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		--entrypoint "$ENTRYPOINT_NO_TMPFS_CHECK" \
		-T --rm prod sh -c 'if [ -f /src/.stolen-token ]; then cat /src/.stolen-token; else echo NOT_PRESENT; fi' \
		<<<"$(printf 'GH_TOKEN=dummy-gh-token\nFOO=bar\n')" 2>&1)" || rc2=$?
	compose_down "$SCRATCH/compose-current.yaml" "$proj"
	echo "1st run (credential.helper に窃取コマンドを仕込む): rc=$rc1"
	echo "2nd run (GH_TOKEN 付きで再実行): rc=$rc2 result=$out2"
	echo "注記: file:// はホスト上のパスへの直接アクセスであり認証を要求しないため、git が credential.helper 自体を呼ばない可能性が高い。上記はその前提込みの生の観測結果。"
}
measure_git M6 "named volume 再利用: credential.helper 経由の GH_TOKEN 窃取の試み" m6_n2_credential_helper

# --- git: github.com の credential helper 固定 (実イメージでの確認) --------------
#
# git は credential helper を設定順に呼び、最初に資格情報を返した helper で解決を
# 確定する。GIT_ASKPASS はどの helper も答えなかった場合のフォールバックでしかなく、
# しかも VS Code は統合ターミナルの environ へ GIT_ASKPASS を注入して上書きしてくる。
# そこでイメージは GIT_CONFIG_COUNT=2 を使い、スロット 0 の空値で github.com 向けに
# 積まれた helper を全て捨て、スロット 1 で自前の helper を絶対パスで積み直している。
#
# 打ち消しと積み直しのロジックそのものは tests/git-credential.test.sh が docker なしで
# 見ている。ここで見るのは「実際にビルドされたイメージの ENV にそれが載っていて、
# 実効値が自前 helper 1 本になっているか」で、Dockerfile の ENV 行が消えたり別の
# レイヤで上書きされたりしたらここで落ちる。VS Code が書くのと同じ形 (global の
# generic な helper) をコンテナ内で再現してから確認する。
#
# shellcheck disable=SC2016 # $(...) と "$..." はこのスクリプトではなくコンテナ
# 内の sh に評価させる。
m6_credential_reset() {
	docker run --rm --user 1000:1000 -e HOME=/tmp "$IMG" sh -c '
		printf "#!/bin/sh\nexit 0\n" > /tmp/vscode-helper.sh
		chmod +x /tmp/vscode-helper.sh
		git config --global credential.helper /tmp/vscode-helper.sh
		echo "ENV=[$(env | grep ^GIT_CONFIG_ | sort | tr "\n" " ")]"
		echo "github.com (固定あり)=[$(git config --get-urlmatch credential.helper https://github.com)]"
		echo "github.com (否定対照: ENV を外す)=[$(env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 -u GIT_CONFIG_KEY_1 -u GIT_CONFIG_VALUE_1 git config --get-urlmatch credential.helper https://github.com)]"
		echo "gitlab.com (打ち消しは URL 限定)=[$(git config --get-urlmatch credential.helper https://gitlab.com)]"
	'
}
measure M6 "github.com の credential helper 固定がイメージに載っているか" m6_credential_reset

# shellcheck disable=SC2016 # 同上。
a6_credential_reset() {
	docker run --rm --user 1000:1000 -e HOME=/tmp "$IMG" sh -c '
		printf "#!/bin/sh\nexit 0\n" > /tmp/vscode-helper.sh
		chmod +x /tmp/vscode-helper.sh
		git config --global credential.helper /tmp/vscode-helper.sh
		[ "$(git config --get-urlmatch credential.helper https://github.com)" = /usr/local/bin/git-credential-gh-token ] || exit 1
		[ "$(env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 -u GIT_CONFIG_KEY_1 -u GIT_CONFIG_VALUE_1 git config --get-urlmatch credential.helper https://github.com)" = /tmp/vscode-helper.sh ] || exit 2
		[ "$(git config --get-urlmatch credential.helper https://gitlab.com)" = /tmp/vscode-helper.sh ] || exit 3
	'
}
assert M6 "github.com の helper が自前 1 本になり、否定対照 (ENV なし) と他ホストでは VS Code 相当が残る" a6_credential_reset

# トークンが無いときに helper が連鎖ごと止めること。helper が「答えない」だけだと
# git は次の helper や GIT_ASKPASS へフォールスルーして、そこで成功しうる。
# prod container には /run/secrets/GH_TOKEN が無い状態で起動できるので、そのまま
# `git credential fill` を流して quit=1 の効果を見る。GIT_ASKPASS には「答えて
# しまう」ものを置き、それが呼ばれないことまで確かめる。
#
# shellcheck disable=SC2016 # 同上。
a6_credential_quit() {
	docker run --rm --user 1000:1000 -e HOME=/tmp "$IMG" sh -c '
		printf "#!/bin/sh\necho ASKPASS_RAN >> /tmp/log\necho host-pw\n" > /tmp/askpass.sh
		chmod +x /tmp/askpass.sh
		: > /tmp/log
		printf "protocol=https\nhost=github.com\n\n" | GIT_ASKPASS=/tmp/askpass.sh git credential fill > /tmp/out 2>/tmp/err
		[ $? -ne 0 ] || exit 1
		grep -q "told us to quit" /tmp/err || exit 2
		[ ! -s /tmp/log ] || exit 3
		grep -q "^password=" /tmp/out && exit 4
		exit 0
	'
}
assert M6 "GH_TOKEN 不在時、helper が quit=1 で連鎖を止め askpass へ落ちない" a6_credential_quit

# 固定が黙って外れたときに気づける側 (git-auth-check) も、実イメージで
# 「実効 helper のパスと、イメージ固定の生死を常に1行報告する」ことを見る。
# イメージが焼く GIT_CONFIG_* が実際に効いていることを確認できる唯一の経路
# でもあるため、GIT_CONFIG_* を落とした状態も併せて叩く。
#
# shellcheck disable=SC2016 # 同上。
a6_auth_check() {
	docker run --rm --user 1000:1000 -e HOME=/tmp "$IMG" sh -c '
		printf "#!/bin/sh\nexit 0\n" > /tmp/vscode-helper.sh
		chmod +x /tmp/vscode-helper.sh
		git config --global credential.helper /tmp/vscode-helper.sh
		alive="$(git-auth-check 2>&1)"
		[ -n "$alive" ] || exit 1
		printf "%s\n" "$alive" | grep -q "git-credential-gh-token" || exit 2
		printf "%s\n" "$alive" | grep -q "生きている" || exit 3
		broken="$(env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 -u GIT_CONFIG_KEY_1 -u GIT_CONFIG_VALUE_1 git-auth-check 2>&1)"
		printf "%s\n" "$broken" | grep -q "外れている" || exit 4
	'
}
assert M6 "git-auth-check が実効 helper のパスと固定の生死を常に1行報告する" a6_auth_check

# --- git 設定優先順位 ------------------------------------------------------------
m6_hookspath_precedence() {
	# バグ2: 元のコマンドは cwd を指定せずに `git config` を呼んでいた。
	# docker_prod_run (docker run) は compose の working_dir: /src を経由
	# しないため、exec された "$@" のカレントディレクトリはイメージの
	# 既定 WORKDIR のままで /src ではなく、そこは git repo ではないので
	# `fatal: not in a git directory` になっていた。`git -C /src` で
	# 対象リポジトリを明示する。
	#
	# 測りたいのは「/src/.git/config (local スコープ) に core.hooksPath を
	# 書いたとき、イメージの /etc/gitconfig (system スコープ、A3 が
	# /usr/local/share/git-hooks と確定させている) の値を上書きするか」。
	# 実効値 (--get) と、どのスコープの値が並んでいるか (--show-origin
	# --get-all) の両方を出力する。
	#
	# SC2016: 単引用符は意図的。この $(...) はこのスクリプトのシェルではなく
	# コンテナ内の sh に評価させる (docker_prod_run の第 4 引数以降はコンテナ
	# 内で実行されるコマンド)。
	# shellcheck disable=SC2016
	docker_prod_run "file://$TEST_BARE_DIR" "$TEST_COMMIT" "FOO=bar" \
		sh -c 'git -C /src config core.hooksPath /tmp/local-hooks &&
			echo "effective (git -C /src config --get core.hooksPath): $(git -C /src config --get core.hooksPath)" &&
			echo "--- git -C /src config --show-origin --get-all core.hooksPath ---" &&
			git -C /src config --show-origin --get-all core.hooksPath'
}
measure_git M6 "/src/.git/config の core.hooksPath がシステム設定 (/etc/gitconfig) を上書きするか" m6_hookspath_precedence

# =============================================================================
# M7: 匿名 volume の削除 (参考測定)
#
# /src は tmpfs にする方針が決まっているため実運用への影響は無いが、
# 記録として測る。compose-anon.yaml は GIT_REPO / GIT_REF も
# prod-entrypoint.sh も使わない最小構成 (匿名 volume ひとつだけを持つ)。
# =============================================================================
echo
echo "=== M7: 匿名 volume の削除 ==="

# バグ4: 元の実装は「run 前後の volume 数」しか見ておらず、compose run
# 自体が (mount 不備等で) 起動に失敗していた場合、「そもそも作られな
# かった」のか「作られて --rm で消えた」のか出力から区別できなかった。
# ここでは (1) compose-anon.yaml の entrypoint を sleep に差し替えて
# run 中に観測できる時間を作り、(2) run 前後で volume 名の集合を diff
# して「増えた名前」を特定し、(3) その名前が sleep 終了後に消えている
# かを見る、という手順に直す。compose run 自体の rc も必ず記録する。
m7_anon_volume_cleanup() {
	local proj="verify-m7-$$" run_rc=0 cid stderr_file before_vols during_vols final_vols created tries
	before_vols="$(docker volume ls -q | sort)"
	stderr_file="$SCRATCH/m7-run-stderr-$$.log"
	# compose-anon.yaml の既定 entrypoint (["true"]) は起動直後に終了する
	# ため、-d の戻りを待つ頃には --rm で既に消えている可能性があり
	# 「作られた」ことを観測できない。--entrypoint sleep で上書きして
	# 観測用の時間を作る。docker compose run が -d + --rm の組み合わせを
	# 受け付けること自体は未確認 (docker run 単体では受け付けられるはず、
	# の推測)。標準出力 (コンテナ ID のみのはず) と標準エラー (警告等) を
	# 混ぜない — 混ぜると $cid にコンテナ ID 以外の行が混入し、後段の
	# `docker wait "$cid"` が壊れる。
	#
	# compose-anon.yaml は GIT_REPO / GIT_REF を参照しないので compose_run
	# には空文字列を渡す (未使用の env var が渡るだけで無害)。
	cid="$(compose_run "$SCRATCH/compose-anon.yaml" "$proj" "" "" \
		-d --rm --entrypoint sleep prod 5 2>"$stderr_file")" || run_rc=$?
	if [ "$run_rc" -ne 0 ]; then
		compose_down "$SCRATCH/compose-anon.yaml" "$proj"
		echo "HARNESS ERROR: docker compose -f $SCRATCH/compose-anon.yaml run -d --rm --entrypoint sleep prod 5 の起動に失敗 (rc=$run_rc): $(cat "$stderr_file" 2>/dev/null) $cid"
		return 0
	fi
	during_vols="$(docker volume ls -q | sort)"
	created="$(comm -13 <(printf '%s\n' "$before_vols") <(printf '%s\n' "$during_vols") | head -1)"
	# sleep 5 の終了 (= --rm がコンテナと専有 volume を片付けるはずの
	# タイミング) を待つ。docker wait はプロセスの終了は待つが --rm の
	# 後片付け完了までは保証しない可能性があるため (未確認・推測)、
	# volume 消滅を数回ポーリングして確認する。
	docker wait "$cid" >/dev/null 2>&1 || true
	tries=0
	while :; do
		final_vols="$(docker volume ls -q | sort)"
		if [ -z "$created" ] || ! printf '%s\n' "$final_vols" | grep -qxF "$created"; then
			break
		fi
		tries=$((tries + 1))
		[ "$tries" -ge 20 ] && break
		sleep 0.5
	done
	compose_down "$SCRATCH/compose-anon.yaml" "$proj"
	echo "compose run (-d --rm --entrypoint sleep prod 5) rc=$run_rc"
	if [ -z "$created" ]; then
		echo "run 中に新しい volume が確認できなかった (作成そのものを観測できなかった)"
	elif printf '%s\n' "$final_vols" | grep -qxF "$created"; then
		echo "run 中に作られた匿名 volume ($created) が run 後も残っている (削除されていない)"
	else
		echo "run 中に作られた匿名 volume ($created) は run 後に削除された"
	fi
}
measure M7 "docker compose run --rm が匿名 volume を削除するか" m7_anon_volume_cleanup


# =============================================================================
# M8: 復号失敗を非ゼロ終了にする手段があるか (バグ3 対応、MEASURE)
#
# M5 ケース A の実測で判明した事実: 鍵がどこにも無い状態で
# `dotenvx run -f .env.test -- printenv FOO` を実行すると、rc=0 のまま
# "encrypted:..." という暗号文リテラルを値として注入する。これは設計の
# 不変条件 I6 (secret の欠落が沈黙した成功にならない) に真っ向から反する。
# ここでは対処 (どう直すか) を決める前に、dotenvx 側に何が用意されて
# いるかを MEASURE する (pass/fail 判定はしない。対処の設計は測定結果を
# 見てから決める、とのタスク指示のとおり)。
# =============================================================================
echo
echo "=== M8: 復号失敗を非ゼロ終了にする手段があるか (MEASURE) ==="

m8_run_help() {
	docker run --rm --user 1000:1000 "$IMG" dotenvx run --help
}
measure M8 "dotenvx run --help の全文 (--strict 等のフラグの有無を確認する)" m8_run_help

# M5 ケース A ("鍵はどこにも無い") と同じ条件を、pnpm の足場なしで
# 再現する (M8 が見たいのは --strict の有無で rc が変わるかだけであり、
# pnpm run 経由の PATH 解決は本題ではないため)。
m8_strict_case_a() {
	docker run --rm --user 1000:1000 -e HOME=/tmp "$IMG" sh -c '
		set -e
		cd /tmp
		printf "FOO=bar\n" > .env.test
		/opt/tools/bin/dotenvx encrypt -f .env.test >/dev/null
		rm -f .env.keys
		set +e
		out="$(dotenvx run --strict -f .env.test -- printenv FOO 2>&1)"
		rc=$?
		set -e
		echo "rc=$rc"
		echo "$out"
	' 2>&1
}
measure M8 "鍵なしで dotenvx run --strict -f .env.test -- printenv FOO を実行したときの rc" m8_strict_case_a

m8_get_no_key() {
	docker run --rm --user 1000:1000 -e HOME=/tmp "$IMG" sh -c '
		set -e
		cd /tmp
		printf "FOO=bar\n" > .env.test
		/opt/tools/bin/dotenvx encrypt -f .env.test >/dev/null
		rm -f .env.keys
		set +e
		out="$(dotenvx get -f .env.test FOO 2>&1)"
		rc=$?
		set -e
		echo "rc=$rc"
		echo "$out"
	' 2>&1
}
measure M8 "鍵なしで dotenvx get -f .env.test FOO を実行したときの rc と出力" m8_get_no_key

# 呼び出し側が rc に頼らず、注入された値そのもの ("encrypted:" 接頭辞)
# を見て復号失敗を検出できるかの確認。
m8_caller_detects_prefix() {
	docker run --rm --user 1000:1000 -e HOME=/tmp "$IMG" sh -c '
		set -e
		cd /tmp
		printf "FOO=bar\n" > .env.test
		/opt/tools/bin/dotenvx encrypt -f .env.test >/dev/null
		rm -f .env.keys
		set +e
		dotenvx run -f .env.test -- sh -c "case \"\$FOO\" in encrypted:*) exit 1 ;; esac"
		rc=$?
		set -e
		echo "rc=$rc (1 なら呼び出し側で encrypted: 接頭辞を検出して失敗にできたことを意味する)"
	' 2>&1
}
measure M8 "呼び出し側が注入値の encrypted: 接頭辞で復号失敗を検出できるか" m8_caller_detects_prefix

# =============================================================================
# A36: secret の置き場 (/run) が tmpfs でない構成で何が起きるか
#
# entrypoint の tmpfs 自己検査は /src と「secret を書く先の親」の 2 つを見る。
# /src 側は A35 が ASSERT として押さえられる (named volume を差せば必ず
# 検査に到達する) が、/run 側は到達するかどうか自体が未確認である:
#
#   - `read_only: true` と /run への bind mount / named volume の併用が
#     docker/compose に受理されるか
#   - 受理されても、entrypoint の `mkdir -p /run/secrets` や secret の
#     書き込みが先に失敗しないか (uid/権限)
#
# このどちらかで先に落ちるなら「自己検査までは届かない」が観測結果であり、
# 自己検査が止めたわけではない。docker の無い環境では確認できなかったため、
# 初回は ASSERT にせず MEASURE として生の rc と出力を記録した (推測で ASSERT を
# 書くと、実際には別の理由で落ちているものを「防壁が効いた」と誤読する —
# この検証記録が二度踏んでいる偽の合格の形そのもの)。
#
# 実測で決着した (2026-08-06 の CI)。read_only との併用は受理され、uid 1000 は
# 0777 の bind mount 先に書けて、自己検査まで到達した:
#
#   prod-entrypoint: /run is not a tmpfs: fstype=ext4
#   prod-entrypoint:   mount line: /dev/root /run ext4 rw,relatime,... 0 0
#
# 昇格条件 (出力に "is not a tmpfs" を含む) を満たしたので A36 として ASSERT に
# 変える。measure のままだと、この経路が壊れても記録に残るだけで CI が緑になる。
#
# fetch 依存ではない (自己検査は fetch より前) ため、A11 / A17 と同じく
# preflight ゲートの対象にしない = assert_git ではなく assert を使う。
# =============================================================================
echo
echo "=== A36: /run が tmpfs でない構成 ==="

a36_run_not_tmpfs_rejected() {
	local proj="verify-a36-$$" rc=0 out
	out="$(compose_run "$SCRATCH/compose-run-volume.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		-T --rm prod true <<<"FOO=bar" 2>&1)" || rc=$?
	compose_down "$SCRATCH/compose-run-volume.yaml" "$proj"
	# A23 の教訓: 「落ちた」だけでは通さない。別の理由 (compose の起動エラー、
	# mkdir の Permission denied) で落ちたのを「防壁が効いた」と誤読しないよう、
	# 自己検査のメッセージが出ていることまで確認し、失敗時は実際の出力を出す。
	if [ "$rc" -eq 0 ]; then
		echo "secret の置き場が tmpfs でないのに entrypoint が完走した (rc=0)。出力:" >&2
		echo "$out" >&2
		return 1
	fi
	case "$out" in
	*"is not a tmpfs"*) return 0 ;;
	esac
	echo "非ゼロ終了はしたが、自己検査のメッセージ ('is not a tmpfs') が無い。" >&2
	echo "別の理由 (compose の起動エラー / mkdir の権限) で落ちた可能性がある。rc=$rc 出力:" >&2
	echo "$out" >&2
	return 1
}
assert A36 "secret の置き場が tmpfs でない構成で entrypoint が非ゼロ終了し、tmpfs でないことを名指しする [compose-run-volume.yaml。自己検査は fetch より前なので harness preflight とは無関係]" a36_run_not_tmpfs_rejected

# =============================================================================
# ASSERT: 設計上確定している性質。落ちたらスクリプトは最後に非ゼロ終了する。
# 測定結果 (M1〜M8) に依存しないものだけをここに置く。
# =============================================================================
echo
echo "=== ASSERT ==="

a1_path_resolution() {
	docker run --rm "$IMG" sh -c '
		[ "$(command -v dotenvx)" = /usr/local/bin/dotenvx ] &&
		[ "$(command -v wrangler)" = /usr/local/bin/wrangler ] &&
		[ "$(command -v gh)" = /usr/local/bin/gh ]
	'
}
assert A1 "PATH 解決が shim (/usr/local/bin/{dotenvx,wrangler,gh}) に当たる" a1_path_resolution

a2_shim_passthrough() {
	docker run --rm "$IMG" sh -c '[ ! -e /run/secrets ] && dotenvx --version'
}
assert A2 "/run/secrets 不在時に shim が素通しする (dotenvx --version が動く)" a2_shim_passthrough

a3_hookspath_system() {
	docker run --rm "$IMG" sh -c '[ "$(git config --system --get core.hooksPath)" = /usr/local/share/git-hooks ]'
}
assert A3 "git config --system --get core.hooksPath が /usr/local/share/git-hooks を返す" a3_hookspath_system

a4_executable_bits() {
	docker run --rm "$IMG" sh -c 'test -x /usr/local/bin/prod-entrypoint.sh && test -x /usr/local/share/git-hooks/pre-commit'
}
assert A4 "prod-entrypoint.sh と pre-commit hook が実行可能" a4_executable_bits

a5_secrets_mode_tmpfs() {
	# SC2016: 単引用符は意図的。$(...) はコンテナ内の sh に評価させる。
	# shellcheck disable=SC2016
	docker_prod_run "file://$TEST_BARE_DIR" "$TEST_COMMIT" "FOO=bar" \
		sh -c '[ "$(stat -c %a /run/secrets/FOO)" = "600" ] && mount | grep -Eq "(^| )/run type tmpfs| on /run type tmpfs"'
}
assert_git A5 "entrypoint 実行後、/run/secrets/<VAR> が mode 600 で tmpfs 上にある [docker_prod_run: --read-only --tmpfs uid= 形]" a5_secrets_mode_tmpfs

# docker inspect の出力全文 (Config.Env / Mounts を含む JSON 全体) に secret
# の値そのものが一切現れないことを、marker 文字列の grep で確認する。jq を
# 使わないのは macOS ホストに既定で入っていないため (このスクリプトの
# 移植性の制約)。--rm を使わず docker create/start/inspect/rm を手動で行う
# のは、コンテナ終了後に inspect する必要があるため (--rm だと消えてしまう)。
a6_no_secret_in_inspect() {
	local cid marker create_out create_rc=0 start_out start_rc=0 \
		inspect_out inspect_rc=0 rm_out rm_rc=0
	marker="A6MARKERVALUE_$$"

	# バグ3 で特定した原因: 元のコードは `docker create` に -i/--interactive
	# を付けていなかった。コンテナの STDIN が「開いているかどうか」は
	# create (もしくは run) 時点で固定され、後段の `docker start -ai` の
	# -i は「開いている STDIN に attach する」だけの意味しか持たない。
	# create 時点で閉じていれば、start 側で -i を付けても pipe した
	# secrets はコンテナに届かず即 EOF になり、entrypoint は 1 行も読めずに
	# "no secrets received on stdin" で exit 1 する — これが rc=1 の
	# 実際の原因だった (メッセージが空に見えたのは、下の元コードが
	# `docker start` の出力を /dev/null に捨てていたため)。
	# /src:exec (bugfix): docker_prod_run() 冒頭のコメントと同じ理由。ここは
	# --entrypoint で prod-entrypoint.sh を明示しているため、noexec のままだと
	# secrets 取込直後の自己検査で start が非ゼロ終了し、この関数が検証したい
	# 「docker inspect に secret が漏れないこと」まで到達できない。
	create_out="$(docker create \
		--read-only --user 1000:1000 --interactive \
		--tmpfs /run:uid=1000,gid=1000,mode=0755 \
		--tmpfs /tmp:uid=1000,gid=1000,mode=1777 \
		--tmpfs /out:uid=1000,gid=1000,mode=0755 \
		--tmpfs /home/node:uid=1000,gid=1000,mode=0755 \
		--tmpfs /src:exec,uid=1000,gid=1000,mode=0755 \
		--ulimit core=0 \
		-v "$SCRATCH:$SCRATCH:ro" \
		-e GIT_REPO="file://$TEST_BARE_DIR" -e GIT_REF="$TEST_COMMIT" \
		-e GIT_CONFIG_GLOBAL="$SAFE_GITCONFIG" \
		--entrypoint /usr/local/bin/prod-entrypoint.sh \
		"$IMG" true 2>&1)" || create_rc=$?
	if [ "$create_rc" -ne 0 ]; then
		echo "docker create failed (rc=$create_rc): $create_out" >&2
		return 1
	fi
	cid="$create_out"

	# `docker start -ai` は attach + interactive で、プロセスの終了まで
	# 同期的にブロックする (docker wait を別途挟む必要はない)。よって
	# ここでの inspect は entrypoint の完走を待たずに行われる、という
	# タイミング問題は無い。ただし start の出力は握りつぶさず、失敗時に
	# 何が起きたかを残す。
	start_out="$(printf 'FOO=bar\nDOTENV_PRIVATE_KEY_TEST=%s\n' "$marker" | docker start -ai "$cid" 2>&1)" || start_rc=$?

	inspect_out="$(docker inspect "$cid" 2>&1)" || inspect_rc=$?
	rm_out="$(docker rm -f "$cid" 2>&1)" || rm_rc=$?

	if [ "$start_rc" -ne 0 ]; then
		echo "docker start -ai failed (rc=$start_rc): $start_out" >&2
		return 1
	fi
	if [ "$inspect_rc" -ne 0 ]; then
		echo "docker inspect failed (rc=$inspect_rc): $inspect_out" >&2
		return 1
	fi
	if [ "$rm_rc" -ne 0 ]; then
		echo "docker rm -f failed (rc=$rm_rc): $rm_out (secrets check was still performed)" >&2
	fi

	if printf '%s' "$inspect_out" | grep -qF "$marker"; then
		# secret 値そのものは出力しない。何行目に現れたかだけ示す。
		local hit_line
		hit_line="$(printf '%s' "$inspect_out" | grep -nF "$marker" | head -1 | cut -d: -f1)"
		echo "secret marker found in 'docker inspect' output at line $hit_line (value withheld)" >&2
		return 1
	fi
	return 0
}
assert_git A6 "docker inspect の Config.Env / Mounts に secret 値が一切現れない [docker create: --read-only --tmpfs uid= 形、手動 start/inspect/rm]" a6_no_secret_in_inspect

# a7〜a9: entrypoint は stdin のパースに入る前に無条件で
# `mkdir -p /run/secrets` する。--tmpfs /run:uid=... を与えないと (M1 が
# 確定させたとおり) 素の /run は root:root 755 相当で、既定 USER (node,
# uid 1000) の mkdir が Permission denied で落ちる。これだと rc は
# 非ゼロになるので assert 自体はどのみち "ok" になってしまうが、
# 検証したいのはパース失敗の経路であって mkdir の権限エラーではないため、
# 書き込み可能な /run を明示して意図した経路を通す (バグ2)。
a7_empty_stdin_fails() {
	local rc=0
	printf '' | docker run --rm -i \
		--tmpfs /run:uid=1000,gid=1000,mode=0755 \
		-e GIT_REPO=unused -e GIT_REF=unused \
		--entrypoint /usr/local/bin/prod-entrypoint.sh \
		"$IMG" true >/dev/null 2>&1 || rc=$?
	[ "$rc" -ne 0 ]
}
assert A7 "stdin が空のとき entrypoint が非ゼロ終了する [docker run: --tmpfs /run:uid= 形、既定 USER (node)]" a7_empty_stdin_fails

a8_empty_value_fails() {
	local rc=0
	printf 'KEY=""\n' | docker run --rm -i \
		--tmpfs /run:uid=1000,gid=1000,mode=0755 \
		-e GIT_REPO=unused -e GIT_REF=unused \
		--entrypoint /usr/local/bin/prod-entrypoint.sh \
		"$IMG" true >/dev/null 2>&1 || rc=$?
	[ "$rc" -ne 0 ]
}
assert A8 'KEY="" を与えたとき entrypoint が非ゼロ終了する [docker run: --tmpfs /run:uid= 形、既定 USER (node)]' a8_empty_value_fails

a9_no_reflect_marker() {
	local marker out rc=0
	marker="A9MARKER_$$"
	out="$(printf '%s\n' "$marker" | docker run --rm -i \
		--tmpfs /run:uid=1000,gid=1000,mode=0755 \
		-e GIT_REPO=unused -e GIT_REF=unused \
		--entrypoint /usr/local/bin/prod-entrypoint.sh \
		"$IMG" true 2>&1)" || rc=$?
	[ "$rc" -ne 0 ] || return 1
	! printf '%s' "$out" | grep -qF "$marker"
}
assert A9 "パース失敗時の stderr に、与えた目印文字列 (secret 相当) が現れない [docker run: --tmpfs /run:uid= 形、既定 USER (node)]" a9_no_reflect_marker

a10_gh_token_removed() {
	docker_prod_run "file://$TEST_BARE_DIR" "$TEST_COMMIT" "$(printf 'GH_TOKEN=dummy\nFOO=bar\n')" \
		sh -c '[ ! -e /run/secrets/GH_TOKEN ]'
}
assert_git A10 "checkout 後に /run/secrets/GH_TOKEN が存在しない [docker_prod_run: --read-only --tmpfs uid= 形]" a10_gh_token_removed

a11_missing_git_ref_fails() {
	local rc=0
	env -u GIT_REF GIT_REPO="file://$TEST_BARE_DIR" \
		docker compose -f "$SCRATCH/compose-current.yaml" -p "verify-a11-$$" \
		run -T --rm prod true <<<"FOO=bar" >/dev/null 2>&1 || rc=$?
	[ "$rc" -ne 0 ]
}
assert A11 "GIT_REF 未指定で docker compose run が失敗する [compose-current.yaml。compose のパース時点 (\${GIT_REF:?}) で落ちるため harness preflight とは無関係]" a11_missing_git_ref_fails

a12_logging_none_stdout() {
	local out marker
	marker="A12MARKER_$$"
	out="$(docker run --rm --log-driver none "$IMG" echo "$marker" 2>&1)"
	printf '%s' "$out" | grep -qF "$marker"
}
assert A12 "logging: driver: none でもアタッチ時に stdout が手元に出る" a12_logging_none_stdout

a13_ulimit_core_zero() {
	local out
	out="$(docker run --rm --ulimit core=0 "$IMG" sh -c 'ulimit -c')"
	[ "$out" = "0" ]
}
assert A13 "ulimits: core: 0 下で 'ulimit -c' が 0 を返す" a13_ulimit_core_zero

a14_precommit_rejects_plaintext_env() {
	local rc=0
	docker run --rm --user 1000:1000 -e HOME=/tmp "$IMG" sh -c '
		set -e
		mkdir -p /tmp/repo && cd /tmp/repo
		git init -q
		git config user.email t@example.com
		git config user.name t
		printf "FOO=bar\n" > .env
		git add .env
		git commit -q -m test
	' >/dev/null 2>&1 || rc=$?
	[ "$rc" -ne 0 ]
}
assert A14 "core.hooksPath 下で平文 .env の commit が拒否される" a14_precommit_rejects_plaintext_env

a15_husky_chain_runs() {
	local out rc=0
	out="$(docker run --rm --user 1000:1000 -e HOME=/tmp "$IMG" sh -c '
		set -e
		mkdir -p /tmp/repo/.husky && cd /tmp/repo
		git init -q
		git config user.email t@example.com
		git config user.name t
		printf "#!/bin/sh\necho HUSKY_HOOK_RAN\n" > .husky/pre-commit
		chmod +x .husky/pre-commit
		printf "hello\n" > README.md
		git add README.md .husky/pre-commit
		git commit -q -m test
	' 2>&1)" || rc=$?
	[ "$rc" -eq 0 ] || return 1
	printf '%s' "$out" | grep -q "HUSKY_HOOK_RAN"
}
assert A15 ".husky/pre-commit を置いたリポジトリで、チェーン先の hook が実行される" a15_husky_chain_runs

a16_recovers_from_leftover() {
	# /src:exec (bugfix): docker_prod_run() 冒頭のコメントと同じ理由。この
	# ケースは leftover を仕込んだ後 `exec /usr/local/bin/prod-entrypoint.sh`
	# するため、noexec のままだと自己検査で即 exit 1 し、検証したい「/src
	# 非空・.git 無しの状態からの復帰」に到達できない。
	docker run --rm -i \
		--read-only --user 1000:1000 \
		--tmpfs /run:uid=1000,gid=1000,mode=0755 \
		--tmpfs /tmp:uid=1000,gid=1000,mode=1777 \
		--tmpfs /out:uid=1000,gid=1000,mode=0755 \
		--tmpfs /home/node:uid=1000,gid=1000,mode=0755 \
		--tmpfs /src:exec,uid=1000,gid=1000,mode=0755 \
		--ulimit core=0 \
		-v "$SCRATCH:$SCRATCH:ro" \
		-e GIT_REPO="file://$TEST_BARE_DIR" -e GIT_REF="$TEST_COMMIT" \
		-e GIT_CONFIG_GLOBAL="$SAFE_GITCONFIG" \
		--entrypoint sh \
		"$IMG" -c '
			mkdir -p /src/leftover-dir &&
			echo leftover > /src/leftover-file &&
			exec /usr/local/bin/prod-entrypoint.sh test -f /src/file.txt
		' <<<"FOO=bar"
}
assert_git A16 "entrypoint が /src 非空・.git 無しの状態から復帰できる [docker run: --read-only --tmpfs uid= 形一式]" a16_recovers_from_leftover

a17_prod_run_pipefail() {
	local fake_broker rc=0
	fake_broker="$SCRATCH/fake-broker-fail.sh"
	cat >"$fake_broker" <<'EOS'
#!/usr/bin/env bash
echo "fake broker: authorization denied" >&2
exit 7
EOS
	chmod +x "$fake_broker"
	PROD_COMPOSE_FILE="$SCRATCH/compose-current.yaml" \
		PROD_BROKER="$fake_broker" \
		GIT_REPO="file://$TEST_BARE_DIR" \
		GIT_REF="$TEST_COMMIT" \
		bash "$REPO_ROOT/images/runtime-base/templates/host/prod-run.sh" true >/dev/null 2>&1 || rc=$?
	[ "$rc" -ne 0 ]
}
assert A17 "broker (フェイク) が非ゼロ終了したとき、prod-run.sh 経由でパイプ全体が非ゼロ終了する [compose-current.yaml 経由 prod-run.sh。broker が secrets を一切渡さず失敗する経路のため harness preflight とは無関係]" a17_prod_run_pipefail

a18_home_empty_no_fallback() {
	docker run --rm --tmpfs /home/node:uid=1000,gid=1000,mode=0755 --user 1000:1000 -e HOME=/home/node "$IMG" \
		sh -c '[ -z "$(ls -A /home/node 2>/dev/null)" ] && [ ! -e /home/node/.config/gh ] && [ ! -e /home/node/.wrangler ]'
}
# SC2016: 説明文中の $HOME は展開させたくない文字どおりの文字列。
# shellcheck disable=SC2016
assert A18 '$HOME が tmpfs で空であり、fallback 資格情報 (~/.config/gh 等) が存在しない' a18_home_empty_no_fallback

# =============================================================================
# A19〜A34: 出荷 templates/host/compose.prod.yaml の構造検証 (docker が要る、jq を使う)
#
# compose_prod_config() / tmpfs_entries_or_fail() は「compose ファイル生成」
# 節 (上、$SCRATCH セットアップの一部) で定義済み。ここでは 1 検査 1 assert()
# で並べる。docker (docker compose config) は使うが bare repo は使わないので
# preflight (HARNESS_GIT_OK) には依存させず、常に assert() を使う
# (assert_git() ではない)。
# =============================================================================
# jq による構造検査の共通ヘルパ。
#
# 失敗時に「何を見たのか」を必ず stderr へ出す。CI 8 回目の A23 は
# `jq -e ... >/dev/null` だけで書かれていたため、落ちた事実は分かっても
# 実際の値が分からず、正規化形を推測し直す羽目になった。判定式と一緒に
# 「失敗したときに表示する部分」の jq パスを受け取り、そこを出す。
#
#   jq_check <判定式> <失敗時に表示する jq パス>
jq_check() {
	local expr="$1" show="$2" cfg
	cfg="$(compose_prod_config)" || {
		echo "docker compose config の実行に失敗した" >&2
		return 1
	}
	if printf '%s' "$cfg" | jq -e "$expr" >/dev/null 2>&1; then
		return 0
	fi
	printf '実際の値 (%s): %s\n' "$show" \
		"$(printf '%s' "$cfg" | jq -c "$show" 2>&1)" >&2
	return 1
}

a19_read_only_true() {
	jq_check '.services.prod.read_only == true' '.services.prod.read_only'
}
assert A19 "services.prod.read_only が true [docker compose config の解決結果]" a19_read_only_true

a20_user_1000_1000() {
	jq_check '.services.prod.user == "1000:1000"' '.services.prod.user'
}
assert A20 'services.prod.user が "1000:1000" [docker compose config の解決結果]' a20_user_1000_1000

a21_working_dir_src() {
	jq_check '.services.prod.working_dir == "/src"' '.services.prod.working_dir'
}
assert A21 "services.prod.working_dir が /src [docker compose config の解決結果]" a21_working_dir_src

a22_entrypoint_exact() {
	jq_check '.services.prod.entrypoint == ["/usr/local/bin/prod-entrypoint.sh"]' '.services.prod.entrypoint'
}
assert A22 'services.prod.entrypoint が ["/usr/local/bin/prod-entrypoint.sh"] [docker compose config の解決結果]' a22_entrypoint_exact

# `docker compose config` は ulimits の値 0 を落とす。CI 9 回目の実測:
#
#   実際の値 (.services.prod.ulimits): {"core":{}}
#
# `core: 0` と書いてあるのに空オブジェクトになる。Go 側の omitempty が
# ゼロ値を落としているとみられる (未確認)。つまり config の出力では
# **「core が 0」と「core が未設定」を区別できない**。値の検査はこの経路では
# 原理的に不可能なので、ここでは「core キーが存在すること」= ulimits の
# 指定がまるごと消えていないことだけを見る。
#
# 実効値が 0 であることは B5 で確認する — 出荷ファイル由来のコンテナを
# 実際に起動して `ulimit -c` を読む。値を見たいなら挙動を見るしかない。
#
# 他の A 系検査がこの罠を踏んでいないことも確認した: read_only は true、
# user / working_dir / logging.driver は文字列、entrypoint / tmpfs は配列で、
# いずれもゼロ値ではないため omitempty の対象にならない。
a23_ulimits_core_present() {
	jq_check '(.services.prod.ulimits // {}) | has("core")' '.services.prod.ulimits'
}
assert A23 "services.prod.ulimits に core キーが存在する (値 0 は config が落とすため実効値は B5 で見る) [docker compose config の解決結果]" a23_ulimits_core_present

a24_logging_driver_none() {
	jq_check '.services.prod.logging.driver == "none"' '.services.prod.logging'
}
assert A24 'services.prod.logging.driver が "none" [docker compose config の解決結果]' a24_logging_driver_none

# A25〜A27: 「キーが存在しない」ではなく「実質的に空である」を見る。
# docker compose config はコンテナへ流し込む正規化 JSON であり、
# 宣言していないキーにも既定の空コンテナ (例: トップレベル volumes: {}) を
# 補って出力する可能性がある — その場合 `has("volumes")` は常に true に
# なり検査として意味を失う。`(.volumes // {} | length) == 0` の形なら
# 「キー自体が無い」「キーはあるが空」のどちらでも 0 になり、実際に
# prod-src 等が復活した場合 (length > 0) だけを正しく検出できる。
a25_no_top_level_volumes() {
	local n
	n="$(compose_prod_config | jq '.volumes // {} | length')" || return 1
	[ "$n" = "0" ]
}
assert A25 "トップレベル volumes: が実質的に空 (rev.5/D18 で削除済み。config が既定の空コンテナを補う場合に備え has() ではなく length で見る) [docker compose config の解決結果]" a25_no_top_level_volumes

a26_no_service_volumes() {
	local n
	n="$(compose_prod_config | jq '.services.prod.volumes // [] | length')" || return 1
	[ "$n" = "0" ]
}
assert A26 "services.prod.volumes が実質的に空 [docker compose config の解決結果]" a26_no_service_volumes

a27_no_secrets_anywhere() {
	local json svc_n top_n
	json="$(compose_prod_config)" || return 1
	svc_n="$(printf '%s' "$json" | jq '.services.prod.secrets // [] | length')"
	top_n="$(printf '%s' "$json" | jq '.secrets // {} | length')"
	[ "$svc_n" = "0" ] && [ "$top_n" = "0" ]
}
assert A27 "services.prod.secrets もトップレベル secrets: も実質的に空 (D1 で却下済み、read_only と併用不可) [docker compose config の解決結果]" a27_no_secrets_anywhere

a28_tmpfs_five_mounts() {
	local entries paths
	entries="$(tmpfs_entries_or_fail)" || return 1
	paths="$(printf '%s' "$entries" | jq -c '[.[] | split(":")[0]] | sort')"
	[ "$paths" = '["/home/node","/out","/run","/src","/tmp"]' ]
}
assert A28 "services.prod.tmpfs に /src /run /tmp /out /home/node の 5 つが過不足なく揃っている [docker compose config の解決結果]" a28_tmpfs_five_mounts

# SC2016: 単引用符は意図的。$opts はこのスクリプトのシェルではなく jq の
# 文字列内挿で展開させる。
# shellcheck disable=SC2016
a29_tmpfs_src_has_exec() {
	local entries opts
	entries="$(tmpfs_entries_or_fail)" || return 1
	opts="$(printf '%s' "$entries" | jq -r '.[] | select(split(":")[0] == "/src") | (split(":")[1] // "")')"
	if [ -z "$opts" ]; then
		echo "/src の tmpfs エントリが見つからない: $entries" >&2
		return 1
	fi
	case ",$opts," in
	*,exec,*) return 0 ;;
	esac
	echo "/src の tmpfs オプションに exec が無い: $opts" >&2
	return 1
}
assert A29 "/src の tmpfs エントリに exec が含まれる (node_modules/.bin を動かすため) [docker compose config の解決結果]" a29_tmpfs_src_has_exec

a30_tmpfs_run_out_no_exec() {
	local entries run_opts out_opts
	entries="$(tmpfs_entries_or_fail)" || return 1
	run_opts="$(printf '%s' "$entries" | jq -r '.[] | select(split(":")[0] == "/run") | (split(":")[1] // "")')"
	out_opts="$(printf '%s' "$entries" | jq -r '.[] | select(split(":")[0] == "/out") | (split(":")[1] // "")')"
	if [ -z "$run_opts" ]; then
		echo "/run の tmpfs エントリが見つからない: $entries" >&2
		return 1
	fi
	if [ -z "$out_opts" ]; then
		echo "/out の tmpfs エントリが見つからない: $entries" >&2
		return 1
	fi
	case ",$run_opts," in
	*,exec,*)
		echo "/run の tmpfs オプションに exec が含まれる (noexec のままであるべき): $run_opts" >&2
		return 1
		;;
	esac
	case ",$out_opts," in
	*,exec,*)
		echo "/out の tmpfs オプションに exec が含まれる (noexec のままであるべき): $out_opts" >&2
		return 1
		;;
	esac
	return 0
}
assert A30 "/run と /out の tmpfs エントリに exec が含まれない (noexec のまま) [docker compose config の解決結果]" a30_tmpfs_run_out_no_exec

a31_tmpfs_all_uid_gid_1000() {
	local entries bad
	entries="$(tmpfs_entries_or_fail)" || return 1
	bad="$(printf '%s' "$entries" | jq -r '
		.[]
		| . as $e
		| ($e | split(":")[1] // "") as $opts
		| select((",\($opts)," | contains(",uid=1000,") | not) or (",\($opts)," | contains(",gid=1000,") | not))
		| $e
	')"
	if [ -n "$bad" ]; then
		echo "uid=1000/gid=1000 のいずれかを欠くエントリ: $bad" >&2
		return 1
	fi
	return 0
}
assert A31 "全 tmpfs エントリに uid=1000 と gid=1000 が含まれる [docker compose config の解決結果]" a31_tmpfs_all_uid_gid_1000

# A32/A33: `${VAR:?...}` は config が補間した後の JSON には現れない
# (補間済みの値になってしまうため、grep 的な文字列一致では検査できない)。
# 代わりに「その変数を与えずに docker compose config を実行すると失敗する
# こと」を見る — これは `:?` が付いていることの直接の証拠になる (grep より
# 強い)。A11 (compose-current.yaml に対する同種のケース) と同じ
# `env -u VAR ... docker compose ... config` の形。
a32_missing_git_repo_fails() {
	local rc=0
	env -u GIT_REPO GIT_REF="verify-dummy-git-ref-do-not-use" \
		docker compose -f "$COMPOSE_PROD_YAML" config --format json >/dev/null 2>&1 || rc=$?
	[ "$rc" -ne 0 ]
}
assert A32 "GIT_REPO 未指定で docker compose config が失敗する (\${GIT_REPO:?...} の直接証拠)" a32_missing_git_repo_fails

a33_missing_git_ref_fails() {
	local rc=0
	env GIT_REPO="verify-dummy-git-repo-do-not-use" -u GIT_REF \
		docker compose -f "$COMPOSE_PROD_YAML" config --format json >/dev/null 2>&1 || rc=$?
	[ "$rc" -ne 0 ]
}
assert A33 "GIT_REF 未指定で docker compose config が失敗する (\${GIT_REF:?...} の直接証拠)" a33_missing_git_ref_fails

# A34: 補間の影響を受けないフィールドなので、A19〜A24 と同じく config の
# 出力をそのまま見る。
a34_image_has_sha256_digest() {
	jq_check '(.services.prod.image | type) == "string" and (.services.prod.image | contains("@sha256:"))' '.services.prod.image'
}
assert A34 'services.prod.image が "@sha256:" を含む (digest pin のまま。タグ参照へ退化していない) [docker compose config の解決結果]' a34_image_has_sha256_digest

# A35: tmpfs 自己検査が named volume の /src を実際に止めること。
#
# 単体テスト (entrypoint.test.sh) は /src を tmpdir へ書き換えたコピーを
# 使うため /proc/mounts のどの mountpoint とも一致せず、「該当行なし →
# WARNING で続行」の経路しか通らない。「実際に named volume を差したら
# exit 1 する」は docker が無いと測れないので、ここで確認する。構成は
# compose-current.yaml (/src が named volume) — M6 が N-1 / N-2 の再現に
# 使っている、まさにその形。
#
# 「落ちた」だけでは足りない (A23 の教訓: 失敗が何も言わない検査は結局
# 二度手間になる)。/src が tmpfs でないことを名指ししたメッセージが出て
# いることまで見る。どちらの条件で落ちたのかが分かるよう、失敗時には
# 実際の rc と出力を stderr へ出す。
#
# この経路は fetch より前で終わるため bare repo の到達性に依存しない。
# A11 / A17 と同じ扱いで assert_git ではなく assert を使う (GIT_REPO には
# TEST_BARE_DIR を渡すが、自己検査が働けば fetch までは進まない)。
a35_named_volume_src_rejected() {
	local proj="verify-a35-$$" rc=0 out
	out="$(compose_run "$SCRATCH/compose-current.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		-T --rm prod true <<<"FOO=bar" 2>&1)" || rc=$?
	compose_down "$SCRATCH/compose-current.yaml" "$proj"
	if [ "$rc" -eq 0 ]; then
		echo "entrypoint が exit 0 で完走した (named volume の /src が検出されていない)。実際の出力: $out" >&2
		return 1
	fi
	case "$out" in
		*"/src is not a tmpfs"*) return 0 ;;
	esac
	echo "非ゼロ終了 (rc=$rc) はしたが、/src が tmpfs でないことを名指しするメッセージが無い。実際の出力: $out" >&2
	return 1
}
assert A35 "/src が named volume の構成で entrypoint が非ゼロ終了し、/src が tmpfs でないことを名指しする [compose-current.yaml。自己検査は fetch より前なので harness preflight とは無関係]" a35_named_volume_src_rejected

# =============================================================================
# B1〜B4: 出荷 templates/host/compose.prod.yaml からの最小派生の実挙動 (docker が要る)
#
# compose-shipped.yaml (上、$SCRATCH セットアップの一部) は出荷ファイルその
# ものへの sed 派生で、加えた変更は image: / bind mount 追加 / GIT_CONFIG_GLOBAL
# 追加の 3 点だけ (diff は setup ログに出力済み)。bare repo は TEST_BARE_DIR
# で足りる (pnpm install 等は絡まないので SELF_BARE_DIR は不要)。preflight
# (bare repo がコンテナから見えるか) に依存するので assert_git() を使う。
#
# tmpfs 自己検査の誤検知 (正しい構成なのに落とす) は、この B シリーズが
# そのまま検出器になっている: B1〜B5 はいずれも出荷ファイル由来の
# 全 tmpfs 構成 (/src /run /tmp /out /home/node) で素の entrypoint を
# 完走させる ASSERT なので、自己検査が誤って落とせば B1〜B5 が軒並み
# FAIL する。同じ理由で docker_prod_run 経由の A5 / A10 / A16 も
# 検出器として働く。誤検知のための専用 ASSERT は足していない。
# =============================================================================
b1_entrypoint_secrets_mode() {
	local proj="verify-b1-$$" rc=0
	# SC2016: 単引用符は意図的。$(...) はコンテナ内の sh に評価させる。
	# shellcheck disable=SC2016
	compose_run "$SCRATCH/compose-shipped.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		-T --rm prod sh -c '[ "$(stat -c %a /run/secrets/FOO)" = "600" ]' <<<"FOO=bar" || rc=$?
	compose_down "$SCRATCH/compose-shipped.yaml" "$proj"
	return "$rc"
}
assert_git B1 "entrypoint 完走後、/run/secrets/FOO が mode 600 で作られる [出荷 compose.prod.yaml からの最小派生]" b1_entrypoint_secrets_mode

b2_mount_noexec() {
	local proj="verify-b2-$$" rc=0
	# SC2016: 単引用符は意図的。$(...) はコンテナ内の sh に評価させる。
	# shellcheck disable=SC2016
	compose_run "$SCRATCH/compose-shipped.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		-T --rm prod sh -c '
			src_line="$(mount | grep " /src ")" || exit 1
			run_line="$(mount | grep " /run ")" || exit 1
			case "$src_line" in *noexec*) exit 1 ;; esac
			case "$run_line" in *noexec*) : ;; *) exit 1 ;; esac
		' <<<"FOO=bar" || rc=$?
	compose_down "$SCRATCH/compose-shipped.yaml" "$proj"
	return "$rc"
}
assert_git B2 "mount 出力: /src に noexec が無く、/run に noexec がある [出荷 compose.prod.yaml からの最小派生]" b2_mount_noexec

b3_src_exec_runs() {
	local proj="verify-b3-$$" rc=0
	# SC2016: 単引用符は意図的。コンテナ内の sh に評価させる。
	# shellcheck disable=SC2016
	compose_run "$SCRATCH/compose-shipped.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		-T --rm prod sh -c '
			printf "#!/bin/sh\necho EXEC_OK\n" > /src/t.sh
			chmod +x /src/t.sh
			[ "$(/src/t.sh)" = "EXEC_OK" ]
		' <<<"FOO=bar" || rc=$?
	compose_down "$SCRATCH/compose-shipped.yaml" "$proj"
	return "$rc"
}
assert_git B3 "/src に置いた実行ファイルが動く (exec が効いている直接確認) [出荷 compose.prod.yaml からの最小派生]" b3_src_exec_runs

b4_run_owner_node() {
	local proj="verify-b4-$$" rc=0
	# SC2016: 単引用符は意図的。コンテナ内の sh に評価させる。
	# shellcheck disable=SC2016
	compose_run "$SCRATCH/compose-shipped.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		-T --rm prod sh -c '[ "$(stat -c "%U:%G" /run)" = "node:node" ]' <<<"FOO=bar" || rc=$?
	compose_down "$SCRATCH/compose-shipped.yaml" "$proj"
	return "$rc"
}
assert_git B4 "stat -c '%U:%G' /run が node:node を返す [出荷 compose.prod.yaml からの最小派生]" b4_run_owner_node

# `docker compose config` は ulimits の値 0 を落として {"core":{}} にするため
# (A23 のコメント参照)、コアダンプ抑止が実際に効いているかは起動して読むしかない。
# 出荷ファイル由来のコンテナで `ulimit -c` が 0 を返すことを直接確認する。
b5_ulimit_core_zero() {
	local proj="verify-b5-$$" rc=0
	# SC2016: 単引用符は意図的。コンテナ内の sh に評価させる。
	# shellcheck disable=SC2016
	compose_run "$SCRATCH/compose-shipped.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		-T --rm prod sh -c '[ "$(ulimit -c)" = "0" ]' <<<"FOO=bar" || rc=$?
	compose_down "$SCRATCH/compose-shipped.yaml" "$proj"
	return "$rc"
}
assert_git B5 "ulimit -c が 0 を返す (コアダンプ抑止の実効確認。config では値が見えない) [出荷 compose.prod.yaml からの最小派生]" b5_ulimit_core_zero

# =============================================================================
# summary
# =============================================================================
echo
echo "=== MEASUREMENTS ==="
for line in "${MEAS_LOG[@]}"; do
	printf '%s\n' "$line"
done
echo "=== ASSERTIONS ==="
for line in "${ASSERT_LOG[@]}"; do
	printf '%s\n' "$line"
done
printf '\n%s measurements recorded, %s assertions passed, %s failed\n' \
	"${#MEAS_LOG[@]}" "$ASSERT_PASS" "$ASSERT_FAIL"
if [ "$HARNESS_GIT_OK" -eq 0 ]; then
	echo "HARNESS ERROR: bare repo がコンテナから読めなかったため、SKIP と記録したケース (M1 の compose 経由分 / M2 / M6 / A5 / A6 / A10 / A16 / B1 / B2 / B3 / B4) は測定・検証できていない。上の preflight のログを見ること。"
fi

# 明示的な `exit N` ではなく、この判定式自身の終了コードをスクリプトの
# 終了コードにする。理由: `trap cleanup EXIT` を登録した後段で文字どおりの
# `exit` 文を書くと、shellcheck 0.9.0 の到達可能性解析が、動的ディスパッチ
# (measure/assert の "$@" 経由) でしか呼ばれない mN_* / aN_* 関数群を
# 「到達不能」と誤検出する (SC2317 が数百件連鎖する既知の癖。手元で
# `trap … EXIT` の後に裸の `exit` を置く再現コードを作って確認済み)。
# ASSERT_FAIL が 0 なら真 (exit 0)、1 以上なら偽 (exit 1) になるため、
# 意味は元の if/exit と同じ。HARNESS_GIT_OK=0 (preflight 失敗) の場合も
# 非ゼロ終了にする — SKIP は「合否未検証」であって「合格」ではないため、
# ハーネス自体が壊れているのに CI が黙って緑になるのを避ける。
[ "$ASSERT_FAIL" -eq 0 ] && [ "$HARNESS_GIT_OK" -eq 1 ]
