# L7 proxy PoC（sidecar 版）

> **2026-08-19 の実行結果: PASS=16 FAIL=0 SKIP=5。** V3〜V9 と補助項目がすべて通りました。記録は [`../../docs/verification-record.md`](../../docs/verification-record.md) §6.24。
> **V1（L3 側の対照実験）も同じ日に再現しました** — 適用直後は成功し、約 4 分後に `No route to host`。
> **未実施は V2 と、Squid を挟んだ状態での VS Code 拡張の実インストールです。**

**これは未検証の PoC であり、egress-guard の実装ではありません。** `packages/egress-guard/scripts/` 配下の本体には一切触れておらず、ここにあるものは `packages/egress-guard/docs/spec.md` §10.1 の L7 proxy 移行に着手する前に、[`docs/design.md`](../../docs/design.md) §2.23 の判断（sidecar 配置・明示型 CONNECT・TLS 非終端）が実際に成立するかを確かめるための使い捨て検証環境です。ここの `squid.conf` / `docker-compose.poc.yml` をそのまま本実装へ持ち込むことは想定していません。

検証項目 V1〜V10 の定義は [`poc-plan.md`](#出典) にあります（本 PoC 用に scratchpad からこのディレクトリへ内容を引き継いでいます。原本は `packages/egress-guard/docs/verification-record.md` §6.24 として本編へ移すまでの作業用ファイルです）。

## この PoC が答える問い

L3 の実現層（`init-project-firewall.sh` の ipset ベースの allowlist）では表現できない 2 件——

* `spec.md` §9.7: アドレスが動く（CDN drift）ドメインを allowlist に載せられない
* `known-issues.md` #7: VS Code 拡張の配信 CDN（`*.gallerycdn.vsassets.io` と `*.gallery.vsassets.io` の 2 系統）がワイルドカードを受理できないために allowlist できない

——が、SNI-only の L7 proxy を sidecar に置くことで実際に解消するかを確かめます。「L7 で通った」だけでは答えになりません。同じ環境で L3 だと落ちること（V1・V2）を先に示さないと、通った理由が proxy なのか環境差なのか区別できないため、対照実験を先に回す構成になっています。

## どこで実行する必要があるか

**ホスト側で `docker compose` を実行する必要があります。devcontainer の中からは実行できません。**

* この devcontainer には `docker` コマンドが無く、Docker ソケットも渡されていません（今回のセッションで実機確認済み）。
* そもそも egress-guard の L3 firewall が enforce で効いている環境では、proxy 自身が L3 の allowlist に縛られます。検証したい「L3 では落ちるが L7 なら通る」という現象そのものが再現しません。

検証機の記録には、ホスト OS・Docker のバージョン・`iptables` バックエンド（`nf_tables` / `legacy`）を含めてください。`known-issues.md` #3 の通り、Linux ホストでは挙動が変わります。

対照実験（V1・V2）と本実験（V3 以降）は同じホスト・同じ日に回してください。CDN のアドレスは日をまたぐと変わるため、別の日の結果を並べても比較になりません。

## ディレクトリの中身

| ファイル | 役割 |
|---|---|
| `squid.conf` | 検証対象の Squid 設定。`proxy-selection-research.md` §4 をベースに、`dstdomain -n` を必須で入れてある（`design.md` §2.23 必須要件 2。下記「V6 の判定方法」参照） |
| `allowed-domains.txt` | `deb.debian.org` と `.gallerycdn.vsassets.io` / `.gallery.vsassets.io` のみを許可する ACL。本実装での `firewall.json` → この形式への変換処理は対象外（poc-plan.md の未決事項） |
| `Dockerfile.proxy` | Squid の自前ビルド。Docker Official Image が存在しないため。選定理由はファイル内コメント参照 |
| `Dockerfile.client` | クライアント（エージェント役）。`curl` を焼き込んである。理由はファイル内コメント（道具の導入を検証対象の経路に依存させない） |
| `docker-compose.poc.yml` | sidecar 構成一式。`egress-proxy`（検証対象）、`client`（`.devcontainer/docker-compose.yml` の `dev` を模した最小クライアント）、`egress-proxy-v6` と `ptr-spoof-harness`（V6 専用、下記参照） |
| `test-helpers/ptr-spoof-harness.py` | V6 のためだけの使い捨てツール。実装ではない |
| `verify.sh` | V3〜V9 を可能な範囲で自動判定するスクリプト。shellcheck クリーン（`shellcheck -x --shell=bash --severity=style verify.sh` で確認済み） |

`.devcontainer/docker-compose.yml`（本体）は読むだけで変更していません。`docker-compose.poc.yml` は別ファイルとして独立に起動・破棄できます。

## 実行手順

```sh
cd packages/egress-guard/poc/l7-proxy
./verify.sh
```

`verify.sh` が `docker compose up -d --build` からスタックの起動・各検証・後片付け（`down -v`）まで一通り行います。個別に動かしたい場合は次の手順です。

```sh
docker compose -f docker-compose.poc.yml up -d --build
docker compose -f docker-compose.poc.yml exec client sh
# ... 手で試す ...
docker compose -f docker-compose.poc.yml down -v
```

環境変数 `V3_WAIT_SECONDS`（既定 90）で V3 の待機時間を、`KEEP_UP=1` で終了後にスタックを残すかどうかを調整できます。

## V1〜V10 の判定方法

| 項目 | 内容 | 判定方法 | このリポジトリでの扱い |
|---|---|---|---|
| V1 | 現行 L3 で `deb.debian.org` が（2 回目に）落ちる対照実験 | `firewall.json` に `deb.debian.org` を足して再ビルドし、直後と数分後に **`docker exec -u root <container> apt-get update`**（非 root では lock で落ちて HTTP に到達しない） | **このディレクトリの対象外**（`verify.sh` は既存ファイルを変更しない方針）。**2026-08-19 に実施し再現済み** — `verification-record.md` §6.24 |
| V2 | 現行 L3 で VS Code 拡張が入らない対照実験 | `verification-record.md` §6.23 の手順（enforce と audit を比較） | 同上。対象外、手動 |
| V3 | proxy 経由で `apt-get update` が（2 回とも）成立する | `verify.sh` が自動判定 | 自動 |
| V4 | ワイルドカード ACL で拡張配信 CDN が入る（2 系統とも） | `verify.sh` が `anthropic.gallerycdn.vsassets.io` と `anthropic.gallery.vsassets.io` への接続とログ上の具体名一致を自動判定 | 自動（ただし下記「V4 の限界」参照） |
| V5 | 未許可ドメインが拒否され、ログにドメイン名が残る | `verify.sh` が自動判定 | 自動 |
| V6 | 名前の偽装（`dstdomain -n` の PTR 逆引き対策）が通らない | `verify.sh` が自動判定。判定方法は下記「V6 の判定方法」で詳説 | 自動 |
| V7 | proxy が落ちたら閉じる（I2） | `verify.sh` が proxy 停止後の接続失敗を自動判定 | **部分的に自動。** L3 との統合込みの完全な fail-closed は検証できない（下記「V7 の限界」） |
| V8 | proxy 設定へエージェントが到達できない（I1） | `verify.sh` が client からの ACL ファイル探索を自動判定 | 部分的に自動。ACL 変更に再ビルド相当が要ることの確認は手動 |
| V9 | 設定が壊れているとき起動しない（fail-closed） | `verify.sh` が壊れた設定での起動失敗を自動判定 | 自動 |
| V10 | ECH（`design.md` §2.23 必須要件 3） | 検証項目として存在しない | **検証不要になった。** 下記「V10 が検証項目から外れた理由」参照 |

補足として `verify.sh` は poc-plan.md には無い 2 項目も自動判定します。

* **cache manager が `http_access deny manager` だけで塞がるか**（`proxy-selection-research.md` §8 未確認事項 1）— allowed なホスト経由でも `/squid-internal-mgr/` に到達できないことを確認
* **read-only bind mount + `read_only: true` で Squid が起動するか**（同 §8 未確認事項 3）— スタック起動時点でこれが成立していないと以降の全項目が実行できないため、`verify.sh` の起動前提チェックとして組み込んである

### V4 の限界

`verify.sh` が確認するのは 2 系統への `curl` 接続の成立とログの具体名一致までで、**実際の VS Code 拡張インストールの成功は確認しません。** `client` は素の Debian で、VS Code Server が動いていないためです。

**前提のうち 1 つは別途確認済みです。** 2026-08-19 に、VS Code でアタッチした devcontainer に `HTTPS_PROXY` を向けて `test-helpers/connect-sniffer.py` で観測し、**VS Code Server が proxy 設定を読むこと**と、**接続先が 2 系統あること**を実測しました（`known-issues.md` #7）。

**残っているのは「実際に中継したときにインストールが成功するか」です。** sniffer は中継せず 502 を返して切るため、そこまでは分かりません。`known-issues.md` #7 の最終判定には、**Squid を実際に挟んだ状態で VS Code から拡張をインストールする**実測が要ります。

### V6 の判定方法

poc-plan.md は V6 の手順を「明示型なら `curl --resolve` 相当」としていますが、**この PoC を作る過程で実測した結果、`curl --resolve` は明示型プロキシの `CONNECT` トンネル先には効きません。**

```
$ curl -x http://<proxy> --resolve deb.debian.org:443:<偽IP> https://deb.debian.org/
> CONNECT deb.debian.org:443 HTTP/1.1     # ← --resolve で指定したIPは使われない。名前がそのまま飛ぶ
```

これは自前の TCP リスナで受信バイト列を記録して確認した事実です（下記フェーズ1参照）。つまり明示型 CONNECT では、クライアント側の操作だけで「名前は A だが接続先は B」という状態を作ることが構造的にできません（`proxy-selection-research.md` §1 の「構造的に○」はここでも成立します）。

実際に成立しうる攻撃は `design.md` §2.23 が挙げている **PTR 逆引きの罠**だけです。`CONNECT <IPリテラル>:443` を送り、そのリテラル IP の PTR レコードが `deb.debian.org` を返すよう攻撃者が細工していれば、`dstdomain` の `-n` が無い設定では ACL が通ってしまいます。

`verify.sh` の V6 はこれを再現します。

1. `egress-proxy-v6` — 出荷する `squid.conf` / `allowed-domains.txt` をそのまま使う、テスト専用の 2 個目の Squid インスタンス。DNS の向き先だけ `ptr-spoof-harness` に固定してある
2. `ptr-spoof-harness`（`test-helpers/ptr-spoof-harness.py`）— 自分自身への PTR 問い合わせに `deb.debian.org` で答える偽 DNS と、443/tcp の「victim」リスナーを兼ねる、検証専用の使い捨てツール
3. `client` が `egress-proxy-v6` へ `https://<harness の IP>/` を要求する（＝ `CONNECT <IPリテラル>:443`）
4. `squid.conf` に `dstdomain -n` が入っているため、PTR の結果は無視され、名前としては扱われず deny になる。**harness の 443 に接続が来ないこと**を一次判定にし、squid 自身のアクセスログの deny 行を補助判定にしている

`-n` を外した設定でこの再現がどう壊れるかは、この PoC ではあえて検証していません（出荷する設定が安全であることを示すのが目的で、脆弱な設定を再現するための追加のバリアントを増やすと検証環境自体が複雑になりすぎるため）。`-n` の必要性そのものは `proxy-selection-research.md` §1 が Squid のソース（`src/cf.data.pre`）を引用して示しています。

#### harness のアドレスを TEST-NET-3 にしてある理由（V6 が成立する前提）

**`ptr-spoof-harness` は `203.0.113.53`（RFC 5737 の TEST-NET-3）に置いています。私設アドレス帯に置いてはいけません。**

`squid.conf` の `http_access` は `deny to_private`（`10.0.0.0/8` 等）を `deny !allowed` より前に置いています。I6 相当の検査を先に効かせるためで、本番設定としてはこの順序が正しいものです。しかし **harness を私設帯に置くと、`CONNECT <harness IP>:443` は `dstdomain` の判定に到達する前に `to_private` で落ちます。**

そうなると **V6 は `dstdomain -n` が効いているかどうかに関わらず必ず成功します。`-n` を外しても成功するため、検証になっていない偽陽性です。**

TEST-NET-3 は文書用に予約された実在しない帯で、`squid.conf` のどの禁止レンジにも該当しません。そのため `CONNECT` は `dstdomain` の判定まで到達し、PTR 逆引きの結果が ACL に使われるかどうかがそのまま V6 の結果になります。

**この PoC を改変する際、`v6-test-net` のサブネットを変えるなら同じ条件を満たすこと**（`squid.conf` の `to_private` / `to_private6` のどれにも該当しないこと）を確認してください。

### V10 が検証項目から外れた理由

当初の検証項目（poc-plan.md）は V10 を「ECH 付き ClientHello を拒否する」としていました。**`design.md` §2.23 の必須要件 3 が改訂され、この項目は検証対象ではなくなりました。**

* **ECH でも平文の SNI は消えません。** `draft-ietf-tls-esni` は ClientHelloOuter に `ECHConfig.contents.public_name` を `server_name` として入れると定めています。したがって「SNI が読めないから拒否する」という判定は**透過型でもそもそも成立しません**
* **明示型ではこの論点自体が消えます。** 接続先は proxy が `CONNECT` の authority を自分で解決した結果で確定しており、トンネルの中を流れる TLS が ECH かどうかは接続先を変えられません

この PoC は明示型なので、**確かめるべき挙動が存在しません。** `verify.sh` はこの理由を明示して SKIP します。透過型を採る場合にのみ問題になる項目です。

### 起動しなかった原因（2026-08-19、修正済み）

**最初にホストで回したとき、Squid の 2 サービスだけが起動しませんでした。** `client` と `ptr-spoof-harness` は上がっており、Compose もネットワークも正常でした。

```
ALERT: setgid: (1) Operation not permitted
ALERT: initgroups: unable to set groups for User proxy and Group 13
（延々と繰り返し）
egress-proxy-1 exited with code 139      ← SIGSEGV
```

**原因は `cap_drop: [ALL]` です。** Squid は root で起動したあと `cache_effective_user`（Debian の既定は `proxy`、uid 13）へ降格しようとします。これには `CAP_SETUID` と `CAP_SETGID` が要りますが、sidecar は全 capability を落として動かしているため降格に失敗し、最終的に落ちていました。

**`cap_add: [SETUID, SETGID]` で戻す修正は採りませんでした。** `design.md` §2.23 は「SNI proxy は ipset を書かないので特権を必要としない」ことを sidecar 配置の根拠にしています。降格のためだけに特権を持たせると、その根拠と食い違います。

**採った修正は「降格させない」です。** 最初から uid 13 で起動すれば、Squid は降格処理そのものを行いません。

* `docker-compose.poc.yml` の両 Squid サービスに `user: "13:13"`
* `Dockerfile.proxy` に `USER proxy`（compose を経由せず `docker run` しても同じ条件になるように）
* tmpfs は既定で root 所有になるため、`uid=13,gid=13` を明示

**`http_port` が 3128 で特権ポートではないため、この構成に不都合はありません。** むしろ root で動く瞬間が無くなる分、当初より攻撃面が小さくなっています。

### 2 回目の実行で分かったこと（2026-08-19）

**Squid は起動しました。`read_only: true` のまま 4 サービスとも running になり、`proxy-selection-research.md` §8 未確認事項 3 に答えが出ました。** read-only bind mount + read-only ルートファイルシステム + `cap_drop: [ALL]` + 非 root で、Squid は動きます。

確かな結果が出た項目:

* **V8（I1: client から ACL ファイルへ到達できない）— PASS**
* **V9（設定が壊れていると起動しない）— PASS。** 壊れた `squid.conf` で Squid は非 0 終了しました

**一方で、`verify.sh` に判定上の欠陥が見つかりました。** これがこの回の最大の収穫です。

**同じ原因（`cap_drop: [ALL]`）が client 側でも出ました。** apt は `_apt`（uid 42）へ降格して取得するため、`setegid` / `seteuid` に失敗して落ちます。

```
E: setegid 65534 failed - setegid (1: Operation not permitted)
E: seteuid 42 failed - seteuid (1: Operation not permitted)
```

その結果 `curl` が入らず、**curl を使う判定がすべて「接続が失敗した」に見えました。** そして `verify.sh` は失敗の理由を区別していなかったため、次の 3 つが**偽陽性で `ok` になっていました。**

```
OCI runtime exec failed: exec: "curl": executable file not found in $PATH
  ok   V5-1: 許可していないドメインへの接続は失敗する
  ok   V6-1: victim (harness) への接続は発生しなかった
  ok   V7-1: proxy停止後はproxy経由の経路が失われる
```

**「接続が失敗すること」を成功条件にする判定は、失敗の理由を区別しなければ意味を持ちません。** 特に V6 は必須要件 2 の関門なので、ここが偽陽性で通るのは看過できません。

行った修正は 3 つです。

1. **client の `cap_drop: [ALL]` を外しました。** client は「エージェントが動くコンテナ」を模したもので、本物の `.devcontainer/docker-compose.yaml` は cap_drop していません（むしろ `cap_add` で `NET_ADMIN` / `NET_RAW` を足しています）。**PoC の client だけを本物より絞ると、検証対象と無関係な失敗が出ます**
2. **`curl` を `Dockerfile.client` でイメージに焼きました。** 道具の導入を検証対象の経路（proxy 越しの apt）に依存させたのが誤りでした。V3（`apt-get update` が proxy 経由で成立するか）は引き続き実行時に見ます
3. **`verify.sh` に「判定不能」を導入しました。** `client_curl` ヘルパが、curl を実行できなかった場合（exit 126/127、`executable file not found` 等）を接続失敗と区別して返します。**判定不能なら `ok` も `FAIL` も出さず SKIP します。** あわせて次の 2 つの前提チェックを足しました
   * **V6**: victim に接続が来なかったことを判定する前に、**リクエストが `egress-proxy-v6` まで届いたこと**をログで確認します。届いていなければ `-n` の効果は判定できません
   * **V7**: proxy を止める前に、**同じ経路が生きていること**を確認します。元から通っていなければ、停止後に失敗しても proxy を止めたためとは言えません

### V7 の限界

`verify.sh` は「proxy を止めると proxy 経由の経路が失われる」ことは確認します。しかし `design.md` §2.23 が主張する I2（**proxy が落ちたら外向き通信が全部落ちる**）の本当の強さは、`init-project-firewall.sh` が作る縮小後の iptables（proxy 宛 + DNS 固定のみ許可）との組み合わせで初めて成立します。

この PoC の `client` サービスには L3 の iptables 制限を一切課していません。そのため「`http_proxy` を無視して直接接続する」という経路まで塞がれるかどうかは、この PoC の範囲では検証できません。本実装で L3（既存の `init-project-firewall.sh`）と L7（この PoC 相当のもの）を組み合わせたときに、改めて確認する必要があります。

## フェーズ1: この devcontainer 内で実測できたこと・できなかったこと

このディレクトリを作る前に、この devcontainer 自身の中でどこまで実測できるかを確認しました。**推測で埋めた項目はありません。実測できなかったものは「実測不能」とその理由を記録してあります。**

### Squid そのものは入手できませんでした

* `sudo apt-get install squid` は試す前の時点で止まります。`sudo -n -l` の結果は次の 1 行だけで、`apt-get` を含む一般コマンドへの `NOPASSWD` は付与されていません。

  ```
  User node may run the following commands on <host>:
      (root) NOPASSWD: /usr/local/bin/init-project-firewall.sh ""
  ```

  つまり `deb.debian.org` が allowlist に無いから、という以前に、**この devcontainer の sudoers 設定自体が `init-project-firewall.sh` 以外の root 実行を許していません**（`design.md` §2.16 の設定そのものが、この devcontainer 自身にも適用されています）。
* `dpkg -l`、ファイルシステム全体の `find`、`apt-cache policy squid` のいずれでも Squid のバイナリ・パッケージキャッシュは見つかりませんでした（`/usr/share/vim/vim90/syntax/squid.vim` という vim のシンタックスファイルが 1 件ヒットしただけです）。
* 以上より、**この devcontainer 内で Squid を直接起動しての実測（V3〜V9 相当）は実行できませんでした。**

### 自前の TCP リスナで実測できたこと

`nc` / `netcat` / `ncat` / `socat` はいずれもこの devcontainer に入っていませんでしたが、`python3`（3.11.2）は入っていたため、`accept()` して受信バイト列を記録するだけの数十行のリスナを立てて実測しました。外向き通信は一切発生していません。

以下は **実際にこの devcontainer 内で観測した結果**です（`proxy-selection-research.md` §8 の番号に対応させています）。

| 未確認事項 | 結果 | 観測方法 |
|---|---|---|
| §8-5 `NODE_USE_ENV_PROXY=1` の効果 | **解決。** node v24.18.0（`--use-env-proxy` の閾値 v24.0.0 以上）で `NODE_USE_ENV_PROXY=1` を付けたときのみ `fetch()` が `CONNECT` を発行することを確認。付けない場合はリスナに何も届かない（＝既定 OFF は実装通り） | `env NODE_USE_ENV_PROXY=1 https_proxy=... node -e "fetch(...)"` |
| §8-10 Claude Code が `CONNECT` を発行するか | **解決。** `claude -p "hi"` を `HTTPS_PROXY` 付きで実行し、`CONNECT api.anthropic.com:443` を複数回（リトライ込み）観測。副次的に `CONNECT http-intake.logs.us5.datadoghq.com:443`（テレメトリ）も観測 | 実行中の Claude Code CLI（v2.1.221）そのものを同じ手法でプロキシ越しに実行 |
| §8-11 `curl` が https URL に対して自動的に `CONNECT` を使うか | **解決。** `-x` を付けるだけで `--proxytunnel` 無しに自動で `CONNECT` を送ることを確認 | `curl -x http://127.0.0.1:PORT https://example.invalid/` |
| §8-12 npm / pnpm が https 宛に `CONNECT` を使うか | **解決（両方）。** npm は `--proxy`/`--https-proxy` フラグで、pnpm は環境変数 `https_proxy`/`http_proxy` で、それぞれ `CONNECT registry.npmjs.org:443` を送ることを確認。**ただし `pnpm config set proxy/https-proxy`（pnpm 独自の設定キー）では効果が無く、直接接続が成立してしまいました。** 環境変数方式（`docker-compose.poc.yml` が採用している方式）でのみ確認できています | npm: `npm view left-pad version --proxy ... --https-proxy ...`。pnpm: `env https_proxy=... http_proxy=... pnpm view left-pad version` |
| （参考、apt） | apt は非特権ユーザーでも `-o Dir::State::Lists=` 等でディレクトリを差し替えれば動かせることを確認したうえで、`https_proxy` 経由で `CONNECT deb.debian.org:443` を送ることを確認（`proxy-selection-research.md` の一次情報引用の裏付け） | `apt-get -o Dir::State::Lists=/tmp/... -o ... update` |
| （参考、git https） | `git -c http.proxy=... ls-remote https://...` が `CONNECT github.com:443` を送ることを確認（同上の裏付け） | 上記の通り |

**副次的な発見:** `HTTPS_PROXY`/`HTTP_PROXY` を広くセットすると、Claude Code が発する**ローカルループバック宛の内部通信**（コーディングハーネスの hook 通知。`127.0.0.1:<port>` 宛の `POST`）も同じプロキシへ流れることを観測しました。`docker-compose.poc.yml` / `proxy-selection-research.md` の推奨設定が `no_proxy`/`NO_PROXY` に `localhost,127.0.0.1` を含めているのは、CDN や外部 API のためだけでなく、**この種のローカル IPC を巻き込まないためにも必須**だと分かりました。これは実測するまでは一次情報に無かった具体的な根拠です。

### 実測できなかったこと

* **§8-9 VS Code Server の拡張ギャラリークライアントが `HTTPS_PROXY` を読むか（最優先項目）。→ 2026-08-19 に解決しました。** このディレクトリを作った環境（`~/.vscode-server` が無く、VS Code Remote でアタッチされていないセッション）では原理的に確認できませんでしたが、**VS Code でアタッチした devcontainer に `HTTPS_PROXY` を向けて `test-helpers/connect-sniffer.py` で観測したところ、読むことが確認できました。** あわせて接続先が 2 系統（`.gallerycdn.vsassets.io` / `.gallery.vsassets.io`）あることも分かり、`allowed-domains.txt` と V4 の判定を両系統に広げてあります。詳細は `known-issues.md` #7 と `design.md` §2.23
* **§8-1 `http_access deny manager` だけで cache manager が塞がるか。** Squid バイナリが無いため未実行。`verify.sh` に自動判定を組み込んであるので、ホスト側でスタックを起動すればそこで確認できます
* **§8-2 Squid イメージ候補の保守状況・サイズ。** `hub.docker.com` へこの devcontainer から到達できないため未確認のまま。`Dockerfile.proxy` は Docker Official Image（`debian:bookworm-slim`）+ Debian 本体の `squid` パッケージという、サードパーティ配布イメージに頼らない構成にすることでこの論点を回避しています
* **§8-3 read-only bind mount + `read_only: true` での Squid 起動。→ 2026-08-19 に解決しました。成立します。** read-only bind mount + read-only ルートファイルシステム + `cap_drop: [ALL]` + 非 root（uid 13）で Squid は起動します。そこへ至るまでに踏んだ問題は下記「起動しなかった原因」
* **未確認事項 3（`dstdomain -n` の PTR 偽装再現）。** Squid バイナリが無いため未実行。`verify.sh` の V6 として自動化してあります（上記参照）
* **§8-13 `nc -X connect` が使えるか（git over ssh 経由の CONNECT）。** `nc` / `netcat` はこの devcontainer に入っていませんでした。ただし git over ssh が `HTTP_PROXY` 系の環境変数を読まないことは `proxy-selection-research.md` §5 が `ssh_config(5)` の一次情報で既に確定させており、これは実測ではなく仕様の話なので優先度は低いままです
* **git over ssh の `ProxyCommand` 経由での動作。** 上記の理由により未実施
* **§8-4 `ssl_bump peek`+`splice` の証明書要否。** この PoC は `ssl_bump` を採用しない方針（`design.md` §2.23 の MITM 不採用）なので、そもそも検証の対象にしていません
* **§8-6 HAProxy の `do-resolve` 公式サンプル / §8-7 nginx・Envoy のイメージ収録状況 / §8-8 Privoxy 全般。** Squid 採用が確定した後の調査であり、この PoC の対象外のままです

## 出典

* `proxy-selection-research.md`、`poc-plan.md` — セッションの scratchpad にある調査結果と検証項目定義（このリポジトリには同梱していません。作業時の一次資料です）
* [`../../docs/design.md`](../../docs/design.md) §2.23 — sidecar 配置・TLS 非終端の設計判断
* [`../../docs/spec.md`](../../docs/spec.md) §9.7、§10.1
* [`../../docs/known-issues.md`](../../docs/known-issues.md) #7
