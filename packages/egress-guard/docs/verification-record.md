# 受け入れ検証の記録

## 0. この文書の目的

**穴が見つかったときに「なぜ見逃したのか」を追い、受け入れテストを改善するための記録**です。

手順書ではありません。手順は §6 に付録として置いてありますが、この文書の主眼は次の 3 つです。

| 節 | 問い |
|---|---|
| §2 カバレッジ | **何が確かめられていて、何が確かめられていないか** |
| §3 見つけた欠陥 | 検証が捕まえた欠陥は、なぜユニットテストで捕まらなかったのか。回帰させないための落とし穴と、テスト自体の欠陥もここ |
| §4 **見逃した欠陥** | 後から出た指摘を、当時のチェックリストはなぜ捕まえられなかったのか |

§4 が改善の直接の入力です。「どの観点が欠けていたか」を書きます。

**§6 はこの文書で最も分量が多く、全体のおよそ半分（行数では約 6 割）を占めます。それでも単独で読む節ではありません。** §2 のカバレッジ表の「根拠となる §6 の手順」列から辿るための付録で、「何が確かめられているか」（§2）に対する「どうやって確かめたか」を置く場所です。新しく読む人は §2 から入り、必要になった行だけ §6 を開いてください。

生のターミナル出力は**判定を決めた行だけ**を引用します。全文は残しません。

---

## 1. 実施状況

| 環境 | 日付 | 範囲 | 結果 |
|---|---|---|---|
| Docker Desktop / macOS arm64、linuxkit 6.12.76、**デフォルトブリッジ** | 2026-08-02 | §6.1〜§6.13 | 全項目合格（5 件の実装欠陥を発見・修正） |
| 同上、**ユーザー定義ネットワーク**（`egress-guard-toganashi`） | 2026-08-03 | §6.18（§6.2・§6.3・§6.6・§6.15 の再実施を含む） | 全項目合格 |
| 同上、デフォルトブリッジ | 2026-08-03 | §6.14・§6.15・§6.16・§6.17、および §6.11 に統合された当時の項目 16 | 当時の項目 18.4 を除き合格（18.4 に対応する手順は現行 §6 に無い。§5 を参照） |
| 同上、デフォルトブリッジ、**egress-guard 未適用**（Claude Code v2.1.220） | 2026-08-03 | [`web-search-fetch.md`](./web-search-fetch.md) §5.1（当時の §6.19 の 19.0〜19.2） | WebFetch は直接 egress する。**文書の推論を否定** |
| 同上（実装の静的解析。環境非依存） | 2026-08-03 | [`web-search-fetch.md`](./web-search-fetch.md) §5.2（当時の §6.20） | 参照元記事の主張を再現。**打ち切りの「サイレント」のみ食い違い** |
| 同上、ユーザー定義ネットワーク、**audit モード** | 2026-08-03 | §6.21 | 起動後セットアップに要る 2 ドメインを特定 |
| 同上、ユーザー定義ネットワーク、**enforce** | 2026-08-03 | §6.19 の 19.3、および §6.21 の再実施 | 合格。プロビジョニング中だけ audit にする運用で起動後セットアップが成立した |
| 同上、**Docker Compose**（`egress-guard-toganashi_default`、gw `172.22.0.1`） | 2026-08-03 | §6.22（§6.2・§6.3・§6.6・§6.15 の再実施を含む） | **全項目合格。** README の第一推奨がこれで検証済みになった |
| 同上、**`enforce` と `audit` を比較**（VS Code の UI 上での確認） | 2026-08-03 | §6.23 | `enforce` では拡張が 2 つ入らない。[`known-issues.md`](./known-issues.md) #7 の実害を確認 |

> **§3 の欠陥 1・2 は、この表より前の初期検証で見つけたものです。** §6 のチェックリストを整備する前に実施したもので、実施日と範囲の記録は残っていません。そのため §6 には対応する節がありません。

**未実施の環境**は [`known-issues.md`](./known-issues.md) を参照してください（IPv6 が有効なコンテナ、Linux ホスト、CI ランナー、rootless Docker）。

---

## 2. カバレッジ

[`spec.md`](./spec.md) §11 の受け入れ基準に対する対応です。**「未確認」の行がこの表の主役**です。

[`spec.md`](./spec.md) §11 は不変条件（I1〜I7）ごとに分類されているため、**どの不変条件が実環境で確かめられていないか**をこの表から追えます。

本表の「不変条件」列は [`spec.md`](./spec.md) §11 の同名の見出しに、「受け入れ基準」列はその見出し下の各チェック項目に、「根拠となる §6 の手順」列は本書 §6 の手順にそれぞれ対応します。

### 確認済み

