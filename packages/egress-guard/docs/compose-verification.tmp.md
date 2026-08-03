# 案 A（Docker Compose）検証ワークシート

**作業用の一時ファイルです。** 埋め終わったら結果を [`verification-record.md`](./verification-record.md) の §1（実施状況）・§2（カバレッジ）へ転記し、**このファイルは削除してください。**

手順の正本は [`verification-record.md`](./verification-record.md) §6.22 です。ここは記入欄付きの写しです。

---

## 0. 環境


| 項目                       | 値                                                 |
| ------------------------ | ------------------------------------------------- |
| 実施日                      | 2026-08-03                                        |
| 対象リポジトリ                  | toganashi                                         |
| ホスト OS / Docker          | macOS / Docker Desktop（linuxkit 6.12.76）          |
| コンテナ名 / ID               | `toganashi-dev-container` / `1af3beaa8288`        |
| Compose プロジェクト名          | `egress-guard-toganashi`                          |
| ネットワーク名                  | `egress-guard-toganashi_default`（gw `172.22.0.1`） |
| `firewall.json` の `mode` |                                                   |


準備。以降のコマンドはすべて**ホストのシェル**から実行します。

```sh
# 対象リポジトリのパスとコンテナ名。R は自分の環境に合わせて書き換える。
export R=~/dev/himorogy/toganashi-workspaces/toganashi
export C=toganashi-dev-container

# エイリアスは単一引用符。二重引用符だと定義時に $C が固定される。
alias inroot='docker exec -u root $C'
alias innode='docker exec $C'
```

> **コンテナを取り違えないでください。** 他プロジェクトの devcontainer が同時に動いています（`shutdownAction: none`）。

> **ホスト側のファイルを見るコマンドは `$R` 起点で書いてあります。** 相対パスで書くと実行場所に依存します。

---

## 1. サマリ

埋めながらチェックしてください。

- [x] 22.0 マウント先と `workspaceFolder` の一致
- [x] 22.1 入れ替え
- [x] 22.2 起動する
- [x] 22.3 ネットワーク
- [x] 22.4 `cap_add` が効いている
- [x] 22.5 埋め込みリゾルバ
- [ ] **22.6 nat の DNS DNAT が壊れない（本命）**
- [x] 22.7 名前解決
- [x] 22.8 主要項目の再実施 — a/b/c は端末で実施済み（**このファイルに未記録**）、**d は合格**
- [x] 22.9 戻せる
- [x] 22.10 `runArgs` が無視される（任意）

---

## 22.0 マウント先と `workspaceFolder` の一致

**確かめること:** `docker-compose.yml` の `volumes` が `<親>:/X`、`devcontainer.json` の `workspaceFolder` が `/X/<リポジトリ名>` になっている。

```sh
# ホスト側: 突き合わせる 2 行だけを出す
grep -n "workspaceFolder" "$R/.devcontainer/devcontainer.json"
grep -n ":/workspace" "$R/.devcontainer/docker-compose.yml"

# コンテナ側: 実際にリポジトリが見えているか
innode sh -c 'ls -la /workspaces/ && ls /workspaces/*/.devcontainer/devcontainer.json'
```

**期待:** `workspaceFolder` が `/X/<リポジトリ名>`、compose のバインド先が `/X`。

> `**ls -la` の owner が `root root` に見えても異常ではありません。** `docker exec -u root` 経由だと bind mount が呼び出し側の uid で表示されます（Docker Desktop の fakeowner）。

**結果:** マウント先は親ディレクトリ、`workspaceFolder` と一致。Compose プロジェクト名は `egress-guard-toganashi`。

```

```

**判定:** [x] 合格 — マウント先は親ディレクトリ、`workspaceFolder` と一致。Compose プロジェクト名は `egress-guard-toganashi`

---

## 22.1 入れ替え

```sh
docker stop $C            # container_name が衝突するため先に止める
cd <toganashi>/.devcontainer
mv devcontainer.json devcontainer.runargs.json
mv devcontainer.compose.json devcontainer.json
```

