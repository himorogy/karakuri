---
status: open
type: chore
base: main
targets:
  - images/runtime-base/Dockerfile
verify:
  - pnpm lint:sh
  - bash images/runtime-base/tests/run.sh
  - bash .github/scripts/tests/pin-lag.test.sh
---

# runtime-base が焼く egress-guard を 0.4.0 へ上げる

## 内容

`images/runtime-base/Dockerfile` の `ARG EGRESS_GUARD_VERSION=0.3.0` を `0.4.0` へ上げる（1 行）。
他のファイルには触れない。

### なぜ今上げるか

0031（anthropic バンドルへ `platform.claude.com` を追加）の続きである。

1. `@himorogy/egress-guard@0.4.0` は npm へ公開済み（`npm view @himorogy/egress-guard version` が `0.4.0` を返す）
2. **runtime-base → devcontainer-base の順でタグを打つ。このチケットはその前提となる bump を main へ入れる。** devcontainer-base のタグには 0032（node を proxy グループへ）も乗る
3. karakuri の `.devcontainer/Dockerfile` の pin 上げ、`.devcontainer/docker-compose.yaml` の `group_add` 除去、`.devcontainer/proxy/Dockerfile` の pin 上げ、`verify-l7.sh` へのログイン経路の検査は、devcontainer-base のタグの後に別チケットで行う

公開済みの base はすべて egress-guard 0.3.0 以下を焼いており、anthropic バンドルに `platform.claude.com` を持たない。
base に 0.4.0 を焼かないと、`allowDomains` で自前に足していないプロジェクトは enforce で Claude Code のトークン更新とログインが拒否されたままになる。

### やらないこと

- タグ打ち（runtime-base / devcontainer-base）。マージ後に人間が行う
- karakuri 自身の pin と compose の変更（上記 3）
- `packages/egress-guard/CHANGELOG.md`。0.4.0 の節は 0031 で書いた

### 検収

- タグ後、runtime-base のイメージで `init-project-firewall.sh --print-proxy-acl` が `profile: ["anthropic"]` の設定に対して `platform.claude.com` を出す

## 保証

### 新たに宣言する保証

- なし。base が焼く egress-guard の版は利用側が依存してよい振る舞いではなく、その版の egress-guard が果たす約束（`packages/egress-guard` の台帳行）の担い手が替わるだけである。版を台帳に載せると上げるたびに改訂が要る「上流のリリースノートの写し」になる

### 維持する保証

- pin 監視の行「固定値を読み出せないとき（`ARG` の行が消えた・名前が変わった場合を含む）、`lag` は `pinned-unreadable` を返す」（`docs/guarantees.md` 403 行付近、起源 `0015-pin-refresh-and-monitor-tiers`）——触るのがまさにその `ARG EGRESS_GUARD_VERSION=` の行である。値だけを変えれば読み出しは維持され、bump 後は pin と npm の最新が一致する。行の形を崩すと監視が「読めない」側へ倒れる
- F-a「`anthropic` バンドルを選んだ構成では、Claude Code のログインと、その後のアクセストークンの更新が通る」（起源 `0031`）——base 経由でこの約束を届けるのがこの bump であり、担い手が 0.3.0 から 0.4.0 へ替わる

### 廃止する保証

- なし。版を上げる変更であり、約束を取り下げるものではない
