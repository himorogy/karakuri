# runtime-base 検証記録

設計書 §10「検証項目」の消化状況。**未実施の項目を空欄のまま放置しない**ために、
実施済み・未実施・実施できない理由を全て明示する。

実施日と環境:

- 2026-08-05 / karakuri monorepo（`feat-new-prodshell`）/ dev container 内（Node 24、linux-arm64）
- **この環境には docker が無い**（dev container は Docker socket を持たない。これは設計の前提条件
  そのものであり、崩してはならない）。したがって docker を要する項目は**全て未実施**である。

凡例: ✅ 実施・合格 / ⬜ 未実施 / ⛔ この環境では実施不能

---

## 1. 自動テストで恒常的に確認しているもの

`pnpm test` が回帰として毎回検証する。テストは docker 不要で、shim / entrypoint を一時
ディレクトリへ複製しパスを書き換えて実行する方式（実体はフェイクに差し替え）。

| # | 項目 | 状態 | 根拠 |
|---|---|---|---|
| 1 | 空値 secret（`KEY=""`）で entrypoint が非ゼロ終了 | ✅ | `tests/entrypoint.test.sh` |
| 2 | stdin 空でも非ゼロ終了 | ✅ | 同上 |
| 3 | 値に `=` を含む行が壊れない | ✅ | 同上（`postgres://u:p@h/db?a=b`） |
| 4 | CRLF 行で値末尾に `\r` が残らない | ✅ | 同上 |
| 5 | `=` 無し行 / 不正な鍵名で非ゼロ終了 | ✅ | 同上 |
| 6 | 生成された secret ファイルが mode 600 | ✅ | 同上 |
| 7 | clone 後に `/run/secrets/GH_TOKEN` が削除されている | ✅ | 同上 |
| 8 | 引数なし呼び出しで非ゼロ終了 | ✅ | 同上 |
| 9 | `/src` 非空・`.git` 無し（前回失敗の残骸）から復帰できる | ✅ | 同上 |
| 10 | named volume 再利用時に tracked file の改変が復元される | ✅ | 同上（rev.4 で追加。`reset --hard` の回帰） |
| 11 | パース失敗メッセージに入力行・鍵名が出ない | ✅ | 同上（rev.4 で追加） |
| 12 | shim: secret 存在時に注入される | ✅ | `tests/shim.test.sh` |
| 13 | shim: 空ファイルで非ゼロ終了 | ✅ | 同上 |
| 14 | shim: 不在時に素通しし、呼び出し元の環境変数を引き継ぐ | ✅ | 同上 |
| 15 | shim: 存在・非空だが読めない（mode 000）で非ゼロ終了 | ✅ | 同上（rev.4 で追加。root 実行時は skip） |
| 16 | shim: `NODE_OPTIONS` が両分岐で除去される | ✅ | 同上 |
| 17 | dotenvx shim: `DOTENV_PRIVATE_KEY_*` 複数注入で全て export される | ✅ | 同上（`_LOCAL` + `_DEVELOPMENT` 同居） |
| 18 | 起動ラッパー: broker 失敗 + docker 成功でパイプ全体が非ゼロ終了（`pipefail`） | ✅ | `templates/tests/prod-run.test.sh` |
| 19 | 起動ラッパー: docker 先行失敗 + broker SIGPIPE(141) で docker を原因として報告 | ✅ | 同上（rev.4 で追加） |
| 20 | 起動ラッパー: 必須環境変数の欠落を名指しで報告し非ゼロ終了 | ✅ | 同上 |
| 21 | 起動ラッパー: 非 40 桁 `GIT_REF` で警告を出しつつ続行 | ✅ | 同上 |
| 22 | 起動ラッパー: `-T` と引数が docker へ正しく渡り、stdin が素通しされる | ✅ | 同上 |

---

## 2. ビルド時 / CI で確認するもの

| # | 項目 | 状態 | 根拠 |
|---|---|---|---|
| 23 | PATH 解決が shim に当たる（`/usr/local/bin/<name>`） | ⬜ | Dockerfile に `command -v` 検証を焼き込み済み。**ビルド未実行** |
| 24 | `core.hooksPath` が `/usr/local/share/git-hooks` に設定されている | ⬜ | CI smoke test に登録。**ビルド未実行** |
| 25 | 両アーキ（amd64 / arm64）で起動する | ⬜ | CI smoke test に登録。**ビルド未実行** |

イメージを一度も GHCR へ push していないため 23〜25 は未実施。最初のタグ push
（`runtime-base-v1.0.0`）で確認できる。

---

## 3. 実機（docker のあるホスト）で確認が要るもの — **全て未実施**

⛔ は dev container 内で原理的に実施できない項目。ホスト側で実施すること。

### secret 搬送路

| # | 項目 | 状態 |
|---|---|---|
| 26 | entrypoint 実行後、`/run/secrets/<VAR>` が mode 600 で tmpfs 上にある（`mount \| grep /run`） | ⛔ |
| 27 | `docker inspect` の `Config.Env` / `Mounts` に secret が一切現れない | ⛔ |
| 28 | broker 出力の形式（quoting / 改行）と entrypoint パーサの整合 | ⛔ |
| 29 | broker が非対話環境で非ゼロ終了し、`pipefail` 下でパイプ全体が止まる | ⛔ |
| 30 | macOS `security` の ACL 設定（毎回確認 / Touch ID / 常時許可）ごとの挙動 | ⛔ |
| 31 | 必要 secret を欠いた状態で下流コマンドが認証失敗として顕在化する（`$HOME` tmpfs により fallback 資格情報が拾われないことを含む） | ⛔ |

