# @himorogy/egress-guard

## 0.2.0

### Minor Changes

- **`sshdPort` を opt-in にした。既定値 `22` を廃止。**（**破壊的変更**。0.x のため minor で上げている）

  0.1.x では `sshdPort` の既定値が `22` で、`firewall.json` に書かなくても 22 番の inbound が開いていた。0.2.0 では**指定したときだけ** sshd 規則（INPUT の `NEW` 許可 + 対になる OUTPUT の `ESTABLISHED` 応答）を bootstrap・最終・panic の全テーブルに出す。**書かなければどのテーブルにも出ない。**

  **移行手順:**

  - **listen する sshd を運用している場合** — `firewall.json` に `"sshdPort": 22`（実際に使っているポート番号）を明示する。明示すれば挙動は 0.1.x と同一
  - **`docker exec` で入る運用（`sshd -i` の inetd モードを含む）の場合** — 何もしなくてよい。その経路は iptables を通らない
  - 無効化のために `"sshdPort": 0` と書くことはできない（従来どおり拒否される）。無効化はキーを書かないことで表現する
  - `0`・負値・非整数・文字列・65536 以上を拒否する挙動は従来どおり

  **なぜ:** sshd 規則が bootstrap・panic テーブルにまで入る唯一の inbound 許可として特別扱いされてきた理由は「firewall 適用のどの中間状態でもオペレータの制御チャネルを切らない」ことだった。その制御チャネルが `docker exec` 上の `sshd -i` へ移行し、iptables の管轄外になったため根拠が消滅した。

  加えて、INPUT の default DROP は独立したサービス保護機能ではなく **egress 規制の従属規則**である。inbound 接続を 1 本許すと、以後その接続上の送信は conntrack の `ESTABLISHED` として扱われ、**OUTPUT の allowlist を経由せずにデータを外へ出せる**（逆方向チャネル）。既定で開いていてよい性質のものではない。詳細は `docs/design.md` §2.22。

  **副次的な変更:** `sshdPort` 未指定時の panic テーブルは loopback の 2 行だけになる。設定の読み込みより前に panic へ倒れた場合（所有権違反・スキーマ違反など）は、`sshdPort` を指定していても値が未確定のため sshd 行は入らない。`docker exec` は iptables を経由しないため、どちらの場合もコンテナには入れる。

## 0.1.1

### Patch Changes

- README の導入手順で、パッケージのバージョンを固定するよう改めた。

  - `npm install -g @himorogy/egress-guard@<version>` と版を明示する。このスクリプトは root 所有の `/usr/local/bin` に置かれ、パスワードなし sudo の対象になる。dist-tag のまま追従させると、パッケージ側の更新がそのままコンテナ内 root でのコード実行になる
  - `NPM_CONFIG_PREFIX` を `node` 所有のディレクトリへ移しているイメージでは、`npm install` だけを `node` として実行する必要があることを注記した。root で入れると root 所有のファイルがグローバル領域に混ざり、以後 `node` での `-g install` が権限で失敗する

## 0.1.0

### Minor Changes

- 初回リリース。開発コンテナ向けの allowlist ベース egress ファイアウォール。

  基底プロファイルは選択制で、許可される宛先は `--print-allowlist` で読み出せる。

  - `firewall.json` の `profile` が文字列の配列を受理する。バンドルは `anthropic` / `anthropic-updates` / `openai` / `npm` / `vscode` / `github` の 6 つ。**`profile` を省略すると基底プロファイルは空**で、既定で許可されるドメインは無い
  - `openai`（`auth.openai.com`、`chatgpt.com`）は codex CLI を audit モードで実測して作った。API キー経路（`api.openai.com`）は測っていないため含まない
  - `anthropic-updates`（Claude Code の更新チャネル）を `anthropic` から分けた。バージョンを固定したい利用者は選ばなければよい。遮断しても動作は継続し、更新だけが失敗する
  - **`sentry.io`、`statsig.com`、`console.anthropic.com` はどのバンドルにも入れていない。** いずれも claude-code の devcontainer から引き継いだもので、`audit` でも観測されず、`claude` の実行ファイル（v2.1.221）にも文字列として存在しない。テレメトリが必要なら `allowDomains` に書く。`anthropic` バンドルは `api.anthropic.com` の 1 ドメイン
  - `--print-allowlist` は、基底プロファイルと `firewall.json` をマージした結果を出力する。非特権で実行でき、ネットワークにも触れないため遮断された状態でも読める。一覧は stdout、進捗ログは stderr
  - 「常に許可されているドメイン」を持たないため、ネットワーク生存判定と自己検証のプローブは実行時に決まるアンカードメインを使う。GitHub meta API の CIDR 取得は `github` バンドル選択時のみ行う
  - 宛先の実測手順とバンドルの保守を `docs/measuring-egress.md` にまとめた。3 つの特定方法（DNS 突き合わせ / TLS SAN / 実行ファイルの文字列走査）とそれぞれの限界、記録の汚染を避ける順序、性質別の判断基準、実測記録。**CDN 上では名前を特定しきれないため、候補を `enforce` で動かして確かめるところまでを 1 周とする**
  - エージェント向けの指示は、常時読み込ませる短い断片を README に置き、詳説を `docs/agent-brief.md` に置いた。断片には絶対パスを書かない — 任意のリポジトリにコピーされるものなので、配置に依存させない
