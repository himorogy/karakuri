# egress-proxy

`@himorogy/egress-guard` の `layer: "l7"`（既定）が使う L7 proxy sidecar の、GHCR で配布する
prebuilt image。

```
ghcr.io/himorogy/egress-proxy:1
```

**何のために** — これまで `layer: "l7"` を選ぶプロジェクトは、`packages/egress-guard/templates/proxy/`
の雛形（`Dockerfile` と `squid.conf`）をコピーし、ビルドのたびに `node` イメージで
egress-guard を `npm install` して squid の ACL を焼いていた。squid の据え方（非 root、
`-N`、ACL の置き場所、cache manager の拒否、`dstdomain -n`）はどのプロジェクトでも変える
理由が無い部分で、そこを prebuilt image に焼き込むと、利用側に残るのは `firewall.json`
から ACL と `mode` を焼く 1 コマンドだけになる。

## 何を焼いてあるか

- `squid`（`/etc/squid/squid.conf`。CONNECT と絶対 URI の HTTP だけを扱い、TLS は
  終端しない）
- `/usr/local/bin/init-project-firewall.sh` — `@himorogy/egress-guard` から `npm install -g`
  で取得（`ARG EGRESS_GUARD_VERSION`）
- `/usr/local/bin/egress-proxy-bake` — 利用側が呼ぶ焼き込みコマンド
- `USER proxy`（uid 13）で起動する `ENTRYPOINT`

`firewall.json` そのものはこのイメージに含まれない。利用側が自分の `firewall.json` を
`COPY` し、`egress-proxy-bake` で焼く。

## 使い方

利用側の compose で `dockerfile_inline` を使い、次の 3 行だけを書く。

```yaml
services:
  egress-proxy:
    build:
      dockerfile_inline: |
        FROM ghcr.io/himorogy/egress-proxy:1
        COPY firewall.json /firewall.json
        RUN egress-proxy-bake /firewall.json
```

`FROM` の直後から `USER proxy` のままで、`USER root` / `USER proxy` の 2 行を挟む必要は
ない（`egress-proxy-bake` の書き込み先はあらかじめ `proxy:proxy` 所有にしてある）。

`allowDomains` や `mode` を変えたときは、このイメージを再ビルドしないと反映されない。
実行中のコンテナに ACL を差し替える経路は無い。

## 保証

- 台帳 `docs/guarantees.md`（テスト: `images/egress-proxy/tests/bake.test.sh`）
- squid が非 root（uid 13）で起動することは、起源チケット `0035-egress-proxy-image` の
  未検証の約束として台帳にある（push 済みイメージでの smoke test が要る）

## リリース

`.github/workflows/egress-proxy.yml` が `linux/amd64,linux/arm64` のマルチアーキビルドと
GHCR への push を行う。`runtime-base` / `devcontainer-base` のリリースとは独立で、
順序の縛りは無い。

### タグ体系

| タグ | 内容 |
|---|---|
| `:1` | メジャー内の最新。**利用側が参照するのはこれ** |
| `:1.0` | マイナー内の最新 |
| `:1.0.0` | 特定バージョン |
| `sha-<commit>` | ビルド元コミット |
| `:edge` | `workflow_dispatch` からの任意ビルド |

`:latest` は生成しない。

### 手順

```sh
# images/egress-proxy/ の変更を main にマージしたあと
git tag -a egress-proxy-v1.0.0 -m "egress-proxy 1.0.0"
git push origin egress-proxy-v1.0.0
```

タグ名は `egress-proxy-v<MAJOR>.<MINOR>.<PATCH>`。形式が違うとワークフローが検証で
落ちる。試作は `workflow_dispatch` の `:edge` を使う。

### 初回だけ手動で必要なこと

GHCR のパッケージは初回 push 時に **private** で作成されるのが通常。初回リリース後に
実際の可視性を確認し、private なら GitHub の
`Packages → egress-proxy → Package settings → Change visibility` で **Public** に
切り替える。public にしておくと利用側の `docker pull` に認証が不要になる。
