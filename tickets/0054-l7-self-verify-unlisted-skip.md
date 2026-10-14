---
status: open # draft → open → close
type: fix
base: main
targets:
  - packages/egress-guard/scripts/init-project-firewall.sh
  - packages/egress-guard/tests/firewall-rules.test.sh
  - docs/guarantees.md
verify:
  - pnpm lint:sh
  - pnpm lint
  - pnpm test
---

# L7 実現層の自己検証で、許可していない宛先の検査を飛ばし、誤った警告を出さない

## 内容

dev が `internal: true` のネットワークだけに載る構成（0050 / 0051）で、L7 実現層の firewall を適用すると、自己検証が毎回次の警告を出す。

```
[firewall] WARNING: verify SKIP: every egress probe host is in the allowlist, so none can prove that unlisted hosts are blocked
```

この警告の理由は事実と違う。

- `init-project-firewall.sh` の `pick_blocked_probe` は、名前解決できて、かつ allowlist に無い probe（`EGRESS_PROBES`）を1つ選ぶ。名前解決できない probe は候補から外れる
- internal の構成では割り当ての resolver が外部名に答えないので、どの probe も名前解決できず、何も選ばれない。呼び出し側は「選べなかった」だけを見て、allowlist に入っていたと決めつけた文言で警告する
- そもそも L7 実現層では、dev から直接 curl して届かないことを確かめても、許可していない宛先が遮断されていることの証明にならない。遮断しているのは proxy の ACL であり、直接の経路は最終テーブルと internal ネットワークが塞いでいる
- 「許可した宛先に届くか」の検査は、同じ理由で L7 実現層では info を出して飛ばしている。「許可していない宛先が遮断されるか」の検査だけ、L7 の扱いが漏れている

警告は適用のたびに出るノイズになり、本物の警告を読み落とす原因になる。

### 変えるもの

- L7 実現層では、自己検証の「許可していない宛先が遮断されるか」の検査を行わず、飛ばした旨を info で出す。理由は「許可した宛先に届くか」を飛ばすときと同じ（遮断は proxy の ACL が担い、この検査は proxy を通らない）。警告は出さない
- L3 実現層で、どの probe も選べなかったときの文言を、選べなかった理由に合わせる。allowlist に入っていたのか、名前解決できなかったのかを区別して述べ、名前解決できなかったときに「allowlist に入っている」と述べない。L3 で警告として扱うこと自体は変えない
- テストを足す。dev 側の DNS が外部名を解決できない L7 の構成で、上の警告が出ず、飛ばした旨が出ること。既存の「l7 anchor liveness without external DNS」の構成（proxy だけが名前解決できる）がそのまま使える
- 台帳 §5 の行を直す（下の「保証」）

### やらないこと

- L7 実現層で、proxy を通して許可していない宛先が拒否されることを自己検証で確かめること（proxy の ACL の検査は `verify-l7.sh` が持つ）
- probe の候補（`EGRESS_PROBES`）の変更
- `packages/egress-guard` の版と CHANGELOG の更新
- runtime-base / devcontainer-base のタグを打つこと、karakuri の pin を上げること（このスクリプトは runtime-base に焼き込まれ、devcontainer-base が引き継ぐ。タグは追って決める）
- 検査の深さ: L3 で probe が選べない2つの理由のうち、名前解決できないほうの文言はテストで固定しない（L3 では DNS が引けない時点で anchor の検査が先に失敗する）

## 保証

### 新たに宣言する保証

- 台帳 §5 に次の行を足す: 「L7 実現層では、自己検証は許可していない宛先が遮断されるかの検査を行わず、行わなかった旨を述べる。dev 側の DNS が外部名を解決できない構成でも、この検査を理由とする警告を適用ログに出さない」（テスト: "self verification skips the unlisted host check under l7 without a warning"）

### 維持する保証

- 台帳 §5「自己検証の『到達できないはず』の検査は、その宛先が allowlist に載っていたら別の宛先へ移る……」の行。L3 実現層の振る舞いとして維持する（既存テストの "probe selection" はそのまま通る）
- 台帳 §5「L7 実現層では、割り当て resolver が外部名を解決できるとき、DNS が外へ転送されている旨の警告を……」の行。DNS の転送の警告は今回の変更と別で、そのまま出す
- 台帳 §5「anchor になるドメインが1つも無い設定は失敗ではなく……」の行は、末尾の「飛ばすのは『許可したものに届くか』側の検査だけで、『許可していないものが遮断されるか』側は飛ばさない」を L3 実現層に限る書き方へ直す。L7 実現層では後者も飛ばすようになるので、そのままでは新しい行と食い違う。L3 の約束としての中身は変えない

### 廃止する保証

- なし
