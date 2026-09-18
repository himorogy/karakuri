---
status: close
type: feat
base: main
targets:
  - images/egress-proxy/Dockerfile
  - images/egress-proxy/squid.conf
  - images/egress-proxy/bin/egress-proxy-bake
  - images/egress-proxy/README.md
  - images/egress-proxy/tests/bake.test.sh
  - .github/workflows/egress-proxy.yml
  - .github/workflows/monitor.yml
  - package.json
  - docs/guarantees.md
  - images/runtime-base/tests/shipped-symbols.test.sh # 拡張: 出荷物メッセージ検査の対象に images/egress-proxy/bin が無い
verify:
  - pnpm lint:sh
  - pnpm test
---

# L7 sidecar を配布イメージ egress-proxy にする（イメージ側）

## 内容

**束（0035 → タグ → 0036）。** 0035 がイメージを作り、人間がタグを打って GHCR に出し、0036 が利用側（`packages/egress-guard/templates/proxy/`、
`images/devcontainer-base/examples/`、karakuri 自身の `.devcontainer/`、`verify-l7.sh`、README）をそのイメージへ切り替える。
このチケットは利用側に触れない——公開済みの版が無い段階で切り替えると、利用側が存在しないイメージを参照する。

いま L7 sidecar は雛形 `templates/proxy/{Dockerfile,squid.conf}` を利用側がコピーして持ち、ビルドのたびに `node` イメージで egress-guard を
`npm install` して ACL を焼く。squid の据え方（非 root、`-N`、ACL の場所、mgr 拒否、`dstdomain -n`）は利用側が変える理由の無い部分であり、
利用側に残すべきなのは `firewall.json` から ACL と `mode` を焼く操作だけである。それを prebuilt image + 焼き込みコマンドの形にする。

### 作るもの

1. `images/egress-proxy/Dockerfile` — 2 ステージ。
   - builder: `node:24-bookworm-slim` で `npm install -g @himorogy/egress-guard@${EGRESS_GUARD_VERSION}`（`ARG EGRESS_GUARD_VERSION=0.4.0` をファイル先頭のグローバルスコープに置く。監視が `^ARG EGRESS_GUARD_VERSION=` の形で読む）
   - final: `debian:bookworm-slim` + `squid` + `jq`。builder から `init-project-firewall.sh` を `/usr/local/bin/` へ複製（root 所有 755）。`squid.conf` を `/etc/squid/squid.conf` へ、`bin/egress-proxy-bake` を `/usr/local/bin/egress-proxy-bake` へ（root 所有 755）。`/var/spool/squid` `/var/log/squid` `/run` の作成、`EXPOSE 3128`、`USER proxy`、`ENTRYPOINT ["squid","-N","-f","/etc/squid/squid.conf"]` は雛形と同じ
   - **焼き込みの出力先 2 つ（`/etc/squid/allowed-domains.txt`、`/etc/squid/squid.conf`）は `proxy:proxy` 所有にする。** 利用側の `dockerfile_inline` は `FROM` の後 `USER proxy` のまま `RUN egress-proxy-bake` を打つので、そこで書けなければ利用側に `USER root` / `USER proxy` の 2 行が要る。実行時は compose の `read_only: true` が書き込みを塞ぐ（B-b の「実行中のコンテナに ACL を差し替える経路を持たない」はこれと、restart で再読込しない構造の 2 つで成り立つ。0036 で README に載せる）
   - final は node を持たない。ACL 生成は bash + jq で足りる（`init-project-firewall.sh` は bash スクリプトで、`--print-proxy-acl` が使う外部コマンドは jq のみ）
2. `images/egress-proxy/squid.conf` — `templates/proxy/squid.conf` と同一内容。0036 で雛形側を消すまで 2 か所に存在する
3. `images/egress-proxy/bin/egress-proxy-bake` — 利用側が `RUN egress-proxy-bake /firewall.json` で呼ぶ。
   - `init-project-firewall.sh --check-config --config <path>` → 非ゼロならそのまま非ゼロで終わる
   - `--print-proxy-acl` の出力を一時ファイルへ書いてから `/etc/squid/allowed-domains.txt` へ移す（途中で失敗した状態の ACL を残さない）
   - `jq -r '.mode // "enforce"'` が `audit` なら `squid.conf` の `http_access deny !allowed` を `allow !allowed` へ書き換え、書き換わったことを `grep` で確かめる（雛形の Dockerfile と同じ手順）
   - 引数が無い・ファイルが無いときは usage を stderr に出して非ゼロ。メッセージは英語（`docs/conventions.md`「出荷物のメッセージ言語」）
   - **リポジトリ上で 100755 にする**（配布物。`images/runtime-base/bin/*` と同じ扱い。`distributed-file-modes.test.sh` の型を参照）
4. `images/egress-proxy/tests/bake.test.sh` — docker 無しで走る。`PATH` の先頭に `packages/egress-guard/scripts/` を置き、出力先を環境変数（`EGRESS_PROXY_SQUID_DIR` のような 1 つ）で一時ディレクトリへ向けて `egress-proxy-bake` を呼ぶ。
   検査: (a) `templates/firewall.json` で ACL が `--print-proxy-acl` の出力と一致し `squid.conf` は `deny !allowed` のまま、(b) `templates/firewall.audit.json` で `allow !allowed` になる、(c) 壊れた JSON で非ゼロ、かつ ACL ファイルが作られない、(d) 引数無しで非ゼロ。
   ランナーは `images/runtime-base/tests/run.sh` の形に倣うが、1 本なので直接 `bash images/egress-proxy/tests/bake.test.sh` を `package.json` の `test` に足す。`lint:sh:images` に `images/egress-proxy/bin/*`（sh）と `images/egress-proxy/tests/*.sh`（bash）を足す
