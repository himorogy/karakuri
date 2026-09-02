# 保証台帳

## Guarantees

### 1. `packages/env-guard/tests/install.test.sh` — `packages/env-guard/bin/env-guard.js`

起源: `0006-ledger-env-guard`

- `install` は、書き込みが1キーの追加で済むときだけ `package.json` を書き換える。追加後のファイルは期待テキストと1バイトの差も無い（既存キーの順序・インデント・末尾改行を含む）（テスト: "pre-commit 未設定 -> 追加した 1 キー以外は 1 バイトも変わらない"）
- 既に `simple-git-hooks` セクションがあるときは、その中へ `pre-commit` を足すだけで、同居する他の hook 設定はそのまま残る
- 導入済みのリポジトリで再実行しても終了コード 0 で、導入済みである旨を出力し `package.json` は1バイトも変わらない（テスト: "2 回目の実行 -> package.json が 1 バイトも変わらない"）
- `simple-git-hooks` が依存に無いときは非ゼロ終了し、依存として入れるためのコマンドを出力し、`package.json` には触れない
- `pre-commit` に別のコマンドが設定済みのときは上書きせずに非ゼロ終了し、現在の値と必要な値の両方を出力する。既存の値はそのまま残る（テスト: "別のコマンドが設定済み -> 既存の値が保たれている"）
- `install --check` は状態を報告するだけで `package.json` を一切書き換えない。未導入なら非ゼロ、導入済みなら 0 で終了する
- `install` は `package.json` に書けたことをもって成功としない。hook が実体化され、その呼び先のファイルが実際に置かれていることまで確かめてから 0 で終了する
- 呼び先のパッケージが `node_modules` に無いときは、`package.json` に書けても hook ファイルが生まれても成功と報告せず、理由を添えて非ゼロ終了する。同じ状態で `--check` も 0 を返さない（テスト: "否定対照: hook の呼び先が無い -> 導入を成功と報告せず非ゼロ終了する"）
- 導入後、平文の値を含む `.env` を stage して commit しようとすると hook が非ゼロで拒否し、どの変数が暗号化されていないかを名前で伝える
- 拒否の出力に平文の値そのものは現れない（テスト: "通し: 拒否の出力に値そのものが出ていない"）
- 暗号化済みの `.env` は通り、検査した件数が出力される
- hook からスキャナへの経路が壊れていて検査できないときは、黙って通さず理由を添えて非ゼロ終了する（テスト: "否定対照: スキャナが見つからない -> 黙って通さず、理由付きで非ゼロ終了する"）
- `core.hooksPath` の指す hook が共有スキャナ `env-guard-scan` を直接呼んでいれば、パッケージ側の hook を経由していなくても `--check` は 0 を返す。スキャナにもパッケージ側の hook にも触れない hook ファイルでは `--check` が非ゼロになる（意図的な緩和。コンテナ内で `--check` が偽陰性になった実測に基づく）
- `install` は、git リポジトリの外、または `git` が PATH に無いときは `package.json` を書き換えず、何も書かなかった旨を出して非ゼロ終了する（テスト: "git repo の外 -> 非ゼロ終了し、何も書かなかったことを出力する"）

### 2. `images/runtime-base/tests/env-guard.test.sh` — `packages/env-guard/bin/env-guard-scan`

起源: `0006-ledger-env-guard`

- 平文の `.env` は非ゼロ終了し、`<パス> line <行番号>: <キー名> is not encrypted` の形で場所とキー名が名指しされる
- 暗号化済みの `.env` は 0 で終了し、検査したファイル数が出力に残る
- 作業ツリーに `.env.keys` があると非ゼロ終了し、そのパスが報告される
- 既定の検査対象は basename が `.env` で始まるものと `secret.env.*`。それ以外の名前は対象外として 0 で通る。既定の許可リストは `.env.container.example` を飛ばし、飛ばしたことが出力に残る
- 平文の値と、`=` を含まない行の内容そのものは、検出時にも出力へ一切反射されない。報告されるのはキー名と行番号だけである（テスト: "the plaintext value is not echoed to the log" / "a line without '=' is not echoed to the log"）
- 1件も検査しなかった実行は黙って 0 を返さず、何も検査しなかったことを明示する
- git リポジトリでない場所では「0件検査して合格」に倒さず非ゼロ終了し、何も検査していないことを説明する（テスト: "a directory that is not a git repo fails instead of passing"）
- リポジトリルートの `env-guard.conf` で検査対象パターンと許可リストを上書きでき、既定では拾わないファイルを拾い、既定では落ちるファイルを許すようになる
- 設定ファイルが壊れているとき（未知のディレクティブ・値の無いディレクティブ・読めない）は既定へ黙って倒れず、行番号付きの理由を添えて非ゼロ終了する（テスト: "an unknown directive fails instead of falling back to the defaults"）
- `env-guard.conf` 自身は、パターンを「全部拾う」に上書きしてもなお検査対象にならない（設定ファイルの中身は暗号化された代入の形を取り得ないため、検査対象になれば必ず落ちる）
- 同じリポジトリに対して CI 側の入口（tracked の一覧）と hook（staged の一覧）は、終了コードだけでなく出力までバイト一致する
- hook は自前の判定を持たず共有スキャナへ委ねる。hook が呼ぶスキャナを差し替えると、合否も終了コードも差し替えた側のものになる（テスト: "the hook passes plaintext when the scanner it calls passes" / "the hook returns the stand-in scanner's own exit code"）。hook 単体でも `pattern` / `allow` の上書きが同じように効く

