---
status: close
type: feat
base: main
targets:
  - images/runtime-base/Dockerfile
  - images/runtime-base/README.md
  - .github/workflows/runtime-base.yml
  - package.json
  - pnpm-lock.yaml
bundle:
  - 0056-runtime-base-trixie-v2
  - 0057-devcontainer-base-trixie-v3
verify:
  - pnpm lint:sh
  - pnpm lint
  - pnpm test
---

# runtime-base を Debian 13（trixie）に載せ替え、固定している版を上げて v2 にする

## 内容

束の全体像: base イメージ2本を Debian 13（trixie）へ載せ替え、固定している版を最新へ上げて、どちらもメジャー版を上げる。
派生イメージが `apt-get install` するパッケージの名前や glibc が変わるので、浮動タグ（runtime-base `:1`、devcontainer-base `:2`）の追従者に黙って届けないためにメジャーを上げる。
順序は次のとおりで、入れ替えられない。

1. 0056（このチケット）: runtime-base を v2 にする
2. マージ後、人間が `runtime-base-v2.0.0` を打ち、GHCR に `:2` が載るのを待つ
3. 0057: devcontainer-base を v3 にする（`FROM runtime-base:2`）。PR の検証ビルドが `:2` を pull するので、2 より前に着手しない
4. 人間が `devcontainer-base-v3.0.0` を打つ

node は 24 のまま据え置く。26 への移行は issue `#36`（2026-10-28 以降）で扱う。
egress-proxy（`debian:bookworm-slim` + squid）は対象外。

### 変えるもの

- `images/runtime-base/Dockerfile`
  - `FROM node:24` を `FROM node:24-trixie` にする。
    - 2026-10-14 の時点で `node:24` は bookworm に解決されている（この devcontainer の apt の snapshot が `20261005T000000Z` の bookworm）。明示しないと trixie にならない
  - `PNPM_VERSION` を 12.11.2、`DOTENVX_VERSION` を 2.35.0、`WRANGLER_VERSION` を 4.151.0 にする（2026-10-14 時点の npm の latest）。実装時に新しい版が出ていれば、その版へ上げてよい
  - apt でインストールしているパッケージが trixie でそのまま入るかを、PR の検証ビルドで確かめる。名前が変わっていれば直す。起草の時点では次の2つが未確認
    - `dnsutils`（trixie では `bind9-dnsutils` への移行用パッケージの可能性がある）
    - `aggregate`
  - `curl` は `node:24` に同梱される前提でインストールしていない。`node:24-trixie` にも同梱されるかは未確認。無ければ apt の一覧に足す
  - Debian の版に依存するコメント（git の版など）と、pnpm の版に依存するコメント（「pnpm 10 / 11 の global bin のレイアウト」）を実態に合わせる。pnpm 12 の global bin の位置は、検証ビルドの smoke test（`pnpm bin -g`）で確かめる
- `package.json` の `packageManager` を `pnpm@12.11.2` にし、`pnpm install` で `pnpm-lock.yaml` を更新する。
  - 理由: base の pnpm と `packageManager` の版が違うと、pnpm が `packageManager` の版を取得して切り替わる。pnpm 12.11.2 で 2026-10-14 に実測した。`packageManager: pnpm@11.25.0` の下で `pnpm --version` が `11.25.0` を返し、取得物が `PNPM_HOME` の下の `package-manager-store/` に置かれた。版が一致していれば取得も切り替えも起きない
  - このリポジトリ自身の devcontainer は devcontainer-base 2.7.0（pnpm 11.25.0）に pin したままなので、マージ後は pnpm 11.25.0 が 12.11.2 を取得して切り替わる。2026-10-14 に実測し、切り替わった先で `pnpm install` と `pnpm lint` が通った。pin を上げるまではこの状態で運用する
  - pnpm 12 は `packageManager` を lockfile に記録する。2026-10-14 に pnpm 12.11.2 で実測した。`pnpm-lock.yaml` の先頭に `packageManagerDependencies` を持つ YAML 文書が1つ増える
- `.github/workflows/runtime-base.yml`
  - コメントのうち、node のタグ・pnpm 11 の global bin・浮動タグの例（`:1 / :1.4 / :1.4.2`）に依存している行を実態に合わせる。
  - 浮動タグそのものは `docker/metadata-action` がタグ名から作るので、ワークフローの中にメジャー番号の固定は無い
- `images/runtime-base/README.md`: 浮動タグの参照を `:2` にし、Debian 13（trixie）が土台であることと、pnpm の版の記述を実態に合わせる
- 台帳の候補層 `docs/guarantee-candidates/0056-runtime-base-trixie-v2.md` を置く。中身は次の1行で、裁可は求めない
  - 「浮動タグ `:N` の中では土台の Debian のメジャー版を変えない。変えるときはイメージのメジャー版を上げる」

確かめること（検収で人間が見る。PR の CI だけでは分からないもの）:

- 焼いた pnpm がネットワーク無しで起動する（`docker run --rm --network none <image> pnpm --version` が 12 系を返す）。
  - pnpm 12 は初回起動時にネイティブバイナリを取得しうる（同梱の CHANGELOG に記載）。
  - npm は pnpm 12 の install script を「許可されていない」と警告する（npm 11.19.0 で観測）。script が走らずに取得が初回起動へ持ち越されると、prod container で pnpm が動かない
- prod container の entrypoint が書く store の設定を pnpm 12 が読む（台帳 §6 の行）。
  - いまの entrypoint は store の設定を2種類の設定ファイル（v11 系の `config.yaml` と v10 系の rc）へ書く。
  - pnpm 12 がこのどちらも読まない場合は、`images/runtime-base/bin/prod-entrypoint.sh` の変更が要る。その時点で止まって報告する（targets の拡張は軽量裁可で決める）
- `pnpm verify:docker`（`images/runtime-base/tests/verify-docker.sh`）が新しいイメージで通る。iptables / ipset と egress-guard の組み合わせが trixie で動くかは、ここで見る

### やらないこと

- タグを打つこと・GHCR に push すること（人間の手作業）
- devcontainer-base 側の変更（0057）。devcontainer-base の README・examples・ルートの README の浮動タグと pnpm の記述（0057）
- monitor.yml の変更（0055 が node の FROM の接尾辞を扱う）
- node 26 への移行（issue `#36`）
- egress-proxy の trixie 化
- 利用側リポジトリ向けの移行の手引きを文書として足すこと。破壊的な変更点は PR 本文とタグの注釈に書く
- 検査の深さ: trixie で入る各パッケージの版の差（git や gh のマイナー版の違い）を一つずつ検証することはしない。CI の smoke test・`verify:docker`・検収の項目が通れば足りる

## 保証

### 新たに宣言する保証

- なし（Debian の版と固定している版の更新であり、利用側に差し出す振る舞いは増えない。浮動タグの規則は候補層に置く）

### 維持する保証

- 台帳 §6「起動中に pnpm は一度も実行されない。store の設定は2種類の設定ファイルの両方へ、同一のパスで書かれる」。pnpm 12 が別の設定ファイルを読む場合に偽になりうる
- 台帳 C-2a / C-2b（shim・hook・`init-project-firewall.sh`・各スクリプトの配置と実行権）。土台を替えても、イメージの中の配置は変わらないこと

### 廃止する保証

- なし（取り下げる約束は無い）