5. `images/egress-proxy/README.md` — 何を焼いてあるか、利用側の書き方（compose の `dockerfile_inline` 3 行: `FROM ghcr.io/himorogy/egress-proxy:1` / `COPY firewall.json /firewall.json` / `RUN egress-proxy-bake /firewall.json`）、
   リリース節（`images/devcontainer-base/README.md`「リリース」の型。タグ `egress-proxy-v*` → `:1` / `:1.0` / `:1.0.0` / `sha-`。runtime-base / devcontainer-base とは独立で順序の縛りは無い）。GHCR のパッケージを public にする初回の手順は README に書かない（PR レビューの指示）。
   設計の理由は書かない（`packages/egress-guard/docs/design.md` が持つ）
6. `.github/workflows/egress-proxy.yml` — `runtime-base.yml` の型（tag push / pull_request 検証のみ / workflow_dispatch で `:edge`、action は SHA 固定、multi-arch、metadata-action の semver 3 行）。
   paths は `images/egress-proxy/**`（`*.md` 除外）とこの workflow 自身。
   smoke test は push 後の両アーキで、(a) `--entrypoint egress-proxy-bake` を `templates/firewall.json` に対して走らせて 0 で終わる、(b) その結果に対し `squid -k parse` が通る、の 2 つ。
   build-context は要らない（egress-guard は npm から取る）
7. `.github/workflows/monitor.yml` — `EGRESS_GUARD_VERSION` の pin 監視を `images/egress-proxy/Dockerfile` にも掛ける（runtime-base の行と同じ `report_lag_no_advisory` の呼び出しを 1 つ足す）
8. `docs/guarantees.md` — 「公開面の定義」に **C-3. `egress-proxy` イメージ** を足す（`/usr/local/bin/egress-proxy-bake`、`/etc/squid/squid.conf`）。保証節の新規宣言を裁可済み節へ

### やらないこと

- 利用側の切り替え（`templates/proxy/` の削除、examples、karakuri の `.devcontainer/proxy/`、`verify-l7.sh`、egress-guard README の「L7 sidecar を用意する」節）。0036
- タグ打ち・GHCR の public 化。マージ後に人間が行う
- restart で ACL を再読込する経路。焼き込みを維持する（理由は 0036 で README に載せる）
- egress-guard の版上げ・CHANGELOG。イメージが焼く版は 0.4.0 のまま

### 検収

タグ後、ホストで `docker buildx build` を使わずに次が通る:

```sh
printf 'FROM ghcr.io/himorogy/egress-proxy:1\nCOPY firewall.json /firewall.json\nRUN egress-proxy-bake /firewall.json\n' \
  | docker build -t ep-test -f - .devcontainer
docker run --rm --entrypoint sh ep-test -c 'id -u; cat /etc/squid/allowed-domains.txt | head -3; grep -c "deny !allowed" /etc/squid/squid.conf'
```

`13`、ACL の先頭に `api.anthropic.com`、`1` が出る。否定対照: `firewall.json` を壊した context では `docker build` が非ゼロで止まる。

## 保証

### 新たに宣言する保証

- `egress-proxy-bake` は、設定が `--check-config` を通らないとき非ゼロで終わり、ACL を書かない（テスト: "壊れた設定では非ゼロで終わり ACL を作らない"）
- `egress-proxy-bake` が書く ACL は、同じ設定に対する `init-project-firewall.sh --print-proxy-acl` の出力と一致する。`mode` が `audit` のときだけ、allowlist 外の宛先を通す（テスト: "ACL は --print-proxy-acl の出力と一致する" / "audit では allowlist 外を通す設定になる" / "enforce では拒否のまま"）
- イメージは `squid` を非 root（uid 13）で起動する（`未検証の約束 (テスト困難: CI の egress-proxy ワークフローが push 済みイメージで smoke test する)`）——B-b の同じ文の担い手が、0036 以降はこのイメージになる。ここでは C-3 の行として置き、B-b は 0036 で担い手の交替を書く

### 維持する保証

- B-b「proxy のイメージは非 root（uid 13）で起動し、ACL をビルド時に焼き込むため、実行中のコンテナに ACL を差し替える経路を持たない」（`docs/guarantees.md` 508 行付近、起源 `0020-l7-sidecar-and-branch`）——このチケットでは利用側に触れないので担い手は雛形のまま。新イメージは同じ据え方を持つ
- B-c「`firewall.json` を書き換えても、イメージを再ビルドするまで proxy の判定は変わらない」（510 行付近、起源 `0021-l7-verification-and-cutover`）——同上
- pin 監視「固定値を読み出せないとき…`pinned-unreadable`」（403 行付近、起源 `0015-pin-refresh-and-monitor-tiers`）——新しい Dockerfile の `ARG EGRESS_GUARD_VERSION=` を同じ読み出しに掛ける。形を崩さない

### 廃止する保証

- なし