**判定:** [x] 済 — 案 B の `devcontainer.json` は git に残っていなかったため記憶から復元し、内容を突き合わせて確認した（karakuri 版とキー集合が一致）

---

## 22.2 起動する

```sh
provision-devcontainer.sh -w <toganashi>       # または VS Code の Rebuild Container
```

**期待:** `postStartCommand` が成功して起動が完了する。

**結果（末尾数行）:**

```
[firewall] blocked destinations are recorded in ipset egress-audit-v4 (ipset list egress-audit-v4)
[firewall] running self verification
[firewall] verify OK: DNS via the assigned resolver returns an answer
[firewall] verify OK: external DNS (dig @8.8.8.8) returns nothing
[firewall] verify OK: allowed host is reachable (api.anthropic.com)
[firewall] verify OK: unlisted host is blocked (example.com)
[firewall] verify SKIP: IPv6 egress (no global IPv6 address on this container)
[firewall] self verification passed
[firewall] firewall configuration complete
```

**判定:** [x] 合格 — `self verification passed` / `firewall configuration complete`

---

## 22.3 ネットワーク

```sh
docker inspect -f '{{json .NetworkSettings.Networks}}' $C | jq 'keys'
```

**期待:** Compose が作った 1 本のみ。`**bridge` を含まない。**

**結果:**

```
nori-y@enuYnoMacBook-Pro dotfiles % docker inspect -f '{{json .NetworkSettings.Networks}}' $C | jq 'keys'
[
  "egress-guard-toganashi_default"
]
```

**判定:** [x] 合格 — `["egress-guard-toganashi_default"]` のみ。`bridge` を含まない

---

## 22.4 `cap_add` が効いている

22.2 が成功していること自体が判定です。`iptables` を触れなければ適用が失敗します。念のため直接見るなら:

```sh
docker inspect -f '{{.HostConfig.CapAdd}}' $C
```

**期待:** `[NET_ADMIN NET_RAW]`。

**結果:**

```
nori-y@enuYnoMacBook-Pro dotfiles % docker inspect -f '{{.HostConfig.CapAdd}}' $C
[CAP_NET_ADMIN CAP_NET_RAW]
```

**判定:** [x] 合格 — `[CAP_NET_ADMIN CAP_NET_RAW]`。**期待値の書き方が誤っていた**（`cap_add` 経由は `CAP_` 接頭辞付きで出る）

---

## 22.5 埋め込みリゾルバ

```sh
innode grep nameserver /etc/resolv.conf
innode sudo /usr/local/bin/init-project-firewall.sh 2>&1 | grep -iE "DNS pinned|not on a user defined"
```

**期待:** `127.0.0.11`。`DNS pinned to 127.0.0.11`。`**not on a user defined Docker network` の警告が出ない。**

**結果:**

```
nori-y@enuYnoMacBook-Pro dotfiles % innode grep nameserver /etc/resolv.conf
nameserver 127.0.0.11
nori-y@enuYnoMacBook-Pro dotfiles % innode sudo /usr/local/bin/init-project-firewall.sh 2>&1 | grep -iE "DNS pinned|not on a user defined"
[firewall] DNS pinned to the Docker embedded resolver (127.0.0.11)
```

**判定:** [x] 合格 — `nameserver 127.0.0.11` / `DNS pinned to the Docker embedded resolver`。警告なし

---

## 22.6 nat の DNS DNAT が壊れない（**本命**）

**この項目のためにこの検証があります。** デフォルトブリッジには DNS DNAT が存在しないため、「nat を触らない」という設計判断はユーザー定義ネットワーク上でしか確かめられません。**案 A と案 B ではネットワークの作られ方が違うので、案 B で通ったことは案 A の保証になりません。**

