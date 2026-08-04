# karakuri

**LLM エージェントを devcontainer で動かすときに、外に出せるものを構造的に絞る**ためのツール群です。

エージェントは指示に従わないことがあり、プロンプトインジェクションを受けることもあります。**「エージェントが正しく振る舞う」ことを前提にしない**という方針で、通信先と秘密情報のそれぞれに手を打っています。

## パッケージ

* **[`@himorogy/egress-guard`](./packages/egress-guard)** — allowlist に無い宛先への外向き通信を遮断する egress ファイアウォール。**漏洩先を限定します**
* **[`@himorogy/enclave-env`](./packages/enclave-env)** — dotenvx による暗号化と実行時ガードで、**本番用の秘密情報をエージェントの手元に置かない**ようにする env 管理 CLI

どちらも `packages/` 配下にあり、それぞれの README に導入手順があります。

## この repo での開発

pnpm workspace（`packages/*`）です。CI が回すのと同じ 3 つをルートで実行できます。

```sh
pnpm lint      # biome
pnpm lint:sh   # shellcheck（各パッケージへ再帰）
pnpm test      # 各パッケージのテスト
```

リリースは changeset を積んでタグを打つと GitHub Actions から公開されます。経路の設計と、そこに置いたゲートの根拠は [`docs/secure-publish.md`](./docs/secure-publish.md)。脆弱性の報告方法は [`SECURITY.md`](./SECURITY.md)。

## この repo 自身が egress-guard の下で動いています

`.devcontainer/firewall.json` がこのコンテナの実効ポリシーのソースです。**自分で作ったものを自分に適用しているので、壊れればまずここで気づきます。**

エージェント向けの前提は [`CLAUDE.md`](./CLAUDE.md) に置いてあります。allowlist を変更する作業を頼むときは [`packages/egress-guard/docs/agent-brief.md`](./packages/egress-guard/docs/agent-brief.md) を読ませてください。

### `allowDomains` に `nodejs.org` がある理由

**リモート接続の relay が `node-pty` をビルドするため、node-gyp が Node のヘッダを取りに行きます。** 2026-08-03 に audit モードで観測しました（`104.16.213.131`）。

**再ビルドのたびに繰り返されます。** `~/.orca-remote`・`~/.cache`・`~/.vscode-server` はいずれもコンテナローカルで、ボリュームに載っていないためです。**外すとリモート接続が壊れます。**

> **これは「観測されなかった」を「不要」と読み違えかけた例でもあります。** 先行する enforce の観測に `nodejs.org` は現れていませんでした。しかし実際には、その手前で `apt` が `deb.debian.org` に到達できず `openssh-server` が入らないため接続自体が成立せず、**node-gyp がそもそも実行されていなかった**というだけでした。経緯は `b1930bd` のコミットメッセージにあります。

**他のドメインを足すときも同じ手順を踏んでください。** 推測で書かず、`audit` で測ってから足す。手順は [`packages/egress-guard/docs/measuring-egress.md`](./packages/egress-guard/docs/measuring-egress.md)。
