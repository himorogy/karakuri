# proxy 実装選定 — 調査結果（2026-08-04）

`design.md` §2.23 の未決事項（透過型か明示型か / どの実装を採るか）を潰すための調査です。**一次情報にあたった結果であり、実測ではありません。** 実測は [`README.md`](./README.md) と [`../../docs/verification-record.md`](../../docs/verification-record.md) §6.24。

**未確認事項を §8 に明示してあります。断定されているものと未確認のものを混同しないでください。** `squid.conf` と `README.md` はこの文書の節番号を参照しています。

---

## 1. 必須要件（名前の再解決）

### 明示型 CONNECT は構造的に満たす

Squid の `src/cf.data.pre`:

* `client_dst_passthru`（DEFAULT: on）— "With NAT or TPROXY intercepted traffic Squid may pass the request directly to the original client destination IP ... The clients original destination IP and port will be used instead."
* `host_verify_strict`（DEFAULT: off）— "When set to OFF (the default): ... Forward-proxy traffic is not checked at all. ... Intercepted requests which fail verification are sent to the client original destination instead of DIRECT."

**「元の宛先 IP」は intercepted モード固有の概念です。** 明示型では Squid が受け取るのは `CONNECT host:port` の文字列だけで、宛先 IP は Squid 自身の DNS 解決結果しかありません。

同じ性質を tinyproxy（`opensock()` が `getaddrinfo()` の `res->ai_addr` にしか `connect()` しない）と Go 標準ライブラリ（`net.Dial` の doc）でもソースレベルで確認しています。

### 【重要】Squid には要件を静かに破る罠がある — `dstdomain` の PTR 逆引き

`src/cf.data.pre` の ACL 定義:

```
acl aclname dstdomain [-n] .foo.com ...
  # Destination server from URL [fast]
  # For dstdomain and dstdom_regex a reverse lookup is tried if a IP
  # based URL is used and no match is found. The name "none" is used
  # if the reverse lookup fails.
```

`-n` を付けないと、`CONNECT 203.0.113.5:443` のような IP リテラル宛 CONNECT に対して Squid が PTR 逆引きを行い、その結果を `dstdomain` のパターンと突き合わせます。**敵は自分が管理する IP の rDNS を許可済みドメイン名に設定するだけで ACL を通せます。**

`-n` の定義:

```
-n	Disable lookups and address type conversions.  If lookup or
	conversion is required because the parameter type (IP or
	domain name) does not match the message address type (domain
	name or IP), then the ACL would immediately declare a mismatch
	without any warnings or lookups.
```

**`dstdomain -n` は必須指定です。** これが `design.md` §2.23 の必須要件 2 になりました。

## 2. ECH は透過型では原理的に解けない

### 検出手段が存在しない

* nginx `ngx_stream_ssl_preread_module.c` の拡張ディスパッチャは SNI(0) / ALPN(16) / supported_versions(43) の 3 分岐のみ。それ以外は `size = (p[2] << 8) + p[3];` で読み飛ばす
* Envoy `tls_inspector` の設定面は JA3/JA4・バッファサイズ等のみ。ソースを `0xfe0d|65037|encrypted_client_hello|ech` で grep して 0 hit
* HAProxy 3.0/3.2 のドキュメントに `ech` 記載なし。3.3 の `ech <dir>` は experimental な**復号**用で、判定用 sample fetch は存在しない

### 「SNI が無い = ECH」という判定も成立しない

`draft-ietf-tls-esni`:

> "1. It SHOULD place the value of `ECHConfig.contents.public_name` in the "server_name" extension."
> `enum { encrypted_client_hello(0xfe0d), (65535) } ExtensionType;`

**ECH の ClientHelloOuter は平文の `server_name` を持ち続けます。** SNI-only proxy から見るとごく普通のホスト名に見えます。`design.md` §2.10 で「正しく解決できたようにしか見えない」形を最悪としたのと、同じ形の穴が透過型 SNI proxy には構造的に残ります。

### 明示型では論点自体が消える

宛先 TCP コネクションの相手は「proxy が CONNECT の authority を自分で解決した結果」で確定しており、そのあと中で流れる TLS が ECH かどうかは接続先を変えられません。**これが明示型を採る決め手になりました。**

## 3. 候補ごとの判定

要件 A = 名前を自分で解決して接続 / B = ECH / C = 管理ポートを開かない

