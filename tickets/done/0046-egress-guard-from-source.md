---
status: close
type: refactor
base: main
targets:
  - images/runtime-base/Dockerfile
  - images/egress-proxy/Dockerfile
  - .github/workflows/runtime-base.yml
  - .github/workflows/runtime-base-verify.yml
  - .github/workflows/egress-proxy.yml
  - .github/workflows/monitor.yml
  - images/egress-proxy/README.md
  - images/devcontainer-base/README.md
  - README.md
  - packages/egress-guard/tests/verify-l7.sh
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
  - pnpm test
---

# runtime-base と egress-proxy が egress-guard をリポジトリのソースから焼く

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

### egress-guard の配布の流れ（0046 / 0047）

`@himorogy/egress-guard` の npm への公開をやめ、`init-project-firewall.sh` と雛形の配布経路をイメージだけにする。
現在は runtime-base と egress-proxy の2つのイメージが、それぞれ `ARG EGRESS_GUARD_VERSION=0.4.0` で npm から同じパッケージを取得している。
pin が2本あるため、dev 側と proxy 側が別の版で同じ `firewall.json` を解釈しうる。また、このリポジトリのソースを npm 経由で取り直す連鎖（publish → 各イメージ）が、リリースのたびに要る。
変更後の版の正本は、各イメージのビルド元コミットになる。

runtime-base を使わない利用者（例えば受託先のコンテナ）は、public な egress-proxy イメージからスクリプトと雛形を取り出す。
l7 を使うならどのみち egress-proxy を sidecar として pull するので、proxy とスクリプトを同じ digest で固定できる。

karakuri 自身の pin の更新は、人間が runtime-base → devcontainer-base → egress-proxy のタグを打ったあと、0051 がまとめて行う。

### この枚の変更

先に「使う側」を npm から外す。publish 経路と公開面の文書は 0047 で閉じる。

1. **runtime-base**: `ARG EGRESS_GUARD_VERSION` と `npm install -g @himorogy/egress-guard@...` を削除する。
   代わりに、env-guard と同じ named build context の型（`COPY --from=env-guard ...`）で `packages/egress-guard` を `egress-guard` として受け、`scripts/init-project-firewall.sh` を `/usr/local/bin/init-project-firewall.sh` へ置く。
   root 所有・755・sudoers の無引数登録・`visudo -cf` は今のまま残す。
   版を固定する理由を説明しているコメント（dist-tag で追従させると、パッケージの更新がそのまま root でのコード実行になる、という趣旨）は、「スクリプトはビルド元コミットのソースそのもので、外部から差し替わる経路が無い」という趣旨に直す。
2. **egress-proxy**: builder ステージ（`node:24-bookworm-slim` で npm から取得する段）と `ARG EGRESS_GUARD_VERSION` を削除し、単一ステージにする。
   named build context `egress-guard` から、次の2つを置く。
   - `scripts/init-project-firewall.sh` → `/usr/local/bin/init-project-firewall.sh`（実行可能）
   - `templates/` の3ファイル → `/usr/share/egress-guard/templates/`（実行可能でない）

   USER・ENTRYPOINT・squid まわりは変えない。
3. **workflow**: `runtime-base.yml` と `runtime-base-verify.yml` の `build-contexts` に `egress-guard=packages/egress-guard` を足す。`egress-proxy.yml` には `build-contexts` を新設する。
   3本とも `pull_request.paths` に `packages/egress-guard/**` と `!packages/egress-guard/**/*.md` を足す（env-guard の行と同じ理由。見ていないと、スクリプトだけを変えた PR でイメージの検証が黙って飛ぶ）。
   `egress-proxy.yml` の smoke test に、push 済みイメージの両アーキについて次の突き合わせを足す。
   - イメージ内のスクリプトと3つの雛形が、`${{ github.workspace }}/packages/egress-guard` の同名ファイルとバイト単位で一致する
   - スクリプトは実行可能で、雛形は実行可能でない
4. **monitor**: `monitor.yml` から egress-guard の遅れ監視2か所（runtime-base 側と egress-proxy 側）と、それに付いたコメントを削除する。
   egress-guard は外部の供給元ではなくなるので、照会の対象ではない。
5. **文書とコメント**:
   - `images/egress-proxy/README.md`: 「何を焼いてあるか」のスクリプトの取得経路を直し、雛形の置き場所を足す。runtime-base を使わずに取り込む例（`COPY --from=ghcr.io/himorogy/egress-proxy:1@sha256:<digest> ...`）を1つ置く
   - `images/devcontainer-base/README.md`: `ARG EGRESS_GUARD_VERSION` の pin と、その更新運用に触れている箇所を直す。npm のリリースタグを例に挙げている箇所は 0047 で直すので触らない
   - ルートの `README.md`: 構成図の `ARG EGRESS_GUARD_VERSION で pin` を直す
   - `packages/egress-guard/tests/verify-l7.sh`: `check_acl_absent_in_dev` のコメントが dev の `$(npm root -g)` を前提にしているので直す。検査の中身は変えない
6. **台帳**: 下の保証節のとおり。公開面の定義の C-3 に、スクリプトと雛形の2つのパスを足す。

### やらないこと

- `packages/egress-guard/package.json` の公開設定、release 経路、パッケージ README の導入手順、台帳の B 節（0047）
- `packages/egress-guard` ディレクトリの移動。置き場所は変えない
- 各イメージのタグを打つことと、karakuri の pin の更新（0051）
- runtime-base の `/usr/local/bin` に雛形を置くこと。runtime-base は今も雛形を持っていない（利用側は自分の `firewall.json` を `COPY` する）ので、変えない

## 保証

### 新たに宣言する保証

- egress-proxy イメージは、`/usr/local/bin/init-project-firewall.sh` と、`/usr/share/egress-guard/templates/` 配下の `firewall.json` / `firewall.audit.json` / `firewall.example.json` を含む。どれもビルド元コミットの `packages/egress-guard` と同一の内容で、スクリプトは実行可能、雛形は実行可能でない。runtime-base を使わない利用者は、このパスからスクリプトと雛形を取り出せる — `未検証の約束 (テスト困難: egress-proxy ワークフローの smoke test が、push 済みイメージの両アーキについてソースと突き合わせる)`

### 維持する保証

- §25（`egress-proxy-bake` が書く ACL は `--print-proxy-acl` の出力と一致し、`audit` のときだけ allowlist 外を通す）。builder ステージを消すので、イメージ内にスクリプトが無くなると壊れる
- C-2b の1行目（`init-project-firewall.sh` が runtime-base の `/usr/local/bin` へ root 所有・755 で複製され、sudoers に無引数での実行が登録されている）。取得経路を差し替える箇所そのもの
- §23（配布物の file mode）。named build context の COPY がリポジトリ上の mode を持ち込むため、Dockerfile 側で明示的に mode を付けることが前提になる

### 廃止する保証

- §21 の「照会に乗らない対象（node / crit / golang builder / egress-guard）では `not-checked` を返す」から egress-guard を外す。monitor の監視対象そのものから外れるため、`not-checked` を返す対象として列挙しておく理由が無くなる。node / crit / golang builder についての約束は変えない
