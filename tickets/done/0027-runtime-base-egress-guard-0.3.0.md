---
status: close
type: chore
base: main
targets:
  - images/runtime-base/Dockerfile
  - packages/egress-guard/CHANGELOG.md
verify:
  - pnpm lint:sh
  - bash images/runtime-base/tests/run.sh
  - bash .github/scripts/tests/pin-lag.test.sh
---

# runtime-base が焼く egress-guard を 0.3.0 へ上げ、CHANGELOG に 0.3.0 を書く

## 内容

2 つを行う。

1. `images/runtime-base/Dockerfile` の `ARG EGRESS_GUARD_VERSION=0.2.0` を `0.3.0` へ上げる（1 行）
2. `packages/egress-guard/CHANGELOG.md` の先頭に `## 0.3.0` の節を足す。0.3.0 は 2026-09-14 に
   npm へ公開済みだが、CHANGELOG の先頭が `## 0.2.0` のまま公開された。公開済みの tarball は
   直せない（CHANGELOG は `package.json` の `files` に含まれないので tarball には元から入って
   いない）が、リポジトリ側の記録として揃える

他のファイルには触れない。

### なぜ今上げるか

0021（karakuri 自身の L7 切替、PR #51）のマージ後に残った順序の 2 番目である。

1. `@himorogy/egress-guard@0.3.0` のタグを打つ —— **済**（Release ワークフロー成功、npm へ 2026-09-14 公開）
2. **runtime-base → devcontainer-base の順でタグを打つ —— このチケットはその前提となる bump を main へ入れる**
3. `.devcontainer/Dockerfile` の pin を `devcontainer-base:edge` の digest から正式版へ戻す（別チケット）
4. ホスト上で `pnpm verify:l7` による検収（別チケット）

公開済みの base はすべて egress-guard 0.2.0 以下を焼いており、`firewall.json` の `version: 2`
（L7 実現層の指定に要る）を `unsupported schema version` で拒否する。base に 0.3.0 を焼かないと、
L7 を選んだ利用側の devcontainer は fail-closed で起動しない。karakuri 自身は先行検証用の
`:edge` ビルドを digest で指してしのいでいる。

### 上げても壊れないことの根拠

egress-guard 0.3.0 は `version: 1` の設定を従来どおり L3 として解釈する。`version` の省略は
0.2.0 でも拒否されていた。したがって、base を利用している既存プロジェクトの `firewall.json`
は書き換えなしで動く。L7 を使うには利用側が `version: 2` へ移り、sidecar
（`packages/egress-guard/templates/proxy/`）を compose に足す必要があるが、それは利用側の
opt-in であり、この bump が強制するものではない。

イメージ側に要る変更が ARG の 1 行だけであることは、公開前検証ブランチ `verify/l7-prepublish`
で確かめてある（tarball から 0.3.0 を入れた runtime-base の上に devcontainer-base を載せ、
別リポジトリで L7 を通した。そのブランチはこのチケットの後に捨てる）。

### CHANGELOG の 0.3.0 節に書くこと

書式は既存の `## 0.2.0` の節に揃える（`### Minor Changes` / `### Patch Changes` の見出し、
太字の要約 1 行 + 説明、必要なら移行手順）。0.x のため破壊的でない機能追加も minor で上げている。
内容は次の Minor 3 項目・Patch 2 項目で、根拠は台帳 `docs/guarantees.md` §4・§5 の該当行（起源 `0019` / `0020` /
`0020a` / `0023`）と `packages/egress-guard/README.md` の現在形の記述にある。
**チケット番号・台帳の節番号は CHANGELOG に書かない**（読み手はこのリポジトリの外にいる）。

`### Minor Changes`

- **設定スキーマ version 2 と実現層（`layer`）の導入。** `version` は `1` と `2` を受理する
  （省略は従来どおり拒否）。`layer` を書けるのは version 2 だけで、`l7`（既定。省略時）と `l3`
  を選べる。**`version: 1` の設定は従来どおり L3 として動き、書き換えは要らない**——移行手順として
  明記する
- **L7 forward proxy 実現層（既定）。** 名前による許可を iptables の IP allowlist から proxy 側の
  ACL へ移す。最終テーブルは proxy 宛の許可・DNS の固定・loopback・`allowCidrs`・`allowHostPorts`
  だけになり、ドメイン由来の ipset も GitHub meta API の取得も無い。`mode: audit` でも OUTPUT は
  `ACCEPT` にならず proxy への到達は強制され、audit の記録は proxy 側のログが担う。sidecar の
  配布物として `templates/proxy/Dockerfile` と `templates/proxy/squid.conf` を追加（ACL と `mode` は
  ビルド時に焼き込み、非 root で起動）。設定から ACL を出す `--print-proxy-acl` を追加。利用側は
  compose に sidecar を足し `http_proxy` / `https_proxy` を配線する必要がある——README の該当節へ
  誘導する