* **Squid（明示 CONNECT / ssl_bump なし）** — A: 構造的に○（`dstdomain -n` 必須）/ B: n/a / C: icp・snmp・htcp 既定 0、manager は `deny manager` / ワイルドカード: `.foo.com` 1 行で apex+sub / ログ: `%ru` に `host:port` / fail-closed: `fatalf` 即死 + `http_access` 既定 deny / イメージ: **公式イメージ無し、CVE 41 件** → **採用（推奨）**
* Squid（透過 intercept）— 「再解決」ではなく「SNI の解決結果と元の宛先 IP を照合」。wiki: "If that SNI name does not resolve to the destination server IP(s) this message will be output and TLS halted" → **CDN の IP ローテーションで誤検知（§9.7 を再導入する）** → 条件付き
* Envoy（CONNECT 終端 + dynamic_forward_proxy）— A: ○ / B: × / 設定が重い。**同梱例 `configs/terminate_http1_connect.yaml` は `ORIGINAL_DST` + client 指定 `:authority` で、まさに禁じたい形。流用禁止** → 条件付き採用可
* Envoy（SNI DFP / 透過）— `tls_inspector` 未設定時に `requested_server_name` が「無し」扱いになる fail-open 罠あり
* HAProxy（透過 SNI + `do-resolve`/`set-dst`）— Docker Official Image あり。`do-resolve(...) req.ssl_sni` の公式例は**未確認**
* nginx（stream + `ssl_preread`）— **CONNECT を話せないため明示型では使えない**。公式イメージが `--with-stream_ssl_preread_module` 付きかは**未確認**
* **tinyproxy** — A: 構造的に○ / **`StatHost` を無効化できず、かつ filter より前に評価される**（`reqs.c:401` vs `:502`）/ `*.foo.com` は apex を含まないので 2 行必要 / `ConnectPort` 未指定だと全ポート CONNECT 可 / **RSS 約 2 MB** → 条件付き採用可（次点）。検証は issue #14
* **Go 自前実装** — A: 構造的に○。`net.Dial("tcp", r.URL.Host)` 以外に宛先を渡す API 面が無い。IP リテラル authority の明示拒否まで書ける唯一の候補。推定 5〜8 MB。JS モノレポに Go を持ち込む保守コスト。検討は issue #15
* Privoxy — **判定不能。** `www.privoxy.org` へ到達不能、GitHub 公式ミラー無し。全項目未確認
* mitmproxy — **不可。** `allow_hosts` / `ignore_hosts` が fail-open（非該当ホストを `TCPLayer` で素通し）、起動時に CA を生成、非 ignore 経路は必ず TLS 終端

## 4. 推奨実装の最小設定

実際に採用した設定は [`squid.conf`](./squid.conf) を参照してください。この節にあった雛形はそちらへ反映済みです。

> **変換器への注意:** Squid の wiki が明記するとおり「1 つの ACL の中に、あるエントリの部分ドメインになる別エントリを入れてはいけない」（Splay tree の比較関数が全順序にならないため）。`firewall.json` → `allowed-domains.txt` の変換時に `github.com` と `.github.com` のような重複を潰す必要があります。Squid は検出時に warn を出しますが fatal ではありません。

### audit モードの引き継ぎ

最終行を `http_access deny all` → `http_access allow all` に差し替えるだけで、access.log の `%ru` に全リクエストのドメイン名が時刻付きで残ります。現行の ipset ベース記録より情報量が多く、収集も `docker compose logs egress-proxy` で済みます。

## 5. `HTTP_PROXY` に従うツール（一次情報）

**従わないのは `git over ssh` と `node の fetch`（既定 OFF）の 2 つだけです。**

* `git` (https) — ○。`Documentation/config/http.adoc`: "http.proxy:: Override the HTTP proxy, normally configured using the 'http_proxy', 'https_proxy', and 'all_proxy' environment variables"
* `git` (**ssh**) — **× 従わない。** `ssh_config.5` を `grep -i proxy` して `HTTP_PROXY`/`http_proxy` は 0 hit。環境変数展開が許されるのは `CertificateFile, ControlPath, IdentityAgent, IdentityFile, Include, KnownHostsCommand, UserKnownHostsFile` のみ。`core.gitProxy` は `git://` 専用
* `curl` — ○。`docs/cmdline-opts/_ENVIRONMENT.md`: "The lower case version has precedence. **`http_proxy` is an exception as it is only available in lower case.**" → `HTTP_PROXY` は無視される
* `apt` / `apt-get` — ○（**小文字のみ**・最低優先度）。`methods/http.cc`: `getenv("http_proxy")` … `if (tls == true) { getenv("https_proxy") }`。https リポには `CONNECT <host>:<port> HTTP/1.1` を発行
* `npm` — ○。`npm/agent/lib/proxy.js` が env キーを小文字化して照合 → 大小両方 OK
* `pnpm` — ○。"their values will be used instead"（env が設定を上書きする）。**ただし `pnpm config set proxy` は効きません**（実測）
* `node` の `fetch`/undici — **× 既定 OFF（opt-in）。** `NODE_USE_ENV_PROXY=1`（v24.0.0 / v22.21.0）または `--use-env-proxy`。`lib/internal/process/pre_execution.js`: `if (!getOptionValue('--use-env-proxy')) { return; }`
* VS Code Server — **○（実測で確認済み）。** 調査時点では公式に明文が無く未確認でしたが、2026-08-19 に実測して読むことを確認しました（[`../../docs/known-issues.md`](../../docs/known-issues.md) #7）
* Claude Code — ○。順序は `https_proxy`, `HTTPS_PROXY`, `http_proxy`, `HTTP_PROXY`。SOCKS 非対応。起動時に一度だけ読む

