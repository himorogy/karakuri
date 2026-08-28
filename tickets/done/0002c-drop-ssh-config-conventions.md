---
status: close
type: fix
base: main
targets:
  - images/runtime-base/templates/host/karakuri.sh
  - images/runtime-base/templates/tests/karakuri.test.sh
  - images/devcontainer-base/PORT-FORWARDING.md
  - example/README.md
  - docs/host-tools-distribution.md
verify:
  - pnpm lint:sh:images
  - bash images/runtime-base/templates/tests/karakuri.test.sh
  - bash images/runtime-base/templates/tests/dock.test.sh
  - bash images/runtime-base/tests/shipped-symbols.test.sh
---

# ssh config の規約に対する依存を karakuri.sh から取り除く

## 内容

0002 の派生である。0002a で broker アイテムキーを、0002b で ssh Host 別名と compose
project 名を引数へ分離した。その続きで、**`karakuri.sh` が利用者の `~/.ssh/config` の
書き方について持っている前提を残らず捨てる。**

依存している規約は 2 つある。どちらも「そう書いてある前提」でコードが動き、違反しても
黙って空振りする。

1. **ホスト名が `devc-` で始まる** — `_karakuri_ssh_host` が接頭辞を補う
2. **`ControlPath` が `~/.ssh/cm-%n` である** — 残骸 socket の削除と一括掃除がこの形に
   依存する

完了すると、`karakuri.sh` が ssh について持つ接点は「利用者が書いた Host 名をそのまま
`ssh` に渡す」だけになる。

**破壊的変更を 2 件含む。** まだ正式リリース前であり、公開面を固める前に前提を落とす
ための判断である。

### 解きたい問題

**1. `devc-` 接頭辞の合成（`_karakuri_ssh_host`）。**

利用者が渡した値に `devc-` を足す（既に付いていれば素通し）。`karakuri-port-forward` /
`karakuri-clean-port-forward` / `karakuri-dock` の 3 関数が通る。0002b で
`karakuri-dock -H` を足して Host 別名を `-p` から独立させたが、**その `-H` の値自体が
合成の対象**なので、`devc-` で始まらない Host 別名は指定できない。逃げ道（`devc-` 付きを
渡すと素通し）はあるが、エラーにも警告にもならないため、逃げ道の存在に気づく契機が無い。

**2. 残骸 socket の削除（`rm -f`）とその根拠。**

`karakuri-port-forward` は `ssh -O exit` の後に `rm -f ~/.ssh/cm-<host>` を実行する。
コード上の根拠は「残骸があると次の接続がそこへ繋ぎに行って失敗する」だった。

**実機で反証した**（macOS / OpenSSH 9.9p2）。`ssh -fN` で master を立て、`kill -9` で
socket を残した状態から同じ `ssh -fN` を実行すると、成功して新しい master が立つ。
OpenSSH が stale socket を検出して unlink し、bind し直している。残骸は張り直しの障害に
ならない。

**3. `karakuri-clean-port-forward` の存在理由。**

固有の価値は次の 3 つのはずだった。棚卸しすると残らない。

- **残骸 socket の削除** — 上のとおり OpenSSH がやる
- **master を落とす** — `ssh -O exit <host>` そのもの。正常終了なので socket も自分で
  消える
- **複数ホストを一括で落とす** — 対象の列挙が `~/.ssh/cm-devc-*` の glob に依存しており、
  1 を捨てて任意の Host 名を許すと列挙の定義自体が失われる

設計上の根拠は `docs/host-tools-distribution.md` の「利用側の実装が `ControlPath` の
規約に依存しているのだから、規約を持っている側が操作も提供すべき」だった。**その規約を
知る必要が無かった**ことが分かったため、根拠が成立しない。

**4. `HostName` と compose project 名の結合（文書）。**

`PORT-FORWARDING.md` が案内する `~/.ssh/config` は、`Host devc-*` のワイルドカードに
`ProxyCommand ... dock.sh -p %h --stdio` を 1 本置く形をとる。`%h` は `HostName` に展開
されて `dock.sh -p` の値になるため、`HostName` が compose project 名を兼ねる。別名を
自由にしても `HostName` は自由にならない。

**逃げ道はある。** プロジェクトごとに `-p` をリテラルで書けば `%h` の結合が消える
（代償はワイルドカード 1 本で済まなくなること）。いまの文書はこの選択肢を示していない。

実機の 3 プロジェクトすべてで `HostName` が compose project 名と食い違っており、
雛形どおりに書かない限り必ず踏む形になっている。

**5. broker アイテムキーの `_common` が予約語なのに無検査。**

`karakuri-broker-env` は dev のとき `env/<key>/shared/dev,env/_common/dev,env/<key>/dev`
を組む。`_common` は全プロジェクト共通の個人項目に予約されているが、broker キーとして
`_common` を渡しても弾かれない。渡すと同じ項目を 2 度引く形になる。`example/README.md`
に注意書きがあるだけで、コードの検査は無い。