### 3. `images/runtime-base/tests/hook.test.sh` — `packages/env-guard/hooks/pre-commit`

起源: `0006-ledger-env-guard`

- hook はカレントディレクトリの git リポジトリのルートを自分で決め、そこを起点に `.env.keys` を探す
- リポジトリルート直下の `.env.keys` でもサブディレクトリの `.env.keys` でも非ゼロ終了し、検出したパスがそのまま出力に現れる
- `node_modules` 配下の `.env.keys` は無視する
- `.env.keys` が一つも無ければ、平文でない `.env` 系ファイルが存在していても 0 で通る
- 走査を完走できなかったときは「0件だった」と取り違えて 0 を返さず、理由が読み取れる形で非ゼロ終了する（テスト: "find が失敗したら理由 (検査を完走できなかった) が読み取れる形で非ゼロ終了する"）

## 境界宣言

### 免責

この台帳に載っていない振る舞いは約束ではない。予告なく変わりうる。この台帳は網羅の宣言ではない。

### 公開面の定義

台帳が対象とする面を配布単位で束ね、その下にエントリポイントを列挙する。

**A. `@himorogy/env-guard`（npm パッケージ）**
- `env-guard`（`bin/env-guard.js`）— 導入 CLI
- `env-guard-scan`（`bin/env-guard-scan`）— スキャナ本体
- `hooks/pre-commit` — 配布される commit 前フック

**B. `@himorogy/egress-guard`（npm パッケージ）**
- `scripts/init-project-firewall.sh` — egress firewall の適用 CLI
- `templates/firewall.json` / `firewall.audit.json` / `firewall.example.json` — 利用者がコピーする設定テンプレート

**C-1. `runtime-base` イメージへ焼かれたコードの振る舞い**
- `/usr/local/bin/prod-entrypoint.sh`、`secrets-ingest.sh`、`git-askpass`、`git-auth-check`、`git-credential-gh-token`、`karakuri-context`、`env-guard-scan`、`init-project-firewall.sh`
- `/usr/local/bin/wrangler`、`gh`、`dotenvx`（shim）
- `/usr/local/share/git-hooks/pre-commit`

**C-2. `runtime-base` イメージへの配置そのもの**
- 上記の各ファイルが PATH 上に置かれ、実行可能であること
- `core.hooksPath` が `/usr/local/share/git-hooks` を指すこと
- `init-project-firewall.sh` が root 所有 755 で複製され、sudoers に無引数実行が登録されていること

**D. ホストと利用側リポジトリへ配布されるテンプレート**
- `host/karakuri.sh` — シェルへ source する関数集
- `host/dock.sh`、`host/prod-run.sh`、`host/dev-inject.sh`
- `host/broker-bitwarden.sh`、`host/broker-macos-keychain.sh`、`host/broker-macos-keychain-set.sh`
- `host/loopback-setup.sh` と `host/loopback/` の daemon・plist
- `host/compose.prod.yaml`
- `project/env-guard.conf`、`project/env-guard.yml`

**E. `devcontainer-base` イメージと `examples/` の雛形3本**
公開面と判定するが、対応するテストを持たず、何を約束にすべきかも定めていない。候補層（`docs/guarantee-candidates/`）へ置く。

### 索引の粒度

出典はテストファイル単位とする。テスト名まで下ろすのは、安全性・不可逆性に関わる行に限る。

### 起源の粒度

裁可済み節と未検証の約束が持つ起源は、行ごとではなくセクション単位で置く。既存のセクションへ行を足すチケットは、その行に個別の起源を付ける。

起源に置くのはチケット id だけで、統合の参照（PR 番号など）は併記しない。統合されたチケットは `tickets/done/` に残るため、`git log --diff-filter=A -- tickets/done/<id>.md` で、そのチケットを done へ移したコミット、すなわち統合の実体まで一意に辿れる。id と別に参照を持つと、統合の後に台帳へ追記する手順が要るが、その手順を持つ工程が無い。
