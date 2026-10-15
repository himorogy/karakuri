---
status: draft
type: feat
base: main
targets:
  - images/devcontainer-base/Dockerfile
  - images/devcontainer-base/README.md
  - images/devcontainer-base/examples/Dockerfile
  - .github/workflows/devcontainer-base.yml
  - README.md
bundle:
  - 0056-runtime-base-trixie-v2
  - 0057-devcontainer-base-trixie-v3
verify:
  - pnpm lint:sh
  - pnpm lint
  - pnpm test
---

# devcontainer-base を runtime-base v2（trixie）に載せ替え、固定している版を上げて v3 にする

## 内容

束の全体像: base イメージ2本を Debian 13（trixie）へ載せ替え、固定している版を最新へ上げて、どちらもメジャー版を上げる。
派生イメージが `apt-get install` するパッケージの名前や glibc が変わるので、浮動タグ（runtime-base `:1`、devcontainer-base `:2`）の追従者に黙って届けないためにメジャーを上げる。
順序は次のとおりで、入れ替えられない。

1. 0056: runtime-base を v2 にする（node:24-trixie、pnpm 12）
2. マージ後、人間が `runtime-base-v2.0.0` を打ち、GHCR に `:2` が載るのを待つ
3. 0057（このチケット）: devcontainer-base を v3 にする
4. 人間が `devcontainer-base-v3.0.0` を打つ

**着手の前提: GHCR に `ghcr.io/himorogy/runtime-base:2` があること。**
このチケットの PR の検証ビルドは `FROM ghcr.io/himorogy/runtime-base:${RUNTIME_BASE_VERSION}` を pull する。`:2` が無いと 403 で落ちる（`.github/workflows/devcontainer-base.yml` 冒頭のコメント）。
前提は成立している。`runtime-base-v2.0.0` は打たれ、2026-10-15 時点で `:2` は `sha256:3332fe838fc9c459b254c0c7c7b3df0c0f1df0a7d7ee8d04a55738fd1135b816` を指す（人間が GHCR で確認。起草の devcontainer からは GHCR に届かず未照合）。
この digest は記録であって pin ではない。`FROM` は浮動タグ `runtime-base:${RUNTIME_BASE_VERSION}` の追随のまま変えない（`images/runtime-base/README.md` の参照の仕方の表）。

node は 24 のまま据え置く。26 への移行は issue `#36` で扱う。

### 変えるもの

- `images/devcontainer-base/Dockerfile`
  - `ARG RUNTIME_BASE_VERSION=1` を `2` にする
  - crit の builder を `golang:<x.y>-trixie` にする。`<x.y>` は実装時の Go の最新の安定版の major.minor とする。
    - 2026-10-14 時点の pin は `1.26-bookworm`。最新版は、この devcontainer からは `go.dev` に届かず未確認
    - crit v0.22.0 の `go.mod` が要求する Go の版を満たすこと
  - `CRIT_VERSION` を v0.22.0 にする（2026-10-14 時点の GitHub releases の latest）
  - apt でインストールしているパッケージが trixie でそのまま入るかを、PR の検証ビルドで確かめる。名前が変わっていれば直す
- `images/devcontainer-base/examples/Dockerfile`: `FROM ghcr.io/himorogy/devcontainer-base:2` を `:3` にする
- `images/devcontainer-base/README.md`
  - 浮動タグの参照（`:2`、「`2.7.0` 以降が要る」の類）を v3 の体系に合わせる
  - 「Node 24（`node:24` 由来）」「base は pnpm 11 を焼いており」など、土台と pnpm の版に依存する記述を実態に合わせる
- ルートの `README.md`
  - 「三者の関係」の図にある `devcontainer-base:1`（2か所）を `:3` にする。実体は v2 の時点で既に `:2` だった
  - 「ベースイメージは pnpm 11 なので」の行を実態に合わせる
- `.github/workflows/devcontainer-base.yml`: コメントのうち、浮動タグの例（`:1 / :1.4 / :1.4.2`、`runtime-base:1`）・node のタグ・pnpm 11 に依存している行を実態に合わせる

確かめること（検収で人間が見る。PR の CI だけでは分からないもの）:

- port forwarding が trixie の openssh-server で動く。
  - trixie の openssh は接続ごとの処理を `sshd-session` という別バイナリへ分けている（9.8 以降の上流の変更。trixie で入る版は未確認）。
  - 焼き込みのラッパー `/usr/local/sbin/sshd-inetd` は `sshd -i`（inetd モード）で起動する。この組み合わせで接続できるか、`/run/sshd` が要るかは実機でしか確かめられない。
  - CI の smoke test は sshd を見ていない。`host-tools/tests/dock.test.sh` は偽の sshd-inetd で検査している。
  - 手順: `workflow_dispatch` で `:edge` を push し、`.devcontainer` の FROM をその digest に一時的に替えて rebuild する。ホストから `karakuri-port-forward` で転送を張る。手順の型は 0029a と同じ（edge 検証 → タグ）
  - 直す必要が出たら、`/usr/local/sbin/sshd-inetd` の生成箇所（このチケットの targets の Dockerfile）で直す。`images/devcontainer-base/PORT-FORWARDING.md` の記述が偽になる場合は、その時点で止まって報告する（targets の拡張は軽量裁可で決める）
- 同じ rebuild で、`postCreateCommand` から `personal-setup` が名前だけで起動する（台帳 E-a）

### やらないこと

- タグを打つこと・GHCR に push すること（人間の手作業）
- このリポジトリ自身の `.devcontainer/Dockerfile` の pin を上げること。上げるのは、v3 が base を利用する別のリポジトリで実運用に耐えてから（`images/devcontainer-base/README.md`「判断済み」の N-1 規律）。上げるときに別のチケットを起票する
- monitor.yml の変更（0055 が golang の変種名のコメントを扱う）
- CI の smoke test に sshd の検査を足すこと
- node 26 への移行（issue `#36`）、egress-proxy の trixie 化
- 検査の深さ: trixie で入る各パッケージの版の差（zsh・vim-tiny・ripgrep などのマイナー版の違い）を一つずつ検証することはしない

## 保証

### 新たに宣言する保証

- なし（土台と固定している版の更新であり、利用側に差し出す振る舞いは増えない）

### 維持する保証

- 台帳 E-a「`personal-setup` はイメージの `/usr/local/bin` に実行可能な状態で置かれ、`postCreateCommand` から名前だけで起動できる」。土台を替えて rebuild しても成り立つこと

### 廃止する保証

- なし（取り下げる約束は無い）
