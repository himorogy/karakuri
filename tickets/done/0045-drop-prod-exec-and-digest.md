---
status: close
type: feat
base: main
targets:
  - host-tools/karakuri.sh
  - host-tools/tests/karakuri.test.sh
  - host-tools/README.md
  - docs/guarantees.md
  - example/README.md
verify:
  - pnpm lint:sh
  - pnpm test
---

# karakuri-prod-exec と digest の2関数を削除する

## 内容

### 束の全体像

host-tools の公開面を縮め、互換性を壊す変更をまとめて `host-tools-v2.0.0` として出す。
0043（`--stdio` / 対話シェルが停止中のコンテナを起動しなくなり、`--ensure-running` が全コンテナを再起動して firewall を適用するようになった変更）は、既にマージ済みでタグは未打ち。
これも 2.0.0 に含める。

- 0044: dev container の入口を `karakuri-dock` に絞る
- 0045（このチケット）: `karakuri-prod-exec` / `karakuri-image-digest` / `karakuri-check-image` を削除する

0044 と 0045 は `host-tools/karakuri.sh` などの targets が重なるので、順に実装する（0044 → 0045）。
着手時は 0044 のマージ後の `origin/main` を取り込む。
タグは両方が着地した後に打つ（チケットの作業ではない）。

### 削除する理由

- `karakuri-prod-exec`: これまでの使い道は、dotenvx を `pnpm` の外側に置くデプロイだった。`pnpm` は scripts の実行時に `node_modules/.bin` を PATH の先頭に足すので、素の `dotenvx` はプロジェクトのローカル版に負け、鍵が注入されないためである。
  いまの runtime-base イメージには、npm scripts から shim を必ず通すための呼び名 `_dotenvx` がある（`images/runtime-base/Dockerfile` の shim の節）。
  scripts に `_dotenvx run ... -- <cmd>` と書けば、`karakuri-prod-run <repo> <sha> <task>` で同じことができる。
- `karakuri-image-digest` / `karakuri-check-image`: 利用実績が無い。digest の pin を更新する人は、配布元のレジストリを直接見て確かめる。

### 変更

**`host-tools/karakuri.sh`**

- 3関数を削除する。
- digest の2関数だけが使う内部関数 `_karakuri_compose_image_ref` / `_karakuri_image_name` / `_karakuri_compose_image_name` / `_karakuri_image_ref` / `_karakuri_resolve_digest` を削除する。
- `_karakuri_compose_for` / `_karakuri_compose_list` / `_karakuri_prod_call` と、環境変数 `KARAKURI_PROD_COMPOSE` / `KARAKURI_PROD_COMPOSE_DIR` は `karakuri-prod-run` / `karakuri-prod-base` が使うので残す。
- 冒頭の目次コメントと `karakuri-help` の一覧から3関数を外す。
  `karakuri-help` の `KARAKURI_PROD_COMPOSE_DIR` の説明にある `karakuri-check-image` への言及も消す。

**`host-tools/tests/karakuri.test.sh`**

- `prod-exec` のケース（"prod-exec never builds a command string" と、COMPOSE_PROJECT_NAME の検査のうち `prod-exec` の分）を削除する。
- compose ファイルの解決を `prod-exec` 経由で検査している1ケースを削除する（`prod-run` / `prod-base` 経由の同じケースが残る）。
- digest の2関数のケースを削除する。
  fixture は、`prod-run` / `prod-base` の compose 解決のケースが共有しているものを残し、digest 専用のものだけを消す。
- 公開関数の一覧を検査する2つのループから3関数を外す。

**文書**

- `host-tools/README.md`
  - 「鍵を渡す」の `prod-run` / `prod-exec` の行を `prod-run` だけにする。
  - 「イメージの digest」の小見出しと2行を消す。
  - alias 例の `prod-exec` を消す。
  - 「prod でコマンドを実行する」の `karakuri-prod-exec acme/app <sha> dotenvx get -f .env.prod` の例は、`prod-run` で scripts を呼ぶ形に置き換える。
    「`dotenvx` は `pnpm` の外側に置く」の1行は、「scripts では `_dotenvx` と書く」に置き換える。
  - 「compose ファイルの置き場所と digest」の「`karakuri-image-digest <tag>` が貼り付け用の行を出す」を、「digest は配布元のレジストリで確かめて貼る」に置き換える。見出しはそのまま残す。
- `example/README.md`
  - デプロイ例（:86-94）を、package.json の scripts に `_dotenvx run --strict --no-armor -f .env.prod -- <cmd>` を書き、`karakuri-prod-run app <sha> <task>` で呼ぶ形に書き換える。
  - 「挙動と制約」の「dotenvx は `pnpm` の外側に置く」（:108）を、「scripts の中では `_dotenvx` と書く。素の `dotenvx` はプロジェクトのローカル版に負けて shim を通らない」に書き換える。

### やらないこと

- `KARAKURI_PROD_INSTALL` / `KARAKURI_PROD_RUN` の変更
- `images/runtime-base` の shim の変更
- `docs/archive/` の言及（履歴層）

## 保証

### 新たに宣言する保証

- prod 系の2コマンドは同じリポジトリ解決を共有し（`karakuri-prod-run` で確認）、リポジトリを1引数で受け、組織名付きの指定からも、既定の組織名で補った裸の指定からもクローン URL を組み立てる（以降は既存行の文言どおり）（テスト: "repository spec is resolved from one argument"）——下の廃止行の「3コマンド」を「2コマンド」にした置き換え
- prod 系の2コマンドはいずれも compose プロジェクト名を `prod-<repo>` として渡す（テスト: "COMPOSE_PROJECT_NAME is per repository"）——同上

### 維持する保証

- §13「既定では導入コマンドとタスクをシェル経由の1文字列として連結し、タスク引数は引用符で包む……」——`prod-exec` の分岐を消すときに `prod-run` の組み立てに触れないこと。example の書き換えはこの振る舞いを前提にしている
- §13「compose ファイルはディレクトリ指定から2つの拡張子で探し……」——共有の解決関数は残る。digest 専用の内部関数だけを消し、解決関数とその fixture を巻き込まないこと
- §13「ヘルプは下位スクリプトを一切呼ばず、公開している関数の名前と環境変数の現在値を出す……」——一覧と説明文から名前を外すだけで、性質は変えない

### 廃止する保証

- §13「prod 系の3コマンドは同じリポジトリ解決を共有し……」——`prod-exec` を削除して2コマンドになるため。新たに宣言する保証の1行目が置き換える
- §13「prod 系の3コマンドはいずれも compose プロジェクト名を `prod-<repo>` として渡す」——同上。2行目が置き換える
- §13「任意コマンドの実行は、既定の導入コマンドが設定されていてもシェルを経由せず、区切りを含めて逐語で渡す」——`prod-exec` の削除による
- §13「digest の解決は compose ファイルを書き換えず……」——`karakuri-image-digest` の削除による
- §13「ディレクトリ内のファイルがイメージ名で食い違っているときは……レジストリへの問い合わせを行わない」——digest の2関数の削除による
- §13「digest の検査は全ファイルを名前順に掃引し、最初の問題で打ち切らない……」——`karakuri-check-image` の削除による
