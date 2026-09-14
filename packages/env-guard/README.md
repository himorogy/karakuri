# @himorogy/env-guard

平文の env ファイルが git に入る事故を止めるための検査です。前提は dotenvx で暗号化した `.env` で、
暗号化されていない行が残ったままの commit と、復号に要る私鍵 `.env.keys` が作業ツリーに置かれた
ままであることの両方を拒否します。私鍵が残る形が起きるのは、dotenvx が私鍵の環境変数を見つけ
られないとき、暗号化した `.env` の隣にある `.env.keys` へ自動でフォールバックするためです。
検出しても報告するのはパス・行番号・鍵名までで、`=` より後は決して出力しません。CI のログは
リポジトリのファイルとは保持期間も配信経路も違うので、そこへ secret を写さないためです。

---

## スキャナ `env-guard-scan`

**何のために。** 平文の行と `.env.keys` を実際に見つける判定です。pre-commit hook も CI も
この 1 本を呼ぶので、同じ一覧を与えれば合否も出力も一致します。

**どう動くか。** 入口ごとに違うのは渡すファイル一覧の作り方だけです。hook は
`git diff --cached --name-only`（staged なもの）を、CI は `git ls-files`（tracked なもの）を
渡します。**手元の commit は通ったのに CI で落ちた**（およびその逆）ときに違っているのは、
この一覧だけです。

判定は行単位です。一度暗号化したファイルに後から平文の変数を書き足した場合も検出します。
`production.env` のように `.env` で始まらない名前は既定では対象外なので、要るなら下記の設定
ファイルで足してください。`.env.keys` の検査だけは渡された一覧に依らずリポジトリ全体を再帰的に
探すため、stage するファイルを絞っても私鍵は見つかります。

検査対象の一覧は標準入力から 1 行 1 パスで受け取ります。パスはカレントディレクトリからの相対と
して解釈するので、**リポジトリルートで実行してください**（`git diff --cached --name-only` は
どこで実行してもルートからの相対パスを出します）。

```sh
git ls-files | env-guard-scan
git diff --cached --name-only | env-guard-scan
```

インストールせずに一度だけ実行する場合:

```sh
git ls-files | npx -y -p @himorogy/env-guard env-guard-scan
```

リポジトリのルートに `env-guard.conf` を置くと、検査対象のパターンと除外リストを上書きできます。
書式は 1 行 1 ディレクティブです。

```
# コメントは行頭のみ
pattern (^|/)\.env
pattern (^|/)[^/]*\.env$
allow   docs/.env.sample
```

`pattern` は検査対象とするパスの拡張正規表現、`allow` は検査から外すパスの glob です。どちらも
**1 行でもあれば既定を置き換えます**（追加ではありません）。書かなかった側は既定のままです。

**保証。** 保証台帳 `docs/guarantees.md` の `images/runtime-base/tests/env-guard.test.sh` の節。

---

## pre-commit hook

**何のために。** commit を試みた時点で止めるためのものです。CI にしか置かないと、平文を含む
commit は既に手元の履歴にあり、push して初めて分かります。hook 自身は staged なファイルの一覧を
作ってスキャナへ渡すだけで、判定は持ちません。

**どう動くか。** git の `core.hooksPath` でこのパッケージの `hooks/` を直接指すこともできますが、
**プロジェクトへの導入手順としては使わないでください。** `core.hooksPath` は `.git/hooks/` を
丸ごと無視させるため、そのリポジトリの他の hook（simple-git-hooks が `.git/hooks/` へ書いた
ものなど）が黙って効かなくなります。下の `env-guard install` は既存の仕組みに相乗りするので、
この問題が起きません。

**保証。** 保証台帳 `docs/guarantees.md` の `images/runtime-base/tests/hook.test.sh` と
`images/runtime-base/tests/env-guard.test.sh` の節。

---

## 導入コマンド `env-guard install`

**何のために。** ホスト側、つまり開発コンテナの外の git クライアントから commit する経路にも
hook を効かせるためのコマンドです。コンテナの中で検査が効いていることは、ホストのターミナルや
GUI クライアントからの commit には何の効果もありません。逆も同じです。

**どう動くか。** [simple-git-hooks](https://www.npmjs.com/package/simple-git-hooks) を経由して
`.git/hooks/pre-commit` を実体化するので、**先にそちらを入れてください。** リポジトリのルートで
実行します。

```sh
npm install --save-dev simple-git-hooks @himorogy/env-guard
npx env-guard install
```

`.git/hooks/` は git の管理外で clone に付いてこないため、新しい clone でも自動で入るようにするには
`package.json` に次を足します。

```json
{
  "scripts": {
    "prepare": "simple-git-hooks"
  }
}
```

ホストからも commit するなら、`env-guard install --check` が 0 を返すことを一度確かめてください。

**保証。** 保証台帳 `docs/guarantees.md` の `packages/env-guard/tests/install.test.sh` の節。
コンテナの中で hook が効くこと自体はこのパッケージではなくイメージ側の約束で、台帳では未検証の
約束（テスト困難）に着地します。起源チケットは `0009-ledger-auth-and-shipped` です。