| 不変条件 | 受け入れ基準 | 根拠となる §6 の手順 | 判定を決めた出力 |
|---|---|---|---|
| — | 2 回連続実行で同一結果・exit 0 | §6.6 の 6.1 | `iptables-save` の diff が日時コメント行のみ |
| — | 3 回以上繰り返しても壊れない | §6.6 の 6.3 | `FAILED` が一度も出ない |
| **I2** | `timeout -s KILL` をどの段階で当てても未許可先に到達できない | §6.7 の 7.1・7.3 | 7 通りのタイミングすべてで `-P OUTPUT DROP` |
| **I3** | 中断後の再実行で収束する | §6.7（当時の項目 7.2。これに対応する明示の手順は現行 §6 に無い） | — |
| **I5** | 不正な `firewall.json` が全て拒否される | §6.8 の 8.3 | — |
| **I5** | ワイルドカードの拒否メッセージが代替を示す | §6.8 の 8.3 | `wildcards are not supported ... List the host names you need instead` |
| **I7** | [`spec.md`](./spec.md) §5 の自己検証が全て通る | §6.2 の 2.2 | `self verification passed` |
| **I4** | `dig @<外部DNS>` が UDP / TCP とも失敗する | §6.3 の 3.2・3.3 | `communications error to 8.8.8.8#53: timed out` / `exit=9` |
| **I4** | DNS の DROP が汎用 ESTABLISHED ACCEPT より前 | §6.3 の 3.4 | `--dport 53 -j DROP` の**次**に `--ctstate RELATED,ESTABLISHED -j ACCEPT` |
| **I7** | ip6tables default DROP | §6.5 の 5.1・5.2 | `-P OUTPUT DROP`（v6）、`match-set` 無し |
| **I7** | IPv6 の未許可先が REJECT される | §6.5 の 5.2b | `-j REJECT --reject-with icmp6-adm-prohibited` |
| **I1** | sudoers が固定パス・引数なし、対象が root 所有・書き換え不可 | §6.1 の 1.1・1.3・1.4、§6.12 の 12.1 | `(root) NOPASSWD: /usr/local/bin/init-project-firewall.sh ""` |
| **I1** | 非 root 所有スクリプトの sudo 実行が exit≠0 | — | **ユニットテストのみ**（§2 未確認を参照） |
| **I1** | 引数付き sudo が拒否され、引数なしは通る | §6.12 の 12.1・12.2 | 引数付き `exit=1`、引数なし `exit=0` |
| **I1** | ワークスペース側 `firewall.json` を書き換えても変化しない | §6.14 の 14.1 | 適用後も `-j REJECT`（`ACCEPT` にならない） |
| **I1** | `/etc/egress-guard/firewall.json` の所有者・権限違反で exit≠0 | §6.14 の 14.3・14.4（14.4 は当時の項目 18.2） | `must be owned by root (found uid 1000)` / `must not be a symlink` |
| **I6** | `allowHostPorts` が両アドレスに対して開く | §6.15 の 15.1・15.2b | ゲートウェイと `host.docker.internal` の 2 行、到達は後者のみ |
| **I4** | 外部ネームサーバーへの試行が記録される | §6.11（当時の項目 16。判定の 1・2 番目の箇条書き） | `8.8.8.8` のみ記録、正規リゾルバは記録されない |
| **I6** | 許可ドメインが禁止レンジを返しても allowlist に入らない | §6.17 | `resolved only to forbidden addresses, skipping` + set に不在 |
| **I2** | 設定エラーで panic テーブルが適用される | §6.16 | `applying panic policy` + `match-set` 不在 |
| — | 個別ドメイン解決失敗で起動が止まらない | §6.9 | `failed to resolve ..., skipping` + `exit=0` |
| **I7** | audit mode で DROP されず遮断先が記録される | §6.10 の 10.1・10.2 | — |
| **I4/I7** | audit mode でも DNS 固定・IPv6・INPUT が締まっている | §6.10 の 10.3・10.4 | — |
| **I7** | 遮断先が allowlist ACCEPT の直後・REJECT の前に記録される | §6.11 の 11.1 | `match-set ... ACCEPT` の直後に `-j SET --add-set` |
| **I7** | `SET` が使えない環境でフォールバックする | — | **ユニットテストのみ** |
| — | 実利用（`git fetch` / `pnpm install` / GitHub API）が成立する | §6.13 | — |
| — | **WebFetch はコンテナから直接 egress する**（従来の推論の否定） | [`web-search-fetch.md`](./web-search-fetch.md) §5.1 の 5.1.2 | `209.51.188.20:443 users:(("claude",pid=32345,fd=14))` |
| — | WebSearch はコンテナから egress しない | [`web-search-fetch.md`](./web-search-fetch.md) §5.1 の 5.1.3 | 検索 2 回で新規 peer なし（常駐テレメトリ 2 件を baseline に含めた上で） |
| — | **事前承認 91 ドメインでは要約がバイパスされ原文が返る** | [`web-search-fetch.md`](./web-search-fetch.md) §5.2 の 5.2.4・5.2.7 | `prompt` が無視され、`curl` と一致する 16,445 バイトが返った |
| — | **遮断された WebFetch はフォールバックせず失敗する** | §6.19 の 19.3 | `allowDomains` 外は出力なしで失敗、`allowDomains` 内と WebSearch は成功 |
| — | 起動後セットアップが成立する（プロビジョニング中だけ audit） | §6.21 | `enforce` 復帰後に `example.com` 到達不可・`openssh-server` 導入済み |
| — | shellcheck クリーン / ユニットテスト全通過 | CI | — |
| — | nat テーブルが変更されない | §6.2 の 2.4、**§6.18 の 18.3**、**§6.22 の 22.6** | 適用前後の `iptables-save -t nat` が `IDENTICAL`。Compose 構成でも `DOCKER_OUTPUT` の `127.0.0.11` 宛 DNAT が残存 |
| **I6** | Compose 構成でも `allowHostPorts` が両アドレスに開く | §6.22 の 22.8d | gw が `172.22.0.1` に変わっても両アドレスの ACCEPT が出る。到達は `host.docker.internal` 側 |
| — | `dockerComposeFile` 下で `runArgs` が無視される | §6.22 の 22.10 | 仕込んだラベルが `docker inspect` に現れない |

### 未確認

**ここがこの文書で最も重要な部分です。**

