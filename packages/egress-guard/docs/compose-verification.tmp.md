# 案 A（Docker Compose）検証ワークシート

**作業用の一時ファイルです。** 埋め終わったら結果を [`verification-record.md`](./verification-record.md) の §1（実施状況）・§2（カバレッジ）へ転記し、**このファイルは削除してください。**

手順の正本は [`verification-record.md`](./verification-record.md) §6.22 です。ここは記入欄付きの写しです。

---

## 0. 環境


| 項目                       | 値         |
| ------------------------ | --------- |
| 実施日                      | 2026-08-03 |
| 対象リポジトリ                  | toganashi |
| ホスト OS / Docker          | macOS / Docker Desktop（linuxkit 6.12.76） |
| コンテナ名 / ID               | `toganashi-dev-container` / `1af3beaa8288` |
| Compose プロジェクト名          | `egress-guard-toganashi` |
| ネットワーク名                  |           |
| `firewall.json` の `mode` |           |


準備。以降のコマンドはすべて**ホストのシェル**から実行します。

```sh
# 対象リポジトリのパスとコンテナ名。R は自分の環境に合わせて書き換える。
export R=~/dev/himorogy/toganashi-workspaces/toganashi
export C=toganashi-dev-container

# エイリアスは単一引用符。二重引用符だと定義時に $C が固定される。
alias inroot='docker exec -u root $C'
alias innode='docker exec $C'

# 確認してから始める
docker ps --filter "name=^${C}$" --format '{{.ID}}  {{.Names}}  {{.Image}}'
ls "$R/.devcontainer/" >/dev/null && echo "R ok"
```

> **コンテナを取り違えないでください。** 他プロジェクトの devcontainer が同時に動いています（`shutdownAction: none`）。

> **ホスト側のファイルを見るコマンドは `$R` 起点で書いてあります。** 相対パスで書くと実行場所に依存します。

---

## 1. サマリ

埋めながらチェックしてください。

- [x] 22.0 → 合格
- [ ] 22.1 案 A の構成 / 戻せること
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
# ホスト側: 突き合わせる 2 行だけを出す
grep -n "workspaceFolder" "$R/.devcontainer/devcontainer.json"
grep -n ":/workspace" "$R/.devcontainer/docker-compose.yml"

# コンテナ側: 実際にリポジトリが見えているか
innode sh -c 'ls -la /workspaces/ && ls /workspaces/*/.devcontainer/devcontainer.json'
```

**期待:** `workspaceFolder` が `/X/<リポジトリ名>`、compose のバインド先が `/X`。`/workspaces/` 直下にリポジトリが 1 つ見え、その `.devcontainer/devcontainer.json` が存在する。

> **`ls -la` の owner が `root root` に見えても異常ではありません。** `docker exec -u root` 経由だと bind mount が呼び出し側の uid で表示されます（Docker Desktop の fakeowner）。

**結果:** 2026-08-03 実施。ホスト側の grep は cwd 誤りで空振りしたため、コンテナ側の観察で判定した。

```
$ ls -la /workspaces/
drwxr-xr-x  3 node node   96 Aug  3 04:13 .
drwxr-xr-x  1 root root 4096 Aug  3 05:51 ..
drwxr-xr-x 19 node node  608 Aug  2 15:22 toganashi

$ ls -la /workspaces/toganashi/.devcontainer/
-rw-r--r--  1 node node  2241 Aug  3 04:12 devcontainer.json
-rw-r--r--  1 node node  2281 Aug  3 05:46 docker-compose.yml
（他略）

$ docker ps
1af3beaa8288  egress-guard-toganashi-dev  toganashi-dev-container
```

* `/workspaces/` 直下がリポジトリ 1 つ = マウント先は**親ディレクトリ**で正しい
* `/workspaces/toganashi/.devcontainer/` が見えている = `workspaceFolder` とマウント先が**一致**
* イメージ名から Compose プロジェクト名は `egress-guard-toganashi`

**判定:** [x] 合格 — メモ: 判定自体は成立。コマンド側に不備があったため書き直した（cwd 依存・`head -3` で切れる・alias の引用符）。

---

## 22.1 案 A の構成になっている / 案 B へ戻せる

**入れ替え方は 2 通りあります。** どちらでも構いませんが、**戻す手段を確保してから先へ進んでください。**

* **2 ファイルを持つ** — `devcontainer.compose.json` と `devcontainer.runargs.json` を並べ、`mv` で切り替える
* **`devcontainer.json` を直接書き換える** — 戻すのは git 頼みになる

```sh
ls "$R/.devcontainer/" | grep -E "devcontainer.*\.json"
git -C "$R" status --short .devcontainer/
git -C "$R" log --oneline -1 -- .devcontainer/devcontainer.json
```

**期待:** 直接書き換えている場合、**案 B 版が git に残っている**こと（コミット済み、または `git stash` などで復元できる状態）。

> **`container_name` を固定しているため、案 B のコンテナが動いていると名前が衝突します。** 切り替える前に `docker stop $C`。

**結果:**

```
```

**判定:** [ ] 合格 / [ ] 不合格 — メモ:

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

**期待:** Compose が作った 1 本のみ。`**bridge` を含まない。**

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

**期待:** `127.0.0.11`。`DNS pinned to 127.0.0.11`。`**not on a user defined Docker network` の警告が出ない。**

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
# 2 ファイル方式なら mv で戻す。直接書き換えているなら git で戻す。
git -C "$R" checkout -- .devcontainer/devcontainer.json
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

**期待:** `false`。`**true` なら README の記述が誤り。**

**結果:**

```

```

**判定:** [ ] 合格 / [ ] 不合格 — メモ:

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