### やること

**1. `_karakuri_ssh_host` を削除する。**

3 つの呼び出し箇所（`karakuri-port-forward` / `karakuri-clean-port-forward` の引数あり
モード / `karakuri-dock`）を、受け取った値をそのまま使う形にする。`karakuri-clean-port-forward`
は下の 3 で削除するので、実質の書き換えは 2 箇所。

利用者は完全な ssh Host 名を打つことになる。

```
karakuri-port-forward devc-app-dev        # 従来は app-dev でもよかった
karakuri-dock -p app-dev -H devc-app-dev  # -H も完全な名前
```

`karakuri-port-forward` の usage 文字列（`(ssh host devc-<name>, or the full host alias)`）
も、完全な Host 名を取ることが読める形に直す。

存在しない Host 名を渡した場合は既存の失敗メッセージがそのまま出る（`~/.ssh/config` に
Host エントリがあるか確かめるよう促す）。渡した名前がそのまま出るので、原因に辿れる。

**2. `karakuri-port-forward` から `rm -f ~/.ssh/cm-<host>` を削除する。**

`ssh -n -O exit "$host"` は残す。これは「張り直す」の意味論そのもので、作り直したコンテナに
古い master を使い続けないために要る。削除するのは残骸掃除の 1 行と、その根拠を述べた
コメントだけ。

コメントは消すのではなく、**実測で分かったことに書き換える**——OpenSSH は stale socket を
自分で unlink するので、こちらで消す必要はない。判定の根拠（版と環境）も 1 行添える。
これはコードから読めない事実であり、次に誰かが「掃除が要るのでは」と考えたときに戻って
くる場所になる。

**3. `karakuri-clean-port-forward` を削除する。**

関数の実体と、ファイル冒頭のコメント一覧・`karakuri-help`・末尾の推奨 alias の 4 箇所。

代替は `ssh -O exit <host>`。一括で落としたい利用者は自分の Host 名を並べる。karakuri は
Host 名の規約を持たなくなるので、列挙を提供できない。

**4. `_common` を broker キーとして拒否する。**

`karakuri-dev-inject` が broker キーを検査している箇所（`_karakuri_plain_name "broker key"`
の隣）で、`_common` を名指しで拒否する。予約語であることと、`env/_common/dev` が全プロジェクト
共通の個人項目であることを、エラーメッセージから読めるようにする。

compose project 名としての `_common` は無害なので `_karakuri_plain_name` 自体には足さない
（`-p` / `repo` の呼び出しにも掛かってしまう）。prod 側は `_common` を挟まないので対象外。

**5. 関数の記載を揃える。**

`karakuri.sh` の規律どおり、次を揃える。

- ファイル冒頭のコメント一覧（`karakuri-clean-port-forward` の行を削除）
- 関数の直前のコメントと `usage` 文字列
- `karakuri-help` の出力
- ファイル末尾の推奨 alias の例（`clean-pf` の alias を削除、`dock` 関数の例の `-H` を
  完全な Host 名にする）

**6. テストを追加・更新する。**

`karakuri.test.sh` の `devc-` 補完に依存しているケースを、verbatim 前提に書き換える。
`karakuri-clean-port-forward` のケースは削除する。あわせて足すこと。

- `karakuri-port-forward` に渡した名前が `devc-` を補われずそのまま `ssh` へ行くこと
- `devc-` で始まらない名前を渡したとき、その名前のまま `ssh` へ行くこと（接頭辞が
  付かないことの否定対照）
- `karakuri-dock -H` に渡した名前が同様に verbatim であること
- `karakuri-port-forward` が `~/.ssh/cm-<host>` を消さないこと
- `karakuri-port-forward` が `ssh -O exit` は従来どおり呼ぶこと
- `karakuri-clean-port-forward` がもう存在しないこと（旧名が残っていないこと）
- `karakuri-dev-inject -b _common` が失敗し、`_common` を名指しすること
- `karakuri-dev-inject -p _common`（`-b` 省略で broker キーが `_common` になる経路）も
  同様に失敗すること
- bash と zsh の両方で出力が一致すること（既存の走らせ方に乗せる）

`dock.test.sh` と `dev-inject.test.sh` は変更しない。

**7. 文書を追随させる。**

- `images/devcontainer-base/PORT-FORWARDING.md` — `devc-` を補うという記述をすべて落とす
  （`-H` の説明、Windows 1 ホップ経路の応用例を含む）。`karakuri-port-forward` の呼び方を
  完全な Host 名に直す。`karakuri-clean-port-forward` への言及を落とし、転送を畳む手段が
  `ssh -O exit` であることを示す。**`ProxyCommand` の `-p` をリテラルで書く選択肢を追加する**
  ——`Host devc-*` のワイルドカード + `%h` は推奨として残し、`HostName` を compose project
  名と別にしたい場合はプロジェクトごとに `-p` を書けばよいことと、その代償（ワイルドカード
  1 本では済まなくなる）を書く
