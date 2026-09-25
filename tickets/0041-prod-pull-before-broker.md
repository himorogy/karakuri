---
status: open
type: fix
base: main
targets:
  - host-tools/prod-run.sh
  - host-tools/tests/prod-run.test.sh
  - docs/guarantees.md
verify:
  - pnpm lint:sh
  - pnpm test
---

# prod の起動で broker を呼ぶ前にイメージの取得を済ませる

## 内容

### 症状

`host-tools/prod-run.sh` は `"$PROD_BROKER" | docker compose -f "$PROD_COMPOSE_FILE" run -T --rm prod "$@"` のパイプで broker と docker を同時に起動する。
compose ファイルが指す image の digest がローカルに無いと、compose の pull 進捗の描画が broker（Bitwarden CLI）の認可プロンプトの行を上書きする。
実機（2026-09-25、`karakuri-prod-base`）では次のように出た。

```
Image ghcr.io/himorogy/runtime-base@sha256:b585515... Pulling
? Master password: [input is hidden] c6cbf97176c5 Already exists 0B
...
Container prod-<repo>-prod-run-<id> Created
```

人間はプロンプトに気付かず入力しなかった。
broker は stdout に何も出さないまま待ち続け、コンテナ側の取込は stdin の EOF を待ってブロックし、clone まで進まない。
別端末から `karakuri-prod-shell` で入ると `/run/secrets` が空だった。
2 回目は取得が済んでいたので進捗が出ず、プロンプトが読めて正常に通った。
再現条件は「その digest をまだローカルに持っていないこと」で、digest を上げた直後と初回導入時に必ず当たる。
`karakuri-prod-run` / `karakuri-prod-exec` / `karakuri-prod-base` はすべて `prod-run.sh` を通るので、3 つとも同じ。

### 変えるもの

`host-tools/prod-run.sh` の起動ブロック（`# --- 起動 ---` の節）で、broker を呼ぶパイプラインの直前に取得を 1 回入れる。

```sh
docker compose -f "$PROD_COMPOSE_FILE" pull prod || true
```

- 置き場所は必須環境変数の検査と `GIT_REF` の検査の**後**。`compose.prod.yaml` の `environment:` は `${GIT_REPO:?}` / `${GIT_REF:?}` を使っており、`pull` も compose ファイルを読むので変数展開が走る。加えて ref を拒否したときに docker を一度も起動しない既存の約束（台帳 §16）を保つため
- サービス名 `prod` を明示する。同じファイルの `run` が起動するものと揃える
- 終了コードは見ない。取得は進捗を broker のプロンプトより前に出し切らせるための前段であって、起動の可否を決めるものではない。取得に失敗しても後続の `run` が同じ取得を試みてそこで正しく失敗する。ここで止める形にすると、レジストリに届かずローカルにイメージがある状況で起動できなくなる
- `--quiet` は付けない。進捗を消すと初回の取得が無言の長い停止になる
- 直上のコメントは「なぜ run の前に分けるか」（プロンプトの行が進捗の描画で上書きされる）と「なぜ失敗を見ないか」の 2 点だけにする。前者は Docker Compose の描画の挙動なので、観測した版（Docker Compose v5.3.1）を併記する

### 経路の列挙

- 前方: 入口 `karakuri-prod-{run,exec,base}` → `_karakuri_prod_call`（`host-tools/karakuri.sh`。環境変数を組んで `prod-run.sh` を呼ぶだけで docker に触れない）→ `prod-run.sh` の引数・環境変数・ref の検査 → **取得（新設）** → broker | `docker compose run` → entrypoint の取込 → clone → `exec`。新設の段が要る条件は compose ファイルの変数展開が通ること（上記の置き場所で満たす）。失敗しうるが、失敗は後続の `run` に委ねる
- 後方: `prod-run.sh` の既存の終了コード切り分け（broker / docker / SIGPIPE の 3 分岐）は `PIPESTATUS` を読む。取得の行はパイプの外に置くので `PIPESTATUS` を上書きしない位置関係を保つこと（取得をパイプの後ろに置かない）
- 参照: `host-tools/tests/karakuri.test.sh` は `prod-run.sh` をフェイクに差し替えており影響を受けない。`host-tools/README.md` / `images/runtime-base/README.md` / `example/README.md` は docker の呼び出し回数に触れていない。`prod-run.sh` の冒頭の「secret が通るのは下記パイプだけ」は取得が secret に触れないので真のまま

### テスト

`host-tools/tests/prod-run.test.sh` のフェイク docker は、呼ばれるたびに argv / stdin / env のファイルを上書きし、終了コードは単一の `FAKE_DOCKER_EXIT_CODE` で決まる。
取得を足すと 1 回の実行で docker が 2 回呼ばれるので、呼び出しの順序と回数を記録でき、取得と起動の終了コードを別々に指定できる形に変える。

- フェイク docker: 呼び出しの種別を追記する記録ファイルを持つ。`pull` の回は argv / stdin / env の記録に触れず、取得用の終了コード（既定 0）で終わる。それ以外の回は現状どおり
- フェイク broker: 同じ記録ファイルへ自分が呼ばれたことを追記する（成功・失敗・SIGPIPE の 3 種とも）

新規に確かめるもの:

- 取得が broker より先に、1 回だけ呼ばれる（テスト名 "pull runs once, before the broker"）
- 取得の引数が `-f <compose> pull prod` である
- 取得が非ゼロで終わっても broker と起動は実行され、全体の終了コードは起動の結果で決まる（テスト名 "a failed pull does not stop the run"）
- ref を拒否したときは取得も呼ばれない

既存の assertion は argv / stdin / env の記録が起動の回だけになるので、そのまま通る想定。
通らないものがあれば、assertion の意図を変えずに記録の読み方だけを直す。

### やらないこと

- `host-tools/karakuri.sh`。取得は `prod-run.sh` の責務で、呼び出し規約の側には現れない
- `host-tools/dock.sh` と `host-tools/dev-inject.sh`。dev 側の注入は起動済みコンテナへの `docker exec` で、取得と同時には走らない
- `prod-run.sh` の既存コメントの整理（0039）。このチケットで足すのは取得の行とその直上のコメントだけ
- `example/` の重複整理（0042）

## 保証

### 新たに宣言する保証

台帳 §16 に 2 行足す。

- broker を呼ぶ前に、起動するイメージの取得を一度試みる。取得の出力が broker の認可プロンプトと同じ端末で重ならないようにするためである（テスト: "pull runs once, before the broker"）
- その取得の失敗だけでは起動を止めない。起動できるかどうかは後続の起動が決める（テスト: "a failed pull does not stop the run"）

### 維持する保証

フェイク docker の作り替えで壊れるリスクがある §16 の行。

- broker の stdout は下位の stdin へ末尾改行を除きバイト単位でそのまま中継される（テスト: "fake docker's stdin matches the broker's output verbatim"）。stdin の記録が取得の回で上書きされないこと
- ref が 40 桁 hex でないとき、既定では docker を一度も起動せずに非ゼロ終了する（テスト: "docker was not invoked when GIT_REF was rejected before launch"）。取得も docker の起動に含まれるので、取得を ref の検査より前に置くと偽になる
- broker と下位の終了コードの扱いは §15 と同一である。取得の終了コードがこの判定に混ざらないこと

### 廃止する保証

- なし。台帳に docker の呼び出し回数を約束した行は無く、取り下げる約束は無い
