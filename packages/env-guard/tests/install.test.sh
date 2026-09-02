#!/usr/bin/env bash
#
# packages/env-guard/bin/env-guard.js (env-guard install) の検査。
#
# 使い捨ての git repo を mktemp -d に作り、その中で実際にコマンドを走らせて
# 終了コードと package.json の中身を見る。npm レジストリには触らない。
#
# simple-git-hooks 本体は入れず、テスト用の最小の代役を node_modules/.bin へ
# 置く。役目は「package.json の simple-git-hooks.pre-commit を
# .git/hooks/pre-commit へ書く」ことだけで、ここで見たいのは
# env-guard install がそれを呼んで結果を確かめるところである。
#
# 通しの確認 (導入 -> 平文の .env を stage -> hook が拒否する) と、その経路を
# わざと壊したときに黙って通らないことを、最後の 2 群で見る。
#
set -uo pipefail

GUARD_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$GUARD_DIR/bin/env-guard.js"
HOOK_COMMAND="sh node_modules/@himorogy/env-guard/hooks/pre-commit"

PASS=0
FAIL=0
SKIP=0

ok() {
	PASS=$((PASS + 1))
	printf '  ok   %s\n' "$1"
}

ng() {
	FAIL=$((FAIL + 1))
	printf '  FAIL %s\n' "$1" >&2
}

skip() {
	SKIP=$((SKIP + 1))
	printf '  skip %s\n' "$1"
}

# --- 足回り --------------------------------------------------------------------

# make_repo <dir> — $dir/repo に git repo を作る。package.json は呼び出し側が置く。
#
# core.hooksPath を local で明示するのは、fixture を環境から切り離すためで
# ある。system の /etc/gitconfig がこの値を持つ環境 (このリポジトリの dev
# container がそれで、イメージが /usr/local/share/git-hooks を焼いている) では
# git init しただけの repo もそれを継承し、`git rev-parse --git-path hooks` が
# イメージ側のディレクトリを返す。そうなると (1) 代役の simple-git-hooks が
# そこへ書こうとして失敗し (root 所有で書けない)、テストが叩く
# .git/hooks/pre-commit が生まれない (2) env-guard install の検証もイメージの
# hook を読んで通ってしまい、「hook の呼び先が無い」の否定対照が緑にならない。
# core.hooksPath を意図的に使う検査 10 は自分で設定し直すので影響を受けない。
make_repo() {
	local dir="$1"
	mkdir -p "$dir/repo"
	git init -q "$dir/repo"
	git -C "$dir/repo" config user.email "env-guard@example.invalid"
	git -C "$dir/repo" config user.name "env-guard test"
	git -C "$dir/repo" config core.hooksPath .git/hooks
}

# link_package <repo> — node_modules/@himorogy/env-guard を作業ツリーへ向ける。
# hook は自分の隣の bin/env-guard-scan を見るので、これで実物のスキャナが走る。
link_package() {
	local repo="$1"
	mkdir -p "$repo/node_modules/@himorogy"
	ln -s "$GUARD_DIR" "$repo/node_modules/@himorogy/env-guard"
}

# fake_simple_git_hooks <repo> — テスト用の最小の代役。
fake_simple_git_hooks() {
	local repo="$1"
	mkdir -p "$repo/node_modules/.bin"
	cat >"$repo/node_modules/.bin/simple-git-hooks" <<'SGH'
#!/bin/sh
set -e
cmd=$(node -e 'process.stdout.write(require("./package.json")["simple-git-hooks"]["pre-commit"])')
hooks=$(git rev-parse --git-path hooks)
mkdir -p "$hooks"
printf '#!/bin/sh\n%s\n' "$cmd" >"$hooks/pre-commit"
chmod +x "$hooks/pre-commit"
SGH
	chmod +x "$repo/node_modules/.bin/simple-git-hooks"
}

# run_cli <repo> [引数...] — repo の中でコマンドを実行し、出力をまとめて返す。
run_cli() {
	local repo="$1"
	shift
	(cd "$repo" && node "$CLI" "$@" 2>&1)
}

