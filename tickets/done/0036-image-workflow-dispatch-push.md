---
status: close
type: fix
base: main
targets:
  - .github/workflows/runtime-base.yml
  - .github/workflows/devcontainer-base.yml
  - .github/workflows/egress-proxy.yml
verify:
  - pnpm lint:sh
  - pnpm test
---

# イメージの workflow で、dispatch をタグ ref で起動しても `push: false` を守る

## 内容

Issue #69。3 本のイメージ workflow（`runtime-base.yml` / `devcontainer-base.yml` / `egress-proxy.yml`）は同じ型で、次の 2 か所が `github.ref` がリリースタグかどうかだけを見ている。

- 「Resolve version from tag」ステップの `if: startsWith(github.ref, 'refs/tags/<image>-v')`
- 「Decide whether to push」ステップの第 1 分岐 `if [ "${{ startsWith(github.ref, 'refs/tags/<image>-v') }}" = "true" ]`

`workflow_dispatch` を既存のリリースタグの ref で起動すると、どちらも真になる。結果、`inputs.push` が `false` でも `push=true` になり、metadata-action の semver 3 行（`:X.Y.Z` / `:X.Y` / `:X`）が有効なまま既存のリリースを上書き push する。

直し方は 3 本とも同じ。2 か所の条件に `github.event_name == 'push'` を足す（タグの push イベントだけをリリースと見なす）。
dispatch はタグ ref で起動しても `ver` が走らず（`version` が空で semver 行は disabled）、push の可否は `inputs.push` だけで決まり、付くタグは `:edge` だけになる。
各ステップの直前にあるコメント（「push するのはリリースタグのとき、または dispatch で明示指定したとき」）は、変更後の条件と食い違わないなら残す。

### やらないこと

- `monitor.yml` や他の workflow。同じ型を持たない
- `:edge` の扱いや dispatch の入力の追加
- タグ打ちのやり直し。既に出ている `:1.0.0` 等はそのまま

### 検収

PR の `pull_request` トリガーで 3 本の検証ビルド（push なし）が緑。
マージ後、いずれかの workflow を `workflow_dispatch` で **既存のリリースタグの ref**・`push: false` で起動し、「Resolve version from tag」が skipped、「Decide whether to push」の出力が `push=false`、build-push の `push: false` で終わること（Actions のログで見る。GHCR に新しいバージョンが増えない）。

## 保証

### 新たに宣言する保証

- なし。workflow の分岐は利用側が依存する振る舞いではなく、リリース手順の担保である

### 維持する保証

- C-2a の見出し「CI の runtime-base ワークフローが、push 済みイメージを両アーキで smoke test する」（`docs/guarantees.md` 462 行付近、起源 `0009-ledger-auth-and-shipped`）——タグ push の経路は変えないので、リリース時の smoke test はそのまま走る
- C-3a の見出し「CI の egress-proxy ワークフローが push 済みイメージで smoke test する」（起源 `0035-egress-proxy-image`）——同上

### 廃止する保証

- なし
