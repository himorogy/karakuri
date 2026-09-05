# 0018-git-identity-derive

### `devcontainer-base` イメージへの `git-identity-setup` の配置

- テスト未作成 `git-identity-setup` が `devcontainer-base` の `/usr/local/bin` に置かれ、対話シェルの起動時に走る仕組みから名前だけで起動できる（起票時は `postCreateCommand` が実行主体だったが、`0018a` で対話シェルの rc へ移した）（`§22` はリポジトリ上のファイルを `sh` で叩いて導出を固定するだけなので、`COPY` の行き先の綴り違いや PATH 不在といった壊れ方は無信号で通る。`§10` は「イメージ側への配置そのものは `C-2b` が持つ」と書くが、`C-2a` / `C-2b` はどちらも runtime-base 専用で、devcontainer-base のイメージ内容を見るものは台帳に一本も無い）