# run_hook <repo> — 実体化された .git/hooks/pre-commit を repo の中で実行する。
run_hook() {
	local repo="$1"
	(cd "$repo" && ./.git/hooks/pre-commit 2>&1)
}

PKG_WITH_SGH='{
  "name": "demo",
  "version": "1.0.0",
  "scripts": {
    "build": "echo build"
  },
  "devDependencies": {
    "simple-git-hooks": "^2.11.1"
  }
}
'

PKG_WITHOUT_SGH='{
  "name": "demo",
  "version": "1.0.0",
  "devDependencies": {
    "typescript": "^5.0.0"
  }
}
'

HAVE_GIT=0
if command -v git >/dev/null 2>&1; then
	HAVE_GIT=1
fi

if [ "$HAVE_GIT" -eq 0 ]; then
	skip "env-guard install の全検査: git 不在のため未検証"
	printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
	exit 1
fi

# --- 1. simple-git-hooks が無ければ何も書かずに落ちる ---------------------------

t="$(mktemp -d)"
make_repo "$t"
printf '%s' "$PKG_WITHOUT_SGH" >"$t/repo/package.json"
cp "$t/repo/package.json" "$t/before.json"
out="$(run_cli "$t/repo" install)"
rc=$?
if [ "$rc" -ne 0 ] &&
	printf '%s\n' "$out" | grep -q "simple-git-hooks is not a dependency" &&
	printf '%s\n' "$out" | grep -q "npm install --save-dev simple-git-hooks"; then
	ok "simple-git-hooks が無い -> 非ゼロ終了し、入れるものを出力する"
else
	ng "simple-git-hooks が無い -> 非ゼロ終了し、入れるものを出力する (rc=$rc out=$out)"
fi
if cmp -s "$t/before.json" "$t/repo/package.json"; then
	ok "simple-git-hooks が無い -> package.json が書き換わっていない"
else
	ng "simple-git-hooks が無い -> package.json が書き換わっていない"
fi
rm -rf "$t"

# --- 2. 未設定なら書き込む。他のキーとインデントは保たれる -----------------------

t="$(mktemp -d)"
make_repo "$t"
printf '%s' "$PKG_WITH_SGH" >"$t/repo/package.json"
link_package "$t/repo"
fake_simple_git_hooks "$t/repo"
out="$(run_cli "$t/repo" install)"
rc=$?
if [ "$rc" -eq 0 ]; then
	ok "pre-commit 未設定 -> 0 で終了する"
else
	ng "pre-commit 未設定 -> 0 で終了する (rc=$rc out=$out)"
fi

cat >"$t/expected.json" <<'EXPECTED'
{
  "name": "demo",
  "version": "1.0.0",
  "scripts": {
    "build": "echo build"
  },
  "devDependencies": {
    "simple-git-hooks": "^2.11.1"
  },
  "simple-git-hooks": {
    "pre-commit": "sh node_modules/@himorogy/env-guard/hooks/pre-commit"
  }
}
EXPECTED
if diff -u "$t/expected.json" "$t/repo/package.json" >"$t/diff" 2>&1; then
	ok "pre-commit 未設定 -> 追加した 1 キー以外は 1 バイトも変わらない"
else
	ng "pre-commit 未設定 -> 追加した 1 キー以外は 1 バイトも変わらない"
	cat "$t/diff" >&2
fi
cp "$t/repo/package.json" "$t/after-first-run.json"

# --- 3. 冪等 — 2 回目で package.json が変わらない --------------------------------

out="$(run_cli "$t/repo" install)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q "already runs the env-guard hook"; then
	ok "2 回目の実行 -> 0 で終了し、導入済みである旨を出力する"
else
	ng "2 回目の実行 -> 0 で終了し、導入済みである旨を出力する (rc=$rc out=$out)"
fi
if cmp -s "$t/after-first-run.json" "$t/repo/package.json"; then
	ok "2 回目の実行 -> package.json が 1 バイトも変わらない"
