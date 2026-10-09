---
status: draft # draft → open → close
type: feat
base: main
targets:
  - images/egress-proxy/squid.conf
  - packages/egress-guard/tests/verify-l7.sh
  - docs/guarantees.md
  - tickets/0046-egress-guard-from-source.md
  - tickets/done/0046-egress-guard-from-source.md
bundle:
  - 0052-proxy-log-vault
  - 0052a-proxy-log-interval
  - 0046-egress-guard-from-source
  - 0047-retire-egress-guard-npm
  - 0049-proxy-logformat
  - 0048-firewall-l7-without-external-dns
  - 0050-template-internal-network
  - 0051-karakuri-internal-network
verify:
  - pnpm lint:sh
  - pnpm lint
  - pnpm test
---

# egress-proxy のアクセスログに時刻のミリ秒・接続時間・上り下りのバイト数を残す

## 内容

egress-guard と egress-proxy の配布・記録・経路を見直す束で、3つの流れからなる。

- egress-guard の配布をイメージだけにする（0046 / 0047）。各イメージが npm を経由せず、このリポジトリのソースから焼く
- egress-proxy のアクセスログを、LLM を通らない経路（パッケージのインストールスクリプト、git hooks、エディタ拡張、常駐プロセスなど）の通信を後から照会できる記録にする（0052 / 0049）。拒否された宛先の判定はこのリポジトリの外の監査側が持ち、ここでは保管庫とその契約までを提供する
- dev から DNS で外へデータを持ち出す経路を、dev を internal ネットワークだけに載せて塞ぐ（0048 / 0050 / 0051）。issue `#83` が起点で、`#83` は 0051 の close で閉じる

順序の依存は次のとおり。
0052 は他に依存しない。
0049 と 0048 は 0046 を待つ（0049 は 0046 と同じファイルに触るため、0048 は npm の新版を出さないので 0046 が無いと改修がイメージへ届かないため）。
0050 は 0048 入りの devcontainer-base のタグを待つ。
0051 は 0050 の着地と、0048 入りの devcontainer-base・0049 入りの egress-proxy のタグを待ち、karakuri の pin をまとめて上げる。

egress-proxy のアクセスログを、LLM を通らない経路（パッケージのインストールスクリプト、git hooks、エディタ拡張、常駐プロセスなど）の通信を後から照会できる記録として扱えるようにする束である。
悪性パッケージは公表が数週〜数か月遅れるので、「その期間にその宛先へ通信したか」を1年遡って引けることが要になる。
0052 がログをホストの保管庫へ書き出して1年保持し、0049 がログの行に照会と時刻の突き合わせに要る項目を足す。
拒否された宛先の判定（抑制リスト、未判定の管理、照会）はこのリポジトリの外の監査側が持つ。

### 前提

0046（egress-guard をソースから焼く）が `images/egress-proxy/` と `verify-l7.sh` に触るので、0046 の着地後に着手する。
0046 の targets に `squid.conf` は入っていない。

修復: 0046-egress-guard-from-source（close 前に統合ブランチへマージされた。tickets/done/ への移動と status の書き換えをこの PR に載せる）

### 変えるもの

`images/egress-proxy/squid.conf` の `access_log` を、組み込みの `squid` 形式から独自の `logformat` に替える。
行は次の項目をこの順に持つ。

```
logformat karakuri %ts.%03tu %6tr %>a %Ss/%03>Hs %>st %<st %rm %ru %un %Sh/%<a %mt
access_log /var/log/squid/access.log karakuri
```

- `%ts.%03tu` — ミリ秒までの epoch 時刻。監査側がエージェントのツール呼び出しの時刻と突き合わせ、対応する呼び出しが無い通信から LLM を通らない経路を推定するために使う
- `%6tr` — 接続時間（ミリ秒）。CONNECT ではトンネルが開いていた時間になる
- `%>a` — 接続元のアドレス。どのコンテナからの通信かを区別する
- `%Ss/%03>Hs` — 結果コード（`TCP_TUNNEL/200`、`TCP_DENIED/403` など）
- `%>st` — クライアントから受け取ったバイト数（クライアントから見た上り）。許可済みの宛先経由での大量送信を拾うために使う
- `%<st` — クライアントへ返したバイト数（クライアントから見た下り）
- `%rm %ru %un %Sh/%<a %mt` — 組み込みの `squid` 形式と同じ項目（method、URL または `host:port`、ユーザー、階層と宛先アドレス、MIME 型）

