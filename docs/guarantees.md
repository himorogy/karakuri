# 保証台帳

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
- `/usr/local/bin/prod-entrypoint.sh`、`secrets-ingest.sh`、`git-askpass`、`git-auth-check`、`git-credential-gh-token`、`prod-context`、`env-guard-scan`、`init-project-firewall.sh`
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

裁可済み節と未検証の約束が持つ起源 `(<チケット id>, <統合の参照>)` は、行ごとではなくセクション単位で置く。既存のセクションへ行を足すチケットは、その行に個別の起源を付ける。
