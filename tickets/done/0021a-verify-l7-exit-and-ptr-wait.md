---
status: close
type: fix
base: main
targets:
  - packages/egress-guard/tests/verify-l7.sh
verify:
  - pnpm lint:sh
  - pnpm test
---

# verify-l7.sh が全通しても非ゼロで終わる欠陥と、PTR 偽装検査の偽 SKIP を直す

## 内容

0021 が常設化した `packages/egress-guard/tests/verify-l7.sh` の派生。0028 の検収（ホストで
`pnpm verify:l7` を 3 回）で露見した欠陥 2 件を直す。変更はこのファイル 1 本。判定項目の
内容・順序・スタックの分離（`-p karakuri-verify-l7` と volume 名の上書き）は変えない。

### 欠陥 1: 判定が全通しても exit 1 で終わる

3 回とも `PASS=20 FAIL=0 SKIP=0`（または `SKIP=1`）を印字した直後に
`verify-l7.sh: line 499: overlay: unbound variable` が出て exit 1、`pnpm verify:l7` は
`ELIFECYCLE Command failed with exit code 1` になる。

原因は関数内の `trap … RETURN`。bash の RETURN trap は関数を抜けても解除されず、以降の
すべての関数 return（最後は `main` の return）で再発火する。その時点で `local` は消えている
ので `set -u` に掛かる。同型の trap は 2 箇所ある——`check_ptr_spoof`（`$overlay`）と
`check_acl_needs_rebuild`（`$tmp_ctx`）。片方だけ直しても、もう片方の trap が最後に登録された
ものとして残り、`main` の return で再発火する。**両方を直す。**

**直した後の振る舞い**: `FAIL=0` なら exit 0、`FAIL>0` なら非ゼロ。一時ファイル（v6 overlay）は
関数を抜けるときに消える。RETURN trap を使い続けるか、明示的な後片付けにするかは実装者が
選ぶ——ただし `trap` を関数の外へ漏らさないこと。

### 欠陥 2: PTR 偽装検査が起動レースで偽 SKIP になる

同一のイメージ（egress-proxy-v6 の sha が 3 回とも一致）で、2 回目だけ
`SKIP PTR偽装 (egress-proxy-v6 のログに 203.0.113.53 宛のリクエストが無い。proxy まで
届いていないため -n の効果を判定できない)` が出た。1 回目と 3 回目は ok 2 件。

原因は `check_ptr_spoof` が `dcv6 up -d --build egress-proxy-v6 ptr-spoof-harness` の直後に
`probe_curl` を打つこと。ビルドが全キャッシュで即座に終わる周では、squid が listen する前に
probe が接続失敗し、リクエストが proxy に届かないまま「判定不能」へ落ちる。メインの
スタックには `wait_for_stack` があるが、v6 側には相当する待ちが無い。

**直した後の振る舞い**: egress-proxy-v6 が接続を受け付ける状態になってから probe を打つ。
待ちには上限を置き、上限内に立たなければ従来どおり SKIP（理由を「起動しなかった」と
区別できる文言で）とする。**「判定できなかった項目を成功として数えない」の規律は変えない**——
待ちを足すのは判定不能を減らすためであって、判定不能を ok に読み替えるためではない。

### 検収（ホスト）

devcontainer の中には docker が無いので、本体はホストで確かめる。

1. `pnpm verify:l7 ; echo "exit=$?"` を **2 回連続**で走らせる（2 回目はビルドが全キャッシュに
   なり、欠陥 2 が最も出やすい条件になる）
2. どちらも `PASS=20 FAIL=0 SKIP=0` かつ `exit=0`。`unbound variable` の行が出ないこと
3. 否定対照: `.devcontainer/firewall.json` の `allowDomains` から `.gallerycdn.vsassets.io` を
   一時的に外して走らせ、FAIL が出て `exit` が非ゼロになることを見る（終了コードが判定に
   従っている証拠）。確認後に戻す

### やらないこと

- 判定項目の追加・削除・順序変更。`APT_RECHECK_WAIT_SECONDS` / `KEEP_UP` の意味も変えない
- `poc/l7-proxy/` は触らない（処分は引き続き別途）
- `tests/ptr-spoof-harness.py` は触らない。待つ側は proxy であって harness ではない
- README・台帳は触らない。B-c の 3 行の検査手段が verify-l7.sh であることは変わらず、
  この修正は手段の信頼性を直すだけで約束を動かさない

## 保証

### 新たに宣言する保証

- なし。verify-l7.sh は台帳 B-c の約束を確かめる手段であり、手段の終了コードや待ちの有無は
  利用者に差し出す振る舞いではない

### 維持する保証

- 台帳 B-c の未検証の約束 3 行（proxy を迂回する接続は最終テーブルが落とす / `firewall.json`
  を書き換えてもイメージを再ビルドするまで proxy の判定は変わらない / 先頭ドットで許可した
  ドメインの具体的なホストへ 2 回目も接続できる）—— 着地先が `verify-l7.sh` なので、判定項目
  を 1 つも落とさないこと・偽陽性を作らないことがこのチケットの境界。検収 1〜2 で全項目が
  ok のまま通ることを確かめる

### 廃止する保証

- なし。検査手段の修正であり、約束を取り下げるものではない
