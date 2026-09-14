---
status: close
type: refactor
base: main
targets:
  - images/runtime-base/templates/host/broker-bitwarden.sh
  - images/runtime-base/templates/host/broker-macos-keychain-set.sh
  - images/runtime-base/templates/host/broker-macos-keychain.sh
  - images/runtime-base/templates/host/compose.prod.yaml
  - images/runtime-base/templates/host/dev-inject.sh
  - images/runtime-base/templates/host/dock.sh
  - images/runtime-base/templates/host/host-run.sh
  - images/runtime-base/templates/host/karakuri.sh
  - images/runtime-base/templates/host/loopback-setup.sh
  - images/runtime-base/templates/host/prod-run.sh
  - images/runtime-base/templates/host/loopback/com.karakuri.loopback-aliases.plist
  - images/runtime-base/templates/host/loopback/karakuri-loopback-aliases
  - images/runtime-base/templates/host/shims/_dotenvx
  - images/runtime-base/templates/host/shims/_dotenvx.cmd
  - images/runtime-base/templates/tests/broker-bitwarden.test.sh
  - images/runtime-base/templates/tests/dev-inject.test.sh
  - images/runtime-base/templates/tests/dock.test.sh
  - images/runtime-base/templates/tests/host-run.test.sh
  - images/runtime-base/templates/tests/host-shim.test.sh
  - images/runtime-base/templates/tests/karakuri.test.sh
  - images/runtime-base/templates/tests/loopback-setup.test.sh
  - images/runtime-base/templates/tests/prod-run.test.sh
  - host-tools/broker-bitwarden.sh
  - host-tools/broker-macos-keychain-set.sh
  - host-tools/broker-macos-keychain.sh
  - host-tools/compose.prod.yaml
  - host-tools/dev-inject.sh
  - host-tools/dock.sh
  - host-tools/host-run.sh
  - host-tools/karakuri.sh
  - host-tools/loopback-setup.sh
  - host-tools/prod-run.sh
  - host-tools/loopback/com.karakuri.loopback-aliases.plist
  - host-tools/loopback/karakuri-loopback-aliases
  - host-tools/shims/_dotenvx
  - host-tools/shims/_dotenvx.cmd
  - host-tools/tests/broker-bitwarden.test.sh
  - host-tools/tests/dev-inject.test.sh
  - host-tools/tests/dock.test.sh
  - host-tools/tests/host-run.test.sh
  - host-tools/tests/host-shim.test.sh
  - host-tools/tests/karakuri.test.sh
  - host-tools/tests/loopback-setup.test.sh
  - host-tools/tests/prod-run.test.sh
  - package.json
  - images/runtime-base/tests/distributed-file-modes.test.sh
  - images/runtime-base/tests/template-sync.test.sh
  - images/runtime-base/tests/shipped-symbols.test.sh
  - images/runtime-base/tests/verify-docker.sh
  - .github/workflows/ci.yml
  - docs/conventions.md
  - docs/guarantees.md
  - images/runtime-base/README.md
  - images/devcontainer-base/PORT-FORWARDING.md
  - example/README.md
  - images/runtime-base/.dockerignore
verify:
  - pnpm lint:sh
  - pnpm test
  - test ! -e images/runtime-base/templates/host
  - test ! -e images/runtime-base/templates/tests
  - test -d images/runtime-base/templates/project
---

# ホスト側ツールを images/runtime-base/templates/host から host-tools/ へ移設する

## 内容

ホスト側ツール一式（`images/runtime-base/templates/host/` 配下、`loopback/` と `shims/` を含む）を
トップレベルの `host-tools/` へ、そのテスト（`images/runtime-base/templates/tests/`）を
`host-tools/tests/` へ移す。挙動は変えない。移動と参照の更新だけを行う。

移す理由: ホスト側ツールはイメージの一部ではなく、独立した配布単位である（利用者はこのリポジトリを
`host-tools-v*` タグで `~/.config/karakuri` へ clone し、そこを `PATH` に入れて使う）。
`images/runtime-base/` の下に置くと、イメージの構成物に見える。`.dockerignore` が `templates/` を
外していることが、イメージの外にあるべきものをイメージのディレクトリに置いている印である。
行き先の名前は既存のタグ系列 `host-tools-v*` に揃える。利用者の側は
`~/.config/karakuri/host-tools` になる。

targets が多いのは改名のためである（ゲートは rename 検出を切るので、旧パスの削除と新パスの作成を
両方列挙している）。実体は 22 ファイルの移動と 11 ファイルの参照更新である。

### 手順

1. `git mv` で移す。`images/runtime-base/templates/host/*` → `host-tools/`、
   `images/runtime-base/templates/tests/*` → `host-tools/tests/`。`images/runtime-base/templates/project/`
   は動かさない（プロジェクトのリポジトリへ置くもので、ホスト側ツールではない）。
   `loopback/` と `shims/` はディレクトリごと移す。`loopback-setup.sh` と `karakuri.sh` は自分の隣に
   `loopback/` と `shims/` があることを前提にしており、丸ごと移せば壊れない。
