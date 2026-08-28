---
status: close
type: fix
base: main
targets:
  - images/runtime-base/templates/host/karakuri.sh
  - images/runtime-base/templates/tests/karakuri.test.sh
  - example/README.md
  - images/devcontainer-base/PORT-FORWARDING.md
  - images/devcontainer-base/examples/docker-compose.yaml
  - docs/host-tools-distribution.md
verify:
  - pnpm lint:sh:images
  - bash images/runtime-base/templates/tests/karakuri.test.sh
  - bash images/runtime-base/templates/tests/dock.test.sh
  - bash images/runtime-base/tests/shipped-symbols.test.sh
---

# ssh Host 別名と compose project 名を引数で受け取るようにする

## 内容

0002 の派生である。0002a の検収と、その後の mac 実機での利用で見つかった「引数で
受けた 1 つの名前から別の意味を持つ名前を組み立てている」箇所を、残らず引数へ
分離する。0002a で broker アイテムキーを `-b` にしたのと同じ処置を、残りの 2 箇所へ
適用する。

**破壊的変更を 1 件含む**（`karakuri-dev-inject` の呼び出し形式）。まだ正式リリース前
であり、非対称を残したまま公開面を固めないための判断である。

### 解きたい問題

**1. ssh Host 別名が `-p` から組み立てられている。**

`karakuri-dock` は `host="$(_karakuri_ssh_host "$project")"` で `devc-<-p の値>` を作り、
`ssh -G` の検査と `karakuri-port-forward` の呼び出しにそれを使う。利用者の
`~/.ssh/config` の Host 別名が compose project 名と違う名前だと、`ssh -G` が別の
ホストを解決して `has no LocalForward in ~/.ssh/config — skipping port forwarding` と
誤診断され、転送が張られない。mac の実機で踏んだ。

`karakuri-port-forward` と `karakuri-clean-port-forward` は単体なら任意の名前を受け
られる（`_karakuri_ssh_host` が `devc-*` を素通しする）。名前を選べないのは
`karakuri-dock` 経由のときだけである。`PORT-FORWARDING.md` が「Host 別名を `HostName`
と違う値にすると誤診断される」と制約として書いているのは、この組み立てがあるため。

**2. `karakuri-dev-inject` が compose project 名を組み立てている。**

`DEV_COMPOSE_PROJECT=${project}-dev`。単一引数から接尾辞を足しており、compose project
名が `<project>-dev` でないプロジェクトでは注入先を引けない。0002a で
`_karakuri_dock_inject` を 2 引数に分離したのに、この経路だけ非対称のまま残っている。

**3. `dock` 関数の例が zsh 前提で、bash に貼ると構文エラーになる。**

```sh
dock() { karakuri-dock -p "$1-dev" -b "$1" -w "/workspaces/$1" "${@:2}" }
```

bash は `}` の前にコマンド終端（`;` か改行）を要求する。zsh は要求しない。この形を
`~/.bash_profile` に貼ると `syntax error: unexpected end of file` になる。0003 で対応 OS
を macOS と Windows(Git Bash) に定めており、Git Bash はログインシェルとして
`~/.bash_profile` を読むため、bash 利用者が最初に踏む。同じ文言が 2 箇所にある
（`example/README.md` と `karakuri.sh` 末尾の推奨 alias のコメント）。

### やること

**1. `karakuri-dock` に `-H <ssh-host>` を足す。**

```
karakuri-dock -p <compose-project> [-b <broker-key>] [-H <ssh-host>] [-s <service>] [-w <workspace>] [up]
```

`-H` を省略したときは `-p` の値を使う（既定不変）。`-h` は `--help` が使用済みなので
大文字にする。値検査は既存の `-p` / `-b` / `-s` / `-w` と同じ形（値が続かなければ
名指しで失敗し usage を出す）。

`-H` の値は `_karakuri_ssh_host` へ渡し、その結果を `ssh -G` の検査・失敗時の
メッセージ・`karakuri-port-forward` の呼び出しの 3 箇所で使う。`_karakuri_ssh_host` は
`devc-` を補い、既に付いていればそのまま使う既存の挙動を変えない。

**2. `karakuri-dev-inject` の引数を `karakuri-dock` と同じ語彙に揃える。**

