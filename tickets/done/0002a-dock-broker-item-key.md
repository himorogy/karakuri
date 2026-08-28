---
status: close
type: fix
base: main
targets:
  - images/runtime-base/templates/host/karakuri.sh
  - images/runtime-base/templates/host/dock.sh
  - images/runtime-base/templates/tests/karakuri.test.sh
  - images/runtime-base/templates/tests/dock.test.sh
  - example/README.md
  - images/devcontainer-base/PORT-FORWARDING.md
  - docs/host-tools-distribution.md
verify:
  - pnpm lint:sh:images
  - bash images/runtime-base/templates/tests/karakuri.test.sh
  - bash images/runtime-base/templates/tests/dock.test.sh
  - bash images/runtime-base/tests/shipped-symbols.test.sh
---

# `karakuri-dock` が broker アイテムキーを引数で受け取るようにする

## 内容

0002 の派生である。0002 で追加した `karakuri-dock` を実際に使ったところ、broker が
アイテムを見つけられずに `Not found.` で止まった。原因は 0002 の実装の誤りではなく、
0002 が裁可を通した設計が既存の命名規約と噛み合っていなかったことにある。

### 解きたい問題

同じ注入先に対して、2 つの経路が違う broker アイテム名を引いている。

`karakuri-dev-inject <project>`（`karakuri.sh:514-538`）は素の project 名を 1 つ受け取り、
そこから 2 つの名前を**別々に**導出する。broker アイテム名は
`env/<project>/shared/dev,env/_common/dev,env/<project>/dev`、compose project 名は
`<project>-dev` である。この 2 つが別ルールであることは、この関数の中で既に解けている。

`_karakuri_dock_inject`（`karakuri.sh:540-567`）は `karakuri-dock` の `-p` の値
（= compose project 名）を 1 つ受け取り、broker にも compose にも**同じ値**を渡す
（560 行目と 563 行目）。`karakuri-dock` の `-p` には利用側の慣習として
`<project>-dev` を渡す（`example/README.md` の `dock` 関数の例）。結果、broker は
`env/<project>-dev/shared/dev,...` を引き、実運用のアイテム名
`env/<project>/shared/dev,...` と食い違う。

`karakuri-dock` には broker アイテムキーを compose project 名と独立に指定する手段が
無い。これが欠けている機能である。

### やること

**1. `karakuri-dock` に `-b <broker-key>` を足す。**

```
karakuri-dock -p <compose-project> [-b <broker-key>] [-s <service>] [-w <workspace>] [up]
```

`-b` を省略したときは `-p` の値を使う。既定を変えないので、`-p` の値がそのまま
アイテムキーになる既存の呼び方は動き続ける。

`-b` の値検査は既存の `-p` / `-s` / `-w` と同じ形にする（値が続かなければ名指しで
失敗し、usage を出す）。`_karakuri_plain_name` による妥当性検査は `-p` が現状
行っていないので、`-b` にも足さない（検査の有無を引数ごとに変えると、どちらが
検査されるのかがコードを読まないと分からなくなる）。

**2. `_karakuri_dock_inject` を 2 つの名前を別々に受け取る形にする。**

```
_karakuri_dock_inject <compose-project> <broker-key> [service]
```

- `karakuri-broker-command dev <broker-key>` と
  `_karakuri_broker_env_into dev <broker-key>` には broker キーを渡す
- `DEV_COMPOSE_PROJECT` には compose project 名をそのまま渡す（変換しない）

`karakuri-broker-command` にも broker キーを渡すのは、この関数の引数が
「プロジェクトごとに別の broker を使う実装のために渡してある」ものであり、受け取る
べきはプロジェクトの識別子であって compose project 名ではないためである。
`karakuri-dev-inject` 経由の呼び出しと粒度が揃う。

`karakuri.sh:540-547` のコメントは、いまは「変換をかけずそのまま使う」理由だけを
書いている。2 引数にする理由——compose project 名と broker アイテムキーは別物であり、
どちらも呼び出し側が決めるので関数側で一方から他方を導かない——に書き換える。

**3. 関数の記載を揃える。**

`karakuri.sh` の規律どおり、引数の形が変わるので次を揃える。

- ファイル冒頭のコメント一覧（`karakuri.sh:60`）
- 関数の直前のコメントと `usage`（`karakuri.sh:569`, `596`）
- `karakuri-help` の出力（`karakuri.sh:1265`）
- ファイル末尾の推奨 alias の例（`karakuri.sh:1343-1349`）

**4. テストを追加・更新する。**

`karakuri.test.sh` に足すこと。

- `-b` を指定したとき、`BROKER_BW_ITEM` が
  `env/<key>/shared/dev,env/_common/dev,env/<key>/dev` になり、
  `DEV_COMPOSE_PROJECT` は `-p` の値のまま変わらないこと
- `-b` を省略したとき、broker アイテムキーが `-p` の値になること
  （現行ケース `karakuri-dock injects only when --secrets-ok fails, using -p verbatim`
  を「`-b` 省略時」の意味に読み替えて維持する。assert 自体は変わらない）
- 再定義した `karakuri-broker-env` に渡る値が `-p` の値ではなく broker キーであること
  （差し替え点の粒度の検証。既存の再定義テスト `karakuri.test.sh:636-651` の作法に倣う）
