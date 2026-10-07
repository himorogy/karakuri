---
status: draft # draft → open → close
type: feat
base: main
targets:
  - images/devcontainer-base/examples/docker-compose.yaml
  - packages/egress-guard/tests/verify-l7.sh
  - packages/egress-guard/README.md
  - images/devcontainer-base/README.md
  - docs/archive/egress-guard-spec.md
  - docs/archive/egress-guard-design.md
  - docs/guarantees.md
verify:
  - pnpm lint:sh
  - pnpm lint
  - pnpm test
---

# 雛形の compose で dev を internal ネットワークだけに載せ、DNS の持ち出し経路を塞ぐ

## 内容

束: 0052-proxy-log-vault → 0046-egress-guard-from-source → 0047-retire-egress-guard-npm → 0049-proxy-logformat → 0048-firewall-l7-without-external-dns → 0050-template-internal-network → 0051-karakuri-internal-network

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

### 前提

0048 の改修が devcontainer-base のイメージに焼かれ、タグが打たれてから着手する。
それより前の base で internal に載せると、`init-project-firewall.sh` が anchor を引けずに panic テーブルへ落ちる。
雛形の Dockerfile は浮動タグ `devcontainer-base:2` を参照しているので、0048 入りの版が 2.x で出れば雛形の側で版を書き換える必要は無い。
README には、internal の構成に要る base の最低版（0048 入りの版）を書く。

### 雛形の compose

`images/devcontainer-base/examples/docker-compose.yaml` に、トップレベルの `networks:` を2本定義する。

- internal 側（`internal: true`）— dev と egress-proxy が載る
- 外向き側 — egress-proxy だけが載る

dev は internal 側だけ、egress-proxy は両方に載せる。
**外向きのネットワークに1本でも載っていると、内蔵 resolver の転送が戻る**（issue `#83` の対照実験。internal と外向きの両方に載せたコンテナでは、存在しない名前に NXDOMAIN が返った）。
dev を両方に載せる構成は塞いだことにならないので、雛形のコメントでそう述べる。
ネットワーク名は実装の判断に任せる。

issue `#83` の実測で、この構成でも壊れないと確かめたもの: サービス名の解決、proxy 経由で許可先への接続（npm で 200）、egress-proxy 自身の外向き、ssh で入る経路（docker exec を土台にしているのでネットワークの影響を受けない）。
直接の外向きは経路そのものが無くなる（default route が無い）。
内蔵 resolver の転送が止まるには、moby の CVE-2024-29018 の修正（26.0.0-rc3 / 25.0.5 / 23.0.11 以降）が要る。
それより前の Docker でホストの resolver が loopback にある構成では漏れる（同 issue）。

### verify-l7.sh

- ハーネスの compose で、ネットワーク名を参照している箇所（`${PROJECT}_default` など）を新しい名前へ付け替える
- v6 ハーネスの overlay は暗黙の `default` ネットワークを `networks: default: {}` で参照している。トップレベルに `networks:` を定義すると暗黙の `default` は作られなくなるので、壊れるかを確かめて直す（壊れるかは未確認。実装者はこの開発環境で docker を動かせないので、compose の仕様で判断し、検収で走らせて確かめる）
- 「dev から外部名が DNS で解決できない」ことの検査を足す。dev の中から割り当て resolver に外部名を問い、答えが返らないことを `ok`、返ることを `ng` とする。既存の `ok` / `ng` / `skip` と判定不能（2）の作法に従う
- 既存の proxy 経由の検査が internal の構成で当たり続けることは、検収で走らせて確かめる

### README

`packages/egress-guard/README.md` の「ネットワーク構成（推奨）」節に、internal の構成を推奨として書く。
次を含める。

- dev を internal 側だけに載せ、egress-proxy を両方に載せること。dev を両方に載せると塞がらないこと
- Docker の版の条件（上記）
- internal と両立しない機能: `allowCidrs`・`allowHostPorts`（internal には外向きの経路もホストへの経路も無いので届かない）と、実現層 `l3`（dev 側の名前解決で allowlist を作るため）。これらを使う構成は従来の単一ネットワークのままにするしかなく、その場合は DNS の持ち出し経路が残る
- 0048 が足した警告（外部名が引けたら適用ログに出る）の意味

`images/devcontainer-base/README.md` が雛形の compose の構成を説明している箇所があれば、同じ内容に揃える（無ければ触らない）。

### archive の注記

`docs/archive/egress-guard-spec.md` §9.4 と `docs/archive/egress-guard-design.md` §3.1 は、DNS トンネルを受容した残余リスクとして書いている。
archive は凍結の慣例があり中身は書き換えないが、各節の冒頭に1行だけ注記を足す。
内容は「この経路は internal ネットワークの構成で塞いだ。現在形は `packages/egress-guard/README.md` を参照」とする。
archive は現在形の文書へ移したあとに消す予定の参考資料で、移す作業がこの節を読んだときに古い判断を README へ戻さないようにするためである。

### やらないこと

- karakuri 自身の `.devcontainer/` の変更（0051）
- egress-guard の改修（0048）
- `allowCidrs` / `allowHostPorts` / `l3` を internal で使えるようにすること
- archive の中身の書き換えと削除（現在形の文書への移送の作業が持つ）
- 検査の深さ: DNS の検査は外部名1つを dev から問うだけで、TCP と UDP の区別、resolver の応答コードの区別、IPv6 の経路は見ない。Docker の版の検出と警告も行わない（README に条件を書くだけ）

## 保証

### 新たに宣言する保証

- 雛形どおりに構成した dev からは、外部名を DNS で解決できない — `未検証の約束 (テスト困難: Docker と外向きの到達性が要り、pnpm test からは走らせられない。verify-l7.sh で常設化し、検収で走らせる。漏れうるのは dev を外向きのネットワークにも載せた構成と古い Docker で、前者は verify-l7.sh のハーネスが雛形と同じ構成であることで、後者は README の版の条件で受ける)`。台帳の未検証の約束 B-c に足す（起源 `0050-template-internal-network`）

### 維持する保証

- B-c「proxy の環境変数を読まずに直接外へ出ようとする接続は、縮小した最終テーブルが落とす」は、internal の構成では経路そのものが無くなるので、より強く成り立つ。文は変えない
- B-c の他の行（ACL が焼き込みであること、先頭ドットの許可）は、ネットワークの付け替えのあとも verify-l7.sh で当たり続けることで維持する
- 台帳「境界宣言」の E（雛形の compose）は公開面として残る。サービスの構成は変えず、ネットワークを足すだけである

### 廃止する保証

- なし（経路を塞ぐ変更で、取り下げる約束は無い）
