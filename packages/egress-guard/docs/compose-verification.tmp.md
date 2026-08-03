# 案 A（Docker Compose）検証ワークシート

**作業用の一時ファイルです。** 埋め終わったら結果を [`verification-record.md`](./verification-record.md) の §1（実施状況）・§2（カバレッジ）へ転記し、**このファイルは削除してください。**

手順の正本は [`verification-record.md`](./verification-record.md) §6.22 です。ここは記入欄付きの写しです。

---

## 0. 環境

| 項目 | 値 |
|---|---|
| 実施日 | |
| 対象リポジトリ | toganashi |
| ホスト OS / Docker | |
| コンテナ名 / ID | |
| Compose プロジェクト名 | |
| ネットワーク名 | |
| `firewall.json` の `mode` | |

準備。以降のコマンドはすべて**ホストのシェル**から実行します。

```sh
export C=toganashi-dev-container     # docker ps で実名を確認すること
alias inroot="docker exec -u root $C"
alias innode="docker exec $C"
```

> **コンテナを取り違えないでください。** 他プロジェクトの devcontainer が同時に動いています（`shutdownAction: none`）。`docker ps` で ID を確かめてから始めてください。

---

## 1. サマリ

埋めながらチェックしてください。

- [ ] 22.0 マウント先と `workspaceFolder` の一致
- [ ] 22.1 入れ替え
- [ ] 22.2 起動する
- [ ] 22.3 ネットワーク
- [ ] 22.4 `cap_add` が効いている
- [ ] 22.5 埋め込みリゾルバ
- [ ] **22.6 nat の DNS DNAT が壊れない（本命）**
- [ ] 22.7 名前解決
- [ ] 22.8 主要項目の再実施（下に展開）
- [ ] 22.9 戻せる
- [ ] 22.10 `runArgs` が無視される（任意）

---

## 22.0 マウント先と `workspaceFolder` の一致

**確かめること:** `docker-compose.yml` の `volumes` が `<親>:/X`、`devcontainer.json` の `workspaceFolder` が `/X/<リポジトリ名>` になっている。

```sh
grep -n "workspaces\|workspace" .devcontainer/docker-compose.yml .devcontainer/devcontainer.json
inroot ls -la /workspaces/toganashi/.devcontainer/ | head -3
```

**期待:** 両者の `/X` が一致。コンテナ内に `.devcontainer/` が見える。

**結果:**

```
```

**判定:** [ ] 合格 / [ ] 不合格 — メモ:

---

## 22.1 入れ替え

```sh
docker stop $C            # container_name が衝突するため先に止める
cd <toganashi>/.devcontainer
mv devcontainer.json devcontainer.runargs.json
mv devcontainer.compose.json devcontainer.json
```

**判定:** [ ] 済 — メモ:

---

## 22.2 起動する

```sh
provision-devcontainer.sh -w <toganashi>       # または VS Code の Rebuild Container
```

**期待:** `postStartCommand` が成功して起動が完了する。

**結果（末尾数行）:**

```
```

**判定:** [ ] 合格 / [ ] 不合格 — メモ:

---

## 22.3 ネットワーク

```sh
docker inspect -f '{{json .NetworkSettings.Networks}}' $C | jq 'keys'
```

**期待:** Compose が作った 1 本のみ。**`bridge` を含まない。**

**結果:**

```
```

**判定:** [ ] 合格 / [ ] 不合格 — メモ:

---

## 22.4 `cap_add` が効いている

22.2 が成功していること自体が判定です。`iptables` を触れなければ適用が失敗します。念のため直接見るなら:

```sh
docker inspect -f '{{.HostConfig.CapAdd}}' $C
```

**期待:** `[NET_ADMIN NET_RAW]`。

**結果:**

```
```

**判定:** [ ] 合格 / [ ] 不合格 — メモ:

---

## 22.5 埋め込みリゾルバ

```sh
innode grep nameserver /etc/resolv.conf
innode sudo /usr/local/bin/init-project-firewall.sh 2>&1 | grep -iE "DNS pinned|not on a user defined"
```

**期待:** `127.0.0.11`。`DNS pinned to 127.0.0.11`。**`not on a user defined Docker network` の警告が出ない。**

**結果:**

```
```

**判定:** [ ] 合格 / [ ] 不合格 — メモ:

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
```

**判定:** [ ] 合格 / [ ] 不合格 — メモ:

---

## 22.7 名前解決

```sh
innode dig +short api.anthropic.com
```

**期待:** アドレスが返る。

**結果:**

```
```

**判定:** [ ] 合格 / [ ] 不合格 — メモ:

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
```

**判定:** [ ] 合格 / [ ] 不合格 — メモ:

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
```

**判定:** [ ] 合格 / [ ] 不合格 — メモ:

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
```

**判定:** [ ] 合格 / [ ] 不合格 — メモ:

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
```

**判定:** [ ] 合格 / [ ] 不合格 — メモ:

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
```

**判定:** [ ] 合格 / [ ] 不合格 — メモ:

---

## 22.10 `runArgs` が無視される（任意）

README の「`dockerComposeFile` を使うと `runArgs` は無視される」は主張であって検証項目がありません。確かめるなら:

```sh
# devcontainer.json（compose 版）に一時的に足す
#   "runArgs": ["--label=egress-guard-runargs-test=1"]
# 再ビルドしてから
docker inspect -f '{{json .Config.Labels}}' $C | jq 'has("egress-guard-runargs-test")'
```

**期待:** `false`。**`true` なら README の記述が誤り。**

**結果:**

```
```

**判定:** [ ] 合格 / [ ] 不合格 — メモ:

> **確かめたら `runArgs` は消してください。** 効かない記述を構成に残さないためです。

---

## 2. 転記

終わったら次を更新して、このファイルを削除してください。

* [`verification-record.md`](./verification-record.md) §1 実施状況 — 環境・日付・範囲・結果の行を 1 行追加
* [`verification-record.md`](./verification-record.md) §2 カバレッジ — 「未確認」から **Docker Compose 構成での動作** の行を消し、「確認済み」へ移す
* [`verification-record.md`](./verification-record.md) §6.22 — 見出しから **未実施** を外す
* [`README.md`](../README.md) 案 A — 「この構成はまだ実機で検証していません」の但し書きを外す
* [`HANDOFF.md`](./HANDOFF.md) §1.1 と §2 — 該当項目を落とす

**落ちた項目があれば、直す前にまず記録してください。** [`verification-record.md`](./verification-record.md) §3〜§5 の「なぜ捕まらなかったか」を書ける状態にしておくためです。
