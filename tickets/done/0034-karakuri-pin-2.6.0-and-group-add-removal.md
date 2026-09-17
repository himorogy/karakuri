---
status: close
type: chore
base: main
targets:
  - .devcontainer/Dockerfile
  - .devcontainer/docker-compose.yaml
  - .devcontainer/proxy/Dockerfile
  - packages/egress-guard/tests/verify-l7.sh
verify:
  - pnpm lint:sh
  - bash -n packages/egress-guard/tests/verify-l7.sh
  - pnpm test
---

# karakuri の pin を devcontainer-base 2.6.0 へ上げ、compose の group_add を外す

## 内容

0031〜0033 で配布側に入れた変更（anthropic バンドルへ `platform.claude.com`、`node` を `proxy` グループへ、egress-guard 0.4.0）が
`runtime-base-v1.7.0` → `devcontainer-base-v2.6.0` としてタグ済みである。このチケットは karakuri 自身の devcontainer をその版へ載せ替え、
配布側で解決したものを利用側から取り除く。4 つの変更は独立して着地できない（後述）ので 1 枚で行う。

1. `.devcontainer/Dockerfile` の `FROM` を `ghcr.io/himorogy/devcontainer-base:2.6.0@sha256:379be607b3dd188a236fd4f7deccbeea9ea998e39687e682de8f24c4e8ed6379` へ。
   直前のコメント「2.5.0 を選ぶ理由」「N-1 規律との関係」を 2.6.0 の内容で書き直す。
   選ぶ理由は「`node` が `proxy` グループに入っており（sshd 経由のログインでも proxy のログが読める）、egress-guard 0.4.0 を焼いている（anthropic バンドルに `platform.claude.com`）最初の版」。
   N-1 規律との関係は 2.5.0 のときと同じ形で、検証の事実だけ差し替える——同じソースから `:local` を焼き、この devcontainer 自身で rebuild して確認済み（ssh 経由の `id -Gn` に `proxy`、`/var/log/egress-proxy/access.log` が読める、`platform.claude.com` が `TCP_TUNNEL/200`、`ab.chatgpt.com` が 403、`codex exec` が動く）。
   「次に規律が効くのは 2.7.0 以降で、そのとき karakuri は 2.6.0 に留まる」。
   bootstrap 規律（digest pin）の段落は変えない
2. `.devcontainer/docker-compose.yaml` の `group_add: ["13"]` とその直上のコメント（proxy のログを読むための補助グループの説明）を外す。
   2.6.0 では `/etc/group` で `node` が `proxy` に入っており、`docker exec` 経路でも sshd 経路でも `group_add` に頼らない。
   残すとそれが読める理由に見え、0032 が直した非対称（`group_add` は sshd 経由に届かない）の説明が二重になる
3. `.devcontainer/proxy/Dockerfile` の `npm install -g @himorogy/egress-guard@0.3.0` を `0.4.0` へ。
   直上のコメント（ビルド時にコードを実行するので pin する、`--print-proxy-acl` を持つ最低版）のうち、「package.json in this repo names the lowest one that does」は成り立たなくなっている（`packages/egress-guard/package.json` は 0.4.0、最低版は 0.3.0）ので、0.3.0 が最低版である旨に直す（PR レビューの指示。それ以外の文は変えない）。
   sidecar が焼く ACL の出どころが 0.4.0 になり、`firewall.json` の `allowDomains` に自前で足してある `platform.claude.com` はバンドル側からも出るようになる（`allowDomains` の行は 0031 の判断どおり残す）
4. `packages/egress-guard/tests/verify-l7.sh` に、ログイン経路でも proxy のログが読める検査を足す。
   既存の `proxy_log_has` は `dc exec -T dev` で読んでおり、これは `docker exec` 経路である。
   sshd 経由のログインは `/etc/group` から補助グループを組み直すので、同じ組み直しを起こす `su node -c 'cat /var/log/egress-proxy/access.log'` を root から実行して読めることを検査する（`dc exec -T -u root dev su node -c ...`）。
   否定対照は要らない——`group_add` を外した状態で 2.5.0 に戻せば FAIL する構造であり、検収でそれを一度見る。
   `main()` の並びでは、ファイアウォール適用の直後・`check_apt_first_pass` の前に置く（ログの内容に依らず、読めるかどうかだけを見る）。
   `proxy_log_has` のコメントにある「`group_add: ["13"]` の効果そのものでもある」は、イメージが `node` を `proxy` に入れている旨に書き換える

### なぜ 1 枚か

`group_add` を外すと、`.devcontainer/Dockerfile` が 2.5.0 のままでは `dc exec` 経路でもログが読めなくなり、`verify-l7.sh` の既存検査（`proxy_log_has`）が落ちる。
逆に pin だけ上げて `group_add` を残すと、読める理由の説明が二重になる。
proxy Dockerfile の pin と verify-l7 の検査は単独でも着地できるが、同じ検収（ホストで `pnpm verify:l7`）で見るものなので分けても負荷は減らない。

### やらないこと

- `.devcontainer/firewall.json` の `allowDomains` から `platform.claude.com` を外すこと。バンドルに入ったが、karakuri が明示的に依存する宛先として残す（0031 の判断）
- `images/devcontainer-base/examples/docker-compose.yaml`。0032 で外し済み
- `.github/workflows/monitor.yml` に `.devcontainer/Dockerfile` や proxy Dockerfile の pin 監視を足すこと（monitor は配布を見ない方針）
- runtime-base / devcontainer-base のタグ。打ち済み

### 検収

ホストで `pnpm verify:l7` が PASS のまま exit 0 で、新しい検査の行（ログイン経路の読取）が `ok` で出る。
否定対照として `.devcontainer/Dockerfile` の `FROM` を一時的に 2.5.0 の行へ戻して回し、新しい検査と `proxy_log_has` を使う検査が FAIL になること。

## 保証

### 新たに宣言する保証

- なし。karakuri がどの版の base に pin しているかは利用側が依存する振る舞いではない。sshd 経由でもログが読めることは既存の行（B-a「この記録はエージェントのコンテナから読めるが、書き換えられない」）の範囲であり、読める経路を増やしたのではなく、その行が黙って狭くなっていたのを検査で塞ぐ

### 維持する保証

- B-a「L7 実現層で `mode` が `audit` のとき、proxy は allowlist に無い宛先も通したうえで、その宛先を名前で記録に残す。`enforce` では従来どおり拒否する。この記録はエージェントのコンテナから読めるが、書き換えられない」（`docs/guarantees.md` 502 行付近、起源 `0020-l7-sidecar-and-branch`）——「読める」の担い手が compose の `group_add` からイメージの `/etc/group` へ替わる。verify-l7 の新しい検査はこの行の「読める」を sshd 経由のログインでも見るもので、行の文は変えない
- B-c「`firewall.json` を書き換えても、イメージを再ビルドするまで proxy の判定は変わらない」（`docs/guarantees.md` 510 行付近、起源 `0021-l7-verification-and-cutover`）——proxy Dockerfile の pin を上げてもビルド時に焼く構造は変わらない
- F-a「`anthropic` バンドルを選んだ構成では、Claude Code のログインと、その後のアクセストークンの更新が通る」（起源 `0031`）——karakuri 自身の sidecar でも担い手がバンドル（0.4.0）になる

### 廃止する保証

- なし
