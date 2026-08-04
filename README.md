# karakuri

**複数のプロジェクトで共通に使う開発基盤を置いておくリポジトリです。**

1 つのプロジェクトで作ったものが、他のプロジェクトでも要るとわかった時点で、ここへ切り出して
バージョンの付いた形にしています。**改善を 1 か所に入れれば全プロジェクトへ伝わる**状態を
保つことが目的です。

収録しているのは、開発コンテナのベースイメージと、そこに載せる部品です。

---

## 収録物

### イメージ

* **[`images/devcontainer-base`](./images/devcontainer-base)** — 全プロジェクト共通の
  devcontainer ベースイメージ。Node / pnpm / エージェントが直接使う CLI 群 /
  egress-guard 本体を収録している。各プロジェクトは `FROM` で参照する

### パッケージ

* **[`@himorogy/egress-guard`](./packages/egress-guard)** — allowlist に無い宛先への
  外向き通信を遮断する egress ファイアウォール。**漏洩先を限定する**
* **[`@himorogy/enclave-env`](./packages/enclave-env)** — dotenvx による暗号化と実行時
  ガードで、**本番用の秘密情報をエージェントの手元に置かない**ようにする env 管理 CLI

### 三者の関係

```
ghcr.io/himorogy/devcontainer-base:1     ← images/devcontainer-base
  ├─ Node / pnpm / git / gh / ripgrep / crit …
  └─ egress-guard 本体（スクリプトと sudoers）
        ↑ ARG EGRESS_GUARD_VERSION で pin

プロジェクトの .devcontainer/Dockerfile
  ├─ FROM ghcr.io/himorogy/devcontainer-base:1
  └─ firewall.json（許可ドメイン。プロジェクトごとに異なる）

プロジェクトの package.json
  └─ @himorogy/enclave-env（devDependency）
```

egress-guard は**イメージ側**に、enclave-env は**プロジェクトの依存**として入ります。
前者は root 権限が要りコンテナ起動時に効くもの、後者はコマンドとして呼ぶもの、という違いです。

---

## エージェントを前提にした設計

egress-guard と enclave-env は、どちらも同じ前提の上に立っています。

**エージェントは指示に従わないことがあり、プロンプトインジェクションを受けることもあります。**
「エージェントが正しく振る舞う」ことを前提にせず、通信先と秘密情報のそれぞれに、
エージェントの側からは外せない形で手を打っています。

守れる範囲と守れない範囲は、それぞれの README と `docs/` に書いてあります。
**どちらも万能ではありません。**

allowlist の変更をエージェントに頼むときは
[`packages/egress-guard/docs/agent-brief.md`](./packages/egress-guard/docs/agent-brief.md)
を読ませてください。遮断をネットワーク障害と診断して迂回を試みるのを防ぐためです。

---

## 使い始める

**ベースイメージはまだ GHCR に公開されていません。**
[`.github/workflows/devcontainer-base.yml`](./.github/workflows/devcontainer-base.yml) が
一度も実行されていないためです。下記はイメージができてからの手順です。

* **新しいプロジェクトに入れる** — [`images/devcontainer-base/examples/`](./images/devcontainer-base/examples)
  の 2 ファイルを `.devcontainer/` にコピーし、`firewall.json` を書く
* **既存の devcontainer を載せ替える** — [`images/devcontainer-base/migration.md`](./images/devcontainer-base/migration.md)。
  ベースイメージは pnpm 11 なので、pnpm 10 のプロジェクトは先に読むこと
* **パッケージだけ使う** — 各パッケージの README に単体での導入手順があります。
  ベースイメージを使わなくても入れられます

---

## この repo での開発

pnpm workspace（`packages/*`）です。CI が回すのと同じ 3 つをルートで実行できます。

```sh
pnpm lint      # biome
pnpm lint:sh   # shellcheck（各パッケージへ再帰）
pnpm test      # 各パッケージのテスト
```

パッケージのリリースは changeset を積んでタグを打つと GitHub Actions から公開されます。
経路の設計と、そこに置いたゲートの根拠は [`docs/secure-publish.md`](./docs/secure-publish.md)。
ベースイメージのリリースは別経路で、[`images/devcontainer-base/README.md`](./images/devcontainer-base/README.md)
の「リリース」を参照してください。

脆弱性の報告方法は [`SECURITY.md`](./SECURITY.md)。

---

## この repo 自身が egress-guard の下で動いています

`.devcontainer/firewall.json` がこのコンテナの実効ポリシーのソースです。
**自分で作ったものを自分に適用しているので、壊れればまずここで気づきます。**

### 許可ドメインを足すときは測ってから足す

`allowDomains` の `nodejs.org` がその例です。リモート接続の relay が `node-pty` を
ビルドするため、node-gyp が Node のヘッダを取りに行きます。2026-08-03 に audit モードで
観測しました（`104.16.213.131`）。`~/.orca-remote` / `~/.cache` / `~/.vscode-server` は
いずれもコンテナローカルなので、**再ビルドのたびに繰り返されます。外すとリモート接続が
壊れます。**

> **これは「観測されなかった」を「不要」と読み違えかけた例でもあります。** 先行する
> enforce の観測に `nodejs.org` は現れていませんでした。しかし実際には、その手前で `apt` が
> `deb.debian.org` に到達できず `openssh-server` が入らないため接続自体が成立せず、
> **node-gyp がそもそも実行されていなかった**というだけでした。経緯は `b1930bd` の
> コミットメッセージにあります。

**推測で書かず、`audit` で測ってから足す。** 手順は
[`packages/egress-guard/docs/measuring-egress.md`](./packages/egress-guard/docs/measuring-egress.md)。