else
	ng "2 回目の実行 -> package.json が 1 バイトも変わらない"
fi
rm -rf "$t"

# --- 4. 既存の simple-git-hooks キーがあれば、その中へ足す -----------------------

t="$(mktemp -d)"
make_repo "$t"
cat >"$t/repo/package.json" <<'PKG'
{
  "name": "demo",
  "devDependencies": {
    "simple-git-hooks": "^2.11.1"
  },
  "simple-git-hooks": {
    "commit-msg": "echo msg"
  }
}
PKG
link_package "$t/repo"
fake_simple_git_hooks "$t/repo"
run_cli "$t/repo" install >/dev/null 2>&1
cat >"$t/expected.json" <<'EXPECTED'
{
  "name": "demo",
  "devDependencies": {
    "simple-git-hooks": "^2.11.1"
  },
  "simple-git-hooks": {
    "commit-msg": "echo msg",
    "pre-commit": "sh node_modules/@himorogy/env-guard/hooks/pre-commit"
  }
}
EXPECTED
if diff -u "$t/expected.json" "$t/repo/package.json" >"$t/diff" 2>&1; then
	ok "既存の simple-git-hooks キーがあれば、他の hook を残したまま中へ足す"
else
	ng "既存の simple-git-hooks キーがあれば、他の hook を残したまま中へ足す"
	cat "$t/diff" >&2
fi
rm -rf "$t"

# --- 5. 別のコマンドが設定済みなら上書きしない -----------------------------------

t="$(mktemp -d)"
make_repo "$t"
cat >"$t/repo/package.json" <<'PKG'
{
  "name": "demo",
  "devDependencies": {
    "simple-git-hooks": "^2.11.1"
  },
  "simple-git-hooks": {
    "pre-commit": "npx lint-staged"
  }
}
PKG
cp "$t/repo/package.json" "$t/before.json"
link_package "$t/repo"
fake_simple_git_hooks "$t/repo"
out="$(run_cli "$t/repo" install)"
rc=$?
if [ "$rc" -ne 0 ] &&
	printf '%s\n' "$out" | grep -q "npx lint-staged" &&
	printf '%s\n' "$out" | grep -q "$HOOK_COMMAND"; then
	ok "別のコマンドが設定済み -> 非ゼロ終了し、現在の値と要る値を両方出力する"
else
	ng "別のコマンドが設定済み -> 非ゼロ終了し、現在の値と要る値を両方出力する (rc=$rc out=$out)"
fi
if cmp -s "$t/before.json" "$t/repo/package.json"; then
	ok "別のコマンドが設定済み -> 既存の値が保たれている"
else
	ng "別のコマンドが設定済み -> 既存の値が保たれている"
fi
rm -rf "$t"

# --- 6. --check は書かずに状態だけを報告する -------------------------------------

t="$(mktemp -d)"
make_repo "$t"
printf '%s' "$PKG_WITH_SGH" >"$t/repo/package.json"
cp "$t/repo/package.json" "$t/before.json"
link_package "$t/repo"
fake_simple_git_hooks "$t/repo"
out="$(run_cli "$t/repo" install --check)"
rc=$?
if [ "$rc" -ne 0 ]; then
	ok "--check は未導入で非ゼロ終了する"
else
	ng "--check は未導入で非ゼロ終了する (rc=$rc out=$out)"
fi
if cmp -s "$t/before.json" "$t/repo/package.json"; then
	ok "--check は package.json を書き換えない"
else
	ng "--check は package.json を書き換えない"
fi

run_cli "$t/repo" install >/dev/null 2>&1
out="$(run_cli "$t/repo" install --check)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q "installed"; then
	ok "--check は導入済みで 0 で終了する"
else
	ng "--check は導入済みで 0 で終了する (rc=$rc out=$out)"
fi
rm -rf "$t"

# --- 7. 通し — 導入したうえで平文の .env を stage すると拒否される ----------------