2. `host-tools/tests/*.test.sh` の対象スクリプト解決を直す。現在は `"$TEST_DIR/../host/<script>"` と
   `HOST_DIR="$TEST_DIR/../host"` で隣のディレクトリを指している。移設後は `"$TEST_DIR/../<script>"` と
   `HOST_DIR="$TEST_DIR/.."` になる。
3. `package.json` の `lint:sh:images` と `test` のパスを差し替える。
4. `images/runtime-base/tests/` の 4 本を直す。
   - `distributed-file-modes.test.sh` — `TARGET_DIRS` の要素と `HOST_DIR` の文字列
   - `template-sync.test.sh` — `TEMPLATE` の文字列
   - `verify-docker.sh` — コメントと `COMPOSE_PROD_YAML`、`prod-run.sh` の直接実行パス（12 箇所）
   - `shipped-symbols.test.sh` — strict 検査は `list_files "$IMG_DIR/templates"` で対象を走査しているので、
     ホスト側ツールが `templates/` を出ると**黙って検査対象から外れる**。`host-tools/`
     （`tests/` を含む。現在も `templates/tests` は strict で見ている）を strict の走査対象に加える。
     `list_files` はディレクトリが無ければ落ちるので、加えれば置き場の変更にも追随する。
5. `.github/workflows/ci.yml` の Windows ジョブが呼ぶ `images\runtime-base\templates\host\shims\_dotenvx.cmd`
   を `host-tools\shims\_dotenvx.cmd` にする。
6. 文書のパスを差し替える。意味を変えず、パスだけ直す。
   - `docs/guarantees.md` — 見出し 13〜20 のテストとスクリプトのパス
   - `docs/conventions.md` — 「出荷物のメッセージ言語」の範囲外の指定
   - `docs/guarantee-candidates/0014-host-secret-run.md` — 見出しのパス（候補層はゲートの除外パスなので
     targets には載せていない）
   - `images/runtime-base/README.md` — clone 先の `PATH` 追加・`source` の行を含む 17 箇所。
     `templates/host/` と `templates/project/` を対で説明している段落は、`host-tools/` と
     `images/runtime-base/templates/project/` の対に書き直す
   - `images/devcontainer-base/PORT-FORWARDING.md` — `ProxyCommand` の絶対パス
   - `example/README.md` — ディレクトリ構成図と `source` の行
   - `host-tools/karakuri.sh` 冒頭コメントの `source` パス例
7. `host-tools/tests/dock.test.sh` と `host-tools/tests/karakuri.test.sh` に実行ビットを付ける（100644 → 100755）。
   この 2 本は移設前から shebang を持つのに実行ビットが無かった（他の 6 本は 100755）。旧
   `templates/tests` は配布物の file mode 検査（台帳 §23）の対象外だったが、`host-tools/` に入ると
   検査対象に入り、規約「配布物の実行可能性」（`docs/conventions.md`）に照らして落ちる。
   規約に合わせて直す。実行ビットの変更はこの 2 件だけである。
8. 参照の取りこぼしが無いことを `git grep -n 'templates/host\|templates/tests'` で確かめる。残ってよいのは
   下記スコープ外の 4 ファイルだけである。

### やらないこと

- `docs/host-tools-distribution.md` / `docs/prod-secret-isolation-design.md` /
  `images/runtime-base/migration.md` / `images/runtime-base/verification-record.md` の参照は直さない。
  この 4 本は次のチケットで履歴として凍結する予定で、凍結後は保守しない。
- `.github/workflows/runtime-base.yml` の `paths` 除外 `!images/runtime-base/templates/**` と
  `images/runtime-base/.dockerignore` の除外行は触らない。`host-tools/` は `images/runtime-base/` の外に出るので、
  除外しなくてもイメージのビルドを起こさない。`.dockerignore` のコメントだけは、`templates/` をホスト側の
  雛形と説明していて移設で偽になるので直す（レビュー指摘による軽量裁可）。
- `host-tools-v*` タグの打ち直しはマージ後に人間が行う。リポジトリの変更ではない。
- ホスト側ツールのコメント整理・挙動の変更はしない（別チケット）。例外は 2 つ。手順 7 の実行ビットは、
  移設によって初めて検査に掛かる規約違反を直すものである。`host-tools/loopback-setup.sh` のエラー文
  `copy the whole host/ directory` は、移設で消えた `host/` を案内してしまうので `host-tools/` に直す
  （stderr の文字列だけの変更。レビュー指摘による裁可）。

## 保証

### 新たに宣言する保証

- なし。ファイルの置き場を変えるだけで、利用者に差し出す振る舞いは増えない。clone 先のパスは README
  （使い方）が持つ。

### 維持する保証

- 台帳 §13〜§20（ホスト側ツール 8 本の保証）— テストとスクリプトが揃って移るので、`pnpm test` で全部
  グリーンのまま。テストの対象解決（手順 2）を誤ると空振りで落ちる
- 台帳 §11（出荷物の記号検査）— strict の走査対象からホスト側ツールが外れないこと（手順 4）。
  外れると「1 件も見ずに緑」になる
- 台帳 §12（配布テンプレートと利用例の同期）— `compose.prod.yaml` の新パスで比較が続くこと
- 台帳 §23（配布物の file mode）— `TARGET_DIRS` と `HOST_DIR` の新パスで検査が続くこと

### 廃止する保証

- なし。約束を取り下げる変更ではない。
