# 0017-devcontainer-cli-env

### `devcontainer-base` イメージの環境変数が SSH セッションへ届く経路

- テスト未作成 devcontainer ツールで作ったコンテナでは、イメージの `ENV` と compose の `environment:` の両方が SSH セッションにも同じ値で届く（sshd は自分の environ を引き継がないため、届く経路は `/etc/environment` への写し込みだけである）
- 要精査 `git-auth-check` の報告は対話シェルの起動時にしか出ないため、非対話の SSH 実行では認証固定が外れていても検知されない。塞ぐには呼び出し主体の設計が要る
