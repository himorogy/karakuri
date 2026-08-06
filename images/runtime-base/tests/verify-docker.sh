#!/usr/bin/env bash
# =============================================================================
# verify-docker.sh — docker が要る検証項目の実行ハーネス
#
# images/runtime-base の設計 (.local/prod-secret-isolation-design.md) には
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
# A16) を実行せず SKIPPED として記録する。A11 (GIT_REF 未指定) は compose
# のパース時点で失敗が確定するため fetch の成否と無関係、A17 (broker
# 失敗の伝播) も broker 自体が secrets を一切渡さず失敗する経路なので
# fetch の成否と無関係 — この 2 つはゲートの対象に含めない。
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
# templates/compose.prod.yaml は変更しない (rev.5 確定後にオーケストレーターが
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

# compose-current.yaml: templates/compose.prod.yaml と同一の tmpfs 記法
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

# compose-src-tmpfs.yaml: M2 用。/src を named volume ではなく tmpfs にした
# 場合の実現可能性を測る。uid= 形式が使えることを前提にする (M1 が否定的な
# 結果を出した場合、この変種の結果はその文脈で読むこと)。
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

# --- docker run 共通ラッパー (compose.prod.yaml と等価な docker run flags) -----
# compose を経由しない ASSERT の多く (A5, A7〜A10, A16 等) は、compose の
# パーサ挙動そのものではなく entrypoint / shim の挙動を見たいだけなので、
# docker run に直接 templates/compose.prod.yaml と同じオプションを渡す。
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
	printf '%s' "$stdin_payload" | docker run --rm -i \
		--read-only \
		--user 1000:1000 \
		--tmpfs /run:uid=1000,gid=1000,mode=0755 \
		--tmpfs /tmp:uid=1000,gid=1000,mode=1777 \
		--tmpfs /out:uid=1000,gid=1000,mode=0755 \
		--tmpfs /home/node:uid=1000,gid=1000,mode=0755 \
		--tmpfs /src:uid=1000,gid=1000,mode=0755 \
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
	echo "HARNESS ERROR: bare repo ($TEST_BARE_DIR) がコンテナから読めない (docker_prod_run 経由)。以降の bare repo fetch 依存ケース (M1 の compose 経由分 / M2 / M6 と ASSERT A5, A6, A10, A16) は SKIPPED (harness setup failed) として記録し、個別には実行しない。"
	echo "--- preflight の生出力 ---"
	echo "$preflight_out"
fi

# =============================================================================
# M1: tmpfs の所有権 (最優先)
#
# 設計書 §4.2 は素の短縮形 `tmpfs: ["/run", …]` を書いているが、実装
# (templates/compose.prod.yaml) は「root:root で作られ USER node が
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
	compose_run "$SCRATCH/compose-current.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
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
# tmpfs 既定サイズ、RAM 使用量 — を測る。compose-src-tmpfs.yaml
# (/src も uid=1000,gid=1000,mode=0755 の tmpfs) を使う。M1 で uid= 形式が
# 拒否される結果が出た場合、この節の結果はその制約の上で読むこと。
# =============================================================================
echo
echo "=== M2: /src の tmpfs 化 ==="

