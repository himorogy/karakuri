# @himorogy/egress-guard

## 0.4.0

### Minor Changes

- **`anthropic` バンドルに `platform.claude.com` を足した。** Claude Code（v2.1.274 で実測）のログインとアクセストークン更新は `api.anthropic.com` ではなく `platform.claude.com/v1/oauth/token` へ送られる。`enforce` を選んだ構成では、0.3.0 まではこの端点が拒否され、トークン更新の失敗と再ログインの失敗という形で現れていた。enforce で許可される宛先が増えるため Patch ではなく Minor とする。

## 0.3.0

### Minor Changes

- **設定スキーマ version 2 と実現層（`layer`）を追加した。** `version` は `1` と `2` を受理する（省略は従来どおり拒否）。`layer` を書けるのは version 2 の設定だけで、`l7`（既定。省略時）と `l3` を選べる。

  **移行手順:**

  - **既存の `firewall.json`（`version: 1`）を使っている場合** — 書き換えは要らない。`version: 1` の設定は従来どおり L3 実現層として動く
  - **L7 を使いたい場合** — `version: 2` へ移り、`layer` を省略するか `l7` を明示する。利用側の opt-in であり、この版が強制するものではない

- **L7 forward proxy 実現層を追加した（既定）。** 名前による許可を iptables の IP allowlist から proxy 側の ACL へ移す。最終 IPv4 テーブルは proxy 宛の許可・DNS の固定・loopback・`allowCidrs`・`allowHostPorts` だけになり、ドメイン由来の ipset も GitHub meta API の取得も無い。`mode: audit` でも OUTPUT は `ACCEPT` にならず proxy への到達は強制され、audit の記録は proxy 側のログが担う。

  sidecar の配布物として `templates/proxy/Dockerfile` と `templates/proxy/squid.conf` を追加した。ACL と `mode` はビルド時に焼き込み、非 root で起動する。設定から ACL を出す `--print-proxy-acl` を追加した。

  **移行手順:** 利用側は compose に sidecar を足し、`http_proxy` / `https_proxy` を配線する必要がある。README の「L7 sidecar を用意する」節を参照。

- **先頭ドットのワイルドカードを追加した。** version 2 の `allowDomains` は `.example.com`（そのドメイン自身とすべてのサブドメイン）を受理する。`*` を含む値は従来どおり拒否し、メッセージが先頭ドットの形を示す。`layer: l3` の設定に先頭ドットがあれば拒否する（L3 はサブドメインを列挙できない）。先頭ドットのドメインは DNS 解決の対象にせず、`WARNING: failed to resolve` を出さない。

### Patch Changes

- 空文字の `allowDomains` / `allowCidrs` エントリを黙って捨てず、理由を述べて拒否するようにした。
- npm へ公開される tarball で `scripts/init-project-firewall.sh` の実行ビットが落ちていた（0.1.1 / 0.2.0）のを止めた。0.3.0 からは実行可能なまま届く。

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
