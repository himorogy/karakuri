---
status: close
type: fix
base: main
targets:
  - images/devcontainer-base/bin/personal-setup
  - images/devcontainer-base/Dockerfile
  - images/devcontainer-base/examples/devcontainer.json
  - images/devcontainer-base/README.md
  - images/devcontainer-base/tests/personal-setup.test.sh
  - package.json
  - docs/guarantees.md
verify:
  - pnpm lint:sh
  - pnpm test
---

# 個人設定フックの実行を personal-setup へ切り出し、proxy を経由させない

## 内容

### 背景

雛形は「取得を伴うセットアップは `postCreateCommand` に置く。firewall（`postStartCommand` の
iptables）はその後に適用される」と案内し、個人設定フック `/personal/setup.sh` もその段で
実行している。L3 実現層ではこの順序どおりに動いていた。

L7 実現層では compose の `environment` に `http_proxy` / `https_proxy` /
`HTTP_PROXY` / `HTTPS_PROXY` が入り、コンテナ作成時から全プロセスに渡る。iptables の
適用順は変わっていないが、`postCreateCommand` の通信が proxy 経由になり、sidecar の ACL に
無い宛先が 403 で落ちる。個人ツールの取得は GitHub Releases（`github.com/.../releases/download/...`
→ `release-assets.githubusercontent.com` への 302）や個人ドメインが相手で、ACL に無い。
実測: karakuri の devcontainer を L7 で作成したとき、フック内の `curl -fL` が全件
`curl: (22) The requested URL returned error: 403`（squid の deny）で失敗した。
audit モードでは成功する。

postCreate の時点で iptables は未適用なので、proxy 変数さえ外せば直接経路で出られる。
これを雛形の `postCreateCommand` のインラインシェルに足す代わりに、devcontainer-base に
焼くスクリプトへ切り出す。理由は、外す変数とその理由をスクリプトのコメントとテストに
置けること、雛形を写した各プロジェクトの `devcontainer.json` が 1 行ずつ乖離しないこと。

### 変更

1. `images/devcontainer-base/bin/personal-setup` を新設する。`git-identity-setup` と同列の
   sh スクリプト（shebang 付き、利用者向けメッセージは英語 — conventions「出荷物のメッセージ言語」）。
   振る舞い:
   - `/personal/setup.sh` が実行可能なら、`http_proxy` / `https_proxy` / `HTTP_PROXY` /
     `HTTPS_PROXY` を環境から外して実行し、その終了コードで終わる
   - 実行主体は変えない。`postCreateCommand` は `remoteUser`（`node`）で走り、`personal-setup` も
     フックもそのユーザーのまま。`sudo` を挟まず、sudoers にも登録しない（root で走らせると
     フックが入れたツールの所有者が root になり、`node` から使えない不整合が起きる。apt が
     使えないのは今までどおりで、フック側の工夫に任せる）
   - 無い、または実行可能でなければ何もせず 0 で終わる（現行のインライン
     `if [ -x /personal/setup.sh ]; then ...; fi` と同じ）
   - フックのパスは環境変数 `PERSONAL_SETUP_HOOK` で差し替えられる（既定 `/personal/setup.sh`）。
     テストが docker なしで固定するための口で、`git-identity-setup` の
     `GIT_IDENTITY_SETUP_FETCH_CMD` と同型
   - `no_proxy` / `NO_PROXY` / `NODE_USE_ENV_PROXY` には触らない。proxy の向き先が無ければ効かない
   - L3 実現層（proxy 変数が無い構成）では外す対象が無いだけで、振る舞いは変わらない
2. `images/devcontainer-base/Dockerfile`: `--- personal hook ---` の帯を立て、
   `COPY bin/personal-setup /usr/local/bin/personal-setup` → `chown root:root` → `chmod 0755`
   の 2 行型（`git-identity-setup` の節と同じ）。`chown root:root` は `COPY` の既定と同じで
   実行主体の指定ではなく、改変防止を目的にもしない — このスクリプトは作成時に 1 回しか
   走らず、コンテナ内で書き換えても次の作成ではイメージの内容に戻る。意味があるのは
   `chmod 0755`（リポジトリ上の mode に依存せず実行ビットを付ける）で、`chown` は
   既存の節と型を揃えるためだけに置く。帯のコメントに、postCreate から `node` として
   呼ぶこと、proxy 変数を外す理由を書く
