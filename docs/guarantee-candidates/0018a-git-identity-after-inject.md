# 0018a-git-identity-after-inject

### `devcontainer-base` イメージのシェル起動時の配線

- テスト未作成 対話シェルを起動すると、identity の導出と報告が走る（`§22` はリポジトリ上のファイルを直接 `sh` で叩いてスクリプト自身の振る舞いを固定するだけで、イメージの `/etc/bash.bashrc` / `/etc/zsh/zshrc` が実際にそれを呼ぶかは見ていない。片方の rc にしか足されない、`karakuri-context` より前に置かれる、モードを指定する引数が抜けて毎回取得しにいく、といった壊れ方は無信号で通る）

### `examples/devcontainer.json` の `postCreateCommand`

- テスト未作成 雛形からコンテナを作ると、鍵注入より前の段階では identity に触れない（雛形を実際に devcontainer ツールで起動して確かめるテストが無い）