### compose の実挙動

| # | 項目 | 状態 | 備考 |
|---|---|---|---|
| 32 | `tmpfs: - /run:uid=1000,gid=1000,mode=0755` の記法で実際に node 所有の tmpfs が作られる | ⛔ | **最優先。効かなければ起動直後に落ちる**（`USER node` が `/run/secrets` を作れない） |
| 33 | `read_only: true` + tmpfs 構成で `git fetch` / `pnpm install` / ビルドが完走する | ⛔ | `/home/node` の書き込み先、named volume `/src` の所有権を含む |
| 34 | `GIT_REF` 未指定時に compose が失敗する | ⛔ | |
| 35 | `logging: driver: none` でもアタッチ時に stdout が手元に表示される | ⛔ | |
| 36 | ホストの `/proc/sys/kernel/core_pattern` の内容と、`ulimits: core: 0` 下でコアが生成されないこと | ⛔ | |
| 37 | 対話二段構え（`run -dT --rm` + `docker exec -it`）で TTY シェルが得られ `/run/secrets` が注入済み。退出 + `docker stop` で消えること | ⛔ | |
| 38 | `dotenvx get -f .env.prod` がファイルを生成しない | ⛔ | |
| 39 | `git clean -xdff` と `node_modules` 保持のトレードオフ（`-e node_modules` 除外の可否） | ⛔ | 設計書 §11 の未決事項 |

### dotenvx 2.x への引き上げに伴う未検証の前提

runtime-base は dotenvx **2.19.2** を焼く（既存 4 repo は enclave-env の peer range `^1.63.0`
下で運用）。2.0.0 は keyring 対応の導入にあわせて `run` / `config` / `get` を
`@dotenvx/primitives` 由来の共有 resolver 経由へ付け替えている。

| # | 項目 | 状態 | 備考 |
|---|---|---|---|
| 40 | dotenvx 2.x で `DOTENV_PRIVATE_KEY_*` の環境変数注入が従来通り効く | ⛔ | **本設計の shim はこの経路に全面的に依存する。落ちると shim 機構そのものが機能しない** |
| 41 | dotenvx 1.x で暗号化した `.env.*` を 2.x が復号できる | ⛔ | 既存 4 repo の移行可否に直結 |

2.0.0 の BREAKING は全て `lib/main` のライブラリ API（`set` / `get` の async 化、
`doctor` / `keypair` / `genexample` の export 削除、`rotate` コマンドの削除）であり、
CLI の `run` / `get` / `set` / `encrypt` / `decrypt` / `precommit` は存続していることは
CHANGELOG で確認済み。40 / 41 が落ちた場合は 1.75.1 へ戻す。

### コミット前検査

| # | 項目 | 状態 | 備考 |
|---|---|---|---|
| 42 | `core.hooksPath` 設定下で平文 `.env` のコミットが実際に拒否される | ⛔ | |
| 43 | husky を使うプロジェクトでチェーン先の hook が引き続き実行される | ⛔ | |
| 44 | prod container 内でも hook が有効である | ⛔ | |
| 45 | ホストの GUI クライアント（Fork）から平文 `.env` の commit が拒否される | ⛔ | 現行の simple-git-hooks 構成で今どうなっているかの確認を含む |
| 46 | `node_modules` が named volume か bind mount か | ⛔ | ホスト側 hook のパス解決に影響する |
| 47 | ホスト側 hook が依存バイナリを解決できない場合に非ゼロ終了する（沈黙して通過しない） | ⛔ | |
| 48 | CI（クリーン checkout・差分ゼロ）で `dotenvx precommit` が実際に検出能力を持つか | ⬜ | no-op なら設計書 §8.2 の fallback へ差し替え。**§9 手順 4 の範囲** |
| 49 | 他 org の private リポジトリから karakuri の reusable workflow が呼び出せる | ⬜ | **§9 手順 4 の範囲** |

---

## 4. 恒常チェック

| # | 項目 | 状態 | 結果 |
|---|---|---|---|
| 50 | dev container に `/var/run/docker.sock` がマウントされていない | ✅ | `.devcontainer/` に socket mount / docker-in-docker / docker-outside-of-docker の参照なし。`/var/run/docker.sock` 不在。`docker` CLI 不在 |

**devcontainer 構成を変更するたびに再確認すること。** この前提が崩れると、dev container から
prod container への `docker exec` や任意 volume の mount が可能になり、本設計の分離全体が
無効化される。

---

## 5. 次にやること

1. **ホストで docker の空き容量を確保する。** 検証を始めた時点で dev container が載っている
   overlay は 95G 中 90G 使用（残り 15MB）で、イメージのビルドすらできない状態だった。
   ホスト側で `docker system prune` 等の整理が要る。
2. runtime-base を一度 GHCR へ push する（項目 23〜25 が消化される）。
3. docker のあるホストで項目 26〜47 を消化する。**32 と 40 を先に見ること** — どちらも
   落ちれば設計の作り直しが要る箇所で、他の項目はその後でよい。
4. 項目 48 / 49 は設計書 §9 の手順 4（reusable workflow の設置）の範囲。本セッションの
   スコープ外。
