---
status: close
type: fix
base: main
targets:
  - packages/egress-guard/tests/verify-l7.sh
  - packages/egress-guard/poc/l7-proxy/README.md
  - packages/egress-guard/poc/l7-proxy/allowed-domains.txt
  - packages/egress-guard/poc/l7-proxy/docker-compose.poc.yml
  - packages/egress-guard/poc/l7-proxy/Dockerfile.client
  - packages/egress-guard/poc/l7-proxy/Dockerfile.proxy
  - packages/egress-guard/poc/l7-proxy/squid.conf
  - packages/egress-guard/poc/l7-proxy/verify.sh
  - packages/egress-guard/poc/l7-proxy/test-helpers/connect-sniffer.py
  - packages/egress-guard/poc/l7-proxy/test-helpers/ptr-spoof-harness.py
  - packages/egress-guard/poc/l7-proxy/proxy-selection-research.md
verify:
  - pnpm lint:sh
  - bash -n packages/egress-guard/tests/verify-l7.sh
  - test ! -e packages/egress-guard/poc
  - pnpm test
---

# verify-l7.sh のログ検査に allow / deny の区別を入れ、PoC を削除する

## 内容

L7 移行（0019〜0021、0021a）の後始末 2 件。どちらも egress-guard の中で閉じ、検収は
ホストの `pnpm verify:l7` 1 本で済む。

### 1. ログ検査が allow と deny を区別しない

`tests/verify-l7.sh` の `proxy_log_has` は access.log をホスト名で `grep -q` するだけで、
呼び側が「許可の証拠」（先頭ドットの具体名に接続できた）として使う箇所と「拒否の証拠」
（allowlist に無いドメインが拒否された）として使う箇所の両方が同じ関数を呼んでいる。
0021a の否定対照で、接続が失敗して FAIL になっているのにログ検査だけ ok になった。
ホスト名がログに現れることは「proxy まで届いた」しか意味せず、単独では証拠にならない。

squid の既定 logformat（`access_log ... squid`）では、許可した CONNECT は
`TCP_TUNNEL/200 <bytes> CONNECT <host>:443`、拒否は `TCP_DENIED/403 <bytes> CONNECT <host>:443`
と出る（karakuri の sidecar の実ログで確認済み）。同じスクリプトの PTR 偽装検査は既に
`TCP_DENIED.*CONNECT $harness_ip` で拒否を見ている。

変更:

- `proxy_log_has` に期待するステータス（`TCP_TUNNEL/200` / `TCP_DENIED/403`）を第 2 引数で
  渡し、`<status> ... CONNECT <host>:` の形で照合する。ホスト名だけの照合は残さない
- 先頭ドットの検査（`check_leading_dot_domains`）は `TCP_TUNNEL/200` を、拒否の検査
  （`check_denied_domain`）は `TCP_DENIED/403` を期待する。ok / ng のメッセージも
  「許可として残る」「拒否として残る」と区別が読める文言にする
- 期待と逆のステータスで残っている（例: 拒否のはずが `TCP_TUNNEL`）場合は ng。ホスト名が
  ログに無い場合も ng のまま

### 2. `poc/l7-proxy/` の処分

使い捨ての検証環境。判定内容は `verify-l7.sh` へ引き継ぎ済みで、`ptr-spoof-harness.py` も
`tests/` に同一内容の写しがある。npm の配布物（`files`）には元から含まれていない。
実装済みの設計と逆の記述（ACL の bind mount 等）がコメントに残っており、根拠として参照
され続けると誤導する。

- `poc/l7-proxy/` の全ファイルを削除する。`proxy-selection-research.md` も含めて残さない。
  この調査記録が支えていた判断（先頭ドット記法が apex を含む理由、`dstdomain -n`、
  `deny manager`）は、既に `README.md` の「ワイルドカード」の節と `init-project-firewall.sh` /
  `templates/proxy/squid.conf` のコメントに自分の言葉で書かれており、現在形の側から
  この文書を指している箇所は無い。履歴はファイルではなく git のコミットに住む —
  過去チケット（`tickets/done/0019`・`0020`）からのパス参照は履歴として辿れる
- `verify-l7.sh` のコメント 5 箇所（冒頭の由来、`APT_RECHECK_WAIT_SECONDS`、`dev_curl` の
  終了コード 2 の扱い、PTR 偽装の overlay 構成、PTR 偽装の前提条件）が
  `poc/l7-proxy/verify.sh` や `docker-compose.poc.yml` を根拠として参照している。参照先が
  消えるので、根拠となる内容（V3 = apt の再検査間隔、V6 = proxy に届いたことを先に確かめる、
  同名関数で起きた偽陽性の実例、TEST-NET-3 を使う理由）をコメント自身に書き切る形に直す。
  「PoC の〜を参照」という指し方は残さない
- `docs/archive/` の既存文書から `../poc/l7-proxy/` へのリンク 5 本は触らない。履歴層は
  不変で、消えたファイルは git の履歴で辿れる

### やらないこと

- `README.md`・`init-project-firewall.sh`・`firewall-config.test.sh` には触れない。
  GitHub Releases の asset が `release-assets.githubusercontent.com` へ転送される件
  （`github` バンドルには無い）は、セッション中に必要になったときに改めて調べて対応する
- CHANGELOG / changeset は書かない。テストの修正と PoC の削除だけで、配布物の振る舞いは変わらない
- `verify-l7.sh` の他の検査項目・SKIP の扱いは変えない
- karakuri の `.devcontainer/` は触らない

### 検収

ホストで `pnpm verify:l7` が PASS のまま exit 0。否定対照として `.devcontainer/firewall.json`
の先頭ドットのドメイン 1 つを一時的に外して回し、接続の FAIL と同時にログ検査も
FAIL になること（0021a では ok のままだった）。

## 保証

### 新たに宣言する保証

- なし。verify-l7.sh は台帳 B-c の 3 行を確かめる手段であり、検査の精度を上げても
  約束の文は変わらない。PoC の削除は公開面の振る舞いを変えない

### 維持する保証

- B-c の 3 行（proxy を迂回する経路は残らない / 再ビルドまで ACL は変わらない / 先頭ドットの
  具体名に接続でき 2 回目も成立する）。verify-l7.sh を直す変更なので、検査が壊れて
  常に ok になる方向の退行を PR レビューで見る

### 廃止する保証

- なし。取り下げる約束は無い。PoC は台帳のどの行の検査手段でもない
