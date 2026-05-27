# @himorogy/enclave-env

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
