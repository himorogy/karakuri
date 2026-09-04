---
status: close
type: feat
base: main
targets:
  - .devcontainer/docker-compose.yaml
  - CLAUDE.md
  - docs/conventions.md
  - example/README.md
  - example/docker-compose.yaml
  - images/devcontainer-base/Dockerfile
  - images/devcontainer-base/PORT-FORWARDING.md
  - images/devcontainer-base/README.md
  - images/devcontainer-base/examples/docker-compose.yaml
  - images/runtime-base/Dockerfile
  - images/runtime-base/bin/git-askpass
verify:
  - pnpm lint
  - pnpm lint:sh
  - pnpm test
---

# devcontainer を CLI 作成前提とし、環境変数を compose へ一本化する

## 内容

devcontainer-base は環境変数を「イメージの `ENV`」と「`/etc/environment` への転記」の 2 箇所へ
書いている。理由として書かれているのは「sshd は自分の environ をセッションへ引き継がないため、
`ENV` だけでは SSH セッションに届かない」であり、機構としては正しい。

しかし実測すると、転記の対象 8 変数は `/etc/environment` に**二重に**載っている。devcontainer CLI
がコンテナを作るとき、そのライフサイクル処理（`patchEtcEnvironment`、マーカー
`/var/devcontainer/.patchEtcEnvironmentMarker` で作成時 1 回）がコンテナの env 全量を写すためで
ある。空が正常値の `GIT_CONFIG_VALUE_0=""` も保たれていた。手動の転記は CLI 経由の作成では
まるごと冗長になっている。

**そして CLI 以外の作成手段は、はじめから支援対象ではない。** `devcontainer.json` は `features`・
`postCreateCommand`・`postStartCommand` を持ち、`waitFor` を `postStartCommand` に置いている。
素の `docker compose up` はこの 3 つを飛ばすため、**egress-guard が適用されないコンテナ**ができる。
環境変数が一部届かないどころの話ではなく、その構成は成立していない。

この 2 つを踏まえて、前提を明記したうえで配り方を 1 段に落とす。

1. **前提を明記する** — devcontainer は CLI（`devcontainer up`）または VS Code Dev Containers 拡張で
   作る。素の `docker compose up` は支援しない。理由は features・postCreate・postStart が走らず
   egress-guard が適用されないこと。置き場は `images/devcontainer-base/README.md` と
   `PORT-FORWARDING.md`
2. **`/etc/environment` への手動転記を落とす** — `images/devcontainer-base/Dockerfile` の
   `RUN printf ... >> /etc/environment`。CLI が写すため不要になる
3. **環境変数の置き場の規律を定める** — `docs/conventions.md` に書く。基準は「利用側が変える前提が
   あるか」で、変える前提が無いものだけイメージの `ENV`、それ以外は compose の `environment:`。
   対象変数の分類は下記
4. **`CRIT_PUBLIC_URL` を `.devcontainer/docker-compose.yaml` に置く** — crit は Host ヘッダを検査し、
   `localhost` と loopback IP 以外を `403` で拒む。`karakuri.test:4588` で開くには広告 URL で
   ホスト名を 1 つ与える必要がある。広告 URL は bind を変えないため listen は `127.0.0.1` のまま。
   併せて `CRIT_ALLOW_UNAUTHENTICATED_NETWORK=1` を置く（新しい crit が広告 URL の指定だけで
   ネットワーク露出とみなして起動を拒否するため。base に焼かれている版はまだ要求しない）
5. **使われていない `ENV DEVCONTAINER=true` を削除する** — このリポジトリにあった
   `packages/enclave-env`（`7854c38` で廃止）が読んでいた値で、base の初回コミットから引き継がれて
   いた。現在はリポジトリ・イメージに焼かれたスクリプト・インストール済みツール
   （`claude` / `crit` / `gh` / `dotenvx`）・個人フックのいずれからも読まれていない
6. **転記を根拠にしている記述を全部直す** — `example/README.md`、雛形 2 本の compose、
   `images/runtime-base/Dockerfile` の言及コメント、`images/devcontainer-base/README.md`
7. **CLAUDE.md の Bash 規律を一般化する（本題の外、軽微な追記）** — 現在の記述は
   `cd X && grep ... file` の形だけを名指ししているが、条件は「読み取り先が静的に決まらないこと」で
   あり、リポジトリ全体への再帰 grep でも同じく成立する（本チケットの起草中に実際に止まった）。
   条件のほうを書く

### 環境変数の分類

置き場の基準は「**利用側が変える前提があるか**」で切る。変える前提が無いものはイメージの `ENV`、
開発者やプロジェクトごとに変えるものは compose の `environment:` に置く。

イメージの `ENV`（変える前提が無い）:

- `LANG` / `LC_ALL` / `TZ`（runtime-base）— イメージのロケール。`TZ` はビルド引数で変えられる
- `PNPM_HOME` / `NPM_CONFIG_PREFIX` / `PATH`（runtime-base）— イメージの構造そのもの
- `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_0` / `VALUE_0` / `KEY_1` / `VALUE_1`（runtime-base）と
  `GIT_ASKPASS`（devcontainer-base）— 変えられると認証が壊れる。生死は `git-auth-check` が毎回報告する