```
karakuri-dev-inject -p <compose-project> [-b <broker-key>] [-s <service>]
```

- `-p` は必須。省略したら usage を出して失敗する
- `-b` を省略したら `-p` の値を使う（`karakuri-dock` と同じ規則）
- `-s` を省略したら `DEV_SERVICE` を渡さない（`dev-inject.sh` の既定に従う）
- `DEV_COMPOSE_PROJECT` は `-p` の値そのままで、`-dev` を足さない
- 旧形式の単一位置引数は受けない。位置引数を渡されたら usage を出して失敗する
  （黙って旧解釈で動かさない。静かに別プロジェクトへ注入する事故を避ける）

`-p` と `-b` は `_karakuri_plain_name` で検査する（現行の `<project>` 引数と同じ検査を
引き継ぐ）。

**3. `_karakuri_dock_inject` を畳む。**

この private 関数を `karakuri-dev-inject` と分けた理由は「`DEV_COMPOSE_PROJECT` に渡す
値が違うため」の一点で、上の 2 でその差が消える。`karakuri-dock` は
`karakuri-dev-inject -p "$project" -b "$broker_key" [-s "$service"]` を直接呼ぶ形にし、
`_karakuri_dock_inject` を削除する。同じ注入経路が 2 つある状態が、0002a のバグを
生んだ形そのものなので、片方に寄せる。

これにより `karakuri-dock` の `-p` にも `_karakuri_plain_name` の検査が掛かる。compose
project 名に `/` を含められないのは docker 側の制約でもあり、締める方向の変更である。

**4. 関数の記載を揃える。**

`karakuri.sh` の規律どおり、引数の形が変わる 2 つの関数について次を揃える。

- ファイル冒頭のコメント一覧
- 関数の直前のコメントと `usage` 文字列
- `karakuri-help` の出力
- ファイル末尾の推奨 alias の例

**5. テストを追加・更新する。**

`karakuri.test.sh` に足すこと。

- `-H` を指定したとき、`ssh -G` の検査と `karakuri-port-forward` の対象がその値に
  なり、`-p` の値が ssh Host 別名に使われないこと
- `-H` を省略したとき、従来どおり `-p` の値から導出されること（既存ケースを維持する）
- `-H` に `devc-` 付きの値を渡したとき、二重に付かないこと
- `-H` に値が続かないときに名指しで失敗し usage を出すこと
- `karakuri-dev-inject -p <name>` で `DEV_COMPOSE_PROJECT` がその値そのままになり、
  `-dev` が足されないこと
- `karakuri-dev-inject` の `-b` 省略時に broker アイテムキーが `-p` の値になること
- `karakuri-dev-inject` を位置引数で呼んだとき、および `-p` を省略したときに usage を
  出して失敗すること
- `karakuri-dock` が注入時に `karakuri-dev-inject` を通ること（`_karakuri_dock_inject`
  が消えても注入経路と渡る環境変数が変わらないこと）
- bash と zsh の両方で出力が一致すること（既存の走らせ方に乗せる）

`dock.test.sh` と `dev-inject.test.sh` は変更しない。`dock.sh` と `dev-inject.sh` は
どちらもこの変更の対象外である。

**6. 文書を追随させる。**

- `example/README.md` — `karakuri-dev-inject` の実行例を新しい引数形に直す。`dock` 関数
  の例に `-H` を加え、**`; }` を足して bash でも貼れる形にする。** 置き場所として
  `~/.zshrc` と `~/.bash_profile` の両方を挙げ、bash では閉じ括弧の前に `;` が要ることを
  1 文添える。この `dock` 関数の例はここが正本である
- `karakuri.sh` 末尾の推奨 alias のコメントにある `dock` 関数の例も同じ形に直す
  （同じ文言が 2 箇所にあるため、片方だけ直すと食い違う）
- `images/devcontainer-base/PORT-FORWARDING.md` — 「Host 別名は `HostName` と同じ値に
  する」を**推奨として残し**、違う名前にしたい場合の逃げ道として `-H` を添える形にする。
  制約を全面的に書き換えない（既定の作法に乗る利用者に選択肢を増やさない）