- `-b` に値が続かないときに名指しで失敗し、usage を出すこと
- bash と zsh の両方で出力が一致すること（既存の走らせ方に乗せる）

`dock.test.sh` と `dev-inject.test.sh` は変更しない。`dock.sh` は broker を知らず、
`dev-inject.sh` は `BROKER_BW_ITEM` を素通しするだけで、どちらもこの変更の対象外である。

**5. 文書を追随させる。**

- `example/README.md` — `dock` 関数の例を `dock() { karakuri-dock -p "$1-dev" -b "$1"
  -w "/workspaces/$1" "${@:2}" }` にする。`-p` と `-b` が別物である理由（compose
  project 名は `-dev` 付き、broker アイテム名は素のプロジェクト名）を 1〜2 文で添える。
  この `dock` 関数の例はここが正本である
- `images/devcontainer-base/PORT-FORWARDING.md` — Windows 側で注入を済ませる手順の
  `karakuri-dock -p <your-project>-dev up` に `-b <your-project>` を足す。
  `karakuri-dock -p <compose-project>` と書いている箇所も新しい形に揃える
- `docs/host-tools-distribution.md` — §4.6 が持っている `dock` 関数の具体例を落とし、
  決定文（規約の組み立ては利用側の関数に委ねる／`dock.sh` 側では組み立てない）だけを
  残して `example/README.md` を指す。同じ例を 2 箇所で保つのをやめる。あわせて
  `karakuri-dock` の引数の形の記載を新しいものに直す

### やらないこと

- `dock.sh` に `-b` 相当の引数は足さない。`dock.sh` は broker を一切知らず、secret の
  経路も持たない。broker の判断は `karakuri.sh` 側にしかない
- `_karakuri_dock_inject` で `-p` の値から末尾の `-dev` を剥がす案は採らない。0002 が
  裁可した「受け取った名前から別の名前を組み立てない」に反するうえ、`-dev` を付けない
  compose project 名や、素で `foo-dev` という名前のプロジェクトで壊れる
- 利用者に `karakuri-broker-env` を再定義させて `-dev` を剥がしてもらう案（文書化だけで
  済ませる案）も採らない。再定義された関数が受け取るのは文字列 1 本だけで、
  `karakuri-dev-inject` 由来（素の名前）か `karakuri-dock` 由来（compose project 名）かを
  区別できない。剥離が `karakuri-dev-inject` と prod 経路にも掛かることになり、
  karakuri 内部の不整合を差し替え点に肩代わりさせる形になる
- `karakuri-dev-inject` は変更しない。素の project 名 1 つから 2 つの名前を導出する形を
  維持する
- broker アイテム名の組み立て規則（`karakuri-broker-env` の中身）は変更しない
- `docs/host-tools-distribution.md` を現在形の文書として残すか、設計書へ統合して畳むかは
  このチケットでは決めない。今回触るのは実装との乖離と、`example/README.md` との重複の
  解消だけである

## 保証

### 新たに宣言する保証

- `karakuri-dock -b <key>` を指定したとき、broker へ渡る `BROKER_BW_ITEM` は
  `env/<key>/shared/dev,env/_common/dev,env/<key>/dev` になり、`DEV_COMPOSE_PROJECT` は
  `-p` の値のまま変わらない
  （テスト: `karakuri.test.sh` の `karakuri-dock -b sets the broker item key independently of -p`）
- `karakuri-dock` の `-b` を省略したとき、broker アイテムキーは `-p` の値になる
  （テスト: `karakuri.test.sh` の
  `karakuri-dock injects only when --secrets-ok fails, using -p verbatim`。既存ケースを維持）
- `karakuri-dock` が `karakuri-broker-command` と `karakuri-broker-env` へ渡す値は
  broker アイテムキーであり、`-p` の値ではない
  （テスト: `karakuri.test.sh` の
  `karakuri-dock passes the broker key to a redefined karakuri-broker-env`）

保証台帳は未敷設のため、これらに対応する台帳の行は作らない。

### 維持する保証

- `karakuri-dock` と `dock.sh` は compose project 名・service 名・workspace を引数で受け、
  コンテナ名や workspace のパスを組み立てない（0002）。`-b` の追加はこの原則を broker
  アイテムキーへ広げるものであり、反しない
- `karakuri-dev-inject <project>` は素の project 名から broker アイテム名
  `env/<project>/shared/dev,env/_common/dev,env/<project>/dev` と compose project 名
  `<project>-dev` を導出する。この経路は変わらない
- `karakuri-dock` は secret が注入済みのとき `dev-inject` を呼ばない
- `dock.sh` は broker を知らず、secret は broker の stdout から `docker exec -i` 経由でのみ
  コンテナへ入る
- `karakuri.sh` は `set -euo pipefail` を使わず、bash と zsh の両方で動く
- 引数の誤り（値の欠落・未知のオプション）は名指しで失敗し、usage を stderr に出す

### 廃止する保証

- なし。0002 は broker アイテム名の作り方を保証として宣言しておらず（既存テストが挙動を
  固定しているだけである）、`-b` 省略時はその挙動をそのまま既定として残す。取り下げるのは
  「`-p` の値以外を選べない」ことだけで、これは約束として置かれていない