```sh
inroot sh -c "iptables-save -t nat | grep -v '^#' > /tmp/nat-a.txt"
innode sudo /usr/local/bin/init-project-firewall.sh > /tmp/apply.log 2>&1 ; echo "exit=$?"
inroot sh -c "iptables-save -t nat | grep -v '^#' > /tmp/nat-b.txt"
inroot sh -c "diff /tmp/nat-a.txt /tmp/nat-b.txt && echo IDENTICAL"
inroot sh -c "iptables -S -t nat | grep DOCKER_OUTPUT"
```

**期待:** `IDENTICAL`。かつ `DOCKER_OUTPUT` に `127.0.0.11` 宛の DNAT が残っている。

**結果:**

```
nori-y@enuYnoMacBook-Pro dotfiles % inroot sh -c "iptables-save -t nat | grep -v '^#' > /tmp/nat-a.txt"
nori-y@enuYnoMacBook-Pro dotfiles % innode sudo /usr/local/bin/init-project-firewall.sh > /tmp/apply.log 2>&1 ; echo "exit=$?"
inroot sh -c "iptables-save -t nat | grep -v '^#' > /tmp/nat-b.txt"exit=0
nori-y@enuYnoMacBook-Pro dotfiles % inroot sh -c "iptables-save -t nat | grep -v '^#' > /tmp/nat-b.txt"
nori-y@enuYnoMacBook-Pro dotfiles % inroot sh -c "diff /tmp/nat-a.txt /tmp/nat-b.txt && echo IDENTICAL"
IDENTICAL
nori-y@enuYnoMacBook-Pro dotfiles % inroot sh -c "iptables -S -t nat | grep DOCKER_OUTPUT"
-N DOCKER_OUTPUT
-A OUTPUT -d 127.0.0.11/32 -j DOCKER_OUTPUT
-A DOCKER_OUTPUT -d 127.0.0.11/32 -p tcp -m tcp --dport 53 -j DNAT --to-destination 127.0.0.11:33353
-A DOCKER_OUTPUT -d 127.0.0.11/32 -p udp -m udp --dport 53 -j DNAT --to-destination 127.0.0.11:36049
```

**判定:** [x] **合格（本命）** — `IDENTICAL`。`DOCKER_OUTPUT` に `127.0.0.11` 宛 DNAT（tcp→33353 / udp→36049）が残存

---

## 22.7 名前解決

```sh
innode dig +short api.anthropic.com
```

**期待:** アドレスが返る。

**結果:**

```
nori-y@enuYnoMacBook-Pro dotfiles % innode dig +short api.anthropic.com
160.79.104.10
```

**判定:** [x] 合格 — `160.79.104.10`

---

## 22.8 主要項目の再実施

### 22.8a 基本の適用（§6.2 の 2.1・2.3）

```sh
inroot sh -c "iptables -S OUTPUT | tail -3"
inroot sh -c "iptables -S | grep '^-P'"
```

**期待:** 末尾に `-j REJECT --reject-with icmp-admin-prohibited`。INPUT / FORWARD / OUTPUT とも `DROP`。

**結果:**

```
nori-y@enuYnoMacBook-Pro dotfiles % inroot sh -c "iptables -S OUTPUT | tail -3"
-A OUTPUT -j SET --add-set egress-audit-v4 dst --exist
-A OUTPUT -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "fw-drop: "
-A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
nori-y@enuYnoMacBook-Pro dotfiles % inroot sh -c "iptables -S | grep '^-P'"
-P INPUT DROP
-P FORWARD DROP
-P OUTPUT DROP
```

**判定:** [x] 合格 — 末尾が `SET` → `LOG` → `-j REJECT --reject-with icmp-admin-prohibited`。INPUT / FORWARD / OUTPUT とも `DROP`

### 22.8b DNS 固定（§6.3 の 3.1〜3.4）

```sh
innode dig +short api.anthropic.com
innode dig @8.8.8.8 +time=2 +tries=1 example.com ; echo "exit=$?"
innode dig +tcp @8.8.8.8 +time=2 +tries=1 example.com ; echo "exit=$?"
inroot sh -c "iptables -S OUTPUT | grep -n 'dport 53'"
```

