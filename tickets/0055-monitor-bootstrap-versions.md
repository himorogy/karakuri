---
status: open
type: fix
base: main
targets:
  - .github/workflows/monitor.yml
verify:
  - pnpm lint:sh
  - pnpm lint
  - pnpm test
---

# 監視が手動公開の初版で毎日 alert を出し続けるのを止める

## 内容

`.github/workflows/monitor.yml` の Slack 通知は、毎日「異常検知」（alert）になっている。
2026-10-14 に workflow 本体をローカルで再現した（Slack 送信だけ外した）ところ、alert と warn の原因は次の3つだった。

- `@himorogy/egress-guard` 0.1.0 に git tag が無い（alert）
- `@himorogy/env-guard` 0.1.0 に git tag が無い（alert）
- `@himorogy/env-guard` の最新版 0.1.0 に provenance が無い（warn）

どちらの 0.1.0 も、trusted publisher を登録する前に手で公開した初版である（`docs/secure-publish.md` §7.4 と §8 の表に記録済み）。
タグも provenance も、今から付けることはできない。
このまま毎日 alert が出ると、即時に動くべき alert（advisory の影響下にある pin など）が埋もれる。

egress-guard は 0047（`kuda/0047-retire-egress-guard-npm`、同僚レビュー中）で private になり、監視対象から外れる。
**このチケットは 0047 の着地後に着手する。** 列挙するのは env-guard 0.1.0 だけにする。

### 変えるもの

- 手で公開した初版を `<pkg>@<ver>` の完全一致で列挙する変数を `monitor.yml` に置き、`@himorogy/env-guard@0.1.0` を載せる。
  - 列挙に当たった版はタグ照合で「タグのない版」に数えない。
  - 最新版が列挙に当たるときは provenance の欠落で warn にしない。
  - 列挙に当たらない版は、これまでどおり検査する。env-guard の次の版を出せば、その版はタグ照合と provenance 検査の両方を受ける
  - 既存の `LEGACY_TAGGED` は意味が違う（旧形式の `v<ver>` タグがあれば通す）ので流用しない。`LEGACY_TAGGED` に当たってもタグが無ければ「タグのない版」になる。
  - 列挙の直前のコメントには、手で公開した初版であることと、出典が `docs/secure-publish.md` §7.4 であることを書く
- runtime-base の node の版を読む抽出を、`FROM node:24-trixie` のように変種の接尾辞が付いても major だけを取り出す形に直す。
  - 0056 で `FROM node:24` が `FROM node:24-trixie` になる。いまの抽出（`s/^FROM node:\(.*\)/\1/p`）は `24-trixie` を返す。
  - それを `pin-lag.sh node-schedule` に渡すと `schedule-unavailable`（rc=1）になり、warn が出る。2026-10-14 に実測した（`24` なら `6 564` / rc=0）。
  - 接尾辞の無い `FROM node:24` からも `24` を返すこと（0056 の着地前後どちらでも動く）
- golang builder の版を読む箇所のコメントで、Debian の変種の例が `-bookworm` に固定されている。0057 で `-trixie` になるので、変種の名前に依らない書き方へ直す。抽出の正規表現は `golang:1.26-trixie` からも `1.26` を返すことを実測済みなので触らない

### やらないこと

- env-guard の次の版を公開すること
- 初版にタグを後から打つこと（「タグ = 公開経路を通った」という意味が崩れる）
- `docs/secure-publish.md` の変更（0047 が触っている。§6 と §7.4 の記述のままで列挙の理由は辿れる）
- monitor.yml の分岐をスクリプトへ切り出してテストを付けること
- golang の最新版がこのコンテナの proxy 越しに取れない件（`go.dev` は devcontainer の allowDomains に無い。CI のランナーからは取れる前提のまま）
- 検査の深さ: node の FROM に digest（`@sha256:…`）や `node:24.11-trixie` のような minor 指定が付く形は扱わない。いまの Dockerfile も 0056 も major だけを書く

## 保証

### 新たに宣言する保証

- なし（monitor.yml は台帳に節を持たない運用の workflow で、利用側が依存する公開面ではない）

### 維持する保証

- 台帳 §21 の node の行（maintenance / EOL までの残り日数を出すだけで、日数で escalate しない）。抽出を変えても `pin-lag.sh node-schedule` に渡る値が major のままであること

### 廃止する保証

- なし（取り下げる約束は無い。初版の扱いは台帳に載っていない）
