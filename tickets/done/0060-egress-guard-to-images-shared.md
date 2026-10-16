---
status: close
type: refactor
base: main
merge: human
targets:
  - packages/egress-guard/package.json
  - packages/egress-guard/LICENSE
  - packages/egress-guard/CHANGELOG.md
  - packages/egress-guard/README.md
  - packages/egress-guard/docs/agent-brief.md
  - packages/egress-guard/scripts/init-project-firewall.sh
  - packages/egress-guard/templates/firewall.json
  - packages/egress-guard/templates/firewall.audit.json
  - packages/egress-guard/templates/firewall.example.json
  - packages/egress-guard/tests/firewall-config.test.sh
  - packages/egress-guard/tests/firewall-rules.test.sh
  - packages/egress-guard/tests/ptr-spoof-harness.py
  - packages/egress-guard/tests/verify-l7.sh
  - images/shared/egress-guard/README.md
  - images/shared/egress-guard/docs/agent-brief.md
  - images/shared/egress-guard/scripts/init-project-firewall.sh
  - images/shared/egress-guard/templates/firewall.json
  - images/shared/egress-guard/templates/firewall.audit.json
  - images/shared/egress-guard/templates/firewall.example.json
  - images/shared/egress-guard/tests/firewall-config.test.sh
  - images/shared/egress-guard/tests/firewall-rules.test.sh
  - images/shared/egress-guard/tests/ptr-spoof-harness.py
  - images/shared/egress-guard/tests/verify-l7.sh
  - images/egress-proxy/CHANGELOG.md
  - images/egress-proxy/README.md
  - images/egress-proxy/Dockerfile
  - images/egress-proxy/squid.conf
  - images/egress-proxy/tests/bake.test.sh
  - images/runtime-base/Dockerfile
  - images/runtime-base/tests/distributed-file-modes.test.sh
  - images/devcontainer-base/README.md
  - images/devcontainer-base/examples/devcontainer.json
  - images/devcontainer-base/examples/docker-compose.yaml
  - .github/workflows/egress-proxy.yml
  - .github/workflows/runtime-base.yml
  - .github/workflows/runtime-base-verify.yml
  - .devcontainer/docker-compose.yaml
  - package.json
  - pnpm-lock.yaml
  - README.md
  - docs/guarantees.md
verify:
  - pnpm lint
  - pnpm lint:sh
  - pnpm test
---

# egress-guard を npm パッケージの形から images/shared/egress-guard へ移す

## 内容

`@himorogy/egress-guard` は npm への公開をやめた（0047）。
いまの中身は、runtime-base と egress-proxy の2つのイメージへ、named build context `egress-guard=packages/egress-guard` で焼く素材である。
第三者による利用はやめていない。runtime-base を使わない利用者は、egress-proxy イメージからスクリプトと雛形を取り出す。
ところが置き場所は `packages/` のままで、`package.json` に `version`（0.5.1）と changesets による版上げが残っている。
このため、外の利用者が見るタグ（`egress-proxy-v*`）とは対応しない版番号で、CHANGELOG が書き続けられている。

この枚では、npm パッケージとしての外形をやめ、中身をイメージの素材として `images/shared/egress-guard/` へ移す。
変更の記録は、外の利用者が実際に受け取る egress-proxy のタグに合わせて付け直す。
スクリプト・雛形の振る舞いは変えない。

### 移設

- `packages/egress-guard/` の次のファイルを、相対構造を保ったまま `git mv` で `images/shared/egress-guard/` へ移す: `README.md`、`docs/agent-brief.md`、`scripts/`、`templates/`、`tests/`
  - 実行ビット（`scripts/init-project-firewall.sh`、`tests/*.sh` の 755）は `git mv` で保たれる。モードは変えない
  - 移設先はリポジトリルートから4階層になる（移設元は3階層）。`tests/` の内部で使う `REPO_ROOT` は `../../..` を `../../../..` に直す。`../scripts` などパッケージ内の相対参照は変更不要