### `git over ssh` の扱い

`ssh_config(5)` の公式解法:

> "ProxyCommand — ... the following directive would connect via an HTTP proxy at 192.0.2.0: `ProxyCommand /usr/bin/nc -X connect -x 192.0.2.0:8080 %h %p`"

`~/.ssh/config` に 1 行入れれば、ssh も `CONNECT github.com:22` として proxy の同じ ACL の下に入ります。**迂回ではなく proxy に乗せる方向で解決できます。**

## 6. 透過型を採らない理由（補強）

* `design.md` §2.4「nat を触らない」を破る
* **§9.7（CDN drift）を再導入する。** Squid の wiki が透過型の運用注意として明記: "Certain CDN networks load balance by rotating a set of IPs in and out of service with each TTL cycle"。**今回の移行は §9.7 を解くためのものなので本末転倒**
* Envoy の `requested_server_name` は `tls_inspector` 忘れで fail-open、同梱 CONNECT 例は `ORIGINAL_DST` を使っている等、罠が多い
* §2 の ECH が原理的に解けない

## 7. Squid を採ることのマイナス点

* **Docker Official Image が存在しない。** `docker-library/official-images/master/library/squid` は 404（nginx / haproxy は 200）。自前ビルドと digest でのピン留めが要る
* **CVE の実績が良くない。** GitHub Security Advisories は 41 件（critical 12 / high 19 / medium 10）。年別 2020:6 / 2021:8 / 2022:3 / 2023:11 / 2024:5 / 2025:3 / 2026:5。**大半は FTP gateway・ICP・cache digest といった本構成で使わない機能だが、バイナリには入っている**
* 本来キャッシュのため `cache deny all` で「キャッシュしない」を明示する必要がある
* **メモリが重い。** 実測でアイドル時 RSS 162 MiB（[`../../docs/design.md`](../../docs/design.md) §2.24）。`cache_mem 0 MB` と `memory_pools off` を入れても下がらない。issue #14 / #15 の起点

## 8. 未確認事項

推測で埋めていません。**解決したものには結果を追記してあります。**

1. **`http_access deny manager` だけで cache manager を塞げるか** → **解決（2026-08-19）。** 403 で拒否されることを実測（§6.24）
2. **Squid の Docker イメージ候補の保守状況・サイズ** → 未確認。`hub.docker.com` へ到達できなかったため。`Dockerfile.proxy` は Docker Official Image（`debian:bookworm-slim`）+ Debian の `squid` パッケージにすることで、サードパーティ配布イメージへの依存を回避
3. **read-only bind mount + `read_only: true` での Squid 起動** → **解決（2026-08-19）。** 成立する。ただし非 root 起動が前提（§6.24）
4. **`ssl_bump peek`+`splice` の証明書要否** → 対象外。`ssl_bump` を採らない方針のため
5. **HAProxy の `do-resolve(...) req.ssl_sni` の公式サンプル** → 未確認
6. **nginx 公式イメージの `--with-stream_ssl_preread_module`** → 未確認。確認コマンド: `docker run --rm nginx nginx -V 2>&1 | grep stream_ssl_preread`
7. **Envoy の distroless イメージに `sni_dynamic_forward_proxy` が含まれるか** → 未確認
8. **Privoxy 全般** → 未確認。到達手段が無かった
9. **VS Code Server の拡張ギャラリークライアントが `HTTPS_PROXY` を読むか** → **解決（2026-08-19）。** 読む（§6.24、known-issues #7）
10. **Claude Code が https 宛に `CONNECT` を発行するか** → **解決（2026-08-19）。** 発行する
11. **`curl` が https URL に対して `--proxytunnel` 無しで自動的に `CONNECT` を使うか** → **解決（2026-08-19）。** 使う
12. **npm / pnpm が https 宛に `CONNECT` を使うか** → **解決（2026-08-19）。** 使う。ただし pnpm は環境変数経由のみ
13. **`nc -X connect` が使える netcat がイメージに入っているか** → 未確認。git over ssh の回避策の前提
14. **41 件の advisory のうち本構成で到達可能なものが何件か** → 未分類

## 9. この文書の位置づけ

**調査時点（2026-08-04）の一次情報です。** その後の実測で覆った箇所（ECH の扱い、VS Code Server の proxy 追従）は本文に追記してあります。

実測の記録は [`../../docs/verification-record.md`](../../docs/verification-record.md) §6.24、設計判断は [`../../docs/design.md`](../../docs/design.md) §2.23・§2.24 にあります。**この文書は「なぜその候補を選んだか」の材料であり、規範ではありません。**
