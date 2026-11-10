---
status: close
type: chore
base: main
targets:
  - images/runtime-base/Dockerfile
  - images/devcontainer-base/Dockerfile
verify:
  - pnpm lint:sh
  - pnpm lint
  - pnpm test
---

# runtime-base / devcontainer-base に焼き込む依存の固定版を最新へ上げる

## 内容

2026-11-11 に node の security release が出る予定である。
`devcontainer-base-v3.2.0`（0064 の `safe.directory` / `core.checkStat` 入り）のタグ打ちを延期し、node の取り込みと同じタグに、焼き込みの依存の版上げを載せる。

### 前提

- 0064（PR #108）のマージ。着手はマージ後の `origin/main` を取り込んでから行う
- 0064 の差分は `images/devcontainer-base/Dockerfile` の `RUN crit --version` の後ろに `git config --system` の区間を足すだけで、このチケットが触る版の行（`ARG CRIT_VERSION`）とは重ならない

### 変えるもの

起票時点（2026-11-10）の固定値と最新版は次のとおり。最新版は `npm view <pkg> version` と GitHub releases で実測した。

- `images/runtime-base/Dockerfile`
  - `ARG PNPM_VERSION`: 12.11.2 → 12.18.0
  - `ARG DOTENVX_VERSION`: 2.35.0 → 2.38.2
  - `ARG WRANGLER_VERSION`: 4.151.0 → 4.159.0
- `images/devcontainer-base/Dockerfile`
  - `ARG CRIT_VERSION`: v0.22.0 → v0.23.2（`tomasz-tomczyk/crit` の releases、2026-10-31 公開）

実装時に最新版をもう一度取り、起票時より新しい版が出ていれば、同じ major の範囲でそちらを採る。major が上がっていたら上げずに止まって報告する。
crit は 0.x の minor 上げなので、v0.22.0 から採る版までのリリースノートを読む。kuda が使う操作（`crit --no-open <file>`・`crit --session`・`crit stop`・`crit comment --reply-to`）に破壊的変更があれば、止まって報告する。

`ARG` 行の書式（`ARG <名前>=<値>`）は変えない。`.github/workflows/monitor.yml` がこの書式を `sed` で読んでいる。

### 版上げしないもの

- node: `FROM node:24-trixie` の浮動タグなので、ソースは変えない。security release はリビルドで取り込まれる
- gh: apt で入れていて版を固定していない。リビルドで取り込まれる
- `golang:1.27-trixie`（crit のビルダ）: patch は浮動タグで取り込まれる
- `ARG RUNTIME_BASE_VERSION=2`: major の浮動参照のまま

### タグを打つ条件と順序（マージ後、人間が行う）

1. node の security release が出て、Docker Hub の `node:24-trixie` に反映されたことを、ホストで確かめる（`docker run --rm --pull always node:24-trixie node --version` が release の版を返す）。反映前にタグを打つと、古い node が焼かれる
2. `runtime-base-v2.2.0` を main に打ち、GHCR への push の完了を待つ
3. 同じコミットに `devcontainer-base-v3.2.0` を打つ。devcontainer-base は `runtime-base:2` を浮動参照するので、2 の完了前に打つと、ビルドは失敗せずに古い runtime-base を焼く
4. digest はホストで取る（この dev からは ghcr.io に届かない）

### 検収

ホストで `ghcr.io/himorogy/devcontainer-base:3.2.0` を pull して、次を確かめる。

1. `node --version` が security release の版を返す
2. `pnpm --version` が 12.18.0 を返す（runtime-base 側の版上げが devcontainer-base に届いたことの確認も兼ねる）
3. `dotenvx --version` と `wrangler --version` が上げた版を返す
4. crit の版は `--version` では出ないので、`grep -a -o 'mod.github.com/tomasz-tomczyk/crit.v[0-9.]*' /usr/local/bin/crit | head -1` で読む
5. `git config --system --get-all safe.directory` が `/workspaces/*` を返す（0064 の変更が同じタグに載ったことの確認）
6. このイメージを使う別のリポジトリの dev で、crit のレビュー（起動・コメント・Finish Review・`crit stop`）が普段どおり動く

### やらないこと

- karakuri 自身の dev の pin（`.devcontainer/Dockerfile`）と、`package.json` の `packageManager`・`pnpm-lock.yaml`・devDependencies の更新。3.2.0 を別のリポジトリで確かめてから、別のチケットで上げる。そのとき 0065 が置いた一時的な git の設定も外す
  - 焼き込みの pnpm と `packageManager` が食い違うと pnpm は `ERR_PNPM_BAD_PM_VERSION` で止まる（pnpm 12.11.2 で 2026-11-10 に実測）。karakuri の dev は 3.1.0（pnpm 12.11.2）のままなので、`packageManager` を先に上げると dev が止まる
- node 26 への移行（Issue #36）
- egress-proxy のイメージ
- 焼いた版と `ARG` の値の突き合わせを CI に足すこと。検収で手で確かめる

## 保証

### 新たに宣言する保証

- なし（焼き込む依存の版を上げるだけで、利用者に差し出す振る舞いは増えない）

### 維持する保証

- 台帳 C-2a の最終行（`packageManager` が焼いた pnpm と異なる版を指すと、pnpm は切り替えずに非ゼロで止まる）。pnpm を上げても成り立つことを、CI の runtime-base ワークフローの smoke test で確かめる
- 台帳 C-2a の `dotenvx` の shim の行と、台帳 8 の shim の各行。dotenvx と wrangler の版上げで、shim が呼ぶ実体が変わる

### 廃止する保証

- なし（版上げで取り下げる約束は無い）
