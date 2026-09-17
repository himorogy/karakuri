---
status: open
type: fix
base: main
targets:
  - packages/egress-guard/scripts/init-project-firewall.sh
  - packages/egress-guard/tests/firewall-config.test.sh
  - packages/egress-guard/tests/firewall-rules.test.sh
  - packages/egress-guard/README.md
  - packages/egress-guard/templates/proxy/Dockerfile
  - packages/egress-guard/package.json
  - packages/egress-guard/CHANGELOG.md
  - docs/guarantees.md
  - .devcontainer/firewall.json
verify:
  - pnpm lint:sh
  - pnpm test
  - jq -e . .devcontainer/firewall.json
---

# anthropic バンドルに `platform.claude.com` を足し、Claude Code のログインとトークン更新を enforce で通す

## 内容

### 実測した事実

- Claude Code 2.1.274 の OAuth は、認証コードの交換とアクセストークンの更新の両方を `platform.claude.com/v1/oauth/token` へ送る。
  バイナリの strings に `platform.claude.com` は 31 回現れ、`/oauth/authorize`・`/oauth/code/callback`・`/v1/oauth/token` の端点がすべてここにある。
  旧 `console.anthropic.com`（バンドルのコメントが「0 回」と記録している名前）の改名先である
- anthropic バンドルは `api.anthropic.com` の 1 件だけなので、L7 の enforce では上の端点が拒否される
- proxy の access log で確認した経過: トークン更新は約 8 時間周期で `platform.claude.com:443` へ CONNECT する（09-15 17:42、09-16 01:40、09-16 09:37 は通っている）。
  enforce に切り替えた後の 09-16 17:34 と 09-17 14:19 が拒否され、その結果アクセストークンが期限切れになり、再ログインの認証コード交換（09-17 14:49〜15:03、15 回）も同じ名前で拒否された。
  現在は karakuri の proxy を audit で立てて回避している

### 変更

1. `packages/egress-guard/scripts/init-project-firewall.sh` の `BUNDLE_ANTHROPIC` に `platform.claude.com` を足す。
   直上のコメントは観測した版を 2.1.274 に更新し、根拠を strings の出現回数と access log の拒否記録に置き換える。
   入れない名前とその理由もコメントに残す:
   - `releases.claude.com` — バイナリに 10 回現れるが、access log に一度も現れていない
   - `ab.chatgpt.com`・`sdmntprsouthcentralus.oaiusercontent.com` — codex 0.154.0 の `codex login` と `codex exec` を audit で計測したときに 1 回ずつ現れたが、enforce で codex が壊れることは示されていない。
     `oaiusercontent.com` の A レコード 172.64.144.52 は前回の計測で「名前を言えない」として除外した宛先と同じで、今回 CONNECT の対象名として観測できたが、必要性は依然として示されていない
2. バンドルの中身を固定しているテストを新しい中身に合わせる:
   - `tests/firewall-config.test.sh` — `ALL_BUNDLES`（488 行付近）、`bundle_holds anthropic`（556 行付近）、`SUBSET_LISTING`（579〜582 行付近）
   - `tests/firewall-rules.test.sh` — `ALL_BUNDLE_DOMAINS` と件数を書いたコメント（1331〜1339 行付近）、先頭ドットの ACL 出力を 3 行で固定している箇所（1825 行付近）
3. `packages/egress-guard/README.md` のバンドル表（342 行付近）の `anthropic` 行に名前を足す
4. `packages/egress-guard/package.json` の version を `0.4.0` へ上げ、`CHANGELOG.md` の先頭に `## 0.4.0` の節を足す（Minor Changes。enforce で許可される宛先が増えるので、Patch ではなく Minor とする）。
   パッケージに同梱される pin——`templates/proxy/Dockerfile` の `npm install -g @himorogy/egress-guard@0.3.0` と README の導入手順（107 行付近）——を `0.4.0` に揃える
5. `.devcontainer/firewall.json` の `allowDomains` に `platform.claude.com` を足す。
   karakuri 自身は新版のバンドルが base イメージ経由で届くまで待てないので、`allowDomains` で先に通す。
   バンドル経由で同じ名前が届いた後も重複除去されるだけなので、消す必要はない。
   `mode` は `enforce` のまま（作業ツリーの audit は回避のための一時的な変更であり、コミットしない）
6. `docs/guarantees.md` に下の「新たに宣言する保証」の 1 行を、未検証の約束の節として起源 `0031-anthropic-bundle-platform-claude-com` を添えて足す

### やらないこと

- `@himorogy/egress-guard@0.4.0` のタグ打ちと npm 公開。マージ後に人間が行う
- `images/runtime-base/Dockerfile` の `ARG EGRESS_GUARD_VERSION`、devcontainer-base のタグ、karakuri の `.devcontainer/Dockerfile` の pin、`.devcontainer/proxy/Dockerfile` の pin。
  0027 → 0028 → 0029a と同じ型で、公開後に別チケットで順に上げる
- codex 向けの名前の追加。上記のとおり必要性が示されていない
- sshd 経由のシェルが補助グループ 13 を失って proxy の access log を読めない件、proxy イメージの配布形の簡略化。どちらも別チケット

### 検収

ホスト上で proxy を enforce のまま rebuild してから確認する。

- `claude` のログインが通る（認証コードの貼り付け後に proxy の拒否が出ない）
- ログインから約 8 時間後、access log に `platform.claude.com:443` の `TCP_TUNNEL/200` が現れ、セッションが切れない
- `codex exec` が enforce で動く。動かなければ access log の `TCP_DENIED` を読み、示された名前を次のチケットで足す

## 保証

### 新たに宣言する保証

- `anthropic` バンドルを選んだ構成では、Claude Code のログインと、その後のアクセストークンの更新が通る（未検証の約束 (テスト困難: proxy と外向きの到達性が要る。enforce で rebuild した proxy 越しに `claude` のログインと 8 時間後の更新を検収で確認する)）

### 維持する保証

- 「ベンダーのバンドルは互いのホストを持ち込まない。どのバンドルにも属さないホストは一覧にも現れない」（§4）——足す名前は anthropic バンドルにだけ入り、`anthropic` を選ばない構成の一覧には現れない
- 「`--print-proxy-acl` の出力は…profile 由来と `allowDomains` をマージ・ソート・重複除去し…」（§4）——karakuri の `firewall.json` は `allowDomains` とバンドルの両方に同じ名前を持つ状態になり、この行に依存する

### 廃止する保証

- なし。バンドルへの追加だけで、既存の名前と振る舞いはすべて残る