t="$(mktemp -d)"
make_repo "$t"
printf '%s' "$PKG_WITH_SGH" >"$t/repo/package.json"
link_package "$t/repo"
fake_simple_git_hooks "$t/repo"
git -C "$t/repo" add package.json
git -C "$t/repo" commit -q -m "initial"
out="$(run_cli "$t/repo" install)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q "verified"; then
	ok "通し: 導入が 0 で終わり、hook が実体化されたことを報告する"
else
	ng "通し: 導入が 0 で終わり、hook が実体化されたことを報告する (rc=$rc out=$out)"
fi

printf 'API_KEY=plaintext-value\n' >"$t/repo/.env"
git -C "$t/repo" add .env
out="$(run_hook "$t/repo")"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "API_KEY is not encrypted"; then
	ok "通し: 平文の .env を stage -> hook が非ゼロで拒否する"
else
	ng "通し: 平文の .env を stage -> hook が非ゼロで拒否する (rc=$rc out=$out)"
fi
if printf '%s\n' "$out" | grep -q "plaintext-value"; then
	ng "通し: 拒否の出力に値そのものが出ていない"
else
	ok "通し: 拒否の出力に値そのものが出ていない"
fi

printf 'DOTENV_PUBLIC_KEY="0123abc"\nAPI_KEY="encrypted:BASE64"\n' >"$t/repo/.env"
git -C "$t/repo" add .env
out="$(run_hook "$t/repo")"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q "inspected 1 file"; then
	ok "通し: 暗号化済みの .env は通り、検査件数が出る"
else
	ng "通し: 暗号化済みの .env は通り、検査件数が出る (rc=$rc out=$out)"
fi
rm -rf "$t"

# --- 8. 否定対照: hook からスキャナへの経路が壊れていたら黙って通さない -----------
#
# hook はスキャナを「自分の隣の ../bin」「イメージが置く /usr/local/bin」の順で
# 探す。前者を欠いた状態を作る。後者が在る環境ではこの状況を作れないので、
# 作れなかったことが分かる形で skip する。

if [ -x /usr/local/bin/env-guard-scan ]; then
	skip "否定対照: 隣にスキャナが無い -> 非ゼロ (/usr/local/bin のスキャナが在るため未検証)"
else
	t="$(mktemp -d)"
	make_repo "$t"
	printf '%s' "$PKG_WITH_SGH" >"$t/repo/package.json"
	# hooks だけを置き、bin/env-guard-scan は置かない。
	mkdir -p "$t/repo/node_modules/@himorogy/env-guard/hooks"
	cp "$GUARD_DIR/hooks/pre-commit" \
		"$t/repo/node_modules/@himorogy/env-guard/hooks/pre-commit"
	fake_simple_git_hooks "$t/repo"
	git -C "$t/repo" add package.json
	git -C "$t/repo" commit -q -m "initial"
	run_cli "$t/repo" install >/dev/null 2>&1

	# 暗号化済みの .env を渡す。スキャナが走っていれば通る内容なので、
	# 非ゼロになったのは検出ではなく「検査できなかった」ためだと分かる。
	printf 'DOTENV_PUBLIC_KEY="0123abc"\nAPI_KEY="encrypted:BASE64"\n' >"$t/repo/.env"
	git -C "$t/repo" add .env
	out="$(run_hook "$t/repo")"
	rc=$?
	if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "scanner not found"; then
		ok "否定対照: スキャナが見つからない -> 黙って通さず、理由付きで非ゼロ終了する"
	else
		ng "否定対照: スキャナが見つからない -> 黙って通さず、理由付きで非ゼロ終了する (rc=$rc out=$out)"
	fi
	rm -rf "$t"
fi

# --- 9. 否定対照: hook の呼び先が置かれていなければ導入を成功と報告しない ---------
#
# package.json に書けて .git/hooks/pre-commit も生まれても、パッケージ本体が
# node_modules に無ければ commit のたびに失敗する。書けたことだけを見て
# 「入った」と報告しないことを見る。

t="$(mktemp -d)"
make_repo "$t"
printf '%s' "$PKG_WITH_SGH" >"$t/repo/package.json"
fake_simple_git_hooks "$t/repo"
out="$(run_cli "$t/repo" install)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "no such file"; then
	ok "否定対照: hook の呼び先が無い -> 導入を成功と報告せず非ゼロ終了する"
