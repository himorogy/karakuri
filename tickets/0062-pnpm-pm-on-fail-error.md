---
status: open
type: feat
base: main
targets:
  - images/runtime-base/Dockerfile
  - images/runtime-base/README.md
  - images/devcontainer-base/README.md
  - .github/workflows/runtime-base.yml
  - docs/conventions.md
  - docs/guarantees.md
verify:
  - pnpm lint
  - pnpm test
---

# packageManager の版が焼いた pnpm と違うとき、別の版を取得せずに止める

## 内容

runtime-base は pnpm を `ARG PNPM_VERSION` で固定して焼いている。
ところが pnpm は、cwd の `package.json` の `packageManager` が自分と違う版を指していると、その版を取得して切り替える（self-switch）。
dev では allowlist の `npm` profile を通って取得が成功するので、焼いた版ではなくプロジェクトが pin した版が静かに走る。
base の版上げで `packageManager` を直し損ねたプロジェクトは、古い版を取得し続けても気づかない。
prod でも同じ切り替えが起き、切り替えた先の版の挙動で落ちた記録がある（`images/runtime-base/bin/prod-entrypoint.sh` の store-dir のコメント）。

この枚では、版が食い違ったときに取得せず止まるようにする。`packageManager` を書く運用は残し、食い違いをその場で見えるようにする。

- runtime-base の Dockerfile に `ENV pnpm_config_pm_on_fail=error` を焼く。devcontainer-base は runtime-base を FROM するので両方に効く
- `docs/conventions.md`「環境変数の置き場」のイメージの `ENV` に置くものへ、この変数を理由とともに足す。理由は、焼いた pnpm と違う版を静かに取得させないための設計判断であり、外すのは版をあえて固定するプロジェクトだけ、ということ
- runtime-base の README に、版が食い違ったときの挙動と逃げ道を書く。逃げ道は compose の `environment:` で `pnpm_config_pm_on_fail` を上書きすること（`download` で従来の切り替えに戻る）。base の版上げで pnpm が変わったら `packageManager` も直す必要があり、直し損ねるとエラーで知らせる、ということも書く
- devcontainer-base の README の検証チェックリストにある「pnpm が packageManager と一致しているか」と、既存プロジェクトの載せ替えの節を、この挙動に合わせて直す
- runtime-base workflow の push 後の smoke test に、両アーキで検査を足す。`--network none` の下で、焼いた版と違う `packageManager`（たとえば `pnpm@10.9.0`）を書いた `package.json` を置いたディレクトリで `pnpm --version` が非ゼロで終わり、出力に `ERR_PNPM_BAD_PM_VERSION` が出ること。`--network none` だけでは既定の挙動でも取得の失敗で非ゼロになるので、エラーの種類で切り分ける
- 台帳 C-2a に、下の「新たに宣言する保証」の1行を足す

pnpm の挙動は 2026-10-18 に pnpm 12.11.2 で実測した。

- 設定なしで `packageManager: pnpm@10.9.0` のディレクトリで `pnpm --version` を打つと、10.9.0 を取得して `10.9.0` を返す
- 環境変数 `pnpm_config_pm_on_fail=error`（大文字の `PNPM_CONFIG_PM_ON_FAIL` でも同じ）を置くと `ERR_PNPM_BAD_PM_VERSION` で rc=1 になる。`npm_config_pm_on_fail` は効かない
- 環境変数で `error` にしたとき、プロジェクトの `pnpm-workspace.yaml` の `pmOnFail: download`、`.npmrc` の `pm-on-fail=download`、`devEngines.packageManager` の `onFail: "download"` のどれでも覆らない。覆るのは CLI の `--pm-on-fail=` だけ
- global の `config.yaml` に `pmOnFail: error` を書く方法は、プロジェクトの `pnpm-workspace.yaml` で覆るので採らない
- `packageManager` が無いとき、および焼いた版と一致するときは、そのまま走る
- 旧設定名（`manage-package-manager-versions` / `package-manager-strict-version`）は pnpm 11 で廃止され、`pmOnFail` に統合されている

版は minor とする（runtime-base-v2.1.0 → devcontainer-base-v3.1.0）。
食い違いで止まるのは、v2 / v3 への移行で `packageManager` を揃えることを求めていたのに揃っていなかったプロジェクトであり、エラーが原因と回避を示すため。
タグはこの枚のマージ後に人間が runtime-base、devcontainer-base の順で打つ。

### やらないこと

- タグを打つこと・push すること
- karakuri 自身の devcontainer の pin を上げること。今の pin（2.7.0）ではこの変数は効かない
- `prod-entrypoint.sh` が store-dir を2形式で書く処理と、そのコメントを変えること。逃げ道で切り替えた版が rc を読む経路は残る
- `node_modules/.bin/pnpm` や global の上書き（`pnpm add -g pnpm` 等）で別の pnpm が走る経路を塞ぐこと
- CI やホストなど、イメージの外で走る pnpm の挙動
- 雛形の compose（`images/devcontainer-base/examples/`）に逃げ道の行を足すこと
- smoke test で、逃げ道（compose での上書き）が効くことまで検査すること

## 保証

### 新たに宣言する保証

- `package.json` の `packageManager` が焼いた pnpm と異なる版を指すディレクトリでは、pnpm がその版を取得して切り替えず、非ゼロで止まる（台帳 C-2a に追加。`未検証の約束 (テスト困難: CI の runtime-base ワークフローが、push 済みイメージを両アーキで smoke test する)`）

### 維持する保証

- 台帳 C-2a の既存の行（shim の位置、secret 不在での `dotenvx`、`core.hooksPath`、実行可能なファイル）。smoke test に検査を足すだけで既存の検査は変えない
- 台帳 §6 の「起動中に pnpm は一度も実行されない」と store の設定を2形式で書く行。entrypoint には触れない

### 廃止する保証

- なし
