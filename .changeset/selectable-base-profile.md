---
"@himorogy/egress-guard": minor
---

基底プロファイルを選択制にし、許可される宛先を読み出す `--print-allowlist` を追加した。

- `firewall.json` の `profile` が文字列の配列を受理する。バンドルは `anthropic` / `anthropic-updates` / `openai` / `npm` / `vscode` / `github` の 6 つ。**`profile` を省略すると基底プロファイルは空**で、既定で許可されるドメインは無い
- `openai`（`auth.openai.com`、`chatgpt.com`）は codex CLI を audit モードで実測して作った。API キー経路（`api.openai.com`）は測っていないため含まない
- `anthropic-updates`（Claude Code の更新チャネル）を `anthropic` から分けた。バージョンを固定したい利用者は選ばなければよい。遮断しても動作は継続し、更新だけが失敗する
- **`"default"` は廃止した。** 旧版で「全バンドル」を意味していた名前で、指定するとバンドルの列挙を促すエラーになる
- **`sentry.io`、`statsig.com`、`console.anthropic.com` をどのバンドルからも外した。** いずれも claude-code の devcontainer から引き継いだもので、`audit` でも観測されず、`claude` の実行ファイル（v2.1.221）にも文字列として存在しない。テレメトリが必要なら `allowDomains` に書く。`anthropic` バンドルは `api.anthropic.com` の 1 ドメインになった
- `--print-allowlist` は、基底プロファイルと `firewall.json` をマージした結果を出力する。非特権で実行でき、ネットワークにも触れないため遮断された状態でも読める。一覧は stdout、進捗ログは stderr
- 「常に許可されているドメイン」が無くなったため、ネットワーク生存判定と自己検証のプローブを、実行時に決まるアンカードメインへ置き換えた。GitHub meta API の CIDR 取得は `github` バンドル選択時のみ行う
- 宛先の実測手順とバンドルの保守を `docs/measuring-egress.md` にまとめた。3 つの特定方法（DNS 突き合わせ / TLS SAN / 実行ファイルの文字列走査）とそれぞれの限界、記録の汚染を避ける順序、性質別の判断基準、実測記録。**CDN 上では名前を特定しきれないため、候補を `enforce` で動かして確かめるところまでを 1 周とする**
- エージェント向けの指示書を作り直した。常時読み込ませる短い断片を README に置き、詳説は `docs/agent-brief.md` へ移した（`templates/AGENTS.md` は削除）。断片には絶対パスを書かない — 任意のリポジトリにコピーされるものなので、配置に依存させない
