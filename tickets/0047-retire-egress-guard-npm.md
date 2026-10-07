---
status: draft
type: chore
base: main
targets:
  - packages/egress-guard/package.json
  - packages/egress-guard/CHANGELOG.md
  - packages/egress-guard/README.md
  - packages/egress-guard/docs/agent-brief.md
  - README.md
  - SECURITY.md
  - docs/secure-publish.md
  - images/devcontainer-base/README.md
  - .github/workflows/release.yml
  - docs/guarantees.md
verify:
  - pnpm lint:sh
  - pnpm test
---

# egress-guard の npm への公開をやめる

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

### egress-guard の配布の流れ（0046 / 0047）

`@himorogy/egress-guard` の npm への公開をやめ、`init-project-firewall.sh` と雛形の配布経路をイメージだけにする。
現在は runtime-base と egress-proxy の2つのイメージが、それぞれ `ARG EGRESS_GUARD_VERSION=0.4.0` で npm から同じパッケージを取得している。
pin が2本あるため、dev 側と proxy 側が別の版で同じ `firewall.json` を解釈しうる。また、このリポジトリのソースを npm 経由で取り直す連鎖（publish → 各イメージ）が、リリースのたびに要る。
変更後の版の正本は、各イメージのビルド元コミットになる。

runtime-base を使わない利用者（例えば受託先のコンテナ）は、public な egress-proxy イメージからスクリプトと雛形を取り出す。
l7 を使うならどのみち egress-proxy を sidecar として pull するので、proxy とスクリプトを同じ digest で固定できる。

karakuri 自身の pin の更新は、人間が runtime-base → devcontainer-base → egress-proxy のタグを打ったあと、0051 がまとめて行う。

### この枚の変更

0046 で「使う側」が npm から外れた後に、「配る側」を閉じる。0046 のマージが前提。

1. **公開を止める**: `packages/egress-guard/package.json` に `"private": true` を付け、`publishConfig` を削除する。
   誤ってタグ `@himorogy/egress-guard@<version>` を打っても、release workflow の publish の段で失敗する状態にする。
   `name` は残す（pnpm workspace とテストのスクリプトが使う）。
   changesets はこの変更の後も private パッケージの版を上げうるが、タグは打たないので公開には繋がらない。版上げを止めるかどうかは実装時に判断してよい。
2. **CHANGELOG**: 最終項として、npm への公開を終了したこと、最後に公開した版が 0.4.0 であること（0.5.0 は公開していない）、以後の入手経路（runtime-base に焼かれているもの、または egress-proxy イメージの `/usr/local/bin/init-project-firewall.sh` と `/usr/share/egress-guard/templates/`）を書く。
3. **パッケージ README**（`packages/egress-guard/README.md`）:
   - セットアップの「Dockerfile に追記するもの」の `npm install -g @himorogy/egress-guard@0.4.0` と `npm root -g` からの `cp` を、egress-proxy イメージからの `COPY --from=ghcr.io/himorogy/egress-proxy:1@sha256:<digest> ...` に書き換える。雛形も同じイメージから取り出せることを書く
   - runtime-base（devcontainer-base）を使う場合はスクリプトが既に焼かれているので、この手順が要らないことを書く
   - 冒頭の見出しなど、npm パッケージであることを前提にした記述を直す
4. **`packages/egress-guard/docs/agent-brief.md`**: npmjs.com へのリンクを、リポジトリ内のパッケージ README へのリンクに替える。
5. **リポジトリ全体の文書**:
   - ルートの `README.md`: 「パッケージ」節の `@himorogy/egress-guard` を、npm パッケージとしてではなく、イメージに焼かれるコンポーネントとして紹介し直す。「三者の関係」の図のうち、egress-guard の取得経路に関わる部分は 0046 で直しているので、整合だけ確かめる
   - `SECURITY.md`: 冒頭の、npm パッケージとして提供していることを前提にした記述を直す
   - `docs/secure-publish.md`: タグ付けの手順例に `@himorogy/egress-guard@0.1.0` を使っている箇所（§4.4 付近）を `@himorogy/env-guard` の例に替える。公開後の照会の遅延について、egress-guard 0.1.1 で観測した事実を述べている行は過去の観測なので残す
   - `images/devcontainer-base/README.md`: タグ形式の比較で `@himorogy/egress-guard@0.1.0` を例に挙げている箇所を、`@himorogy/env-guard` の例に替える
   - `.github/workflows/release.yml`: 冒頭コメントのタグ例を `@himorogy/env-guard@...` に替える。過去の観測を述べているコメント（0.1.1 の 404）は残す
6. **台帳**: 下の保証節のとおり。

### やらないこと

- `npm deprecate` の実行。公開済みの版（〜0.4.0）への告知は、karakuri の pin 更新が着地してから、人間が egress-guard と enclave-env の両方について行う。外へ出る操作なので、このチケットの実装者は行わない
- `packages/egress-guard` ディレクトリの移動・改名
- `docs/archive/` の egress-guard 設計文書の書き換え。履歴として残す
- release workflow の汎用ロジックの変更。egress-guard 固有の分岐は元から無い

## 保証

### 新たに宣言する保証

- なし。公開をやめる変更で、利用者が新たに依存してよい振る舞いは増えない。代替の入手経路（egress-proxy イメージ内のパス）は 0046 で宣言済み

### 維持する保証

- §4・§5（`init-project-firewall.sh` の設定の検証と規則の適用）。スクリプトはイメージを通じて配られ続け、振る舞いは変えない。公開面の B 節を外しても、C-1 と C-3 の下で効く
- §23 のうち env-guard の行（`@himorogy/env-guard` の `bin` と `hooks` の file mode）。同じ行から egress-guard の部分だけを外すので、env-guard の部分を巻き込まない

### 廃止する保証

- 公開面の定義の B 節（`@himorogy/egress-guard`（npm パッケージ）の `scripts/init-project-firewall.sh` と3つの雛形）。npm の配布単位が無くなる。スクリプトは C-1 と C-3、雛形は C-3 に残る
- §23 の「npm パッケージとして配られる面」から `@himorogy/egress-guard` の `scripts` と `templates` を外す。npm で配られなくなるため。イメージに焼かれるときの mode は、0046 で宣言した C-3 の行と、C-2b が持つ