m2_git_ops() {
	local proj="verify-m2-git-$$" rc=0 out
	out="$(compose_run "$SCRATCH/compose-src-tmpfs.yaml" "$proj" "file://$SELF_BARE_DIR" "$SELF_COMMIT" \
		-T --rm prod sh -c 'test -f pnpm-lock.yaml && git rev-parse HEAD' <<<"FOO=bar" 2>&1)" || rc=$?
	compose_down "$SCRATCH/compose-src-tmpfs.yaml" "$proj"
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
	out="$(compose_run "$SCRATCH/compose-src-tmpfs.yaml" "$proj" "file://$SELF_BARE_DIR" "$SELF_COMMIT" \
		-T --rm prod sh -c '
			set -e
			pnpm install --frozen-lockfile
			echo "--- pnpm store path ---"
			store="$(pnpm store path)"
			echo "$store"
			echo "--- du -sh \$store ---"
			du -sh "$store" 2>/dev/null || echo "du failed (store may not exist)"
		' <<<"FOO=bar" 2>&1)" || rc=$?
	compose_down "$SCRATCH/compose-src-tmpfs.yaml" "$proj"
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
	out="$(compose_run "$SCRATCH/compose-src-tmpfs.yaml" "$proj" "file://$SELF_BARE_DIR" "$SELF_COMMIT" \
		-T --rm prod df -h /src <<<"FOO=bar" 2>&1)" || rc=$?
	compose_down "$SCRATCH/compose-src-tmpfs.yaml" "$proj"
	if [ "$rc" -eq 0 ]; then echo "$out"; else echo "FAILED (rc=$rc): $out"; fi
}
measure_git M2 "tmpfs /src の既定サイズ (df -h /src、size= 未指定)" m2_df_default_size

# ビルド成果物を /out に出す構成での /src + /out 合計 RAM 使用量。install
# 後の使用量を du -sh で見る。tmpfs 上の使用量はほぼそのまま RAM 使用量に
# 相当する (実ディスクを介さないため) が、正確な RSS ではなく du の近似値
# であることに注意。
m2_ram_usage() {
	local proj="verify-m2-ram-$$" rc=0 out
	out="$(compose_run "$SCRATCH/compose-src-tmpfs.yaml" "$proj" "file://$SELF_BARE_DIR" "$SELF_COMMIT" \
		-T --rm prod sh -c '
			set -e
			pnpm install --frozen-lockfile >/dev/null 2>&1 || true
			mkdir -p /out
			echo dummy-build-artifact > /out/dummy
			du -sh /src /out 2>/dev/null
		' <<<"FOO=bar" 2>&1)" || rc=$?
	compose_down "$SCRATCH/compose-src-tmpfs.yaml" "$proj"
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
# 全て MEASURE。pass/fail 判定はしない。1 ケースあたり pnpm install が
# 走るため、M9-a / M9-b の 2 ケースに絞る (M9-c は store path の確認のみ
# で pnpm install を走らせない)。
#
# 推測 (docker が無い環境のため未実行・未確認):
#   - `pnpm store path --store-dir <dir>` のようにサブコマンドの後ろに
#     --store-dir を置いても pnpm に受理されるはず、という前提で書いて
#     いる (他の pnpm グローバルオプションと同様のパーサ挙動を想定)。
#   - マウントを跨ぐハードリンク失敗時に pnpm が warn/info を出すという
#     前提で、pnpm install の出力から cross-device/EXDEV/hardlink を含む
#     行を拾っている。実際にそのような行が出るかは未確認。
# =============================================================================
echo
echo "=== M9: pnpm store の置き場所 ==="

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

# M9-c: store-dir をイメージに焼く方法の確認。pnpm install は走らせない
# (store path の確認だけで十分、とのタスク指示のとおり)。GIT_REPO/GIT_REF
# も bare repo fetch も使わないので、bare repo 到達性 (HARNESS_GIT_OK) と
# 無関係 — measure_git ではなく measure を使う。
m9c_store_dir_env() {
	local out
	# shellcheck disable=SC2016
	out="$(docker run --rm --user 1000:1000 "$IMG" sh -c '
			echo "--- 素の pnpm store path (環境変数なし。既定は \$PNPM_HOME/store のはず) ---"
			default_path=$(pnpm store path 2>&1)
			echo "$default_path"
			echo "--- 素の pnpm config get store-dir ---"
			pnpm config get store-dir 2>&1
			echo "--- npm_config_store_dir=/home/node/.local/share/pnpm/store を与えた場合の pnpm store path ---"
			env_path=$(npm_config_store_dir=/home/node/.local/share/pnpm/store pnpm store path 2>&1)
			echo "$env_path"
			echo "--- 同条件での pnpm config get store-dir ---"
			npm_config_store_dir=/home/node/.local/share/pnpm/store pnpm config get store-dir 2>&1
			if [ "$default_path" != "$env_path" ]; then
				echo "M9_C_CHANGED=YES"
			else
				echo "M9_C_CHANGED=NO"
			fi
		' 2>&1)"
	printf '%s\n' "$out" >"$SCRATCH/m9c-output.txt"
	printf '%s\n' "$out"
}
measure M9 "M9-c: 環境変数 npm_config_store_dir だけで pnpm store path / config get store-dir が変わるか (pnpm install は走らせない)" m9c_store_dir_env

# M9 まとめ: M9-a / M9-b / M9-c の出力ファイル ($SCRATCH/m9{a,b,c}-output.txt。
# 上の 3 関数が pnpm install を再実行せず書き出したもの) を読み、一目で
# 比較できる 3 行にする。A と B の「合計」は二重計上を避けて計算する:
# 案 A は store が /src とは別マウントなので store+/src+/out を単純合算、
# 案 B は store が /src の中にあり /src の du に既に含まれているので
# /src+/out だけを合算する (store の値自体は比較用に別途表示する)。
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
	compose_run "$SCRATCH/compose-current.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		-T --rm prod sh -c "git tag v9.9.9 $TEST_COMMIT2" <<<"FOO=bar" >/dev/null 2>&1 || rc1=$?
	out2="$(compose_run "$SCRATCH/compose-current.yaml" "$proj" "file://$TEST_BARE_DIR" "v9.9.9" \
		-T --rm prod cat file.txt <<<"FOO=bar" 2>&1)" || rc2=$?
	compose_down "$SCRATCH/compose-current.yaml" "$proj"
	echo "1st run (commit1 を checkout 後、ローカルタグ v9.9.9 を commit2 に打つ): rc=$rc1"
	echo "2nd run (同じ volume、GIT_REF=v9.9.9): rc=$rc2 file.txt=$out2 (commit1=hello / commit2=world)"
}
measure_git M6 "named volume 再利用: ref 汚染 (N-1) が再現するか" m6_n1_named_volume