- **先頭ドットのワイルドカード。** version 2 の `allowDomains` は `.example.com`（そのドメイン
  自身とすべてのサブドメイン）を受理する。`*` を含む値は従来どおり拒否し、メッセージが先頭ドットの
  形を示す。`layer: l3` の設定に先頭ドットがあれば拒否する（L3 はサブドメインを列挙できない）。
  先頭ドットのドメインは DNS 解決の対象にせず、`WARNING: failed to resolve` を出さない——この事実は
  ここに含める（先頭ドットの記法自体が 0.3.0 の新規なので、公開済みの版に対する不具合修正としては
  書かない。0.3.0 の開発中にしか存在しなかった panic への落ち方も書かない）

`### Patch Changes`

- 空文字の `allowDomains` / `allowCidrs` エントリを黙って捨てず、理由を述べて拒否する
- npm へ公開される tarball で `scripts/init-project-firewall.sh` の実行ビットが落ちていた
  （0.1.1 / 0.2.0）のを止め、0.3.0 から実行可能なまま届く

### 実装者への注意

- Dockerfile の ARG の値だけを変える。`ARG EGRESS_GUARD_VERSION=` という行の形は変えない
  —— `.github/workflows/monitor.yml` がこの行を `sed -n 's/^ARG EGRESS_GUARD_VERSION=//p'`
  で読んで npm の最新版と照合しており、行の形が変わると監視が黙る
- `RUN npm install -g @himorogy/egress-guard@${EGRESS_GUARD_VERSION}` はそのまま
- Dockerfile 冒頭や周辺のコメントに版の記述は無いので、コメントの追記は要らない

### やらないこと

- **タグは打たない。** `runtime-base-v*` と `devcontainer-base-v*` のタグはマージ後に人間が打つ
  （手順は `images/runtime-base/README.md`「リリース」。runtime-base が先、GHCR の可視性を
  確認してから devcontainer-base）。devcontainer-base は `RUNTIME_BASE_VERSION=1` の浮動タグで
  runtime-base を参照するため、順序を逆にすると古い runtime-base を焼いたまま緑で終わる
- `.devcontainer/Dockerfile` の pin は戻さない。正式版の digest はタグが公開されてからホストで
  `docker buildx imagetools inspect` の index digest を取る必要があり、このチケットの中では
  取れない。別チケットで行う
- egress-guard の README・`docs/` は触らない（0019〜0021 で現在形化済み）。CHANGELOG に書く
  内容がそれらと食い違うと見えたら、CHANGELOG 側を直すのではなく停止して報告する
- `images/devcontainer-base/PORT-FORWARDING.md` の「egress-guard は 0.2.0 で `sshdPort` を
  opt-in にし」は過去の変更点の記述で、0.3.0 でも正しいので触らない
- `images/devcontainer-base/Dockerfile` は触らない。`RUNTIME_BASE_VERSION=1` の浮動参照で
  新しい runtime-base を自動で拾う

## 保証

### 新たに宣言する保証

- なし。base が焼く egress-guard の版は、利用側が依存してよい振る舞いではなく、その版の
  egress-guard が果たす約束（`packages/egress-guard` の台帳行）の担い手が替わるだけである。
  版そのものを台帳に載せると、上げるたびに台帳の改訂が要る「上流のリリースノートの写し」になる

### 維持する保証

- 台帳の pin 監視の行「固定値を読み出せないとき（`ARG` の行が消えた・名前が変わった場合を
  含む）、`lag` は `pinned-unreadable` を返す」（`docs/guarantees.md`、起源
  `0015-pin-refresh-and-monitor-tiers`）—— 今回触るのがまさにその `ARG EGRESS_GUARD_VERSION=`
  の行である。値だけを変えれば読み出しは維持され、bump 後は pin と npm の最新が一致して
  egress-guard の行は遅れ無しの `info` として出る。行の形を崩すと監視が「読めない」側へ倒れる
- 台帳の行「`version` が `1` の設定は L3 実現層として扱われ、最終 IPv4 テーブルは実現層を `l3`
  と明示した version 2 の設定と同一になる」（`docs/guarantees.md`、起源
  `0020-l7-sidecar-and-branch`）—— base を利用する既存プロジェクトの `firewall.json` が
  書き換えなしで動く根拠。担い手が 0.2.0 から 0.3.0 へ替わるだけで、約束は 0.3.0 側の
  テストが固定している

### 廃止する保証

- なし。版を上げる変更であり、約束を取り下げるものではない
