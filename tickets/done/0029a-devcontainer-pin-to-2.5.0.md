---
status: close
type: chore
base: main
targets:
  - .devcontainer/Dockerfile
  - .devcontainer/devcontainer.json
verify:
  - pnpm lint:sh
  - pnpm test
---

# karakuri の devcontainer の pin を 2.5.0 へ上げ、個人フックを personal-setup で呼ぶ

## 内容

0029（PR #62）の派生。0029 は `personal-setup` を devcontainer-base に焼いたが、karakuri 自身の
devcontainer は 2.4.0 に pin されておりその中に無い。`devcontainer-base-v2.5.0`（main `dcad5fe`、
0029 を含む）のタグとビルドが済んだので、pin を上げて `postCreateCommand` を置き換える。
変更は 2 ファイル。

### `.devcontainer/Dockerfile`

`FROM` を次に置き換える。

```
FROM ghcr.io/himorogy/devcontainer-base:2.5.0@sha256:97a3f200e0ef5721b3c3b845037516a55072035f7d5580505e570c7b465490e2
```

digest はホストで `docker buildx imagetools inspect ghcr.io/himorogy/devcontainer-base:2.5.0` の
`Digest:` から取った index digest である。プラットフォーム単体の manifest の digest ではないので、
arm64 / amd64 のどちらでも pull できる。

`FROM` の上のコメント塊のうち「**2.4.0 を選ぶ理由。**」と「**N-1 規律との関係。**」の 2 段落を
2.5.0 用に書き換える。次の 2 点が読めるようにする。

- **2.5.0 を選ぶ理由**: 個人設定フックを proxy 変数を外して実行する `personal-setup` を焼いた
  最初の版である。2.4.0 では `postCreateCommand` のフックが sidecar の ACL に落ちて個人ツールの
  取得が 403 で失敗する（0029 の背景）
- **N-1 規律との関係**: 規律の趣旨は「最新リリースが壊れたときに、直す環境が最新リリース自身に
  依存しない」であり、karakuri の開発環境が動かなくなるのを防ぐためのものである。2.5.0 は
  同じ内容を `:edge` で焼いてこの devcontainer 自身で検証済み（rebuild が通り、個人ツールの
  取得が成功し、enforce のまま proxy 経由の遮断が効いている）で、動くことが確認された版へ
  上げる判断は規律の趣旨に反しない。次に規律が効くのは 2.6.0 以降で、そのとき karakuri は
  2.5.0 に留まる

冒頭の段落（digest pin の根拠、N-1 の規律の本文）は変えない。

### `.devcontainer/devcontainer.json`

`postCreateCommand` を `"personal-setup"` に置き換える。直前のコメント（「個人設定フック … も
ここで実行する」の段落）に、L7 では proxy 変数が作成時から入っているため `personal-setup` が
それを外して直接経路で走らせる旨を 1 文足す。「根拠は examples/devcontainer.json のコメント」は
そのまま残す（雛形側は 0029 で同じ形になっている）。

### 検収

devcontainer の中には `docker` も Docker のソケットも無いので、ホストで確かめる。

1. ホストでこのブランチを取り出し、devcontainer を作り直す（Rebuild Container、キャッシュ無効）
2. `postCreateCommand` のログで `==> 個人用ツール` 以下に `curl: (22) ... 403` が出ず、
   `/home/node/.local/bin` に個人ツールが入ること
3. 作り直した後の `.devcontainer/firewall.json` が `mode: enforce` のままで、proxy を経由しない
   直接接続が落ちること（`pnpm verify:l7` を 1 回通す）

### やらないこと

- `.devcontainer/proxy/`（`templates/proxy/` の写し）は触らない。acl ステージの
  `@himorogy/egress-guard@0.3.0` は 2.5.0 が焼く版と同じ
- `.devcontainer/firewall.json` は触らない
- `images/devcontainer-base/README.md` の N-1 規律の記述は触らない。規律は変わらず、今回の判断は
  Dockerfile のコメントに書く
- `docs/guarantees.md` は触らない。E-a（`personal-setup` がイメージに実行可能な状態で置かれる）の
  裏取りはこのチケットの検収が担うが、行の文は変わらない

## 保証

### 新たに宣言する保証

- なし。base のどの版を pin するかは karakuri 自身の開発環境の選択であって、利用者に差し出す
  振る舞いではない

### 維持する保証

- 台帳 B-c の 3 行（proxy を迂回する経路は残らない / 再ビルドまで ACL は変わらない / 先頭ドットの
  具体名に接続でき 2 回目も成立する）。base の版を上げても egress-guard の版は 0.3.0 のままで
  変わらないが、検収の `pnpm verify:l7` で 2.5.0 の上でも通ることを確かめる
- 台帳 E-a（`personal-setup` は `/usr/local/bin` に実行可能な状態で置かれ、`postCreateCommand`
  から名前だけで起動できる）。karakuri がこの行の最初の利用者になる

### 廃止する保証

- なし。pin の付け替えであり、約束を取り下げるものではない
