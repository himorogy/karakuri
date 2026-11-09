---
status: open
type: chore
base: main
targets:
  - .devcontainer/Dockerfile
bundle:
  - 0064-devcontainer-base-virtiofs-git
  - 0065-karakuri-pin-3-1-0
verify:
  - pnpm lint:sh
  - pnpm lint
  - pnpm test
---

# karakuri 自身の dev の pin を devcontainer-base 3.1.0 へ上げ、virtiofs 上の git の設定を一時的に持つ

## 内容

karakuri 自身の dev は devcontainer-base 2.7.0 に pin されたままで、その後の trixie 化（3.0.x）と pnpm の self-switch 停止（3.1.0）を取り込んでいない。
3.1.0 は base を利用する別のリポジトリで動作を確認済み（利用者の申告、2026-11-09）。

karakuri の dev も `/workspaces` の virtiofs に載っているので、0064 が直す git の不具合（所有者の揺れによる dubious ownership、index の stat の食い違い）を同じように踏む。
0064 は `devcontainer-base-v3.2.0` で配るが、karakuri は自分の最新版を参照しない規律なので、3.2.0 が出てすぐには上げられない。
それまでの間、同じ設定を karakuri の Dockerfile にも置く。

### 前提

- `devcontainer-base-v3.1.0` のタグ（打ち済み）。digest は `sha256:17218234c064c69d829553993b56e42679b86662f1776a26f67706567d68ca6b`（2026-11-09 に利用者がホストで `docker buildx imagetools inspect` を打って取得。この dev からは ghcr.io に届かない）
- 3.1.0 が焼いた pnpm は 12.11.2 で、karakuri の `package.json` の `packageManager`（`pnpm@12.11.2`）と一致する。3.1.0 の「packageManager の版が違えば止める」挙動には当たらない（タグの Dockerfile で確認）

0064 の着地は待たない。この 1 枚だけで完結する。

### 変えるもの

- `.devcontainer/Dockerfile` の `FROM` を `ghcr.io/himorogy/devcontainer-base:3.1.0@sha256:17218234c064c69d829553993b56e42679b86662f1776a26f67706567d68ca6b` にする
  - 作業ツリーには、3.0.1 への書きかけの差分（`FROM` の変更と、2.7.0 を選んだ理由の節の削除）が残っている。この差分を起点にし、`FROM` を 3.1.0 に置き換える
- pin のコメントに、3.1.0 を選ぶ理由を書く。3.1.0 は起票時点で最新版なので、N-1 規律との関係も書く
  - 規律の趣旨は「最新リリースが壊れたときに、直す環境が最新リリース自身に依存しない」。3.1.0 は別のリポジトリで実運用に耐えている
  - 0064 で 3.2.0 を出すと、3.1.0 は 1 つ前の版になる
- `USER root` の区間で `git config --system` を使い、0064 と同じ 2 つを設定する（`safe.directory = /workspaces/*`、`core.checkStat = minimal`）。コメントには、0064 と同じ設定であること、pin が 3.2.0 以降に上がったら外すことを書く

### 検収

ホストで rebuild したあと、次を確かめる。

1. `pnpm --version` が 12.11.2 を返し、別の版の取得も停止も起きないこと
2. `git config --show-origin --get-all safe.directory` と `git config --show-origin --get core.checkStat` が `file:/etc/gitconfig` を示すこと
3. `pnpm verify:l7` が通ること
4. Claude Code・Codex・VS Code の拡張機能と、ssh で入る経路（sshd、ポートフォワード）が普段どおり動くこと
5. `git commit` の直後に `git log` と `git status` を同じコマンドの中で続けても、dubious ownership で止まらないこと

### やらないこと

- egress-proxy の pin の変更
- base への改修（0064）
- pin が 3.2.0 以降に上がったときに、この一時的な設定を外すこと（そのときの pin チケットで行う）

## 保証

### 新たに宣言する保証

- なし（karakuri 自身の開発環境の構成で、公開面に触れない）

### 維持する保証

- 台帳 E-a（pin を上げたあとの rebuild）。検収の rebuild で確かめる
- B-c の各行は、`pnpm verify:l7` が通ることで維持する

### 廃止する保証

- なし