m6_n1_tmpfs() {
	local proj="verify-m6-n1-tmpfs-$$" rc1=0 rc2=0 out2
	compose_run "$SCRATCH/compose-src-tmpfs.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		-T --rm prod sh -c "git tag v9.9.9 $TEST_COMMIT2" <<<"FOO=bar" >/dev/null 2>&1 || rc1=$?
	out2="$(compose_run "$SCRATCH/compose-src-tmpfs.yaml" "$proj" "file://$TEST_BARE_DIR" "v9.9.9" \
		-T --rm prod cat file.txt <<<"FOO=bar" 2>&1)" || rc2=$?
	compose_down "$SCRATCH/compose-src-tmpfs.yaml" "$proj"
	echo "1st run: rc=$rc1"
	echo "2nd run (GIT_REF=v9.9.9。tmpfs なので /src は毎回まっさらのはず、v9.9.9 は存在せず失敗するのが期待): rc=$rc2 out=$out2"
}
measure_git M6 "tmpfs /src: ref 汚染 (N-1) が消えるか" m6_n1_tmpfs

# --- N-2: .git/config 持続 (core.fsmonitor) --------------------------------------
m6_n2_named_volume() {
	local proj="verify-m6-n2-$$" rc1=0 rc2=0 out2
	compose_run "$SCRATCH/compose-current.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		-T --rm prod git config core.fsmonitor 'sh -c "echo FSMONITOR_RAN >> /tmp/fsmonitor-marker; exit 1"' \
		<<<"FOO=bar" >/dev/null 2>&1 || rc1=$?
	out2="$(compose_run "$SCRATCH/compose-current.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		-T --rm prod cat /tmp/fsmonitor-marker <<<"FOO=bar" 2>&1)" || rc2=$?
	compose_down "$SCRATCH/compose-current.yaml" "$proj"
	echo "1st run (core.fsmonitor をローカルに仕込む): rc=$rc1"
	echo "2nd run (同じ GIT_REF で再実行。entrypoint 自身の fetch/checkout/reset/clean が fsmonitor を起動させたか): rc=$rc2 marker=$out2"
}
measure_git M6 "named volume 再利用: core.fsmonitor 持続 (N-2) が再現するか" m6_n2_named_volume