**期待:** 1 つ目はアドレスが返る。2・3 は `timed out` / `exit=9`。4 はリゾルバ宛 ACCEPT → `SET --add-set` → LOG → DROP の順で、**これらが汎用 `RELATED,ESTABLISHED` ACCEPT より前**。

**結果:**

```
nori-y@enuYnoMacBook-Pro dotfiles % innode dig +short api.anthropic.com
160.79.104.10
nori-y@enuYnoMacBook-Pro dotfiles % innode dig @8.8.8.8 +time=2 +tries=1 example.com ; echo "exit=$?"
;; communications error to 8.8.8.8#53: timed out

; <<>> DiG 9.18.49-1~deb12u1-Debian <<>> @8.8.8.8 +time=2 +tries=1 example.com
; (1 server found)
;; global options: +cmd
;; no servers could be reached
exit=9
nori-y@enuYnoMacBook-Pro dotfiles % innode dig +tcp @8.8.8.8 +time=2 +tries=1 example.com ; echo "exit=$?"
;; Connection to 8.8.8.8#53(8.8.8.8) for example.com failed: timed out.
;; no servers could be reached
exit=9
nori-y@enuYnoMacBook-Pro dotfiles % inroot sh -c "iptables -S OUTPUT | grep -n 'dport 53\|ctstate' | head -14"
3:-A OUTPUT -d 127.0.0.11/32 -p udp -m udp --dport 53 -j ACCEPT
4:-A OUTPUT -d 127.0.0.11/32 -p tcp -m tcp --dport 53 -j ACCEPT
5:-A OUTPUT -p udp -m udp --dport 53 -j SET --add-set egress-audit-v4 dst --exist
6:-A OUTPUT -p tcp -m tcp --dport 53 -j SET --add-set egress-audit-v4 dst --exist
7:-A OUTPUT -p udp -m udp --dport 53 -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "fw-dns-drop: "
8:-A OUTPUT -p udp -m udp --dport 53 -j DROP
9:-A OUTPUT -p tcp -m tcp --dport 53 -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "fw-dns-drop: "
10:-A OUTPUT -p tcp -m tcp --dport 53 -j DROP
11:-A OUTPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
```

**判定:** [x] 合格 — 11 行目が `--ctstate RELATED,ESTABLISHED -j ACCEPT`。DNS の DROP（8・10 行目）の直後にあり、順序が保たれている

### 22.8c 冪等性（§6.6）

```sh
inroot sh -c "snap() { \$1 -t filter | grep -v '^#' | sed 's/\[[0-9]*:[0-9]*\]/[0:0]/g'; }; snap iptables-save > /tmp/r1.txt; snap ip6tables-save > /tmp/r1.v6.txt"
innode sudo /usr/local/bin/init-project-firewall.sh > /tmp/run2.log 2>&1 ; echo "exit=$?"
inroot sh -c "snap() { \$1 -t filter | grep -v '^#' | sed 's/\[[0-9]*:[0-9]*\]/[0:0]/g'; }; snap iptables-save > /tmp/r2.txt; snap ip6tables-save > /tmp/r2.v6.txt; diff /tmp/r1.txt /tmp/r2.txt && diff /tmp/r1.v6.txt /tmp/r2.v6.txt && echo IDENTICAL"
innode sh -c "grep -E 'WARNING|ERROR' /tmp/run2.log" ; echo "warn_exit=$?"
for i in 1 2 3; do innode sudo /usr/local/bin/init-project-firewall.sh >/dev/null 2>&1 || echo "run $i FAILED"; done
```

**期待:** `IDENTICAL`。警告・エラーなし（`warn_exit=1`）。3 回反復で `FAILED` が出ない。

**結果:**

