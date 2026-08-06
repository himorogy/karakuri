# @himorogy/env-guard

平文の env ファイルが git に入るのを止めるための検査です。コミット時の pre-commit hook と CI の両方が、**同じ 1 本のシェルスクリプト**を呼びます。

判定の実装が 2 つあると、対象パターンや除外リストを揃えても「手元では通ったのに CI で落ちる」（およびその逆）が必ず残ります。ここでは実装ごと 1 本に寄せてあり、hook と CI で違うのは**渡すファイル一覧の作り方だけ**です。

- hook … `git diff --cached --name-only`（staged なもの）
- CI … `git ls-files`（tracked なもの）

同じ一覧を与えれば、出力も終了コードも完全に一致します。

実行時の依存はありません。スキャナと hook は POSIX シェルと `git` / `grep` / `sed` / `find` があれば動きます。導入コマンド `env-guard install` だけは Node で書かれていますが、こちらも標準モジュール以外は使いません。

---

## 何を検査するか

### 平文のまま置かれた env ファイル

検査対象に当たったファイルを 1 行ずつ見て、次のいずれでもない行を平文として報告します。

- 空行
- `#` で始まるコメント行
- `DOTENV_PUBLIC_KEY` で始まる行
- `KEY=encrypted:...` または `KEY="encrypted:..."` の形の行（鍵名は英大文字・数字・下線）

「暗号化済みのファイルかどうか」ではなく「行ごとに暗号化されているか」を見ます。したがって、一度暗号化したファイルに後から平文の変数を書き足した場合も検出します。

検査対象になるファイル名は、既定では次の拡張正規表現に一致するものです。

```
(^|/)\.env
(^|/)secret\.env\.
```

`.env` / `.env.production` / `packages/api/.env` / `secret.env.staging` などが当たります。`production.env` のように `.env` で始まらない名前は既定では対象外です（設定ファイルで足せます。後述）。

除外リストは既定では `*.env.container.example` の 1 件だけです。

### 作業ツリーに置かれた `.env.keys`

`.env.keys` は dotenvx の私鍵そのものです。1 件でも見つかれば無条件で失敗します。

この検査だけは渡されたファイル一覧に依らず、リポジトリ全体を再帰的に探します（`node_modules` の下は除く）。私鍵が作業ツリーにあること自体が危険であり、「今回のコミットに含まれていない」「絞り込みの外にある」は安全の理由にならないためです。

### 値はログに出しません

検出しても、報告するのはパス・行番号・鍵名までです。`=` より後は決して出力しません。`=` を含まない壊れた行は鍵名を切り出せないため、行番号だけを出します（行の先頭を鍵名として出すと、値そのものを出すのと同じことになるためです）。

CI のログは、リポジトリのファイルとは保持期間も配信経路も違います。そこへ secret を写さないための作りです。

---

## 使い方

### コマンドとして

検査対象の一覧を標準入力から 1 行 1 パスで受け取ります。一覧の作り方はこのスクリプトの責務ではありません。

```sh
git ls-files | env-guard-scan
git diff --cached --name-only | env-guard-scan
```

パスはカレントディレクトリからの相対として解釈します。上の 2 つの git コマンドはどちらもリポジトリルートからの相対パスを出すので、**リポジトリルートで実行してください**（git hook は常にルートで実行されます）。

インストールせずに一度だけ実行する場合:

```sh
git ls-files | npx -y -p @himorogy/env-guard env-guard-scan
```

### pre-commit hook として

パッケージには `hooks/pre-commit` も入っています。staged なファイルの一覧をスキャナへ渡し、その後 `.husky/pre-commit` と `.githooks/pre-commit` があればチェーンします（他の hook 管理ツールを黙って上書きしないためです）。