- `docs/host-tools-distribution.md` — `karakuri-dock` の引数の形の記載を直す

### やらないこと

- `karakuri-port-forward` / `karakuri-clean-port-forward` の引数の形は変えない。どちらも
  すでに任意の名前を受けられる
- `_karakuri_ssh_host` の挙動は変えない。`devc-` を補い、既に付いていればそのまま使う
- `broker` アイテム名の組み立て規則（`karakuri-broker-env` の中身）は変えない
- `dock.sh` / `dev-inject.sh` / `prod-run.sh` は変更しない
- prod 側の名前の組み立て（`karakuri-prod-shell` の `prod-${repo}`、
  `COMPOSE_PROJECT_NAME=prod-${repo}`）は変えない。書く側と読む側が同じ `karakuri.sh`
  内にあり、外部が project 名を決めていないため、別名にしたい理由が無い
- `~/.ssh/cm-<host>` の ControlPath と `port-forward-<host>.log` のログ名も変えない。
  どちらも host をそのまま使う内部の簿記であり、ssh 側の `ControlPath ~/.ssh/cm-%n`
  規約に追随しているだけである
- 旧形式 `karakuri-dev-inject <project>` の互換シムは置かない。移行の保険は失敗を隠して
  原因から遠いエラーに変える（0002 で `dock.sh` のフォールバックを削除したときと同じ
  判断）。位置引数は usage を出して失敗するのが正しい壊れ方である

## 保証

### 新たに宣言する保証

- `karakuri-dock -H <ssh-host>` を指定したとき、`ssh -G` の検査対象と
  `karakuri-port-forward` の対象はその値（`devc-` は無ければ補う）になり、`-p` の値は
  ssh Host 別名に使われない
  （テスト: `karakuri.test.sh` の `karakuri-dock -H targets the given ssh host instead of the -p value`）
- `karakuri-dock` の `-H` を省略したとき、ssh Host 別名は `-p` の値から導出される
  （テスト: `karakuri.test.sh` の既存ケース
  `'ssh -fN' targets 'devc-myproj-dev', matching the -p value exactly`。既存 assert を維持）
- `karakuri-dev-inject -p <compose-project>` は `DEV_COMPOSE_PROJECT` にその値をそのまま
  渡し、`-dev` を足さない
  （テスト: `karakuri.test.sh` の `karakuri-dev-inject passes -p through to DEV_COMPOSE_PROJECT verbatim`）
- `karakuri-dev-inject` の `-b` を省略したとき、broker アイテムキーは `-p` の値になる
  （テスト: `karakuri.test.sh` の `karakuri-dev-inject defaults the broker key to the -p value`）

保証台帳は未敷設のため、これらに対応する台帳の行は作らない。

### 維持する保証

- `_karakuri_ssh_host` は `devc-` を補い、既に付いている場合はそのまま使う
- `karakuri-port-forward` と `karakuri-clean-port-forward` は引数で受けた名前をそのまま
  使い、compose project 名からの組み立てをしない
- `karakuri-dock` は secret が注入済みのとき注入を呼ばない
- `karakuri-dock` は port forwarding を張らなかったとき、飛ばしたこととその理由を stderr
  に出す。`up` 有りは転送の失敗をそのまま返し、`up` 無しは警告に留めて入る
- `dock.sh` は broker を知らず、secret は broker の stdout から `docker exec -i` 経由でのみ
  コンテナへ入る
- broker アイテム名は `env/<key>/shared/dev,env/_common/dev,env/<key>/dev` の形で組まれる
- `karakuri.sh` は `set -euo pipefail` を使わず、bash と zsh の両方で動く
- 引数の誤り（値の欠落・未知のオプション・必須引数の欠落）は名指しで失敗し、usage を
  stderr に出す

### 廃止する保証

- `karakuri-dev-inject <project>` という単一位置引数の呼び出し形式を廃止する。素の
  project 名から compose project 名 `<project>-dev` を導出する挙動を取り下げる（0002 と
  0002a が「維持する保証」として宣言していた行）。規約の組み立ては利用側の関数に移る。
  **破壊的変更であり、利用側の `.zshrc` / `.bash_profile` に置いた呼び出しの書き換えが
  要る。** 正式リリース前に非対称を解消するための変更である
