---
status: close
type: feat
base: main
targets:
  - .github/scripts/pin-lag.sh
  - .github/scripts/tests/pin-lag.test.sh
  - .github/workflows/monitor.yml
  - docs/guarantees.md
  - README.md
verify:
  - pnpm lint:sh
  - pnpm lint
  - pnpm test
---

# 配布中の base イメージに焼かれた node が security release より古いことを監視で拾う

## 内容

2026-10-20 に node v24.22.1（security release）が出たが、`.github/workflows/monitor.yml` は何も鳴らさなかった。
runtime-base は `FROM node:24-trixie` で major だけを固定しており、patch はイメージをビルドした日の版で決まる。
いまの monitor が node について見ているのは、Dockerfile の major と `schedule.json` の maintenance / EOL までの日数だけで、security release は見ていない。
npm の advisory API にも node は載らない。
最後のビルドは runtime-base-v2.0.1（2026-10-16）と devcontainer-base-v3.0.1（2026-10-18）で、どちらも v24.22.0 が焼かれているはず（未確認。ghcr.io はこのコンテナの proxy で CONNECT が 403 になり、届かない。2026-10-30 に実測）。

比べる相手はソースではなく**配布中のイメージ**にする。
ソースには patch が書かれていないので、ソースを見ても露出は分からない。

### 変えるもの

- `pin-lag.sh` にサブコマンドを2つ足す。どちらも取得はせず、呼び出し側が取得した nodejs.org の `dist/index.json` の本文を引数で受け取る（既存の「取得は workflow、判定はスクリプト」の分担に合わせる）
  - `node-advisory <index_json> <baked_version>`: 焼き込み版と同じ major の系統に、焼き込み版より新しい `security: true` の版があれば `checked-alert <その中で最も新しい版>` を返す。無ければ `checked-none`。本文が JSON の配列でない・焼き込み版を読めない・その major の系統が一覧に無いときは `check-failed` を rc=1 で返す。語彙は既存の `advisory` と揃え、1語目を既存の `severity` にそのまま渡せる形にする
  - `node-latest <index_json> <major>`: その系統の最新版を返す。取れなければ `latest-unavailable` を rc=1 で返す。遅れの大きさは既存の `lag` に焼き込み版とこの値を渡して求める
  - 版の比較は桁ごとの数値比較にする（`24.9.0` < `24.10.0`）。`v` 前置の有無は同一視する
  - `index.json` は新しい版が先頭に並ぶ。各要素は `version`（`v` 前置）と `security`（真偽値）を持つ。2026-10-30 に実測し、`v24.22.1` と `v26.12.1` が `security: true` だった
- `monitor.yml` の runtime-base の節に、配布イメージの node の確認を足す。対象は runtime-base と devcontainer-base の2つ
  - 見るタグは、利用側が追う major の浮動タグにする。major は git の最新のリリースタグ（`runtime-base-v*` / `devcontainer-base-v*` を版順に並べた先頭）から取る。checkout は `fetch-depth: 0` で全タグを持っている
  - ghcr.io の registry API を匿名で叩き、`linux/amd64` の image config の `Env` から `NODE_VERSION` を読む
    - 匿名の pull token が取れること、両パッケージが public であることは未確認（README の手順では初回リリース後に public へ切り替える）。実装者もこのコンテナからは確かめられないので、検収の実行で確定させる
    - 公式 node イメージは `ENV NODE_VERSION=<版>` を持つ（`nodejs/docker-node` の `24/trixie/Dockerfile` で 2026-10-30 に確認、値は `24.22.2`）。devcontainer-base は runtime-base を `FROM` するので、同じ `Env` を引き継ぐ
  - `index.json` は1回だけ取得し、両イメージの判定に使う
  - 文面はイメージごとに1行。`node-advisory` が `checked-alert` なら「焼き込み版・security release の版・系統の最新・焼き直す」を出して alert に上げる。それ以外は `lag` の結果で ✅（最新）か ℹ️（遅れ、security release 該当なし）を出す
  - どの段で取得・読み取りに失敗しても、✅ にせず warn にして、どの段で失敗したか（タグが無い・token が取れない・manifest に amd64 が無い・`NODE_VERSION` が無い・`index.json` が取れない）を文面に出す
  - 既存の node の行（maintenance / EOL までの日数）はそのまま残す。行の末尾の「advisory は照会対象外」の文言と、節の冒頭のコメント（「advisory 照会には乗らない」）は、配布イメージで security release を照会するようになったことに合わせて直す