m6_n2_tmpfs() {
	local proj="verify-m6-n2-tmpfs-$$" rc1=0 rc2=0 out2
	compose_run "$SCRATCH/compose-src-tmpfs.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		-T --rm prod git config core.fsmonitor 'sh -c "echo FSMONITOR_RAN >> /tmp/fsmonitor-marker; exit 1"' \
		<<<"FOO=bar" >/dev/null 2>&1 || rc1=$?
	out2="$(compose_run "$SCRATCH/compose-src-tmpfs.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		-T --rm prod sh -c 'grep -c fsmonitor /src/.git/config 2>/dev/null || echo "0 (fresh .git/config)"' \
		<<<"FOO=bar" 2>&1)" || rc2=$?
	compose_down "$SCRATCH/compose-src-tmpfs.yaml" "$proj"
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
	compose_run "$SCRATCH/compose-current.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		-T --rm prod git config credential.helper '!cat /run/secrets/GH_TOKEN > /src/.stolen-token 2>/dev/null; echo done' \
		<<<"FOO=bar" >/dev/null 2>&1 || rc1=$?
	out2="$(compose_run "$SCRATCH/compose-current.yaml" "$proj" "file://$TEST_BARE_DIR" "$TEST_COMMIT" \
		-T --rm prod sh -c 'if [ -f /src/.stolen-token ]; then cat /src/.stolen-token; else echo NOT_PRESENT; fi' \
		<<<"$(printf 'GH_TOKEN=dummy-gh-token\nFOO=bar\n')" 2>&1)" || rc2=$?
	compose_down "$SCRATCH/compose-current.yaml" "$proj"
	echo "1st run (credential.helper に窃取コマンドを仕込む): rc=$rc1"
	echo "2nd run (GH_TOKEN 付きで再実行): rc=$rc2 result=$out2"
	echo "注記: file:// はホスト上のパスへの直接アクセスであり認証を要求しないため、git が credential.helper 自体を呼ばない可能性が高い。上記はその前提込みの生の観測結果。"
}
measure_git M6 "named volume 再利用: credential.helper 経由の GH_TOKEN 窃取の試み" m6_n2_credential_helper

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
	create_out="$(docker create \
		--read-only --user 1000:1000 --interactive \
		--tmpfs /run:uid=1000,gid=1000,mode=0755 \
		--tmpfs /tmp:uid=1000,gid=1000,mode=1777 \
		--tmpfs /out:uid=1000,gid=1000,mode=0755 \
		--tmpfs /home/node:uid=1000,gid=1000,mode=0755 \
		--tmpfs /src:uid=1000,gid=1000,mode=0755 \
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
	docker run --rm -i \
		--read-only --user 1000:1000 \
		--tmpfs /run:uid=1000,gid=1000,mode=0755 \
		--tmpfs /tmp:uid=1000,gid=1000,mode=1777 \
		--tmpfs /out:uid=1000,gid=1000,mode=0755 \
		--tmpfs /home/node:uid=1000,gid=1000,mode=0755 \
		--tmpfs /src:uid=1000,gid=1000,mode=0755 \
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
		bash "$REPO_ROOT/images/runtime-base/templates/prod-run.sh" true >/dev/null 2>&1 || rc=$?
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
	echo "HARNESS ERROR: bare repo がコンテナから読めなかったため、SKIP と記録したケース (M1 の compose 経由分 / M2 / M6 / A5 / A6 / A10 / A16) は測定・検証できていない。上の preflight のログを見ること。"
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
