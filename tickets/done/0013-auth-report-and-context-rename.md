---
status: close
type: fix
base: main
targets:
  - images/runtime-base/bin/git-auth-check
  - images/runtime-base/bin/karakuri-context
  - images/runtime-base/bin/prod-entrypoint.sh
  - images/runtime-base/bin/secrets-ingest.sh
  - images/runtime-base/tests/karakuri-context.test.sh
  - images/runtime-base/tests/git-credential.test.sh
  - images/runtime-base/tests/run.sh
  - images/runtime-base/tests/verify-docker.sh
  - images/runtime-base/Dockerfile
  - images/devcontainer-base/Dockerfile
  - images/runtime-base/README.md
  - images/runtime-base/verification-record.md
  - docs/prod-secret-isolation-design.md
  - docs/guarantees.md
verify:
  - pnpm lint:sh
  - pnpm test
---

# 認証経路を常に報告する形にし、`prod-context` を `karakuri-context` へ改名する

## 内容

対話シェルの起動時に走る2つのスクリプトの思想を揃える。

`prod-context` は「注入済みのものを列挙するだけに留め、無いものが映らないことで気づかせる」型で、鍵名も `/run/prod-ref` も常に1行出す。一方そこから呼ばれる `git-auth-check` は「何も言わないのが正常、異常時だけ喋る」型で、実効 credential helper が想定どおりなら無言で終わる。同じ出力ブロックの中に逆向きの思想が同居している。

**変えるのは後者。** `git-auth-check` を、実効 helper のパスを常に1行報告する形にする。判定と固定の仕組み自体は触らない。

### なぜ報告が要るか

利用側で「注入は効いているのに認証が別の helper で通っている」状態が起きたとき、現状の出力からは切り分けられない。`prod-context` は `注入済み: GH_TOKEN` と出し、`git-auth-check` は「別のヘルパが勝っている」と警告するが、報告が正確でも原因の同定に至らない。実地でこの切り分けに4段の遠回りが発生した。

実効 helper のパスが鍵名の隣に常に並べば、次の4通りが一目で分かる。

- 自前 helper + 鍵あり → 想定どおり
- 自前 helper + 鍵なし → 注入し忘れ
- 別 helper + 鍵あり → 注入したものが使われていない（上記の状態）
- 別 helper + 鍵なし → ホスト側の認証を意図的に使っている可能性

報告に「イメージが環境変数で固定した状態が生きているか」の別を添えると、`GIT_CONFIG_COUNT` が利用側の設定で上書きされて2スロットが消えた場合と、5変数が丸ごと届いていない場合を、警告の分岐を増やさずに区別できる。

### なぜ黙らせる仕組みを足さないか

ホスト側の credential manager を使いたい、GHE が主で github.com の固定が邪魔、といった理由で意識的に外す利用者はいる。現状はその人が毎回警告を浴びるため、抑制手段を用意する案もあった。今回は採らない。状態の報告に変えれば、警告ではなく事実の表示になり、浴び続ける問題そのものが消える。抑制手段は「一度書いて忘れると防御が外れたまま黙る」という、この検査の目的（黙って外れるのを潰す）と正面から衝突する副作用を持つ。

### 改名

`prod-context` という名前とラベルが dev container でも表示される。ホスト側に `karakuri-loopback` / `karakuri-dock` の慣習があるので `karakuri-context` に揃える。実体は「このコンテナが何を持ち、どこへ認証するか」を出すものなので、意味の上でも prod に限らない。

利用者へ直接実行を案内している記述は文書のどこにも無く、`/etc/bash.bashrc` と `/etc/zsh/zshrc` から source される内部スクリプトに閉じている。ただし台帳の公開面の定義 C-1 に名前で列挙されているため、そこの記述も併せて更新する。

### 実イメージ側の検査

`images/runtime-base/tests/verify-docker.sh` の M6 が、廃止する「一致していれば何も出力しない」契約を実イメージで検査している。この枚で新しい契約へ書き換える。`git-credential.test.sh` の H 節が `git-auth-check` のコピーを叩くのに対し、M6 は実イメージへ焼かれた実体を PATH から叩くので、役割が違う。検査自体は残す。

### 順序依存

このチケットは 0009 より先に着地する必要がある。0009 は `§10` に「実効ヘルパが自前のものと一致していれば何も出力せず 0 で終わる」を載せる予定で、この変更はその文面を無効にする。0008 も `§9` の出典を `prod-context.test.sh` と書いているため、改名後のファイル名へ直す必要がある。どちらも別ブランチの open チケットなので、それぞれの裁可時に反映する。

### やらないこと

- 認証経路の固定そのものの変更。打ち消しと積み直しの仕組み、helper の判定条件、`--strict` 相当の挙動には触れない
- 警告を抑制する仕組みの追加（上記のとおり採らない）
- 5変数が丸ごと欠けた状態を専用の分岐として警告文で扱うこと。報告の属性として出るので分岐は増やさない
- `verification-record.md` と `docs/prod-secret-isolation-design.md` が現在形4種のどれに属するかの棚卸し。今回は改名の追随だけを行う（棚卸しは `kuda:migrate` の領分）
- 利用者が古い像を掴んでいる場合への対処。配布物とリポジトリ側は健全であり、`build.pull: true` の必須化として既に文書がある

## 保証

### 新たに宣言する保証

- 認証確認コマンドは、github.com の実効 credential helper のパスを、想定どおりのときも1行報告する（テスト: "実効 helper が自前 helper と一致: パスを1行報告して rc=0"）
- その報告には、イメージが環境変数で固定した状態が生きているかどうかの別が付く。生きていない場合、実効 helper が何であっても報告からそれが読める（テスト: "イメージ固定が外れていれば報告にその別が付く"）
- 報告にも警告にも、資格情報の値は現れない（テスト: "報告に注入した値が出ない"）

### 維持する保証

- 認証経路の固定そのもの。別の helper が勝たないこと、store が自前の helper にだけ届くこと、敵対的な問い合わせプログラムが呼ばれないこと。今回触るのは報告の形だけで、判定と固定の仕組みは変えない（台帳 `§10` に載る予定の行。0009 が未着地のため現時点では `images/runtime-base/tests/git-credential.test.sh` が正本）
- 非対話シェルからは一切出力しないこと。認証確認コマンドが非ゼロで終わってもシェルの起動と本来の出力を壊さないこと。改名後も同じ（台帳 `§9` に載る予定の行。同上）

### 廃止する保証

- 「実効ヘルパが自前のものと一致していれば何も出力せず 0 で終わる」。台帳にはまだ無く、0009 のチケットの保証節に書かれている行なので、取り下げは 0009 の裁可時に反映する
- `/usr/local/bin/prod-context` という名前での提供。利用者が直接呼ぶ経路は文書に無いが、台帳の公開面の定義 C-1 に名前で載っているため、名前の変更は約束の範囲の記述変更にあたる