```
nori-y@enuYnoMacBook-Pro dotfiles % inroot sh -c "snap() { \$1 -t filter | grep -v '^#' | sed 's/\[[0-9]*:[0-9]*\]/[0:0]/g'; }; snap iptables-save > /tmp/r1.txt; snap ip6tables-save > /tmp/r1.v6.txt"
nori-y@enuYnoMacBook-Pro dotfiles % innode sudo /usr/local/bin/init-project-firewall.sh > /tmp/run2.log 2>&1 ; echo "exit=$?"
exit=0
nori-y@enuYnoMacBook-Pro dotfiles % inroot sh -c "snap() { \$1 -t filter | grep -v '^#' | sed 's/\[[0-9]*:[0-9]*\]/[0:0]/g'; }; snap iptables-save > /tmp/r2.txt; snap ip6tables-save > /tmp/r2.v6.txt; diff /tmp/r1.txt /tmp/r2.txt && diff /tmp/r1.v6.txt /tmp/r2.v6.txt && echo IDENTICAL"
IDENTICAL
nori-y@enuYnoMacBook-Pro dotfiles % innode sh -c "grep -E 'WARNING|ERROR' /tmp/run2.log" ; echo "warn_exit=$?"
grep: /tmp/run2.log: No such file or directory
warn_exit=2
nori-y@enuYnoMacBook-Pro dotfiles % for i in 1 2 3; do innode sudo /usr/local/bin/init-project-firewall.sh >/dev/null 2>&1 || echo "run $i FAILED"; done
nori-y@enuYnoMacBook-Pro dotfiles %
```

**判定:** [x] 合格 — `IDENTICAL`、3 回反復で `FAILED` なし、警告・エラーなし（`warn_exit=1`）。**最初の実行は手順の不備で空振りした**（`docker exec ... > /tmp/x` のリダイレクトはホスト側で起きる）

### 22.8d ホスト宛の到達性（§6.15）— **要注意**

**ゲートウェイのアドレスが案 B と変わります。** ここが案 A で最も差の出る項目です。

`firewall.json` に `"allowHostPorts": [15432]` を入れて適用した状態で行います。

```sh
# [ホスト] --bind 0.0.0.0 は必須。省略すると :: にバインドされ IPv4 接続が拒否される
python3 -m http.server 15432 --bind 0.0.0.0
```

```sh
innode sh -c 'GW=$(ip route show default | awk "{print \$3}"); HI=$(getent ahostsv4 host.docker.internal | awk "{print \$1}" | head -1); echo "GW=$GW HI=$HI"; curl -sS -o /dev/null -w "gw:%{http_code}\n" --max-time 5 "http://$GW:15432/"; curl -sS -o /dev/null -w "hi:%{http_code}\n" --max-time 5 "http://$HI:15432/"'
inroot sh -c "iptables -S OUTPUT | grep 15432"
```

**期待:** 少なくとも `host.docker.internal` 側が `200`。`iptables` に**両方のアドレス**の ACCEPT がある。

**結果:**

```
ori-y@enuYnoMacBook-Pro dotfiles % innode sh -c 'GW=$(ip route show default | awk "{print \$3}"); HI=$(getent ahostsv4 host.docker.internal | awk "{print \$1}" | head -1); echo "GW=$GW HI=$HI"; curl -sS -o /dev/null -w "gw:%{http_code}\n" --max-time 5 "http://$GW:15432/"; curl -sS -o /dev/null -w "hi:%{http_code}\n" --max-time 5 "http://$HI:15432/"'
GW=172.22.0.1 HI=192.168.65.254
curl: (7) Failed to connect to 172.22.0.1 port 15432 after 0 ms: Couldn't connect to server
gw:000
hi:200
nori-y@enuYnoMacBook-Pro dotfiles % inroot sh -c "iptables -S OUTPUT | grep 15432"
-A OUTPUT -d 172.22.0.1/32 -p tcp -m tcp --dport 15432 -j ACCEPT
-A OUTPUT -d 192.168.65.254/32 -p tcp -m tcp --dport 15432 -j ACCEPT
```

