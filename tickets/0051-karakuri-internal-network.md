---
status: draft # draft → open → close
type: chore
base: main
targets:
  - .devcontainer/docker-compose.yaml
  - .devcontainer/Dockerfile
verify:
  - pnpm lint:sh
  - pnpm lint
  - pnpm test
---

# karakuri 自身の dev を internal ネットワークへ移し、base と egress-proxy の pin を上げる

## 内容

束: 0052-proxy-log-vault → 0052a-proxy-log-interval → 0046-egress-guard-from-source → 0047-retire-egress-guard-npm → 0049-proxy-logformat → 0048-firewall-l7-without-external-dns → 0050-template-internal-network → 0051-karakuri-internal-network

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

次がすべて済んでから着手する。

- 0050 の着地（雛形の構成が定まっている）
- 0048 入りの devcontainer-base のタグ（runtime-base → devcontainer-base の順に打つ）
- 0049（logformat の拡充）入りの egress-proxy のタグ

pin の更新をこの1枚にまとめるのは、karakuri の rebuild を1回で済ませるためである。

### 変えるもの

- `.devcontainer/Dockerfile` の `FROM ghcr.io/himorogy/devcontainer-base:<版>@sha256:<digest>` を、0048 入りの版と digest に上げる
- `.devcontainer/docker-compose.yaml` の egress-proxy の `dockerfile_inline` の `FROM ghcr.io/himorogy/egress-proxy:<版>@sha256:<digest>` を、0049 入りの版と digest に上げる
- `.devcontainer/docker-compose.yaml` に 0050 の雛形と同じ形でネットワークを2本定義し、dev は internal 側だけ、egress-proxy は両方に載せる。ネットワーク名は雛形に揃える

版と digest は着手の時点で GHCR から読む（起票の時点ではまだ存在しない）。
このリポジトリは egress-proxy の配布元なので浮動タグを使わない、という既存の pin のコメントの規律に従う。

### 検収

ホストで rebuild したあと、次を確かめる。

1. `init-project-firewall.sh` が panic テーブルへ落ちずに最終テーブルを適用し、外部名が引けない旨を情報として出していること（引けた旨の警告が出ていないこと）
2. dev の中から外部名が DNS で引けないこと（`dig` で答えが返らない）
3. Claude Code・Codex・VS Code の拡張機能が普段どおり動くこと（Claude Code のログインと応答、Codex の実行、拡張機能のインストールと更新）
4. ssh で入る経路（sshd、ポートフォワード）が動くこと
5. egress-proxy のアクセスログに 0049 の形式の行が出ていること
6. `pnpm verify:l7` が通ること

### やらないこと

- 雛形・`verify-l7.sh`・README の変更（0050）
- egress-guard の改修（0048）
- タグを打つこと（このチケットの前提であって、変更ではない）
- 検査の深さ: 3 の確認は日常の操作が通ることだけを見る。拡張機能ごとの通信先の洗い出しはしない

## 保証

### 新たに宣言する保証

- なし（karakuri 自身の開発環境の構成を雛形に揃える変更で、公開面に触れない。DNS が引けない約束は 0050 が雛形について宣言している）

### 維持する保証

- 台帳 E-a（pin を上げたあとの rebuild）。検収の rebuild で確かめる
- B-c の各行は、karakuri の構成で `pnpm verify:l7` が通ることで維持する

### 廃止する保証

- なし（取り下げる約束は無い）