上りと下りを分けるのが組み込み形式からの主な違いで、組み込み形式の `%<st` 1列ではトンネルの合計しか読めない。
この形式の行を squid 5.7（Debian `5.7-2+deb12u5`）を直接起動して実測した。
`squid -k parse` は通り、CONNECT で約 500KB を受け取った許可の行は `%>st` が 200、`%<st` が 500229 と、上りと下りが分かれて記録された。

```
1791349197.186     11 127.0.0.1 TCP_TUNNEL/200 200 500229 CONNECT 127.0.0.1:19000 - HIER_DIRECT/127.0.0.1 -
1791349197.199      0 127.0.0.1 TCP_DENIED/403 118 429 CONNECT 10.255.255.1:9999 - HIER_NONE/- text/html
```

（実測時の並びは `%<st` を前、`%>st` を末尾に置いていた。上はこのチケットの並びに組み替えたもので、値は実測のまま）

`%Ss/%03>Hs` のあとに `CONNECT host:port` が続く並びは組み込み形式と変わらないので、`verify-l7.sh` の `proxy_log_has` の正規表現（`"$1 .*CONNECT $2:"`）はそのまま当たる。
直すのは、新しい項目が行に現れることの検査を足すところだけである。
`squid.conf` のログの節のコメントは、形式を替えた理由（上の項目の用途）に合わせて直す。

### 保管庫の契約との関係

0052 の保管庫は行の形式を squid.conf の `logformat` を正本として参照し、「行の形式は egress-proxy の版で変わりうる」と述べている。
このチケットの着地後、保管庫には組み込み形式の行とこの形式の行が、egress-proxy の版の切り替わりを境に混ざる。
行の形式に版の印は入れない。
組み込み形式も時刻は `%ts.%03tu` なので時刻の書式では見分けられないが、空白区切りの列の数が組み込み形式の10に対してこの形式は11になる（`%un` が `-` のとき）。
監査側はこれで見分ける。

### タグと pin

このチケットはイメージを変えるだけで、`egress-proxy-v*` のタグを打つことと karakuri の pin を上げることは含まない。
タグは着地後に打ち、karakuri の pin は 0051 がまとめて上げる。

### やらないこと

- SNI の記録（`ssl_bump peek`）。パッケージの差し替えと検証の費用に見合わないので見送った
- ログの書き出し・ローテーション（0052）
- `strip_query_terms` の変更。平文 HTTP の URL の query は既定どおり落としたままにする
- 検査の深さ: 各項目の値の正しさ（バイト数が実際の転送量と一致するか、時間が実際の接続時間か）は検査しない。行に項目が現れ、許可と拒否の両方で並びが崩れないことだけを見る

## 保証

### 新たに宣言する保証

- egress-proxy のアクセスログの各行は、許可・拒否の結果と宛先に加えて、ミリ秒までの時刻、接続時間、接続元のアドレス、クライアントから受け取ったバイト数と返したバイト数を持つ — `未検証の約束 (テスト困難: 稼働中の egress-proxy と外向きの到達性が要り、pnpm test からは走らせられない。verify-l7.sh で常設化し、検収で走らせる。漏れうるのは squid の版上げで項目の意味が変わることで、許可と拒否の両方の行を目で読む)`。台帳の末尾に未検証の約束の節を新設する（起源 `0049-proxy-logformat`）

### 維持する保証

- B-c の各行（proxy を迂回できないこと、ACL が焼き込みであること、先頭ドットの許可）は、`verify-l7.sh` のログ検査がこの形式でも当たり続けることで維持する
- C-3a（squid を非 root で起動する）は、ログの節だけを変えるので崩れない。CI の `squid -k parse` がこの形式の構文を検査する

### 廃止する保証

- なし（ログの項目を足す変更で、既存の約束を取り下げない）
