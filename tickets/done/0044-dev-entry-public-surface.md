---
status: close
type: feat
base: main
targets:
  - host-tools/karakuri.sh
  - host-tools/dock.sh
  - host-tools/tests/karakuri.test.sh
  - host-tools/README.md
  - docs/guarantees.md
  - example/README.md
  - images/devcontainer-base/PORT-FORWARDING.md
  - images/devcontainer-base/README.md
  - images/devcontainer-base/examples/docker-compose.yaml
  - .devcontainer/docker-compose.yaml
verify:
  - pnpm lint:sh
  - pnpm test
---

# dev container の入口を karakuri-dock に絞り、karakuri-dev-inject と dock.sh の内部モードを公開面から外す

## 内容

### 束の全体像

host-tools の公開面を縮め、互換性を壊す変更をまとめて `host-tools-v2.0.0` として出す。
0043（`--stdio` / 対話シェルが停止中のコンテナを起動しなくなり、`--ensure-running` が全コンテナを再起動して firewall を適用するようになった変更）は、既にマージ済みでタグは未打ち。
これも 2.0.0 に含める。

- 0044（このチケット）: dev container の入口を `karakuri-dock` に絞る
- 0045: `karakuri-prod-exec` / `karakuri-image-digest` / `karakuri-check-image` を削除する

0044 と 0045 は `host-tools/karakuri.sh` などの targets が重なるので、順に実装する（0044 → 0045）。
タグは両方が着地した後に打つ（チケットの作業ではない）。

### 背景

0043 で、`karakuri-dock up` は「dev と sidecar がすべて起動中で secret 注入済み」を、正規の手順を通った印として扱うようになった。
`karakuri-dev-inject` を直接打つと、この印を firewall の無いコンテナにも付けられてしまう（例: Docker Desktop の開始ボタンで起動した後に打つ）。
注入の入口を `karakuri-dock up` だけにして、この経路を利用者の手順から消す（#75）。

### 変更

**`karakuri-dev-inject` を内部関数にする**

- `host-tools/karakuri.sh` の `karakuri-dev-inject` を `_karakuri_dev_inject` に改名する（`_karakuri_*` は既存の内部関数の命名規約）。
  `karakuri-dock` からの呼び出しを追従させる。
- 冒頭の目次コメントと `karakuri-help` の一覧から外す。
- エラーメッセージの接頭辞 `karakuri-dev-inject:` は、利用者が打ったコマンド名で出るように `karakuri-dock:` にそろえる。
- 下位スクリプト `host-tools/dev-inject.sh` は残す。
- テスト（`host-tools/tests/karakuri.test.sh`）は内部名で呼び直す。
  公開関数の一覧を検査する2つのループからは `karakuri-dev-inject` を抜く。
  内部名が一覧に出ないことの検査は、既存の help の検査が受ける範囲で足りる。

**dock.sh の内部モードを約束とヘルプから外す**

- `--ensure-running` / `--secrets-ok` / 引数なしの対話シェルは、動作をそのまま残す（`karakuri-dock` が使う部品）。
- `usage()` と冒頭コメントのモード説明で利用者向けに示すのは `--stdio`（ssh の ProxyCommand 用）だけにする。
  内部モードは「`karakuri-dock` が使う部品で、直接打つ前提ではない」と1行で書く。
- 台帳 §14 の内部モードを約束する行は、起動確認モードの2行を除いて廃止する（下記）。
  対応するテストは内部の回帰テストとして残す（保証を持たないテストがあってよい）。

**文書の追従**

`karakuri-dev-inject` を名指しして、利用者に打たせている箇所をすべて `karakuri-dock ... up` に置き換える。

- `host-tools/README.md`: 「鍵を渡す」の一覧の行（:28）、alias 例の `dev-inject`（:84）、「dev container に入る」節の説明（:135）。
- `example/README.md`: 「dev の起動」の手順2（:142-149）と :162。
  手順は「`karakuri-dock -p app-dev -b app up` で起動と注入を済ませる」に書き換える。
  `-p` / `-b` の説明は `karakuri-dock` の引数として残す。
  :197 の「起動は従来どおり IDE が行う」「起動後 dev-inject を 1 回」は、0043 後の運用（起動も注入も `up`）に合わせる。
- `images/devcontainer-base/PORT-FORWARDING.md`: :164 の見出し、:172 / :174 / :211 の `dev-inject` を、注入の主体として `karakuri-dock up` を指す表現にする。
- `images/devcontainer-base/README.md:67`: 「認可鍵は dev-inject が注入する」を `karakuri-dock up` にする。
- `images/devcontainer-base/examples/docker-compose.yaml:108,114` と `.devcontainer/docker-compose.yaml:88,94`: 「ホスト側の dev-inject スクリプトを実行し直す」を「ホストで `karakuri-dock ... up` を実行し直す」にする。

### やらないこと

- `host-tools/dev-inject.sh` を直接実行できなくすること。ホストの利用者自身は防ぐ相手ではない。目的は誤った手順を案内から消すことである
- `host-tools/tests/dock.test.sh` の書き換え（ケースはそのまま内部の回帰テストとして残る）
- `docs/archive/` の言及（履歴層）
- `karakuri-prod-exec` / digest の2関数（0045）

## 保証

### 新たに宣言する保証

- 停止中のコンテナに対する標準入出力モードは、起動せずに非ゼロで終わり、stdout に何も出さず、stderr にホスト側で打つ起動コマンドを示す（テスト: "--stdio does not start a stopped container"）——下の廃止行から既定モードへの言及を除いた置き換え

### 維持する保証

- §13「dev 注入は、プロジェクト名を加工せずそのまま下位へ渡す……」と「dev 注入は、……いずれも下位スクリプトを起動せずに拒否する」の2行——関数は内部名になるが、`karakuri-dock` 経由の注入で同じ振る舞いが続く。テストの呼び出し名を変えても、検査する内容を変えないこと
- §13「コンテナへの入室は、起動確認 → secret の注入確認 →（未注入のときだけ注入）→ port forwarding → 対話シェル、の順に下位コマンドを呼ぶ」——改名した注入関数の呼び出しを追従させる箇所
- §13「ヘルプは下位スクリプトを一切呼ばず、公開している関数の名前と環境変数の現在値を出す」——一覧から1つ外すだけで、性質は変えない
- §14 起動確認モードの2行（「全コンテナが起動中で secret が注入済みなら……停止・起動せずに 0」「揃わなければ全コンテナを停止し……firewall を適用してから 0」）——起動確認モードは help から外すが、この2行は約束として残す。利用者が打つのは `karakuri-dock up` でも、「`up` が起こした dev には firewall が適用されている」はこの2行にしか書かれておらず、外すと firewall の約束が台帳から消えるため
- §14「標準入出力モードは secret 未注入のとき 1 で止まり……」「標準入出力モードは secret 注入済みのとき、絶対パスで sshd を起動する」——usage とコメントの書き換えで `--stdio` の動作を変えないこと

### 廃止する保証

- §14「secret の確認モードは、注入済みで 0、未注入で 1 を返し……」——内部モードになり、利用者への約束から外す
- §14「secret の確認モードはコンテナの起動状態を変えない……」——同上
- §14「既定モードは対話シェルを開き、作業ディレクトリの指定があるときだけそれを下位へ渡す……」——同上
- §14「停止中のコンテナに対する標準入出力モードと既定モードは……」——既定モードが内部になるため。新たに宣言する保証の行が置き換える
