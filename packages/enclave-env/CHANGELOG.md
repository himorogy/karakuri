# @himorogy/enclave-env

## 0.3.0

### Minor Changes

- f417843: Windows で使用できるように調整

### Patch Changes

- c6cd660: devcontainer の雛形で、グローバルにインストールしたコマンドが PATH に載らなくなる問題を直した。

  pnpm 10 はグローバルの実行ファイルを `PNPM_HOME` の直下に置いていたが、pnpm 11 は `PNPM_HOME/bin` に置く。雛形は旧レイアウトを前提に `PATH` を組んでいたため、pnpm 11 の環境では `pnpm add -g` の結果が PATH の通っていないディレクトリに入っていた。

## 0.2.1

### Patch Changes

- 3c99403: README をシナリオベースに再構成。各機能がどのユースケースに対応するかを「できること」セクションで明示。
- 0398101: テストを拡充・整理。

  - `checkContainerNotRunning` / `checkDevContainerNotRunning` の全分岐を fake docker binary でテスト（コンテナ稼働・未稼働・docker 利用不可・DEVCONTAINER スキップ）
  - `init-check-prod.sh` のテストを追加（同方式）
  - TypeScript テストを `src/` から `tests/` に移動し、シェルテストと同一ディレクトリに集約

## 0.2.0

### Minor Changes

- Initial public release.

  - CLI commands: `encrypt`, `decrypt`, `check`
  - Shell scripts for devcontainer security checks (`check.sh`, `init-check-dev.sh`, `init-check-prod.sh`)
  - devcontainer and prod-shell templates