else
	ng "否定対照: hook の呼び先が無い -> 導入を成功と報告せず非ゼロ終了する (rc=$rc out=$out)"
fi

# 同じ状態で --check も 0 を返さないこと。
run_cli "$t/repo" install --check >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
	ok "否定対照: hook の呼び先が無い -> --check も 0 を返さない"
else
	ng "否定対照: hook の呼び先が無い -> --check も 0 を返さない"
fi
rm -rf "$t"

# --- 10. core.hooksPath がスキャナ直呼びの hook (イメージ方式) を指すとき --------
#
# dev container のイメージは core.hooksPath に置いた hook から共有スキャナ
# env-guard-scan を直接呼ぶ。検査の実体はスキャナであり、node_modules の
# hook ファイルを経由することは要件ではないので、--check はこれを「検査が
# 繋がっている」として通す (コンテナ内で --check が ❌ になる偽陰性を
# 実測で踏んだ regression)。node_modules 経路もイメージ hook も呼ばない
# ファイルは従来どおり落とす (否定対照)。

t="$(mktemp -d)"
make_repo "$t"
printf '%s' "$PKG_WITH_SGH" >"$t/repo/package.json"
fake_simple_git_hooks "$t/repo"
link_package "$t/repo"
run_cli "$t/repo" install >/dev/null 2>&1
mkdir -p "$t/imagehooks"
printf '#!/bin/sh\ngit diff --cached --name-only | /usr/local/bin/env-guard-scan\n' >"$t/imagehooks/pre-commit"
chmod +x "$t/imagehooks/pre-commit"
git -C "$t/repo" config core.hooksPath "$t/imagehooks"
run_cli "$t/repo" install --check >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
	ok "core.hooksPath がスキャナ直呼び hook を指す -> --check は 0"
else
	ng "core.hooksPath がスキャナ直呼び hook を指す -> --check は 0 (rc=$rc)"
fi

# 否定対照: スキャナにも node_modules の hook にも触れないファイルは落ちる。
printf '#!/bin/sh\nexit 0\n' >"$t/imagehooks/pre-commit"
run_cli "$t/repo" install --check >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
	ok "否定対照: 検査に繋がらない hooksPath ファイル -> --check は非ゼロ"
else
	ng "否定対照: 検査に繋がらない hooksPath ファイル -> --check は非ゼロ"
fi
rm -rf "$t"

# --- 11. git が使えない場所では何も書かない -------------------------------------
#
# install は git hook を実体化する機能なので、git repo の外 (または git が
# PATH に無いとき) には成立しない。ここで package.json だけ書き換えると、
# hook を置けたのか確かめられないまま設定だけが残る。何も書かずに落ちる
# ことを見る。

t="$(mktemp -d)"
mkdir -p "$t/repo"
printf '%s' "$PKG_WITH_SGH" >"$t/repo/package.json"
cp "$t/repo/package.json" "$t/before.json"
if git -C "$t/repo" rev-parse --git-dir >/dev/null 2>&1; then
	# mktemp の作り先がたまたま git repo の中だった場合。前提が崩れて
	# いるので、通ったことにせず未検証として残す。
	skip "git repo の外の検査: $t が git repo の中にあるため未検証"
else
	out="$(run_cli "$t/repo" install)"
	rc=$?
	if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "Nothing was written."; then
		ok "git repo の外 -> 非ゼロ終了し、何も書かなかったことを出力する"
	else
		ng "git repo の外 -> 非ゼロ終了し、何も書かなかったことを出力する (rc=$rc out=$out)"
	fi
	if cmp -s "$t/before.json" "$t/repo/package.json"; then
		ok "git repo の外 -> package.json が 1 バイトも変わらない"
	else
		ng "git repo の外 -> package.json が 1 バイトも変わらない"
	fi
fi
rm -rf "$t"

# --- result ----------------------------------------------------------------------

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