- `CRIT_NO_UPDATE_CHECK=1`（devcontainer-base）— 起動の決定性と egress の予測可能性のための設計判断
- `SHELL=/bin/zsh`（devcontainer-base）— 収録物に紐づく

compose の `environment:`（開発者・プロジェクトごとに変える）:

- `NODE_OPTIONS` — マシンのメモリ次第
- `CLAUDE_CONFIG_DIR` — **既定値と同じパスであることを確認できたら compose から削除する。**
  確認は実装時に行う。異なっていた場合は残す——compose は `/home/node/.claude` に named volume を
  マウントしており、設定の置き場がそこから外れるとリビルドのたびに黙って失われる
- `CRIT_PORT` — **base の `ENV` から移す。** `4588` は base が決めた仕様ではなく好みの値であり、
  複数プロジェクトを同時に開いたときにずらす対象でもある。値の原本を雛形の compose に置き、
  base は「固定する理由」だけを文書で持つ
- `CRIT_PUBLIC_URL` — プロジェクトのホスト名
- `CRIT_ALLOW_UNAUTHENTICATED_NETWORK` — **`CRIT_PUBLIC_URL` と同じ場所に対で置く**（下記）

`CRIT_ALLOW_UNAUTHENTICATED_NETWORK` を base に焼かない理由は、これが機能の有効化ではなく
**承認**だからである。crit が起動を拒むのは「広告 URL が非空」のときと「listen が非 loopback」の
ときの 2 つで、base に `=1` を焼くと後者の拒否も一緒に消える。base は `CRIT_HOST` を設定しない
判断を明示しているが、利用側が `CRIT_HOST=0.0.0.0` を置いたときの最後の関門が、承認を先に
与えたことで無くなる。承認は、それを必要とする判断（ホスト名で開く）と同じ場所に置く。

削除するもの:

- `DEVCONTAINER=true`（devcontainer-base）

### 検知の穴を確認する

転記を落とすと、認証の 5 変数（`GIT_CONFIG_*`）と `GIT_ASKPASS` が SSH セッションに届くかどうかは
CLI の写し込みに依存する。これが外れたときの症状は「SSH 経路の git だけホスト側の資格情報で通る」
で、成功してしまうため気付けない。

この検知は既に存在する。`images/runtime-base/bin/git-auth-check` が対話シェルの起動ごとに
イメージ固定の生死を 1 行で報告し、台帳 §10 がテスト付きで固定している。**ただし呼び出し元は
`karakuri-context`（対話シェル限定）であり、非対話の SSH 実行には報告が届かない。** 穴が実在するか
を確認し、結果を「やらないこと」か追加作業のどちらに落ちるか判断する。

塞ぐとしたら、非対話の実行では報告に留めず**非ゼロ終了させる**方向が考えられる。ただし
`git-auth-check` を非対話経路で呼ぶ主体が現在どこにも無いため、フックの設計から要る。
**コード変更とテスト追加、および台帳の行が必要になるので、その場合は別チケットへ切り出す。**
本チケットでは穴の有無を確認し、結果を記録するところまでとする。

### やらないこと

- **`CRIT_PORT` の「固定する」という規律自体は変えない。** 値の置き場を base の `ENV` から
  雛形の compose へ移すだけで、ホスト側 `~/.ssh/config` の `LocalForward` を静的に書けるように
  固定する、という理由は文書に残す
- **転記の前段にある存在検査（`RUN [ -n "${GIT_CONFIG_COUNT}" ] && ...`）は残す。** 転記のための
  検査ではあったが、runtime-base 側で名前が変わったことをビルド時に落とす役目は転記の有無と
  独立に成立する
- **`git-auth-check` の実装には触れない。** 穴の確認までを本チケットで行い、塞ぐ作業は範囲外
- **雛形の Dockerfile 2 本（`example/Dockerfile`・`images/devcontainer-base/examples/Dockerfile`）は
  触らない。** 環境変数の案内は compose 側へ寄せるため

## 保証

### 新たに宣言する保証

- なし。台帳の境界宣言は `devcontainer-base` イメージと `examples/` の雛形を公開面と判定した
  うえで「対応するテストを持たず、何を約束にすべきかも定めていない」として候補層へ送っている
  （`docs/guarantee-candidates/0005-ledger-scaffold.md`）。本変更はその未精査領域の内側に入り、
  1 行だけ先に裁可すると周囲との整合を取らないまま穴の空いた節ができる。今回効くようになる
  不変条件は候補層（`docs/guarantee-candidates/0017-devcontainer-cli-env.md`）へ置く

### 維持する保証

- 台帳 §10（`images/runtime-base/tests/git-credential.test.sh`）— github.com の credential helper を
  イメージ自前のものへ固定する 5 変数と、その生死を毎回報告する認証確認コマンド。転記を落とす
  変更は、この固定が SSH セッションへ届く経路を CLI の写し込みだけに委ねる。**レビューの焦点は
  ここに置く**
- 台帳 §5（`packages/egress-guard/tests/firewall-rules.test.sh`）の INPUT DROP — `CRIT_PUBLIC_URL` を
  置いても到達経路が増えないことの根拠。firewall 設定には触れない

### 廃止する保証

- なし。台帳には `/etc/environment` への転記を約束した行が無く（テストにも言及が無い）、
  取り下げる対象が存在しない
