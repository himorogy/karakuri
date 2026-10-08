---
status: draft # draft → open → close
type: feat
base: main
targets:
  - packages/egress-guard/scripts/init-project-firewall.sh
  - packages/egress-guard/tests/firewall-rules.test.sh
  - docs/guarantees.md
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

# L7 実現層で dev 側の外部名の解決に依存せずにファイアウォールを適用する

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

dev コンテナから DNS で外へデータを持ち出す経路を塞ぐ束である。
dev は Docker 内蔵の resolver（127.0.0.11）にだけ問い合わせられるが、内蔵 resolver は外部名を再帰的に転送するので、`<data>.attacker.example` のような問い合わせで外へ出られる。
proxy のログにも firewall の記録にも残らない唯一の経路で、インストールスクリプト型のマルウェアがよく使う手段でもある。
dev を `internal: true` のネットワークだけに載せ、egress-proxy を internal と外向きの両方に載せると、内蔵 resolver は外部名を転送しなくなる（issue `#83` に実測がある）。
これは偶然の挙動ではなく Docker の設計である。
moby の advisory GHSA-mq39-4gv4-mvpx（CVE-2024-29018。GitHub API で原文を確認）は、internal ネットワークだけに載ったコンテナは上流の resolver で外部名を解決できないことを設計として述べ、ホストの loopback の resolver を経由して外へ転送していた振る舞いを、データ持ち出しにつながる脆弱性として修正した（Moby 26.0.0-rc3 / 25.0.5 / 23.0.11 以降）。
同 advisory は、Docker の文書が `--internal` を「ネットワーク外との通信から完全に隔離する」と述べていることを修正の根拠に挙げている。
退行すれば Docker 側の脆弱性として扱われる種類の振る舞いであり、こちらでは 0050 が verify-l7.sh に足す検査が常設で見張る。
0048 が egress-guard をその構成で動くようにし、0050 が雛形と検収の構成を移し、0051 が karakuri 自身を移す。
0048 は0046（egress-guard をソースから焼く）の着地後に着手する。npm 0.5.0 を出さないので、0046 が無いとこの改修がイメージへ届かない。

### 現状と壊れ方

issue `#83` の実測（Docker Desktop 29.6.2）では、internal だけに載せた dev で外部名は SERVFAIL になり、サービス名（`egress-proxy`）は引ける。
この状態で `init-project-firewall.sh` を L7 で走らせると、`build_allowlist` が anchor（選ばれたバンドルのドメイン、既定では `api.anthropic.com`）を `resolve_domain` で引けずに `die` し、panic テーブルへ落ちる。
L7 では名前による許可は proxy の ACL が担い、dev 側の解決結果は ipset に入れず、生存確認にしか使っていない。

L7 の経路で外部名を引いているのは次の箇所である。

- `add_domain` — バンドルと `allowDomains` の名前を引き、L7 では ipset に入れずに生存の証拠としてだけ使う。引けなければ警告して続ける
- `build_allowlist` の anchor の判定 — 引けなければ `die`
- `self_verify` の「割り当て resolver で anchor が引ける」検査 — 引けなければ `VERIFY_FAILED` で `die`
- `self_verify` の「allowlist に無いホストへ届かない」検査 — 探針の名前が引けなければ既に skip している。internal では常に skip になる

`resolve_proxy_target`（`egress-proxy` の解決）はサービス名なので internal でも引け、変えない。
外部の resolver（`DNS_PROBES`）へ直接問う検査は、届かないことを期待する検査なので internal でもそのまま通る。

### 変えるもの

L7 実現層に限り、次のように変える。
L3 実現層の振る舞いは一切変えない（L3 は dev 側の名前解決で allowlist を作るので internal と両立しない。両立しないことの記述は 0050 が README に書く）。