- `example/README.md` — `karakuri-port-forward` の呼び方と `dock` 関数の例を直す。
  `karakuri-clean-port-forward` への言及があれば落とす
- `docs/host-tools-distribution.md` — 配布する関数の一覧から `karakuri-clean-port-forward`
  を落とす。**`ControlPath` の規約を根拠に「規約を持っている側が操作も提供すべき」と述べて
  いる決定の記述は消さず、その根拠が成立しなかったことを日付付きで追記する**（判断の記録は
  履歴であり、覆ったことも記録に値する）。`karakuri-port-forward` が `ControlPath` の規約に
  依存しているという記述も、依存が無くなった旨に直す

### やらないこと

- `karakuri-port-forward` の `ssh -n -O exit` は削除しない。「張り直す」の意味論であり、
  残骸掃除とは別の目的である
- `_karakuri_check_loopback` は変更しない。受け取った host を `ssh -G` に渡すだけで、
  名前の形に依存していない
- `port-forward-<host>.log` のログ名は変更しない。host をそのまま使う内部の簿記であり、
  利用者が別名にしたい理由が無い
- `karakuri-clean-port-forward` の代替関数は作らない。一括 teardown を提供し直すと、
  対象の列挙のために結局なんらかの規約か記録が要る。`ssh -O exit` で足りる
- 旧形式（`karakuri-port-forward <name>` に `devc-` 無しの名前を渡す形）の互換シムは
  置かない。移行の保険は失敗を隠して原因から遠いエラーに変える（0002 で `dock.sh` の
  フォールバックを削除したときと同じ判断）。存在しない Host 名として ssh が失敗し、
  渡した名前がメッセージに出るのが正しい壊れ方である
- `_karakuri_plain_name` に `_common` の検査を足さない。compose project 名やリポジトリ名
  としての `_common` は無害である
- prod 側の broker アイテム名（`env/<key>/shared/prod,env/<key>/prod`）は変更しない。
  `_common` を挟まないため対象外
- `~/.ssh/config` の生成・配布はしない（既存の方針を維持する）

## 保証

### 新たに宣言する保証

- `karakuri-port-forward <host>` は受け取った名前をそのまま ssh のホスト名として使い、
  `devc-` を補わない
  （テスト: `karakuri.test.sh` の `karakuri-port-forward uses the given name verbatim`）
- `karakuri-dock -H <host>` は受け取った名前をそのまま ssh のホスト名として使い、
  `devc-` を補わない
  （テスト: `karakuri.test.sh` の `karakuri-dock -H uses the given name verbatim`）
- `karakuri-port-forward` は ControlPath の socket ファイルを削除しない
  （テスト: `karakuri.test.sh` の `karakuri-port-forward leaves the control socket alone`）
- `karakuri-dev-inject` は broker アイテムキーが `_common` のとき、`_common` を名指しして
  失敗する（`-b` を省略して `-p` の値が `_common` になる場合を含む）
  （テスト: `karakuri.test.sh` の `dev-inject rejects _common as the broker key`）

保証台帳は未敷設のため、これらに対応する台帳の行は作らない。

### 維持する保証

- `karakuri-port-forward` は転送を張る前に `ssh -O exit` で古い master を落とす
- `karakuri-port-forward` は loopback alias の不足を検出したとき、`karakuri-loopback add`
  の実行を促して転送を中断する（macOS のみ。`ifconfig` の実行に失敗した場合は fail open）
- `karakuri-dock` は port forwarding を張らなかったとき、飛ばしたこととその理由を stderr
  に出す。`up` 有りは転送の失敗をそのまま返し、`up` 無しは警告に留めて入る
- `karakuri-dock` と `karakuri-dev-inject` は compose project 名・broker アイテムキー・
  ssh Host 名・service 名・workspace を引数で受け、一方から他方を組み立てない
- `karakuri-dev-inject` の `-b` を省略したとき、broker アイテムキーは `-p` の値になる
- broker アイテム名は `env/<key>/shared/dev,env/_common/dev,env/<key>/dev` の形で組まれる
- `karakuri.sh` は `set -euo pipefail` を使わず、bash と zsh の両方で動く
- 引数の誤り（値の欠落・未知のオプション・必須引数の欠落）は名指しで失敗し、usage を
  stderr に出す

### 廃止する保証

- `karakuri-port-forward` と `karakuri-dock -H` が、`devc-` で始まらない名前に `devc-` を
  補う挙動を廃止する。**破壊的変更であり、利用者は完全な ssh Host 名を渡すことになる**
  （`karakuri-port-forward app-dev` → `karakuri-port-forward devc-app-dev`）。利用側の
  `.zshrc` / `.bash_profile` に置いた呼び出しと `dock` 関数の書き換えが要る
- `karakuri-clean-port-forward` を廃止する。**破壊的変更であり、代替は
  `ssh -O exit <host>`。** 引数無しモードで一括に畳む手段は無くなる。この関数が担って
  いた残骸 socket の削除は、OpenSSH 自身が行うため不要である
