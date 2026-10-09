---
status: draft # draft → open → close
type: chore
base: main
targets:
  - .devcontainer/docker-compose.yaml
  - .devcontainer/Dockerfile
  - packages/egress-guard/tests/verify-l7.sh
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

# karakuri 自身の dev を internal ネットワークへ移し、base と egress-proxy の pin を上げる

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
退行すれば Docker 側の脆弱性として扱われる種類の振る舞いであり、こちらでは 0051 が verify-l7.sh に足す検査が常設で見張る。
0048 が egress-guard をその構成で動くようにし、0050 が雛形を移し、0051 が karakuri 自身と検収の構成を移す（検収の `verify-l7.sh` は karakuri 自身の `.devcontainer/docker-compose.yaml` を使うので、karakuri の構成と一緒に動かす）。

### 前提

次はすべて済んでいる。

- 0050 の着地（雛形の構成が定まっている）
- 0048 入りの devcontainer-base のタグ `devcontainer-base-v2.7.0`（runtime-base-v1.8.0 の後に打った）
- 0049（logformat の拡充）入りの egress-proxy のタグ `egress-proxy-v1.1.0`

2本のタグは同じコミット（0048 のマージ）を指し、0049 はその祖先に含まれる。

pin の更新をこの1枚にまとめるのは、karakuri の rebuild を1回で済ませるためである。

### 変えるもの

- `.devcontainer/Dockerfile` の `FROM` を `ghcr.io/himorogy/devcontainer-base:2.7.0@sha256:<digest>` に上げる
- `.devcontainer/docker-compose.yaml` の egress-proxy の `dockerfile_inline` の `FROM` を `ghcr.io/himorogy/egress-proxy:1.1.0@sha256:<digest>` に上げる
- `.devcontainer/docker-compose.yaml` に 0050 の雛形（`images/devcontainer-base/examples/docker-compose.yaml`）と同じ形でネットワークを2本定義する。名前は雛形どおり `internal`（`internal: true`）と `outward`。dev は `internal` だけ、egress-proxy は両方に載せる
- 同ファイルで、dev と egress-proxy が暗黙の `default` ネットワークに載っていることを前提にしたコメントを、新しい構成に合わせて直す

digest はこの開発環境から GHCR に届かない（`ghcr.io` への接続はプロキシに拒否され、`gh api` のパッケージ一覧も権限不足で 403。2026-10-09 に確認）。
実装者は着手の時点で利用者にホストでの `docker buildx imagetools inspect ghcr.io/himorogy/devcontainer-base:2.7.0` と `... egress-proxy:1.1.0` の結果を求め、その digest を書く。
このリポジトリは egress-proxy の配布元なので浮動タグを使わない、という既存の pin のコメントの規律に従う。

#### pin のコメントと N-1 規律

`.devcontainer/Dockerfile` の pin のコメントは、karakuri は1つ前の実証済みリリースへ pin する（N-1 規律）と定め、「次に規律が効くのは 2.7.0 以降で、そのとき karakuri は 2.6.0 に留まる」と書いている。
このチケットは 2.7.0 へ上げる。dev を internal に移すと、0048 を含まない 2.6.0 の `init-project-firewall.sh` は anchor を DNS で引けずに panic テーブルへ落ちるため、2.6.0 に留まったまま移せない。
規律の趣旨（karakuri の開発環境が最新リリースの故障で動かなくならないこと）は、2.6.0 のときと同じ型で満たす——下の検収の rebuild で動くことを確かめた版へ上げる。
コメントの「2.6.0 を選ぶ理由」と「N-1 規律との関係」を、2.7.0 を選ぶ理由（0048 を含む最初の版で、internal の構成に要る）と、検収の rebuild を実証とする旨に書き換える。
egress-proxy の pin のコメントの「初版のため、まだ N-1 の判断は無い」も、1.1.0 を選ぶ理由（0049 の logformat を含む最初の版）と、同じ検収で確かめる旨に書き換える。

### verify-l7.sh

ハーネスは karakuri 自身の `.devcontainer/docker-compose.yaml` を読むので、上のネットワークの変更と同じチケットで直す。

- ネットワーク名を参照している箇所を新しい名前へ付け替える。起票時点で見つかっているのは、`probe_curl()` が `docker run --network` に渡す `${PROJECT}_default`（proxy 経由の検査は dev と同じ側から投げるので `${PROJECT}_internal` が候補）と、v6 ハーネスの overlay。ほかにも無いかは実装者が洗う
- v6 ハーネスの overlay は暗黙の `default` ネットワークを `networks: default: {}` で参照している。トップレベルに `networks:` を定義すると暗黙の `default` は作られなくなるので、壊れるかを確かめて直す（壊れるかは未確認。実装者はこの開発環境で docker を動かせないので、compose の仕様で判断し、検収で走らせて確かめる）
- 「dev から外部名が DNS で解決できない」ことの検査を足す。dev の中から割り当て resolver に外部名を問い、答えが返らないことを `ok`、返ることを `ng` とする。既存の `ok` / `ng` / `skip` と判定不能（2）の作法に従う
- 既存の proxy 経由の検査が internal の構成で当たり続けることは、検収で走らせて確かめる

### 検収

ホストで rebuild したあと、次を確かめる。

1. `init-project-firewall.sh` が panic テーブルへ落ちずに最終テーブルを適用し、外部名が引けない旨を情報として出していること（引けた旨の警告が出ていないこと）
2. dev の中から外部名が DNS で引けないこと（`dig` で答えが返らない）
3. Claude Code・Codex・VS Code の拡張機能が普段どおり動くこと（Claude Code のログインと応答、Codex の実行、拡張機能のインストールと更新）
4. ssh で入る経路（sshd、ポートフォワード）が動くこと
5. egress-proxy のアクセスログに 0049 の形式の行が出ていること
6. `pnpm verify:l7` が通ること

### やらないこと

- 雛形・README の変更（0050）
- egress-guard の改修（0048）
- タグを打つこと（このチケットの前提であって、変更ではない）
- 検査の深さ: 3 の確認は日常の操作が通ることだけを見る。拡張機能ごとの通信先の洗い出しはしない

## 保証

### 新たに宣言する保証

- なし（karakuri 自身の開発環境の構成を雛形に揃える変更で、公開面に触れない。DNS が引けない約束は 0050 が雛形について宣言している）

### 維持する保証

- 台帳 E-a（pin を上げたあとの rebuild）。検収の rebuild で確かめる
- B-c の各行は、karakuri の構成で `pnpm verify:l7` が通ることで維持する
- 0050 が B-c に足した「雛形どおりに構成した dev からは、外部名を DNS で解決できない」の行。B-c の着地先は節の見出しのとおり「verify-l7.sh で常設化し、検収で走らせる」であり、このチケットが verify-l7.sh に検査を足すことでその記述が実体を持つ。台帳の文と着地先は変えない

### 廃止する保証

- なし（取り下げる約束は無い）