- `README.md` の「固定値の追従」節で、node の advisory を照会できないとしている記述を直す。node は配布中のイメージに焼かれた版を nodejs.org の security release と比べること、照会できないのは crit と golang builder であることを書く。台帳への参照は既存の節の書き方に合わせる

### やらないこと

- イメージの焼き直し。検収でこの監視が既存のイメージを alert として拾うことを確かめてから、別に行う
- node 26 への移行（issue `#36`）
- `linux/arm64` の manifest を見ること。両アーキテクチャは同じビルドで同じ版を焼く
- `:edge` や過去の版のタグを見ること
- node 以外の固定値（pnpm / dotenvx / wrangler / crit / egress-guard）について、ソースと配布イメージのずれを見ること
- Slack 通知のタイトル（`npm 監視`）の変更
- `index.json` 以外の情報源（CVE 単位の照会や nodejs/security-wg の脆弱性 DB）を使うこと
- 取得の失敗のリトライ。失敗は warn として文面に出すだけにする
- 検査の深さ: `index.json` の版文字列がプレリリース識別子を持つ・3桁でない形は扱わない。`NODE_VERSION` が複数ある `Env` も扱わない。registry API の取得部分（token・manifest・blob）はテストせず、検収の実行で確かめる

### 検収

`gh workflow run monitor.yml --ref kuda/0063-monitor-node-security-release` で実行し、Slack の文面で次を確かめる。

- runtime-base と devcontainer-base の両方に、node の焼き込み版と security release の版を挙げた 🚨 の行が出て、通知全体が異常検知になる
- 取得の失敗を示す ⚠️ が node の行に出ていない

## 保証

### 新たに宣言する保証

台帳の `.github/scripts/tests/pin-lag.test.sh` の節に足す。

- `node-advisory` は、焼き込み版と同じ major の系統に焼き込み版より新しい security release があるとき `checked-alert` を返し、`severity` は `alert` になる。security release が焼き込み版以前にしか無いときは `checked-alert` を返さない（テスト: "node-advisory: 焼き込み版より新しい security release があれば checked-alert、焼き込み版以前だけなら checked-none"）
- **否定対照:** リリース一覧を読めないとき、または焼き込み版の系統が一覧に無いとき、`node-advisory` は `checked-none` に化けず `check-failed` を返す（テスト: "否定対照: node-advisory はリリース一覧が読めない・系統が無いとき check-failed を返す"）
- `advisory` が照会に乗らない対象として `not-checked` を返すのは crit と golang builder である（テスト: "照会に乗らない対象（crit / golang builder）は not-checked"。既存のテスト名 "照会に乗らない対象（node / crit / golang builder）は not-checked" から node を外す。下の廃止と対で、既存の行を書き直す）

### 維持する保証

- 台帳の同じ節の「遅れの大きさや種別だけでは深刻度が `alert` にならない」行。`node-advisory` の結果を `severity` に渡す経路を足しても、`severity` が見るのは advisory の語だけのままであること
- 同じ節の `node-schedule` の行。残り日数で escalate しないことは変えない

### 廃止する保証

- 台帳の同じ節の「照会に乗らない対象（node / crit / golang builder）では、遅れの有無にかかわらず `not-checked` を返す」行。node は `node-advisory` で照会するようになるので、この行を取り下げ、上の crit と golang builder だけの行に置き換える