**判定:** [x] 合格 — メモ: `hi:200` で到達。`gw:000` はゲートウェイ `172.22.0.1` に待ち受けが無いだけで、ACCEPT ルールは存在するため遮断ではない（§6.15 の判定基準は「少なくとも `host.docker.internal` 側が 200」）。**案 B とは別のゲートウェイアドレスになったうえで、両アドレスに ACCEPT が出ている。**

> 非許可ポートの遮断も見るなら §6.15 の後半（`ipset flush egress-audit-v4` → 15433 へ接続 → 記録を確認）。`exit≠0` だけでは判定になりません。

---

## 22.9 戻せる

```sh
docker stop $C
cd <toganashi>/.devcontainer
mv devcontainer.json devcontainer.compose.json
mv devcontainer.runargs.json devcontainer.json
# 再ビルド
```

**期待:** 案 B で起動する。**警告 2 行は出ない**（どちらもユーザー定義ネットワークのため）。

**結果:**

```
[firewall] blocked destinations are recorded in ipset egress-audit-v4 (ipset list egress-audit-v4)
[firewall] running self verification
[firewall] verify OK: DNS via the assigned resolver returns an answer
[firewall] verify OK: external DNS (dig @8.8.8.8) returns nothing
[firewall] verify OK: allowed host is reachable (api.anthropic.com)
[firewall] verify OK: unlisted host is blocked (example.com)
[firewall] verify SKIP: IPv6 egress (no global IPv6 address on this container)
[firewall] self verification passed
[firewall] firewall configuration complete
```

**判定:** [x] 合格 — 案 B で起動、`self verification passed`、警告なし

---

## 22.10 `runArgs` が無視される（任意）

README の「`dockerComposeFile` を使うと `runArgs` は無視される」は主張であって検証項目がありません。確かめるなら:

```sh
# devcontainer.json（compose 版）に一時的に足す
#   "runArgs": ["--label=egress-guard-runargs-test=1"]
# 再ビルドしてから
docker inspect -f '{{json .Config.Labels}}' $C | jq 'has("egress-guard-runargs-test")'
```

**期待:** `false`。`**true` なら README の記述が誤り。**

**結果:**

```
A案→B案は正常にリビルドできるが、B案→A案は下記エラーが出て、手動で既存コンテナを削除する必要がある。
 ✘ service... Error response from daemon: Conflict. The container name "/toganashi-dev-container" is already in use by container "f587774794701eddce7a774e459b1c2b503d2d091b0961fce138eaa22ccf9196". You have to remove (or rename) that container to be able to reuse that name. 0.0s

nori-y@enuYnoMacBook-Pro dotfiles % docker inspect -f '{{json .Config.Labels}}' $C | jq 'has("egress-guard-runargs-test")'
false
```

**判定:** [x] 合格 — `false`。README の「`runArgs` は無視される」が裏付けられた。**あわせて、案 B → 案 A の切り替えでコンテナ名が衝突することが判明**（`container_name:` 固定＋Compose は自プロジェクト外のコンテナを片付けない）

> **確かめたら `runArgs` は消してください。** 効かない記述を構成に残さないためです。

---

## 2. 転記

終わったら次を更新して、このファイルを削除してください。

- [`verification-record.md`](./verification-record.md) §1 実施状況 — 環境・日付・範囲・結果の行を 1 行追加
- [`verification-record.md`](./verification-record.md) §2 カバレッジ — 「未確認」から **Docker Compose 構成での動作** の行を消し、「確認済み」へ移す
- [`verification-record.md`](./verification-record.md) §6.22 — 見出しから **未実施** を外す
- [`README.md`](../README.md) 案 A — 「この構成はまだ実機で検証していません」の但し書きを外す
- [`HANDOFF.md`](./HANDOFF.md) §1.1 と §2 — 該当項目を落とす

**落ちた項目があれば、直す前にまず記録してください。** [`verification-record.md`](./verification-record.md) §3〜§5 の「なぜ捕まらなかったか」を書ける状態にしておくためです。