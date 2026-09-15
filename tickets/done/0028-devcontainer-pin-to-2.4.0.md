---
status: close
type: chore
base: main
targets:
  - .devcontainer/Dockerfile
verify:
  - pnpm lint:sh
  - pnpm test
---

# karakuri の devcontainer の pin を :edge から devcontainer-base 2.4.0 へ戻す

## 内容

`.devcontainer/Dockerfile` の `FROM` を、先行検証用の `devcontainer-base:edge@sha256:12dbdd8e…` から
正式リリース `devcontainer-base:2.4.0` の index digest へ戻す。変更はこのファイル 1 本。

```
FROM ghcr.io/himorogy/devcontainer-base:2.4.0@sha256:4fb802e8baa98dc7e28e22a1d7e24f688c5368a699cdd790916c4a2e06275947
```

digest はホストで `docker buildx imagetools inspect ghcr.io/himorogy/devcontainer-base:2.4.0` の
`Digest:` から取った index digest（`application/vnd.oci.image.index.v1+json`）である。
プラットフォーム単体の manifest の digest ではないので、arm64 / amd64 のどちらでも pull できる。

### なぜ今戻すか

0021（karakuri 自身の L7 切替、PR #51）のマージ後に残った順序の 3 番目である。

1. `@himorogy/egress-guard@0.3.0` のタグ —— 済（npm 公開 2026-09-14）
2. runtime-base → devcontainer-base のタグ —— 済（0027 / PR #58 のマージコミットに
   `runtime-base-v1.6.0` と `devcontainer-base-v2.4.0` を打ち、どちらもビルド成功）
3. **`.devcontainer/Dockerfile` の pin を正式版へ戻す —— このチケット**
4. ホスト上で `pnpm verify:l7` による検収 —— このチケットの検収として行う

`:edge` は `workflow_dispatch` で焼く浮動タグで、正式リリースの系列ではない。digest で固定して
いるので動かないが、コメントに「一時的」と書いた状態を残すと、次に pin を上げる人が何を基準に
上げればよいか読めない。

### Dockerfile のコメントの書き換え

`FROM` の上のコメント塊のうち、「**一時的に :edge の digest を指している**」で始まる段落を
削除する。その代わりに、次の 2 点が読めるようにする。

- **2.4.0 を選んだ理由**: egress-guard 0.3.0（`.devcontainer/firewall.json` の `version: 2` を
  受理する版）を焼いた公開済みの base は 2.4.0 が最初であり、それより前の版はどれも
  `unsupported schema version` で拒否する。L7 を選んだこの devcontainer が起動できる正式版は
  2.4.0 だけである
- **N-1 規律との関係**: 冒頭の段落にある「通常は 1 つ前の実証済みリリースへ pin し、pin を
  上げるのはその版が base を利用する別のリポジトリで実運用に耐えたことを確認してから」は
  この時点では適用できない（1 つ前の版では起動しない）。2.4.0 の実証は、公開前に同じ内容を
  `:edge` で焼いて別のリポジトリで L7 を通したことと、このチケットの検収（下記）が担う。
  規律が再び効くのは 2.5.0 以降で、そのとき karakuri は 2.4.0 に留まる

冒頭の段落（digest pin の根拠、N-1 の規律の本文）は変えない。「正式版への pin の戻しは別の
作業単位で行う」の 1 文はこのチケットで果たされるので消す。

### 検収（ホスト）

devcontainer の中には `docker` も Docker のソケットも無いので、このチケットの本体はホストで
確かめる。

1. ホストでこのブランチを取り出し、devcontainer を作り直す（`docker compose build --pull` で
   `dev` と `egress-proxy` の両方を組む）
2. `pnpm verify:l7` をホストから走らせ、判定できなかった項目が無いことを含めて全項目を読む
3. 実際に開発作業ができることを確認する（`pnpm install`、VS Code 拡張の導入、`git fetch`）

### やらないこと

- `.devcontainer/proxy/`（`templates/proxy/` の写し）は触らない。写しの acl ステージは既に
  `@himorogy/egress-guard@0.3.0` を pin しており、2.4.0 が焼く版と揃っている
- `.devcontainer/firewall.json` は触らない（`version: 2`、`mode: enforce`、実現層は既定の L7）
- `images/devcontainer-base/README.md` の N-1 規律の記述は触らない。規律そのものは変わらず、
  今回だけ適用できない事情は Dockerfile のコメントに書く
- 先行検証ブランチ `verify/l7-prepublish`（ローカルの worktree `karakuri.wt/verify-l7-prepublish`
  と origin のブランチ）の廃棄は、検収が通ったあとに人間が行う。チケットの差分には含めない
- `poc/l7-proxy/` の処分は引き続き別途

## 保証

### 新たに宣言する保証

- なし。base のどの版を pin するかは karakuri 自身の開発環境の選択であって、利用者に差し出す
  振る舞いではない

### 維持する保証

- 0021 が未検証の約束として宣言した 3 行（proxy の環境変数を読まずに直接外へ出る接続は最終
  テーブルが落とす / `firewall.json` を書き換えてもイメージを再ビルドするまで proxy の判定は
  変わらない / 先頭ドットで許可したドメインの具体的なホストへ 2 回目も接続できる）——
  `docs/guarantees.md` の該当行。いずれも `verify-l7.sh` が検収で確かめる対象で、このチケットの
  検収がそれを正式版の base の上で初めて走らせる。先行検証は `:edge` の上でしか通っていない
- `version` が `1` の設定は L3 実現層として扱われる行（起源 `0020-l7-sidecar-and-branch`）——
  karakuri 自身は `version: 2` なので直接は使わないが、2.4.0 が焼く egress-guard 0.3.0 が
  この行の担い手であることを検収の前提として確認する

### 廃止する保証

- なし。pin の付け替えであり、約束を取り下げるものではない
