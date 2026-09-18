---
status: open
type: feat
base: main
targets:
  - packages/egress-guard/templates/proxy/Dockerfile
  - packages/egress-guard/templates/proxy/squid.conf
  - packages/egress-guard/package.json
  - packages/egress-guard/CHANGELOG.md
  - packages/egress-guard/README.md
  - packages/egress-guard/tests/verify-l7.sh
  - images/devcontainer-base/examples/docker-compose.yaml
  - .devcontainer/proxy/Dockerfile
  - .devcontainer/proxy/squid.conf
  - .devcontainer/docker-compose.yaml
  - docs/guarantees.md
verify:
  - pnpm lint:sh
  - bash -n packages/egress-guard/tests/verify-l7.sh
  - pnpm test
---

# L7 sidecar の利用側を配布イメージ egress-proxy へ切り替える

## 内容

0035 の続き。
`ghcr.io/himorogy/egress-proxy:1.0.0`（index digest `sha256:99c49a3c3b26ac1b972985e80f47766d4b9301f97ff2ae7348239bc86b472551`）が公開済みで、利用側の書き方は `images/egress-proxy/README.md` にある（compose の `dockerfile_inline` 3 行）。
このチケットは雛形のコピー方式を持つ利用側をすべてその形へ切り替え、雛形を消す。
切り替えは相互に依存する（雛形を消すと `verify-l7.sh` と karakuri 自身の compose が壊れ、README と examples は雛形を指している）ので 1 枚で行う。

### 変えるもの

1. `packages/egress-guard/templates/proxy/Dockerfile` と `squid.conf` を削除する。
   `package.json` の `files` は `templates` をディレクトリごと含むので編集しない（`templates/*.json` は残る）。
   配布物が減るので `version` を `0.5.0` へ上げ、`CHANGELOG.md` の先頭に `## 0.5.0` の節を足す（`### Minor Changes`。雛形の削除と、sidecar が配布イメージになったこと、移行手順として README の節を指す。0.3.0 の節の書き方に倣う）。
   publish はマージ後に人間が行う
2. `packages/egress-guard/README.md`「L7 sidecar を用意する」（297 行付近）を書き直す。
   雛形のコピーの指示を、`dockerfile_inline` 3 行（`FROM ghcr.io/himorogy/egress-proxy:1` / `COPY firewall.json /firewall.json` / `RUN egress-proxy-bake /firewall.json`）と `images/egress-proxy/README.md` への参照に置き換える。
   `dev` 側に足す 3 つ（`depends_on`、proxy 変数、ログの volume）と「ACL と `mode` はビルド時に焼き込まれる。実行中のコンテナに差し替える経路は無い」はそのまま残す。
   焼き込みの段落に 1 文足す——`restart` で設定を再読込させたくなるが、そうすると sidecar を落とすことが `firewall.json` の再読込になり、`dev` から 3128 へ到達できる以上それはエージェントに届く面になる（`docs/archive` の設計書ではなく README に置くのは、利用者が思いつく操作だから）。
   節の他の文（`l3` では不要、git の ssh の注意、保証の参照）は変えない。
   `templates/proxy/Dockerfile` を名指す 307 行付近も同じ節の中なので一緒に直る
3. `images/devcontainer-base/examples/docker-compose.yaml` の `egress-proxy` service（169 行付近〜）。
   `build.dockerfile: proxy/Dockerfile` を `dockerfile_inline` 3 行（`FROM ghcr.io/himorogy/egress-proxy:1`）へ。
   `context: .` と `pull: true` は残す（`firewall.json` を COPY するため context は要る。`pull` は浮動タグ `:1` を追随させる）。
   雛形のコピーに触れるコメント（169 行付近の「`packages/egress-guard/templates/proxy/` が実体」、184 行付近の `templates/proxy/Dockerfile` への参照）を `images/egress-proxy/` を指す形に直す。
   実行時の縛り（`cap_drop` / `no-new-privileges` / `user: "13:13"` / `read_only` / `tmpfs`）は変えない
4. karakuri 自身: `.devcontainer/proxy/Dockerfile` と `squid.conf` を削除し、`.devcontainer/docker-compose.yaml` の `egress-proxy` service を `dockerfile_inline` 3 行へ。
   `FROM` は `ghcr.io/himorogy/egress-proxy:1.0.0@sha256:99c49a3c3b26ac1b972985e80f47766d4b9301f97ff2ae7348239bc86b472551`（digest pin。`dev` の base と同じ bootstrap 規律で、このリポジトリはイメージの配布元なので浮動タグを使わない）。
   `pull: true` は外す（digest pin では意味を持たない。`dev` 側と同じ扱い）。
   ヘッダコメント 9〜21 行付近（「写し」であることと symlink にしない理由）は前提が消えるので削除し、`egress-proxy` service の直前に digest pin の理由を 2〜3 行で書く（`dev` の Dockerfile の pin コメントを指し、初版なので N-1 の判断は無い旨）。
   158 行付近の `templates/proxy/Dockerfile` への参照は `images/egress-proxy/Dockerfile` へ
