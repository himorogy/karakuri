# 0026-env-guard-docs

### `hooks/pre-commit` から他の hook 管理ツールへのチェーン

- テスト未作成 hook はスキャナの後に `.husky/pre-commit` と `.githooks/pre-commit` があれば順に実行し、他の hook 管理ツールを黙って無効にしない（`core.hooksPath` でイメージから全リポジトリへ効かせる構成では `.git/hooks/` が丸ごと無視されるため、この連鎖が落ちると husky / lefthook の per-repo hook が無信号で消える。チェーンの有無も順序も固定するテストが無い）
