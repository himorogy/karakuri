---
status: close
type: fix
base: main
targets:
  - images/devcontainer-base/bin/personal-setup
  - images/devcontainer-base/tests/personal-setup.test.sh
  - images/devcontainer-base/Dockerfile
  - images/devcontainer-base/README.md
  - images/devcontainer-base/examples/devcontainer.json
  - images/devcontainer-base/examples/docker-compose.yaml
  - .devcontainer/devcontainer.json
  - DEVCONTAINER.md
  - docs/guarantees.md
verify:
  - pnpm lint:sh
  - pnpm lint
  - pnpm test
---

# 個人フックをネットワークに出ない前提へ改め、proxy 変数を外す処理を削除する

## 内容

0050（雛形）と 0051（karakuri 自身）で、dev は `internal: true` のネットワークだけに載る構成になった。
dev から外へ出る経路は egress-proxy だけで、その ACL は `firewall.json` の `allowDomains` から焼き込まれ、起動時から常に効く。
そのため postCreate で走る個人フック（`/personal/setup.sh`）は、firewall の適用前でも外へ出られない。

これまでの前提は「postCreate の時点では firewall が未適用なので、`personal-setup` が proxy 変数を外せば直接経路で取得できる」だった（0029）。
internal の構成では直接経路が存在しないので、この前提は成り立たない。
個人ツールの取得先を `allowDomains` に足すことはしない（個人の都合で dev 全体の到達先を広げることになり、プロジェクトの設定に個人の取得先が混ざるため）。

新しい前提は次のとおり。

- `~/.config/devc-personal` を `/personal` に ro でマウントし、postCreate で `/personal/setup.sh` を実行する。ここまでがこのリポジトリの約束である
- その時点で dev はネットワークに出られない。フックは `/personal` に置かれたものを配置・設定するだけにする
- 取得はホスト側で済ませて結果を `/personal` に置く。取得の方法は利用者に任せ、このリポジトリはランナーや置き場所の規約を持たない

0051 の着地を待つ。0051 が `.devcontainer/docker-compose.yaml` を触るので並行しない。

### 変えるもの

- `images/devcontainer-base/bin/personal-setup` から、proxy の環境変数（`http_proxy` / `https_proxy` / `HTTP_PROXY` / `HTTPS_PROXY`）を外す処理を削除する。「`/personal/setup.sh` が実行可能なら呼び出し元と同じユーザーで実行し、その終了コードで終わる。無い、または実行可能でなければ何もせず 0 で終わる」は残す。冒頭のコメントも新しい前提に合わせる
- `images/devcontainer-base/tests/personal-setup.test.sh` から、proxy 変数を外すことを検査する2本（"proxy 変数はフックへ渡らない" / "否定対照: proxy 以外の環境変数はそのまま渡る"）を削除する。残る3本はそのまま
- 台帳 §24 の proxy 変数の行（2行目）を削除する（下の「廃止する保証」）
- 旧前提（直接経路で取得する、firewall の適用前なら届く、proxy 変数を外す）を述べている文書とコメントを、新しい前提に書き換える。起票時点で見つかっているのは次の箇所で、ほかにも無いかは実装者が洗う
  - `images/devcontainer-base/Dockerfile` の `personal-setup` の COPY 直前のコメント
  - `images/devcontainer-base/README.md` の収録判定（層 C）・収録物・保護範囲の各記述
  - `images/devcontainer-base/examples/devcontainer.json` の `postCreateCommand` 直前のコメント
  - `images/devcontainer-base/examples/docker-compose.yaml` の個人フックの mount のコメント（「firewall 適用前 — ツール取得を伴うため」）
  - `.devcontainer/devcontainer.json` の `postCreateCommand` 直前のコメント
  - `.devcontainer/docker-compose.yaml` の個人フックの mount のコメント（旧前提を述べていなければ触らない）
- `DEVCONTAINER.md` の「devcontainer への個人用開発ツールの導入」の節を直す。いまの本文は「ここでインストールしてください」とし、サンプルは postCreate の中で GitHub Releases から `curl` で取得している。新しい前提では動かないので、取得はホストで済ませて `/personal` に置き、フックはそこから配置する形のサンプルに改める。取得の手段（どこから・どう取るか）はサンプルで1例を示すに留め、規約にしない

### やらないこと

- 個人ツールの取得を担うランナーや、`/personal` の中の配置の規約をこのリポジトリに置くこと
- `allowDomains` の変更
- `personal-setup` という名前・置き場所・`postCreateCommand` からの起動のしかたの変更（台帳 E-a の行はそのまま）
- devcontainer-base のタグを打つこと、karakuri の pin を上げること
- 検査の深さ: フックがネットワークに出られないこと自体はこのリポジトリで検査しない（0050 / 0051 の構成の帰結であり、DNS の検査は verify-l7.sh が持つ）

## 保証

### 新たに宣言する保証

- なし（残る `personal-setup` の振る舞いは台帳 §24 の1行目が既に約束している。フックがネットワークに出られないことは構成の帰結で、`personal-setup` の約束ではない）

### 維持する保証

- 台帳 §24 の1行目（フックの実行・終了コード・無いときに 0）。テスト3本を残して維持する
- 台帳 E-a の `personal-setup` の行（`/usr/local/bin` に置かれ、名前だけで起動できる）。名前と置き場所は変えない

### 廃止する保証

- 台帳 §24 の2行目「フックは proxy の環境変数（`http_proxy` / `https_proxy` / `HTTP_PROXY` / `HTTPS_PROXY`）を持たない環境で走る。呼び出し側の環境にそれらがあってもフックへは渡らない」。internal の構成では直接経路が無く、proxy 変数を外しても外へ出られないので、約束として持つ意味が無い。対応するテスト2本も削除する