導入は `env-guard install` で行います。[simple-git-hooks](https://www.npmjs.com/package/simple-git-hooks) を経由するので、**先にそちらを入れてください**。

```sh
npm install --save-dev simple-git-hooks @himorogy/env-guard
npx env-guard install
```

リポジトリのルートで実行してください。このコマンドがすること:

1. `package.json` の `simple-git-hooks.pre-commit` に `sh node_modules/@himorogy/env-guard/hooks/pre-commit` を書く
2. simple-git-hooks を実行して `.git/hooks/pre-commit` を実体化する
3. その `.git/hooks/pre-commit` が実在し、実行可能で、env-guard の hook を呼んでいることを**確かめてから**成功を報告する

3 があるのは、`package.json` に書いただけでは `.git/hooks/pre-commit` は生まれないためです。「入れたつもりで何も検査されていない」状態は、hook が無い状態より悪くなります。確かめられなければ非ゼロで終わり、何をすればよいかを出力します。

何度実行しても構いません。既に入っていれば何も書かずに終わります。**別のコマンドが既に `pre-commit` に設定されている場合は上書きせず**、現在の値と必要な値の両方を出力して非ゼロで終わります。既にある検査を黙って消さないためです。合成は次の形になります。

```json
{
  "simple-git-hooks": {
    "pre-commit": "sh node_modules/@himorogy/env-guard/hooks/pre-commit && npx lint-staged"
  }
}
```

`.git/hooks/` は git の管理外なので、clone しても付いてきません。新しい clone でも自動で入るようにするには `package.json` に次を足してください。

```json
{
  "scripts": {
    "prepare": "simple-git-hooks"
  }
}
```

状態の確認だけをしたい場合は `--check` を使います。何も書かず、入っていれば 0、入っていない・食い違っている場合は非ゼロで終わります。手順書や CI からの確認に使えます。

```sh
npx env-guard install --check
```

#### hook がスキャナを見つけられなかったとき

hook がスキャナを探す順は、自分自身の隣（`../bin/env-guard-scan`）、次に `/usr/local/bin/env-guard-scan` です。どちらにも無ければ**コミットを拒否します**。見つからないときに黙って通す経路はありません。

hook は自分自身の場所からスキャナの位置を割り出すので、`PATH` を一切引きません。ログインシェルと違う `PATH` で起動される GUI の git クライアントからでも、同じスキャナが走ります。

#### `core.hooksPath` を直接使う方法について

git には `core.hooksPath` で hook ディレクトリごと差し替える機能があり、このパッケージの `hooks/` をそこへ向けることもできます。

```sh
git config core.hooksPath node_modules/@himorogy/env-guard/hooks
```

**プロジェクトへの導入手順としてはお勧めしません。** `core.hooksPath` は `.git/hooks/` を丸ごと無視させるため、そのリポジトリの他の hook（simple-git-hooks や husky が書いたもの）が黙って効かなくなります。上の `env-guard install` は既存の仕組みに相乗りするので、この問題が起きません。

この設定が向くのは、**開発コンテナのイメージ側で全リポジトリにまとめて効かせる**用途です。イメージのビルド時に `hooks/pre-commit` を固定の場所へ置き、`core.hooksPath` をコンテナの git 設定へ書いておけば、そのコンテナの中で作られる clone すべてに最初から効きます。

#### コンテナの中と外で、効いているものが違う

この 2 つは独立に動きます。

| commit する場所 | git が使う hook |
| --- | --- |
| 開発コンテナの中 | コンテナの git 設定が指すディレクトリ（イメージが用意したもの）。`.git/hooks/` は無視される |
| ホスト（ターミナル・GUI クライアント） | `.git/hooks/pre-commit`。コンテナの設定は読まれない |

`env-guard install` が用意するのは**後者**です。コンテナの中で検査が効いていることは、ホストの git クライアントから commit する経路には何の効果もありません。逆も同じです。ホストからも commit するなら、`env-guard install --check` が 0 を返すことを一度確かめてください。

---

## 終了コード

| コード | 意味 |
| --- | --- |
| 0 | 問題なし。何件検査したかを必ず出力します |
| 1 | 平文の値を検出した / `.env.keys` があった / 検査を完走できなかった |

検査を完走できない場合は必ず 1 で終わります。「設定ファイルが読めなかったので既定で通した」「走査に失敗したので 0 件として通した」は作りません。git リポジトリでない場所で実行した場合も、0 件検査の成功ではなく失敗になります。

0 で終わったときの出力は次の 2 つに分かれます。

```
env-guard: OK — nothing to inspect (no env file among the <n> path(s) given).
env-guard: OK — inspected <n> file(s), no unencrypted values.
```

どちらなのかを出力だけで区別できるようにしてあるのは、「1 件も検査していないのに緑」に気付けるようにするためです。

---

## プロジェクトごとの調整 — `env-guard.conf`

リポジトリのルートに `env-guard.conf` を置くと、検査対象のパターンと除外リストを上書きできます。

呼び出し側の入力（workflow の input や hook の引数）ではなくリポジトリ内のファイルに寄せてあるのは、**hook と CI が同じ設定を読む**ようにするためです。設定の置き場が 2 つあると、そこから判定がずれていきます。

書式は 1 行 1 ディレクティブです。

```
# コメントは行頭のみ
pattern (^|/)\.env
pattern (^|/)secret\.env\.
pattern (^|/)[^/]*\.env$
allow   *.env.container.example
allow   docs/.env.sample
```

- `pattern` … 検査対象とするパスの拡張正規表現。**1 行でもあれば既定を置き換えます**（追加ではありません）
- `allow` … 検査から外すパスの glob。同じく 1 行でもあれば既定を置き換えます
- 書かなかった側は既定のままです

このファイルは `source` も `eval` もしません。行単位でパースし、値はパターン文字列としてしか使いません。リポジトリの中身は、検査を回避したい側が書ける場所です。防御する仕組みを攻撃経路にしないためです。

ファイル名を `.env-guard.conf` のようにドットで始めていないのは、既定のパターン `(^|/)\.env` に自分自身が一致してしまい、設定ファイルが env ファイルとして検査されて必ず落ちるためです。

### 壊れた設定は既定へ倒れません

- 知らないディレクティブ … 行番号付きで失敗します
- 値の無いディレクティブ … 行番号付きで失敗します
- ファイルが存在するのに読めない … 失敗します

いずれも「既定で続行」はしません。適用されるはずだった設定が分からない以上、その結果を合格とは呼べないためです。

---

## 平文を見つけたら

```sh
dotenvx encrypt -f <file>
```

暗号化した後、`.env.keys` が作業ツリーに残っていないことを確かめてください。残っていると、この検査は次回も失敗します。

---

## ライセンス

MIT