- 次の3つは削除する
  - `package.json`: npm 向けのメタデータと、changesets の版上げの対象をなくす
  - `LICENSE`: ルートの `LICENSE` と同一の内容で、npm の tarball に入れるための複製だった
  - `CHANGELOG.md`: 下の「変更の記録」へ移す
- named build context の名前 `egress-guard` は変えない。変えるのは、各 workflow の `build-contexts` が指すパスだけである。Dockerfile の `COPY --from=egress-guard ...` は変更不要

### パスを直す箇所

- workflow（`egress-proxy.yml`、`runtime-base.yml`、`runtime-base-verify.yml`）の paths filter（`packages/egress-guard/**` とその `.md` 除外）、`build-contexts`、`egress-proxy.yml` の smoke test が `diff` で突き合わせるソースのパス、それぞれのコメント
- `images/egress-proxy/tests/bake.test.sh` と `images/runtime-base/tests/distributed-file-modes.test.sh` が直書きしているパス
- ルートの `package.json` の `verify:l7`
- Dockerfile・`squid.conf`・`.devcontainer/docker-compose.yaml`・`images/devcontainer-base/examples/` のコメントに出てくるパス
- `README.md`、`images/devcontainer-base/README.md`、`images/egress-proxy/README.md` のパスとリンク
- 移した README の内部リンク: `../../docs/archive/...` は `../../../docs/archive/...` に、`../../images/egress-proxy/README.md` は `../../egress-proxy/README.md` に直す。README の中で「karakuri リポジトリの `packages/egress-guard/...`」と書いている文言も直す
- `pnpm-lock.yaml` の importer `packages/egress-guard` を消す。`pnpm-workspace.yaml` は `packages/*` の glob なので変更不要
- 台帳 `docs/guarantees.md`: §4・§5 の見出しにあるテストと対象のパス、H-a の行の「ビルド元コミットの `packages/egress-guard`」を新しいパスに書き換える。約束の中身は変えない
- 台帳の候補層 `docs/guarantee-candidates/0007-ledger-egress-guard.md` のパスも直す（ゲートの除外パスなので targets には書いていない）

### テストと lint の実行経路を引き継ぐ

egress-guard の `test`（`firewall-config.test.sh` と `firewall-rules.test.sh`）と `lint:sh`（`scripts/*.sh tests/*.sh` に対する `shellcheck -x --shell=bash --severity=style`）は、いまは `packages/egress-guard/package.json` の scripts にあり、ルートから `pnpm -r` で呼ばれている。
`package.json` を消すと `pnpm -r` は該当なしでも成功するので、この2つが**エラーを出さずに実行されなくなる**。
ルートの `package.json` の `test` と `lint:sh:images` に、新しいパスで直接書き足す（`lint:sh:images` の `--shell=bash` の側に置く）。

実装者は、書き足した経路が実際に走ることを否定対照で確かめる。
`firewall-config.test.sh` の期待値を一時的に1つ壊して `pnpm test` が赤になること、`scripts/init-project-firewall.sh` に shellcheck の警告を1つ一時的に入れて `pnpm lint:sh` が赤になること。
確かめた後に戻し、結果を PR 本文に書く。

### 変更の記録

外の利用者が受け取るのは egress-proxy イメージのタグ（`egress-proxy-v1.0.0`、`egress-proxy-v1.1.0`、…）で、egress-guard の版番号は利用者の手元のどこにも現れない。
そこで変更の記録を `images/egress-proxy/CHANGELOG.md` に新設し、見出しを egress-proxy のタグにする。