```
if layer == l7:
    バンドルと allowDomains の名前を dev 側で引かない（引けない名前の警告も出ない）
    anchor の生存確認を、最終テーブルの適用後に proxy 経由で anchor へ CONNECT が通ることで行う
        通らなければ非ゼロで終わり panic テーブルへ落ちる（今の「anchor を引けなければ panic」と同じ重さ）
    割り当て resolver で anchor を引く検査をやめ、代わりに「割り当て resolver で外部名が引けるか」を見る
        引けたら: 外部名が DNS で転送されている（DNS の持ち出し経路が開いている）旨を警告し、実行は続ける
        引けなかったら: その旨を情報として出す
else:  # l3
    今のまま
```

外部名が引けることを失敗にしないのは、internal に移していない利用者（既存の雛形のまま使っている構成）を壊さないためである。
警告は、その構成に DNS の持ち出し経路が残っていることを適用ログで見えるようにする。
「外部名」として何を引くかは実装の判断に任せるが、許可リストに無く、存在が安定している名前にする（今の `EGRESS_PROBES` の流用でよい）。

proxy 経由の到達の確かめ方（`curl -x` など）は実装の判断に任せる。
ただし HTTP の応答コードの中身は問わず、proxy を通ってトンネルが開いたことだけを見る。
anchor が空の設定（CIDR とホストポートだけ、先頭ドットだけ）は、今と同じく検査を飛ばした旨を述べて 0 で終わる。

テストは `firewall-rules.test.sh` のスタブ（`dig` / `getent` を差し替える既存の作法）で、外部名が引けない状態と引ける状態の両方を L7 で組む。
proxy 経由の到達もスタブで差し替える。

### やらないこと

- compose の雛形・karakuri の compose・`verify-l7.sh` の変更（0050 / 0051）
- README の変更（0050 が internal の構成と一緒に書く）
- L3 実現層の変更
- `allowCidrs` / `allowHostPorts` を internal で使えるようにすること（internal には外向きの経路が無いので届かない。0050 が README で両立しないと述べる）
- 検査の深さ: proxy 経由の到達の検査で、proxy が遅いだけの場合と届かない場合の区別、タイムアウトの値の妥当性は検査しない。外部名の転送の検査は1つの名前で見るだけで、resolver の種類や応答コードの区別（SERVFAIL と NXDOMAIN など）はしない

## 保証

### 新たに宣言する保証

台帳の §5（`firewall-rules.test.sh`）に足す。
テスト名は実装時に決め、各行に併記する。

- L7 実現層では、dev 側の DNS が外部名を解決できない構成でも、proxy 経由で anchor に届く限り、最終テーブルを適用して 0 で終わる（テスト: 新設）
- L7 実現層で anchor がある場合、proxy 経由で anchor に届かなければ非ゼロ終了し panic テーブルへ落ちる（テスト: 新設）
- L7 実現層では、割り当て resolver が外部名を解決できるとき、DNS が外へ転送されている旨の警告を適用ログに出し、実行は失敗にしない（テスト: 新設）

### 維持する保証

- §5「anchor がある場合に解決できなければ非ゼロ終了し panic テーブルへ落ちる」と「設定に書いたドメインを解決できないときは、その名前を挙げた警告を適用ログに出す」は、L3 実現層の約束として残す。条件節「L3 実現層では」を足して、L7 の新しい行と範囲が重ならないようにする
- §5 の panic へ落ちる原因の列挙（「設定の拒否・resolver の欠落・anchor の解決失敗……」）は、anchor の解決失敗を「anchor の生存確認の失敗」と読める形に直す。panic へ落ちること自体は変えない
- §5 の L7 の最終テーブルの順序と構成の行は変えない（テーブルの中身はこのチケットで変わらない）
- §5「anchor になるドメインが1つも無い設定は失敗ではなく……0 で終わる」は L7 でもそのまま成り立たせる

### 廃止する保証

- なし（L7 の生存確認の手段を替え、L3 の約束は条件節を足して残すだけで、取り下げる約束は無い）