| 未確認のこと | なぜ確認できていないか | 代替の担保 |
|---|---|---|
| **`host.docker.internal` が公開アドレスを返す場合の拒否** | 偽の DNS 応答をコンテナ内から作れない。`/etc/hosts` の細工は効かない（`resolve_domain` は `dig` を先に試し、Docker がこの名前に応答する） | `tests/firewall-rules.test.sh` の `hostpublic` |
| **非 root 所有スクリプトの sudo 実行拒否** | 実機で再現するにはスクリプトを意図的に壊す必要がある | 同 `placement` |
| **`SET` ターゲットが使えないカーネルでのフォールバック** | 検証環境のカーネルでは常に使える | 同 `recorderfallback` |
| **IPv6 の実到達性（`curl -6` の遮断）** | コンテナに global IPv6 アドレスが無く、自己検証でも恒常的にスキップされる | なし（[known-issues #2](./known-issues.md)） |
| **Linux ホストでの動作** | 検証環境がすべて linuxkit VM | なし（[known-issues #3](./known-issues.md)） |
| **I3: GitHub meta API 不達でも適用が成立すること** | 検証環境では meta API に常に到達できた。ネットワークを部分的に落とす手順が無い | `tests/firewall-rules.test.sh` の `panic` ケースが近いが、そこでは DNS も落ちるため meta 単独の不達は未確認 |

> **優先度の反転は解消しました。** README が第一に推奨する Docker Compose 構成は、2026-08-03 に §6.22 で検証済みです。残っている 6 行は、いずれも**環境か再現手段が無くて確かめられないもの**であり、後回しにしているものではありません。

---

## 3. 検証で見つかった実装の欠陥

**すべてユニットテスト（記録型スタブ）を通過していたもの**です。各件の「なぜ捕まらなかったか」が、テスト設計の改善点になります。

| # | 欠陥 | 発見 | なぜユニットテストで捕まらなかったか | 追加した回帰テスト |
|---|---|---|---|---|
| 1 | `127.0.0.11` 決め打ち。デフォルトブリッジでは埋め込みリゾルバが存在せず起動しない | §6 のチェックリストを整備する前の初期検証 | **スタブが実環境の分岐を持っていなかった。** `resolv.conf` の内容を 1 通りしか想定していなかった | `resolv.conf` を 4 パターン（埋め込み / ホスト / v6 のみ / 空）に分けた |
| 2 | `IFS=$'\n\t'` の下で `"$*"` が改行連結になり、1 行のルールが 4 行に割れる | §6 のチェックリストを整備する前の初期検証 | **アサーションが部分一致だった。** 期待する部分文字列が含まれてさえいれば通ってしまう。加えて `assert_contains ... -- 'pattern'` の `--` 誤用で 12 件が空振りしていた | `assert_well_formed_table`（全行が `-A ... -j ...` の形か）と、全アサート関数の引数個数チェック |
| 3 | `resolve_domain \| head -n1` の SIGPIPE でスクリプトごと落ちる | 当時の項目 8.2<br>（現行 §6.8 に対応する手順は残っていない） | **スタブの応答が 1 行だった。** 複数行返さない限り `head` は上流を殺さない | `dig` スタブを 3 行返す形に変更 |
| 4 | 自己検証プローブが `example.com` 固定。それを `allowDomains` に入れると正しい設定で起動不能 | 当時の項目 8.5<br>（現行 §6.8 に対応する手順は残っていない） | **`ipset test` スタブが常に成功していた。** アドレスを見ていなかったため、プローブが allowlist 内かどうかを判定できていなかった | `ipset` スタブをアドレス認識型に変更、`probeallowed` ケース追加 |
| 5 | カーネルログが出力されない（`nf_log_all_netns` 既定 0） | §6.10 の 10.2 | **スタブは `LOG` ルールの生成しか見ていない。** カーネルが実際に出力するかは、記録型スタブの守備範囲外 | 該当なし（設計変更で ipset 記録に移行） |
| 6 | `allowDomains` の DNS 応答に禁止レンジ検査が無く、`169.254.169.254` が allowlist に載る | §6.17<br>（レビュー由来） | §4 を参照 | `dnsprivate` / `dnsallprivate` |

### ここから読み取れるパターン

1〜4 は**すべてスタブの作りが甘かったことが原因**です。「スタブが単純すぎると、実環境でしか出ない分岐が消える」。特に **2 と 4 は、テスト自体が壊れていて空振りしていた**ケースで、テストの存在がかえって安心材料になっていました。

改善として、アサート関数に引数個数チェックを入れ、追加する回帰テストは**必ず修正前のコードで失敗することを確認**する運用にしています。

### 回帰させないこと（実装上の落とし穴）

**回帰させないための箇条書きです。** 上の表の欠陥がコードのどの形として現れたかを、対応する欠陥番号を括弧で添えて書いてあります。**末尾の 1 件だけは対応する欠陥行がありません。** 実装をレビューするときはここを見てください。

* **`IFS=$'\n\t'` の下で `"$*"` を使わない。** 改行で連結され、1 行のルールが複数行に割れます。空白連結が必要な箇所では `local IFS=' '` を使ってください（欠陥 2）
* **パイプの下流で早期終了しない。** `head -n1` / `grep -q` / `awk '...; exit'` は上流を SIGPIPE で殺し、`set -o pipefail` + `set -e` の下ではスクリプト全体が落ちます。出力をいったん変数に受けてから処理してください（欠陥 3）
* **自己検証のプローブをハードコードしない**（[`spec.md`](./spec.md) §5.1）（欠陥 4）
* **自己検証を「最初の 1 IP」で判定しない**（[`spec.md`](./spec.md) §5.2）。DNS ラウンドロビンで起動がランダムに失敗します（欠陥 4）
* **DNS 応答を検証済みデータとして扱わない**（I5、[`spec.md`](./spec.md) §4.5）。`allowCidrs` にある検査は、名前解決の結果にも要ります（欠陥 6）
* **外部コマンドに渡す前にアドレスファミリで絞る。** GitHub meta API は IPv6 プレフィックスも返します。`aggregate` の挙動はビルドによって異なるため、渡す前に IPv4 だけにしてください（この 1 件は上の表に対応する欠陥行がありません。出所の記録が残っていません）

**配置の検査が競合する攻撃者には勝てないこと**は規範側の注意なので [`spec.md`](./spec.md) §7.1 に残してあります。

### テスト自体の欠陥: ユニットテストがホスト環境に依存していた（修正済み）

**これは実装の欠陥ではなくテスト自体の欠陥ですが、上の表の欠陥 2・4 と同じ「テストが空振りしている」形なのでここに置きます。**

**`tests/firewall-rules.test.sh` の「configuration source」ブロックは、`/etc/egress-guard/firewall.json` が存在しない環境でしか通りません。** egress-guard を導入した devcontainer の中で `pnpm test` を実行すると落ちます（2026-08-03 に発生）。

```
FAIL --check-config does not search the working directory (missing: no firewall.json found)
FAIL the apply path ignores the workspace copy (missing: no firewall.json found)
FAIL the workspace copy cannot relax the policy (missing: ^:OUTPUT DROP)
```

**落ちる件数は実効設定の `mode` で変わります。** `audit` のコンテナでは 3 件、`enforce` のコンテナでは 3 件目が偶然通って 2 件になります。**件数を目印にしないでください。**

`PROD_CONFIG="/etc/egress-guard/firewall.json"` は固定パスで、上書き手段がありません（[`design.md`](./design.md) の「見に行く場所を増やすほど攻撃面が増える」に基づく意図的な設計）。**したがってテスト側で環境を分岐させる必要があります。**

CI には `/etc/egress-guard` が無いため緑のままで、**この依存は導入済みコンテナの中でしか表面化しません。**

#### 最初に書いた修正方針は誤りだった

当初ここには「`PROD_CONFIG` の存在で**期待値を分岐**させる」と書いていました。**これは間違いです。**

`CONFIG_FILE` は `PROD_CONFIG` が存在した時点で確定します（`init-project-firewall.sh` の `[ -n "$CONFIG_FILE" ] || { [ -f "$PROD_CONFIG" ] && ... }`）。**そのためワークスペース側のコピーは、スクリプトが作業ディレクトリを探そうが探すまいが、そもそも到達されません。** 期待値を差し替えれば緑にはなりますが、**ブロック全体が何も検査していない状態**になります。

変異解析で確認しました。`./.devcontainer/firewall.json` を探すよう改造したビルドを、期待値を分岐させた版のテストに掛けても **5 件すべて `ok` のまま通過**しました。上の表の欠陥 2・4 と同じ「テストが空振りしている」状態です。

#### 実際の修正: 観測できない項目は skip する

`PROD_CONFIG` が存在する環境では、当該 5 件を **`SKIP` にして件数を集計に出す**ようにしました。緑にするより、**その環境では確かめられないと表示するほう**が正確です。

```
140 passed, 0 failed, 5 skipped
```

CI（`/etc/egress-guard` が無い）では従来どおり全件実行されます。同じ変異を CI 相当の条件で掛けると **3 件が落ちます**。検査は生きています。

**副産物として、防御が二段になっていることも確認できました。** 変異版は「作業ディレクトリを探した」ところで止まらず、その次の配置検査で弾かれます。

```
[firewall] ERROR: ./.devcontainer must be owned by root (found uid 1000);
                  a writable directory lets the file be replaced
[firewall] ERROR: applying panic policy (egress DROP) after failure
```

> **`PROD_CONFIG` にテスト用の上書きを足す案は採りませんでした。** sudo の `env_reset` で無効化されるとはいえ、固定パスであること自体が設計判断です（[`design.md`](./design.md) §2.1）。

---

## 4. 検証が見逃した欠陥

**当時のチェックリストを全項目合格したうえで、後のレビューで見つかったもの**です。各件に「どの観点が欠けていたか」を書きます。

### 4.1 実効設定をエージェント自身が書き換えられた

**指摘:** sudoers によりエージェントはいつでも再適用でき、再適用が読む `firewall.json` はエージェントが書ける場所にあった。`{"mode":"audit"}` と書いて `sudo` を打つだけで、root を取らずにポリシー全体が無効になる。

**なぜ見逃したか — 検証項目が「機能の正しさ」しか見ていなかった。**

§6.12 は「権限昇格経路の遮断」を確認していますが、確認していたのは**root が取れないこと**でした。この脅威モデルにおける敵はエージェント自身なので、**root を取らずに目的を達成できる経路**が抜けていました。

> **欠けていた観点:** 「攻撃者が root を取れるか」ではなく「**攻撃者が目的を達成できるか**」で検証項目を立てる。

現在は §6.14 でこれを検証しています。

### 4.2 バリデーション失敗時に開いたまま残った

**指摘:** 適用フェーズが設定検証の後に始まるため、設定エラーではルールが一切適用されず終了していた。再適用時なら直前の閉じたポリシーが残るが、**初回起動時の「直前」は全 ACCEPT**。

**なぜ見逃したか — チェックリストがその挙動を「合格」として記録していた。**

これが最も重い見逃しです。当時の項目 8.4「バリデーション失敗時にルールが変更されていないこと」は、**当時の実装の記述としては正しく、合格と記録されました。** しかし確認していたのは「実装が意図どおりか」であって、「**その意図が正しいか**」ではありません。

さらに、判定に使った `-P OUTPUT DROP` は**前回の適用が残していたもの**でした。初回起動を模していないため、「何も適用されていない」と「閉じている」を区別できていません。

> **欠けていた観点 (1):** 検証項目は仕様を追認するだけになりうる。「この期待結果は、望ましい状態か」を項目ごとに問う。
>
> **欠けていた観点 (2):** **初期状態を明示する。** 「前回の適用が残っている状態」と「素の状態」で結果が変わる項目は、両方を実施する。

§6.7 の 7.4「素の状態からの中断」はこの観点を部分的に持っていましたが、**中断（SIGKILL）にしか適用していませんでした**。エラー終了には適用していません。

> **欠けていた観点 (3):** **異常終了の経路を網羅する。** §6.7 は SIGKILL だけを扱っていた。`die` する経路（設定エラー、リゾルバ不在、IPv6 制御不能、host 解決失敗）ごとに終了状態を確認する項目が無かった。

現在は §6.16 でこれを検証しています。**当時の項目 8.4 の記録は現行仕様と正反対の結論**であり、§6 では削除しています。

### 4.3 DNS 応答から禁止レンジへ到達できた

**指摘:** `allowCidrs` は RFC1918 / CGNAT / link-local を拒否するのに、ドメインの A レコードには同じ検査が無かった。許可済みドメインのゾーンが汚染されれば `169.254.169.254` が allowlist に載る。

**なぜ見逃したか — 検証が入力経路を 1 本しか見ていなかった。**

§6.8 の 8.3 は不正な `firewall.json` が拒否されることを確認していますが、**同じ値が別の経路（DNS 応答）から入ってくる可能性**を検証項目にしていませんでした。

> **欠けていた観点:** **同じ検査を必要とする入力経路を列挙する。** 「設定ファイル」「DNS 応答」「GitHub meta API」「`ip route`」「`resolv.conf`」はいずれも外部由来の値がルールに至る経路であり、検査の網羅性は経路ごとに問う必要がある。

現在は §6.17 でこれを検証しています。

### 4.4 `host.docker.internal` を許可していなかった

**指摘:** `allowHostPorts` がデフォルトゲートウェイ宛しか許可しておらず、Docker Desktop ではホスト上のサービスに届かない可能性がある。

**なぜ見逃したか — 検証が「閉じていること」しか確認していなかった。**

§6.4 の 4.6（当時の表題は「ホストゲートウェイが既定で閉じている」）は**遮断側だけ**を確認しています。`allowHostPorts` を指定したときに**実際に届くか**を確認する項目がありませんでした。

> **欠けていた観点:** **許可機能は「許可されること」まで確認する。** 遮断の確認だけでは、その機能が使えるかどうかは分からない。

§6.15 で実測したところ、ゲートウェイ宛の ACCEPT ルールには**パケットが 1 つも乗らず**（`pkts 0`）、到達は `host.docker.internal` 側でのみ成立していました。旧実装では機能そのものが動いていなかったことになります。

### 4.5 「DNS トンネリングの遮断」という過大主張

**指摘:** 53 番の宛先を固定しても、許可したリゾルバが再帰問い合わせをするためトンネリングは通る。埋め込みリゾルバでも同じ。

**なぜ見逃したか — 検証項目が文書の主張と対応していなかった。**

§6.3 は「`dig @8.8.8.8` が失敗すること」を確認しています。これは「**任意のネームサーバーへ直接投げる経路の遮断**」の確認であって、「トンネリングの遮断」ではありません。文書は後者を主張していましたが、それを検証する項目はありませんでした。

> **欠けていた観点:** **文書の主張と検証項目を突き合わせる。** 「この主張を裏付けているのはどの項目か」を問い、対応する項目が無い主張は主張しない。

現在は README / spec とも「DNS 経路の固定」に訂正し、防げない旨を明記しています。

---

## 5. チェックリスト自体の欠陥

手順の誤りです。**いずれも「実行できない」「判定にならない」もの**で、実装の欠陥ではありません。

**この節に出てくる番号は、当時のチェックリストの項目番号です。** 現行 §6 での対応先を括弧で添えます。対応する手順が残っていないものは、その旨を書きます。

### 実行できなかったもの

| 欠陥 | 原因 |
|---|---|
| 検査コマンドに `sudo` を使っていた | sudoers はスクリプトの引数なし実行しか許可していない。`sudo iptables -S` は通らない |
| `sudo timeout ...` が実行不能 | 同上 |
| 12 で `sudo -n` を使わずパスワード待ちで停止（現 §6.12） | 非対話にしていなかった |
| 15.2 / 15.3 が `nc` 前提（現 §6.15 は `curl` ベースに書き直し済み） | コンテナに `nc` が入っていない |
| 14.4 が repo 内のスクリプトを直接実行（**現 §6.14 の 14.4 は symlink 検査で、当時の 14.4 とは別内容**） | 実行ビットが無く `permission denied` |
| `/etc/hosts` の後始末に `sed -i` | bind mount のため inode を張り替えられず `Device or resource busy` |
| ホスト側 `python3 -m http.server` に `--bind 0.0.0.0` が無い | 既定で `::` にバインドされ、IPv4 接続が即座に拒否される。**firewall の `REJECT` と区別がつかず、無罪の firewall を疑う原因になった** |

### 判定にならなかったもの

| 欠陥 | 原因 |
|---|---|
| `grep 'ctstate ESTABLISHED'` が空振り | `iptables -S` は `--ctstate` を正規化して表示する（`ESTABLISHED,RELATED` → `RELATED,ESTABLISHED`） |
| `iptables-save` の diff にタイムスタンプ行が混ざる | 除外していなかった |
| `grep -c '/'` が過小カウント | ipset は `/32` を省略表示する |
| 7.3 に「`enforce` で実施」の前提が無い（現 §6.7 は冒頭で指定している） | `audit` では policy が `OUTPUT ACCEPT` になり、中断の成否を判定できない |
| 13 の `gh auth status` が疎通確認にならない（現 §6.13） | ネットワークに触れない |
| 15.2 / 15.3 がゲートウェイアドレスを直書き（現 §6.15 は取得して使う） | ネットワーク構成を変えると古いアドレスを叩く（§6.18 で実際に発生） |
| 18.4 が `/etc/hosts` で名前解決を細工できる前提（**現行 §6 に対応する手順は無い**） | `resolve_domain` は `dig` を先に試すため `getent` に到達しない |
| **ユニットテストの「configuration source」がホスト環境に依存していた** | 修正済み。詳細と、最初に書いた修正方針が誤りだった経緯は §3 |

### ここから読み取れるパターン

* **環境の前提を検証に含めていない** — `nc` の有無、`/etc/hosts` が bind mount であること、`iptables -S` の表示規則
* **アドレスやパスを直書きしている** — 構成が変わると古い値を叩き、しかも失敗が「遮断されている」ように見える
* **失敗の原因を区別できない判定** — `exit≠0` だけでは「遮断された」「相手が居ない」「コマンドが無い」が区別できない。`egress-audit-v4` の記録有無のような**遮断の証跡**を判定に入れる必要がある
* **調査の操作が証跡を汚す** — 遮断先の記録を読んでから候補 IP に `openssl` で当たると、その接続自体が `egress-audit-v4` に載る。**証跡を読む手順と、証跡を作る手順を同じコンテナで続けて実行しない**（当時の項目 21.6 で実際に汚染した）
* **記録の時刻は「いつ追加されたか」ではない** — `timeout` の残量から逆算できるのは最後に接触した時刻で、`--exist` の再追加でリセットされる。それでも**「コンテナ起動時刻より前のエントリがある」ことは、対象を取り違えている証拠として使える**（当時の項目 21.7）

---

## 6. 手順（付録）

**現行仕様に対して再実行可能な形**にしてあります。実施結果は §1〜§5 にあり、ここには書きません。

実行場所を `[node]`（コンテナ内・node ユーザー）、`[root]`（ホストから開く root シェル）、`[ホスト]` で区別します。

```sh
# [ホスト] root シェルを開く
docker exec -it -u root <container> bash
```

**`node` から `sudo iptables` は実行できません。** sudoers が許可しているのは `init-project-firewall.sh` の引数なし実行だけです。ルールの検査は `[root]` で行います。

### 6.1 配置と権限

| # | 確かめること | コマンド | 判定 |
|---|---|---|---|
| 1.1 | スクリプトが root 所有・755 | `[node] ls -l /usr/local/bin/init-project-firewall.sh` | `-rwxr-xr-x 1 root root` |
| 1.2 | `/etc/egress-guard` が root 所有・755 | `[root] ls -ld /etc/egress-guard` | `drwxr-xr-x ... root root` |
| 1.3 | node から書き換え不可 | `[node] echo x >> /usr/local/bin/init-project-firewall.sh` | `Permission denied` |
| 1.4 | sudoers が引数なしのみ | `[node] sudo -l` | `(root) NOPASSWD: /usr/local/bin/init-project-firewall.sh ""` |

### 6.2 基本の適用

| # | 確かめること | コマンド | 判定 |
|---|---|---|---|
| 2.1 | 起動時に適用されている | `[root] iptables -S OUTPUT \| tail -3` | `-j REJECT --reject-with icmp-admin-prohibited` |
| 2.2 | 手動実行が成功する | `[node] sudo /usr/local/bin/init-project-firewall.sh` | `self verification passed` / `exit=0` |
| 2.3 | default policy | `[root] iptables -S \| grep '^-P'` | INPUT / FORWARD / OUTPUT とも `DROP` |
| 2.4 | nat が変更されない | `[root] iptables-save -t nat \| grep -v '^#' > /tmp/a` → 適用 → 同 `/tmp/b` → `diff` | 差分なし |
| 2.5 | リゾルバ検出 | `[node] cat /etc/resolv.conf` と適用ログ | `DNS pinned to ...` が `nameserver` 行と一致 |

### 6.3 DNS 固定

| # | 確かめること | コマンド | 判定 |
|---|---|---|---|
| 3.1 | 通常の名前解決が動く | `[node] dig +short api.anthropic.com` | アドレスが返る |
| 3.2 | 外部 DNS（UDP）が遮断される | `[node] dig @8.8.8.8 +time=2 +tries=1 example.com` | `timed out` / `exit=9` |
| 3.3 | 外部 DNS（TCP）が遮断される | `[node] dig +tcp @8.8.8.8 +time=2 +tries=1 example.com` | 同上 |
| 3.4 | ルール順序 | `[root] iptables -S OUTPUT \| grep -n 'dport 53'` | リゾルバ宛 ACCEPT → `-j SET --add-set egress-audit-v4` → LOG → DROP。**この一連が汎用 `RELATED,ESTABLISHED` ACCEPT より前** |

### 6.4 allowlist

| # | 確かめること | コマンド | 判定 |
|---|---|---|---|
| 4.1 | 許可先に到達できる | `[node] curl -sS -o /dev/null -w '%{http_code}\n' https://api.anthropic.com/` | ステータスが返る |
| 4.2 | 未許可先が遮断される | `[node] curl -sS --max-time 5 https://example.com/` | `exit=7`（`Failed to connect`） |
| 4.3 | GitHub が使える | `[node] git ls-remote https://github.com/git/git HEAD` | 成功 |
| 4.4 | meta レンジが入っている | 適用ログ | `allowed N GitHub ranges from the meta API` |
| 4.5 | npm が使える | `[node] npm view react version` | バージョンが返る |
| 4.6 | ホスト網が既定で閉じている | `[root] iptables -S OUTPUT \| grep "$(ip route show default \| awk '{print $3}')"` | 該当なし（`allowHostPorts` 未設定時） |

### 6.5 IPv6

| # | 確かめること | コマンド | 判定 |
|---|---|---|---|
| 5.1 | default policy | `[root] ip6tables -S \| grep '^-P'` | すべて `DROP` |
| 5.2 | allowlist が存在しない | `[root] ip6tables -S \| grep match-set` | 該当なし |
| 5.2b | **silent DROP ではなく REJECT** | `[root] ip6tables -S OUTPUT \| tail -2` | `fw-drop6:` の LOG の後に `-j REJECT --reject-with icmp6-adm-prohibited` |
| 5.3 | 実際の到達性 | `[node] curl -6 -sS --max-time 5 https://example.com/` | 失敗。**global IPv6 アドレスが無い環境ではスキップになる**（§2 未確認） |

### 6.6 冪等性

```sh
# [root]
snap() { "$1" -t filter | grep -v '^#' | sed 's/\[[0-9]*:[0-9]*\]/[0:0]/g'; }
snap iptables-save > /tmp/r1.txt ; snap ip6tables-save > /tmp/r1.v6.txt
```

```sh
# [node]
sudo /usr/local/bin/init-project-firewall.sh > /tmp/run2.log 2>&1 ; echo "exit=$?"
```

```sh
# [root]
snap iptables-save > /tmp/r2.txt ; snap ip6tables-save > /tmp/r2.v6.txt
diff /tmp/r1.txt /tmp/r2.txt && diff /tmp/r1.v6.txt /tmp/r2.v6.txt && echo IDENTICAL
```

**判定（6.1）:** `IDENTICAL`。加えて `grep -E 'WARNING|ERROR' /tmp/run2.log` が空（2 回目も名前解決と meta 取得が成功している）。

3 回以上の反復（6.3）:

```sh
# [node]
for i in 1 2 3; do sudo /usr/local/bin/init-project-firewall.sh >/dev/null 2>&1 || echo "run $i FAILED"; done
```

### 6.7 中断耐性

**`enforce` モードで実施してください。** `audit` では policy が `OUTPUT ACCEPT` になり、中断の成否を判定できません。

```sh
# [root] 複数のタイミングで刻む
for t in 0.05 0.1 0.2 0.5 1 1.5 2; do
  timeout -s KILL "$t" /usr/local/bin/init-project-firewall.sh >/dev/null 2>&1
  echo "t=$t OUTPUT=$(iptables -S | grep '^-P OUTPUT')"
done
```

**判定（7.1・7.3）:** すべてのタイミングで `-P OUTPUT DROP`。その後 `[node]` から未許可先へ到達できないこと。

**素の状態からの中断（7.4）**（`iptables -F && iptables -P OUTPUT ACCEPT` の直後に最短で kill）では `-P OUTPUT ACCEPT` が残ります。これは**仕様どおり**です。スクリプトが最初の `iptables-restore` に到達する前に殺された場合は「スクリプトが走らなかった」状態であり、`postStartCommand` の失敗としてコンテナ起動側に伝わります（[`spec.md`](./spec.md) §4.6）。

### 6.8 firewall.json のバリデーション

> **設定の書き換えには注意。** 実効設定は `/etc/egress-guard/firewall.json` です。検証中は `[root]` から直接編集するのが速いですが、**再ビルドを経た状態も 1 回は確認してください**（`COPY` の権限設定が正しいことの確認になります）。

**8.3 — 不正な設定が全て拒否されること。**

| 設定 | 期待結果 |
|---|---|
| `{ "version": 2 }` | `unsupported schema version` |
| `{ "version": 1, "allowDomains": ["*"] }` | `rejected allowDomains entry` |
| `{ "version": 1, "allowDomains": ["*.example.com"] }` | `wildcards are not supported` + **代替の書き方を含むこと** |
| `{ "version": 1, "allowCidrs": ["0.0.0.0/0"] }` | `rejected allowCidrs entry` |
| `{ "version": 1, "allowCidrs": ["192.168.0.0/16"] }` | 同上 |
| `{ "version": 1, "allowCidrs": ["100.64.0.0/10"] }` | 同上（CGNAT） |
| `{ "version": 1, "allowEverything": true }` | `unknown field` |
| `not json` | `is not valid JSON` |

`--check-config` は `sudo` なしで実行できます（`sudo` を付けると §6.12 のとおり拒否されます）。

**同梱テンプレートがそのまま通ること**も確認します。

```sh
# [node]
for f in /usr/local/share/npm-global/lib/node_modules/@himorogy/egress-guard/templates/*.json; do
  init-project-firewall.sh --check-config --config "$f" || echo "FAILED: $f"
done
```

### 6.9 ドメイン解決失敗時の挙動

`allowDomains` に解決できない名前を 1 件混ぜて適用します。

**判定:** `WARNING: failed to resolve ..., skipping` が出たうえで `exit=0`。他の許可先（§6.4）が成立したままであること。自己検証は `verify SKIP: none of the N firewall.json domains resolved` になります。

### 6.10 audit モード

`{ "version": 1, "mode": "audit" }` を適用します。

| # | 確かめること | 判定 |
|---|---|---|
| 10.1 | 未許可先に到達できる | `curl https://example.com/` が成功 |
| 10.2 | 遮断先が記録される | `[root] ipset list egress-audit-v4` の Members が非空 |
| 10.3 | DNS 固定は維持される | `dig @8.8.8.8` が `timed out` |
| 10.4 | IPv6 と INPUT は締まったまま | `ip6tables -S \| grep '^-P'` がすべて DROP、`iptables -S \| grep '^-P INPUT'` が DROP |

**確認後は必ず `enforce` に戻してください。**

### 6.11 遮断先の記録

```sh
# [root]
ipset flush egress-audit-v4
```

```sh
# [node]
curl -sS --max-time 5 https://example.com/ ; dig @8.8.8.8 +time=2 +tries=1 example.com
```

```sh
# [root]
ipset list egress-audit-v4
iptables -S OUTPUT | grep -n 'SET --add-set'
```

**判定:**

* `example.com` のアドレスと `8.8.8.8` の**両方**が記録されている
* **正規のリゾルバは記録されていない**（DNS の recorder はリゾルバ宛 ACCEPT より後にある）
* **（11.1）** 記録ルールが `match-set egress-allow-v4 dst -j ACCEPT` の**直後**、`REJECT` の**前**にある
* `ipset flush egress-audit-v4` で空にでき、再適用しても set は作り直されない

### 6.12 権限昇格経路の遮断

```sh
# [node]
sudo -n /usr/local/bin/init-project-firewall.sh --config /tmp/evil.json ; echo "exit=$?"
sudo -n /usr/local/bin/init-project-firewall.sh --check-config ; echo "exit=$?"
sudo -n iptables -S ; echo "exit=$?"
sudo -n cp /bin/sh /usr/local/bin/init-project-firewall.sh ; echo "exit=$?"
```

**判定:**

* **12.1** すべて `exit≠0`
* **12.2** 引数なしの `sudo -n /usr/local/bin/init-project-firewall.sh` だけが `exit=0`

### 6.13 実利用の疎通確認

```sh
# [node]
git ls-remote https://github.com/git/git HEAD
pnpm install --dry-run
curl -sS -o /dev/null -w '%{http_code}\n' https://api.github.com/rate_limit
```

**判定:** いずれも成功。**`gh auth status` は使わないでください**（ネットワークに触れないため疎通確認になりません）。

### 6.14 実効設定の分離

**この項目が通らない場合、他がすべて合格でも目的は達成されていません。**

| # | 手順 | 判定 |
|---|---|---|
| 14.1 | `[node]` ワークスペース側に `{"mode":"audit","allowDomains":["example.com"]}` を置いて `sudo` で再適用 | ログが `/etc/egress-guard/firewall.json` を読む。`allowed example.com` が出ない。適用後も `-j REJECT` |
| 14.2 | `[root]` `/etc/egress-guard/firewall.json` を退避して適用 | `no firewall.json found, using base profile only`（ワークスペース側を拾わない） |
| 14.3 | `[root]` `chown node` して適用 | `must be owned by root (found uid 1000)` + panic |
| 14.3 | `[root]` `chmod 666` して適用 | `must not be group or world writable (mode 666)` + panic |
| 14.4 | `[root]` `firewall.json` を symlink に置き換えて適用 | `must not be a symlink` + panic。**リンク先が root 所有でも拒否されること**が要点 |
| 14.5 | `[node]` `/usr/local/bin/init-project-firewall.sh --check-config`（cwd に `.devcontainer/firewall.json` がある状態） | `reading /etc/egress-guard/firewall.json`。cwd のファイルを拾わない |

> 14.3 / 14.4 は失敗させる項目です。実行後は panic テーブルが適用された状態になります。復旧を確認するまで通信できません。

### 6.15 ホスト宛の到達性

```sh
# [ホスト] --bind 0.0.0.0 は必須。省略すると :: にバインドされ IPv4 接続が拒否される
python3 -m http.server 15432 --bind 0.0.0.0
```

`{ "version": 1, "allowHostPorts": [15432] }` を適用します。

```sh
# [node] アドレスは直書きせず取得する
GW=$(ip route show default | awk '{print $3}')
HI=$(getent ahostsv4 host.docker.internal | awk '{print $1}' | head -1)
curl -sS -o /dev/null -w "gw:%{http_code}\n" --max-time 5 "http://$GW:15432/"
curl -sS -o /dev/null -w "hi:%{http_code}\n" --max-time 5 "http://$HI:15432/"
```

**判定（15.1・15.2b）:** 少なくとも `host.docker.internal` 側が `200`。`[root] iptables -S OUTPUT | grep 15432` に**両方のアドレス**の ACCEPT があること。

**非許可ポートの遮断は `exit≠0` だけでは判定になりません**（相手が居ないだけでも同じ結果になる）。遮断の証跡を見ます。

```sh
# [root]
ipset flush egress-audit-v4
```

```sh
# [node]
curl -sS --max-time 5 "http://$HI:15433/" ; echo "exit=$?"
```

```sh
# [root]
ipset list egress-audit-v4
```

**判定:** `exit=7` かつ **`egress-audit-v4` にそのアドレスが記録されている**。

> **`getent hosts` ではなく `getent ahostsv4` を使ってください。** 前者は IPv6 を優先して返し、スクリプトが実際に許可したアドレスと食い違います。

### 6.16 設定エラーで panic テーブルが適用される

```sh
# [root]
cp /etc/egress-guard/firewall.json /tmp/fw.bak
echo '{ "version": 1, "allowCidrs": ["0.0.0.0/0"] }' > /etc/egress-guard/firewall.json
/usr/local/bin/init-project-firewall.sh ; echo "exit=$?"
iptables -S OUTPUT
ip6tables -S | grep '^-P'
```

**判定:** `exit≠0`、`applying panic policy`、`-P OUTPUT DROP` で `match-set` が無く `--sport 22` の ESTABLISHED のみ。IPv6 も DROP。

```sh
# [root]
cp /tmp/fw.bak /etc/egress-guard/firewall.json
/usr/local/bin/init-project-firewall.sh ; echo "exit=$?"
```

**判定:** `exit=0` に戻る。

### 6.17 禁止レンジを返すドメイン

```sh
# [root] /etc/hosts は bind mount のため sed -i が使えない
echo "169.254.169.254 metadata.test" >> /etc/hosts
echo '{ "version": 1, "allowDomains": ["metadata.test"] }' > /etc/egress-guard/firewall.json
/usr/local/bin/init-project-firewall.sh 2>&1 | grep -E 'forbidden|metadata'
ipset list egress-allow-v4 | grep 169.254 ; echo "grep exit=$? (1 が正しい)"
grep -v 'metadata.test' /etc/hosts > /tmp/h && cat /tmp/h > /etc/hosts
```

**判定:** `which is in a forbidden range` と `resolved only to forbidden addresses, skipping` が出て、**適用は成功する**（個別ドメインの解決失敗は warn して継続）。set に `169.254.*` が入っていないこと。自己検証もこのドメインをスキップし panic にならないこと。

### 6.18 推奨構成（ユーザー定義ネットワーク）

**README が推奨する構成での再検証です。** デフォルトブリッジでの結果をもって「動作確認済み」としないでください。

| # | 確かめること | コマンド | 判定 |
|---|---|---|---|
| 18.1 | ネットワークに繋がっている | `[ホスト] docker inspect -f '{{json .NetworkSettings.Networks}}' <container> \| jq 'keys'` | 目的のネットワークのみ。`bridge` を含まない |
| 18.2 | 埋め込みリゾルバが使われる | `[node] grep nameserver /etc/resolv.conf` | `127.0.0.11`。適用ログの警告 2 行が**出ない** |
| 18.3 | **nat の DNS DNAT が壊れない** | §6.2 の 2.4 と同じ手順 | `IDENTICAL`。`iptables -S -t nat \| grep DOCKER_OUTPUT` に `127.0.0.11` 宛 DNAT が残る |
| 18.4 | 名前解決が動く | `[node] dig +short api.anthropic.com` | アドレスが返る |
| 18.5 | 主要項目の再実施 | §6.2 / §6.3 / §6.6 / §6.15 | **§6.15 は特に注意。** ゲートウェイのアドレスが変わり、`host.docker.internal` の解決経路も変わり得る |
| 18.6 | デフォルトブリッジに戻せる | 構成を戻して適用 | 成功し、警告 2 行が再び出る |

> **18.3 がこの項目の本命です。** デフォルトブリッジには DNS DNAT ルールが存在しないため、「nat を触らない」という設計判断はこの構成でしか検証できません。

> Docker Compose 構成（README の第一推奨）での再検証は §6.22 で実施済みです。上記は `initializeCommand` 構成で実施したものです。

### 6.19 遮断された WebFetch がフォールバックしないこと

**`enforce` 下で、`allowDomains` に無いドメインの WebFetch がそのまま失敗することを確かめます。** 成功するなら Anthropic 側の取得へ切り替わっていることになり、[`web-search-fetch.md`](./web-search-fetch.md) の「取得先ごとの許可が要る」という記述が成り立ちません。

| # | 確かめること | 手順 | 判定 |
|---|---|---|---|
| 19.3 | 遮断時のフォールバック | `enforce` 適用後、`allowDomains` に無いドメインを WebFetch する | **失敗する**（2026-08-03 実施）。成功するならフォールバックしている |

> **再測定では別の URL を使ってください。** WebFetch の応答は URL ごとに 15 分キャッシュされます。

> **egress-guard を適用しない状態での測定（WebFetch / WebSearch が実際に egress するか）は [`web-search-fetch.md`](./web-search-fetch.md) §5.1 へ移しました。** 当時の項目 19.0〜19.2 が対応します。egress-guard 自身の検証ではなく、外部ツールの挙動の測定だからです。

結果は §1・§2 と [`web-search-fetch.md`](./web-search-fetch.md) §1。

### 6.20 WebFetch の要約と打ち切りの確認（実装の静的解析）

**この手順は [`web-search-fetch.md`](./web-search-fetch.md) §5.2 へ移しました。** egress-guard の検証ではなく、外部ツールの実装をバージョンごとに確かめ直すためのものだからです。当時の項目 20.1〜20.7 が、同 §5.2 の 5.2.1〜5.2.7 に対応します。

結果は §1・§2。

### 6.21 audit モードで、起動後セットアップに要るドメインを洗い出す

**手順は [README](../README.md) の「特定の通信だけが通らない」へ移しました。** `enforce` にしたら何かが動かなくなった、という状況の切り分けであり、受け入れ検証の項目ではないためです。当時の項目 21.1〜21.7 が対応します。**ここから読み取れるパターンは §5 に残してあります。**

結果は §1・§2 と [README](../README.md) の「コンテナ起動後にセットアップを行う場合」、[known-issues #7](./known-issues.md)。

### 6.22 Docker Compose 構成（README の第一推奨）

**README が案 A として第一に推奨している構成です。** §6.18 は案 B（`initializeCommand`）で実施したため、長らく未検証のまま残っていました。

> **2026-08-03 に toganashi で実施し、全項目合格しました。** 判定を決めた出力は §1・§2。本命の 22.6 は `IDENTICAL` かつ `DOCKER_OUTPUT` の `127.0.0.11` 宛 DNAT（tcp→33353 / udp→36049）が残存。22.8d はゲートウェイが `172.22.0.1` に変わったうえで両アドレスの ACCEPT が出て `host.docker.internal` 側が `200`。22.10 は `false` で、README の「`runArgs` は無視される」が裏付けられました。

このリポジトリに検証用の一式を置いてあります。**既定の構成は案 B のままで、入れ替えたときだけ有効になります。**

* `.devcontainer/docker-compose.yml`
* `.devcontainer/devcontainer.compose.json`

#### 実施前に

> **既存コンテナ（`karakuri-dev-container`）を止めてください。** `container_name` を案 B と揃えてあるため名前が衝突します。`shutdownAction: none` なので自動では止まりません。衝突が起きる理由は [`../README.md`](../README.md) の「ネットワーク構成（推奨）」案 A の注意書き。

> **`claude` と `codex` の再ログインが要ります。** `${devcontainerId}` が Compose では使えない（同上）ため、`devcontainer.json` の `mounts` が作るボリュームとは別の、固定名のボリュームになります。既存のボリュームを引き継ぎたい場合は `docker volume ls | grep claude-code-config` で実名を調べ、`docker-compose.yml` の当該ボリュームを `external: true` にして名前を合わせてください。

| # | 確かめること | コマンド | 判定 |
|---|---|---|---|
| 22.0 | **マウント先と `workspaceFolder` が一致している** | `docker-compose.yml` の `volumes` と `devcontainer.json` の `workspaceFolder` を目で突き合わせる | 前者が `<親>:/X`、後者が `/X/<リポジトリ名>` になっていること |
| 22.1 | 入れ替え | `[ホスト] cd .devcontainer && mv devcontainer.json devcontainer.runargs.json && mv devcontainer.compose.json devcontainer.json` | — |
| 22.2 | 起動する | `[ホスト] provision-devcontainer.sh -w <repo>`（または Rebuild Container） | `postStartCommand` が成功して起動が完了する |
| 22.3 | ネットワーク | `[ホスト] docker inspect -f '{{json .NetworkSettings.Networks}}' karakuri-dev-container \| jq 'keys'` | Compose が作った 1 本のみ。**`bridge` を含まない** |
| 22.4 | **`cap_add` が効いている** | 22.2 が成功していること自体 | `iptables` を触れなければ適用が失敗する。**これが案 A の成否そのもの** |
| 22.5 | 埋め込みリゾルバ | `[node] grep nameserver /etc/resolv.conf` | `127.0.0.11`。適用ログの警告 2 行が**出ない** |
| 22.6 | **nat の DNS DNAT が壊れない** | §6.2 の 2.4 と同じ手順 | `IDENTICAL`。`iptables -S -t nat \| grep DOCKER_OUTPUT` に `127.0.0.11` 宛 DNAT が残る |
| 22.7 | 名前解決 | `[node] dig +short api.anthropic.com` | アドレスが返る |
| 22.8a | **主要項目の再実施** — 基本の適用 | §6.2 の手順 | §6.2 の判定どおり |
| 22.8b | 同 — DNS 固定 | §6.3 の手順 | §6.3 の判定どおり |
| 22.8c | 同 — 冪等性 | §6.6 の手順 | §6.6 の判定どおり |
| 22.8d | 同 — ホスト宛の到達性 | §6.15 の手順 | §6.15 の判定どおり。**ここは特に注意。** ゲートウェイのアドレスが案 B と変わる |
| 22.9 | 戻せる | 22.1 を逆に行って再ビルド | 案 B で起動し、警告 2 行が出ない（どちらもユーザー定義ネットワークのため） |

> **22.0 を飛ばさないでください。** マウント先と `workspaceFolder` がずれると `postCreateCommand` が **exit 127** で落ちます。なぜ案 A でだけ起きるのか、なぜ原因に辿り着きにくいのか、実際に踏んだ経緯は [`../README.md`](../README.md) の「ネットワーク構成（推奨）」案 A の注意書き。再現と切り分けはこうです。
>
> ```sh
> # [ホスト] 失敗したコマンドをそのまま再現する
> docker exec -w <workspaceFolder の値> <container> /bin/sh -c 'bash ./.devcontainer/post-create.sh'
> ```

> **22.6 がこの項目の本命です。** §6.18 と同じ理由で、「nat を触らない」という設計判断はユーザー定義ネットワーク上でしか検証できません。**案 A と案 B でネットワークの作られ方が違うため、案 B で通ったことは案 A の保証になりません。**

#### `runArgs` が無視されることの確認（任意）

README は「`dockerComposeFile` を使うと `runArgs` は無視される」と書いています。**これは主張であって、検証項目がありません。** 確かめるなら次を足してください。

| # | 確かめること | 手順 | 判定 |
|---|---|---|---|
| 22.10 | `runArgs` が無視される | `devcontainer.json` に `"runArgs": ["--label=egress-guard-runargs-test=1"]` を足して再ビルド → `[ホスト] docker inspect -f '{{json .Config.Labels}}' karakuri-dev-container \| jq 'has("egress-guard-runargs-test")'` | `false`。**`true` なら README の記述が誤り** |

**確かめたら `runArgs` は消してください。** 残しても効きませんが、効くように見える記述を構成に残すのは避けます。

### 6.23 `enforce` と `audit` で入る VS Code 拡張を比べる

**[`known-issues.md`](./known-issues.md) #7（`*.gallerycdn.vsassets.io` を allowlist できない）が実害として出ているかを確かめる手順です。** 拡張の実体を配る CDN が遮断されると、拡張のインストールが失敗します。

| # | 手順 | 注意 |
|---|---|---|
| 23.1 | `firewall.json` を `mode: "audit"` にして**再ビルドする** | **再接続では駄目です。** 導入物がホームに残っていると再インストールが走らず、差が出ません |
| 23.2 | VS Code の拡張ビューで、実際に入った拡張を控える | `~/.vscode-server/extensions` はボリュームに載っていないため、再ビルドのたびに再ダウンロードが走ります |
| 23.3 | `firewall.json` を `mode: "enforce"` に戻して**再ビルドする** | 23.1 と同じ理由で、ここも再接続では駄目です |
| 23.4 | 同じ手順で控え、23.2 と突き合わせる | **差が出た拡張が、遮断された CDN から配られているものです** |

> **2026-08-03 に実施しました。** 同じワークスペースで両モードを比べた結果です（VS Code の UI 上での確認）。
>
> | モード | 入った拡張 |
> |---|---|
> | `enforce` | `anthropic.claude-code`、`biomejs.biome` |
> | `audit` | 上記に加えて `ms-vscode.js-debug-companion`、`ms-ceintl.vscode-language-pack-ja` |
>
> **`enforce` では 2 つ足りません。** `gallerycdn` の遮断と整合します。
>
> **ただし「全滅する」わけではない点に注意してください。** `enforce` でも 2 つは入っており、この差がどこから来るのかは未確認です（別経路で取得しているのか、キャッシュから復元されたのか）。**「拡張が入らない」ではなく「一部が入らない」が正確な記述です。**
