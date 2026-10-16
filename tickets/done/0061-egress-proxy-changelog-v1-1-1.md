---
status: close
type: docs
base: main
targets:
  - images/egress-proxy/CHANGELOG.md
verify: []
---

# egress-proxy の CHANGELOG を v1.1.1 のリリースに向けて整える

## 内容

`egress-proxy-v1.1.0` の後に、同梱の `init-project-firewall.sh` を変える修正が2つ main に入っている。
L7 の anchor 検査が起動中の proxy を待たずに panic へ落ちる問題の修正（0059）と、L7 実現層の自己検証が誤った警告を出す問題の修正（0054）である。
runtime-base を使わない利用者は egress-proxy イメージからスクリプトを取り込むので、この2つは `egress-proxy-v1.1.1` を打つまで届かない。
リリース手順（`images/egress-proxy/README.md`「手順」）は、タグを打つ前に前回のタグからの変更を CHANGELOG に書くことを求めている。

ところが `images/egress-proxy/CHANGELOG.md` の「未リリース」には 0054 の修正が無い。
0054 は旧 CHANGELOG（`packages/egress-guard/CHANGELOG.md`）に項目を残さずにマージされ、0060 の付け直しは旧 CHANGELOG にある項目だけを移したためである。

この枚では CHANGELOG を v1.1.1 のリリースに向けて整える。タグはこの枚のマージ後に人間が打つ。

- 「未リリース」に 0054 の修正の項目を足す。書くのは利用者から見た変化で、L7 実現層では自己検証が「許可していない宛先が遮断されるか」の検査を行わず、行わなかった旨を info で出すようになり、dev 側の DNS が外部名を解決できない構成でも誤った警告が出なくなったこと。L3 実現層で probe を選べなかったときの警告文が、原因（解決できた probe がすべて allowlist に入っていた / どの probe も解決できなかった）で分かれたことも書く
- 見出し「未リリース」を `egress-proxy-v1.1.1` に変える。版は patch とする（入る変更が修正と告知だけで、利用側の設定や構成の変更を要しない）
- 既存の2項目（npm 公開終了の告知、anchor 検査の待ち）の文言は変えない

`egress-proxy-v1.1.0` から main までに egress-proxy に焼かれる中身を変えたコミットは、0059・0054・0060 の3つである。0060 はパスとコメントだけの変更で、焼かれる中身は変わらないので項目にしない。

### やらないこと

- タグを打つこと・push すること。マージ後に人間が行う
- CHANGELOG 以外の文書の変更。README のリリース手順は 0060 で整っている
- 過去のタグの見出しの下にある項目の書き換え
- 項目の漏れを機械で検出する仕組み（changeset に相当するもの）を作ること

## 保証

### 新たに宣言する保証

- なし（変更の記録で、振る舞いの約束ではない）

### 維持する保証

- なし（文書だけの変更で、スクリプト・イメージには触れない）

### 廃止する保証

- なし