5. `packages/egress-guard/tests/verify-l7.sh`。
   `PROXY_TEMPLATE_DIR`（20 行付近）を消し、依存している 3 か所を作り直す。
   - `check_acl_needs_rebuild`（313 行付近〜）: 雛形の Dockerfile で `docker build` している。`.devcontainer/docker-compose.yaml` の `egress-proxy` と同じ `FROM`（digest pin）を持つ 3 行の Dockerfile を一時 context に書いて `docker build` する形へ。`FROM` の行は compose から読み出す（compose と別に版を持たない）
   - `check_config_fail_closed`（377 行付近〜）: 壊す元の `squid.conf` を雛形から読んでいる。compose でビルド済みの `egress-proxy` イメージから取り出す（`dc run --rm --entrypoint cat egress-proxy /etc/squid/squid.conf` の形）。`images/egress-proxy/squid.conf` を読まない——ソースは pin した版と一致するとは限らない
   - `check_ptr_spoof`（441 行付近〜）の overlay: `build.dockerfile: proxy/Dockerfile` で `.devcontainer` からビルドしている。ビルド済みの compose イメージ（`karakuri-verify-l7-egress-proxy`）を `image:` で使うか、同じ `dockerfile_inline` を overlay に書くかは実装者が選ぶ（前者なら二重ビルドが消える）
   - `check_acl_absent_in_dev`（271 行付近）のコメントにある `templates/proxy/` の言及を `images/egress-proxy/` へ
6. `docs/guarantees.md`。
   - 公開面の定義 B 節（561 行付近）の `templates/proxy/Dockerfile` / `templates/proxy/squid.conf` の行を消す（C-3 が同じものを持つ）
   - C-3a（541 行付近）の「B-b の同じ文の担い手が、0036 以降はこのイメージになる。ここでは 25 の行として置き、B-b は 0036 で担い手の交替を書く」を、担い手がこのイメージである現在形の 1 文に直す（番号の先読みを消す）
   - B-b の行（515 行付近）の文は変えない

### やらないこと

- `.github/workflows/monitor.yml`。`images/egress-proxy/Dockerfile` の pin 監視は 0035 で入っており、雛形側の監視は元から無い
- `images/egress-proxy/` 自体の変更
- npm publish（`@himorogy/egress-guard@0.5.0`）。マージ後に人間が行う
- runtime-base / devcontainer-base のタグ。egress-guard の版を焼き直す必要はない（`templates/proxy/` はイメージに焼かれていない）

### 検収

ホストで `pnpm verify:l7` が PASS のまま exit 0（`check_acl_needs_rebuild` / `check_config_fail_closed` / `check_ptr_spoof` を含む）。
否定対照として `.devcontainer/firewall.json` の先頭ドットのドメイン 1 つを一時的に外して回し、接続の FAIL と同時にログ検査も FAIL になること（0030 の検収と同じ）。
その後 karakuri 自身を rebuild し、`dev` から `platform.claude.com` が `TCP_TUNNEL/200`、`ab.chatgpt.com` が 403。

## 保証

### 新たに宣言する保証

- なし。利用側の据え方が変わるだけで、sidecar の約束（B-a / B-b / B-c）と bake の約束（25）は既にある

### 維持する保証

- B-b「proxy のイメージは非 root（uid 13）で起動し、ACL をビルド時に焼き込むため、実行中のコンテナに ACL を差し替える経路を持たない」（`docs/guarantees.md` 515 行付近、起源 `0020-l7-sidecar-and-branch`）——担い手が雛形（利用側がコピーした Dockerfile）から配布イメージ + `egress-proxy-bake` へ替わる。文は変えない
- B-c「`firewall.json` を書き換えても、イメージを再ビルドするまで proxy の判定は変わらない」（522 行付近、起源 `0021-l7-verification-and-cutover`）——`dockerfile_inline` でも焼き込みはビルド時で、`verify-l7.sh` の `check_acl_needs_rebuild` を作り直してこの行を見続ける
- B-a「…この記録はエージェントのコンテナから読めるが、書き換えられない」（498 行付近）——ログの volume と `read_only` は変えない
- 25「`egress-proxy-bake` は…」の 2 行（起源 `0035-egress-proxy-image`）——利用側がこの入口を使い始める

### 廃止する保証

- なし。公開面の定義から `templates/proxy/` の行が消えるが、その振る舞いは C-3（`egress-proxy` イメージ）が引き継ぐ