- `packages/egress-guard/CHANGELOG.md` のうち、イメージにしか届いていない項目（0.5.0、0.5.1、公開終了の告知）は、どのタグに初めて入ったかを `git tag --contains` などで特定し、そのタグの見出しの下に置く。まだどのタグにも入っていない項目は「未リリース」の見出しに置く
- egress-proxy 自身の変更（`egress-proxy-bake`、`squid.conf` など）の記録は、ここで遡って書き起こさない。今後のタグから書く
- npm で公開した版（〜0.4.0）の項目は、末尾に「npm で公開していた版」の節としてまとめて残す。npm から移ってくる利用者が、自分の使っていた版からの差分を読むためである
- 冒頭に、この記録が egress-proxy に同梱する `init-project-firewall.sh` と雛形を含むことを書く。あわせて、runtime-base を使わない利用者はスクリプトと雛形を自分のコンテナへ `COPY --from` で取り込んでいるので、版を上げるときは sidecar とそのコンテナの両方を同じ digest で建て直す必要があることを書く。詳しい手順はパッケージ README の「セットアップ」へのリンクで済ませ、ここには書き写さない
- `images/egress-proxy/README.md` のリリースの「手順」に、タグを打つ前に前回のタグからの変更を CHANGELOG に書く、という1行を足す

runtime-base のタグに合わせた記録は作らない。runtime-base の利用者は devcontainer-base を経由する内部の利用者だけである。

### やらないこと

- スクリプト・雛形・テストの中身の変更。パスの書き換えとリンクの修正に限る
- named build context の名前の変更
- `packages/env-guard` の移動・変更。npm で公開中であり、そのまま残す
- `docs/archive/` の設計文書にあるパスの書き換え。履歴として残す
- すでに存在しない `docs/spec.md` / `docs/design.md` を指しているリンク（`init-project-firewall.sh:5,513`、`.devcontainer/docker-compose.yaml:12` など）の修正。移設前から切れており、この枚の範囲外である。ただし、移設で行が動くファイルの中では、パスの接頭辞だけを直す
- `images/shared/` を、他の `images/*` と同じ「1イメージ = 1ディレクトリ」の構造（Dockerfile・README）にすること。ここはイメージではなく、複数のイメージが共有する素材の置き場である
- GitHub Release の作成や、タグとリリースノートの自動連携
- `.github/CODEOWNERS` の変更。`/packages/*/package.json` の保護は、egress-guard の `package.json` が消えるだけで env-guard には効き続ける
- npm の `deprecate` 文言の更新
- 検査の深さ: 移設後に走らせるのは verify のコマンドと上の否定対照までとする。`docker build` によるイメージの実ビルドは、PR の CI（`runtime-base-verify`、`egress-proxy` の workflow）に任せる

### 実装者が確かめること

- `pnpm-lock.yaml` の更新に、ネットワークが要るかどうかは未確認。`pnpm install --lockfile-only` が通らなければ、importer の1ブロックを手で消し、`pnpm install --frozen-lockfile` が通ることで確かめる
- 移設後に `git grep -n 'packages/egress-guard' -- ':!tickets/' ':!docs/archive/'` を流し、残りが CHANGELOG の過去の記述や、意図して残したものだけであることを確かめる

## 保証

### 新たに宣言する保証

- なし（置き場所の移動で、配布物の中身と配置先のパスは変わらない。CHANGELOG は利用者向けの記録で、振る舞いの約束ではない）

### 維持する保証

- §4・§5（`init-project-firewall.sh` の設定の検証と規則の適用）: テストとスクリプトのパスが変わる。見出しのパスだけを書き換え、本文は変えない。テストが CI で走り続けることは、上の否定対照で確かめる
- H-a（egress-proxy イメージがスクリプトと雛形を含み、ソースと同一の内容で、スクリプトは実行可能、雛形は実行可能でない）: smoke test が突き合わせるソースのパスが変わる。行の中のパスだけを書き換える
- §23（配布物の file mode）: `distributed-file-modes.test.sh` の検査対象のディレクトリが新しいパスを指すこと。移設で検査対象から外れると、mode の欠落が検出されなくなる
- 公開面の定義 C-2・C-3（runtime-base と egress-proxy での `init-project-firewall.sh` と雛形の配置）: 焼き込み先のパスは変えない

### 廃止する保証

- なし（npm パッケージとしての面は 0047 で既に台帳から外れている。この枚は置き場所を変えるだけで、約束を取り下げない）