3. `images/devcontainer-base/examples/devcontainer.json`: `postCreateCommand` を
   `"personal-setup"` に置き換える。直前のコメント（「取得を伴うセットアップはここに置く」
   の段落）に、L7 では proxy 変数が作成時から入っているため、フックはそれを外して直接経路で
   走る旨を足す
4. `images/devcontainer-base/README.md`: 層 C の収録判定（「実行は postCreate（firewall 適用前）」
   の箇所）と「保護範囲」の「コンテナ作成中の通信」の項に、proxy 変数の件を 1 行ずつ足す。
   現在形の文書なので kuda:docs の規律に従う
5. `images/devcontainer-base/tests/personal-setup.test.sh` を新設し、ルート `package.json` の
   `test` 連鎖に `bash images/devcontainer-base/tests/personal-setup.test.sh` を足す。
   `lint:sh:images` は `images/devcontainer-base/bin/*` と `tests/*.sh` を glob しているので
   shellcheck の対象には自動で乗る
6. `docs/guarantees.md` に §24 を新設する（下の「新たに宣言する保証」）。イメージへの配置
   （`/usr/local/bin` に実行可能な状態で置かれる）はテストで見られないので、C-2b と同型の
   未検証の約束として置く

### やらないこと

- karakuri 自身の `.devcontainer/devcontainer.json` は変えない。base を 2.4.0 に pin して
  おり、`personal-setup` はその中に無い。base の次版をタグ → pin を上げる派生チケットで
  `postCreateCommand` を `personal-setup` に置き換える
- `examples/docker-compose.yaml` は変えない。`/personal` のマウントのコメントは
  「postCreateCommand が実行する」のままで正しい
- egress-guard 側（`github` バンドルへの `release-assets.githubusercontent.com` 追加）は
  扱わない。postCreate が直接経路になれば、この経路での必要性は消える
- squid の ACL に個人ドメインを足す運用（`allowDomains`）は案内しない
- フックを root で走らせる経路（sudoers への登録、`postCreateCommand` を root で実行する
  指定）は作らない

### 検収

base の次版をタグし pin を上げた後の rebuild で、`postCreateCommand` のログに
`curl: (22) ... 403` が出ず、個人ツールが `/home/node/.local/bin` に入ること。

## 保証

### 新たに宣言する保証

台帳 §24（`images/devcontainer-base/tests/personal-setup.test.sh` —
`images/devcontainer-base/bin/personal-setup`）として新設する。

- `/personal/setup.sh` が実行可能なら、呼び出し元と同じユーザーのままそれを実行し、その
  終了コードで終わる。無い、または実行可能でなければ何もせず 0 で終わる
  （テスト: "フックがあれば呼び出し元のユーザーで実行して終了コードを返す" /
  "フックが無ければ何もせず 0 で終わる" / "実行可能でないフックは実行せず 0 で終わる"）
- フックは proxy の環境変数（`http_proxy` / `https_proxy` / `HTTP_PROXY` / `HTTPS_PROXY`）を
  持たない環境で走る。呼び出し側の環境にそれらがあってもフックへは渡らない
  （テスト: "proxy 変数はフックへ渡らない" / "否定対照: proxy 以外の環境変数はそのまま渡る"）
- `personal-setup` はイメージの `/usr/local/bin` に実行可能な状態で置かれ、
  `postCreateCommand` から名前だけで起動できる
  （`未検証の約束 (テスト困難: イメージのビルドが要る。pin を上げた後の rebuild を検収で確認する)`）

### 維持する保証

- §22 `git-identity-setup` の各行。Dockerfile の隣接する節に帯を足すだけで、
  `git-identity-setup` の COPY と rc への追記には触れない

### 廃止する保証

- なし。個人フックを呼ぶ入口を変えるだけで、取り下げる約束は無い（フックが postCreate で
  走ること、firewall 前であることは台帳に行が無く、README の散文にしか書かれていない）
