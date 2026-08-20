---
status: close
type: fix
base: main
targets:
  - images/runtime-base/templates/host/karakuri.sh
  - images/runtime-base/templates/tests/karakuri.test.sh
verify:
  - bash images/runtime-base/templates/tests/karakuri.test.sh
  - pnpm lint:sh:images
---

# `_karakuri_check_loopback` が loopback alias の不足を検出できない問題を修正する

## 内容

`_karakuri_check_loopback` は、macOS で `lo0` に alias が無いまま port forwarding を
張ろうとしたときに `karakuri-loopback add <addr>` の実行を促して中断する検査である。
この検査が現在、すべてのケースで素通しになっている。

原因は `ssh -G` の出力形式の読み違い。`ssh -G <host>` の `localforward` 行は
bind アドレスを角括弧で囲んで出す。

```
localforward [127.0.1.1]:4588 [localhost]:4588
```

現行の awk は `$2` を `:` で分割した先頭が `127.` で始まるかを見るため、実際には
`[127.0.1.1]` と比較しており一致しない。結果として検出されたアドレスの一覧が常に
空になり、直後の「空なら成功として返る」で fail open する。関数のコメントは1行が
`localforward 127.0.1.1:4519 localhost:4519` の形になると書いており、この前提が
実際と異なっていた。fail open の理由として書かれている「読み取りが外れたときに
転送そのものが止まるのを避ける」が、常時発動していた状態である。

修正は、分割する前に角括弧を取り除く。IPv6 (`[::1]:4519`) は角括弧を外すと
`:` で切った先頭要素が空になるため、`127.` で始まる判定から自然に外れる。
unix socket のパスと、bind 側を省略したときの `[*]` も同様。コメントに書かれている
出力形式の前提も実際の形に直す。

テストには、127.x が角括弧に入っている入力で alias 不足を検出できることの確認を
追加する。既存のテストは `[::1]:4520` のケースを持つが、これは「127. 以外なので
無視される」ことの確認であり、このバグの否定対照になっていない。alias が
載っている場合に素通しすること、前方一致で誤検出しないこと（`127.0.1.10` だけが
載っている状態で `127.0.1.1` を要求されたら検出する）も併せて確認する。

やらないこと。fail open そのものの是非は変えない。`ifconfig` の実行に失敗したときに
転送を止めない挙動は意図されたもので、維持する。`karakuri-dock` の改修とは独立して
おり、このチケットだけで完結する。

## 保証

### 新たに宣言する保証

- なし。既存の検査が意図どおり動くようにする修正であり、外から観測できる新しい
  約束を追加しない（保証台帳は未敷設のため、対応する台帳の行も発生しない）

### 維持する保証

- `ssh -G` の結果に `localforward` 行が無いホストでは、この検査は何もせず成功する
  （転送を書いていないホストへの `karakuri-pf` を妨げない）
- `ifconfig` の実行に失敗した場合は fail open して転送を止めない
- Darwin 以外の OS では検査自体を行わない（Linux と Windows は 127.0.0.0/8 全体が
  最初から bind でき、alias の概念が無い）
- `karakuri.sh` は `set -euo pipefail` を使わず、bash と zsh の両方で動く

### 廃止する保証

- なし。検査の意味論は変えず、出力の読み取りの誤りだけを直す
