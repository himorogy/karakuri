---
status: open
type: fix
base: main
targets:
  - images/devcontainer-base/Dockerfile
  - images/devcontainer-base/examples/docker-compose.yaml
verify:
  - pnpm lint:sh
  - pnpm test
---

# devcontainer-base で node を proxy グループに入れ、ssh で入ったシェルからも egress-proxy の記録を読めるようにする

## 内容

### 実測した事実

- egress-proxy の access log は proxy（uid/gid 13）所有の mode 0640 で作られ、dev には named volume を `/var/log/egress-proxy` に `:ro` でマウントしている。
  node（uid 1000）が読むには補助グループ 13 が要り、compose の `group_add: ["13"]` がそれを与えている
- `group_add` が効くのはコンテナの PID 1 と `docker exec` で起こしたプロセスだけである。
  ホストの dock.sh が `docker exec -i -u root <container> /usr/local/sbin/sshd-inetd` で起こす sshd 経由のログインでは、sshd が `/etc/group` を読んで補助グループを組み直すため 13 が落ちる。
  実測: PID 1 は `Groups: 13 1000`、ssh 経由のシェルは `Groups: 1000`、`/etc/group` の `proxy:x:13:` に node は居ない。
  ssh 経由のシェルで `cat /var/log/egress-proxy/access.log` は `Permission denied` になる
- 台帳 B-a「この記録はエージェントのコンテナから読めるが、書き換えられない」の読める側は、`docker exec` 経路でしか成立していない。
  `verify-l7.sh` の `proxy_log_has` も `dc exec` で読んでいるので、この差はそこでは捕まらない

### 変更

1. `images/devcontainer-base/Dockerfile` で node を `proxy` グループ（gid 13）に入れる（`usermod -aG proxy node`）。
   置き場所は sshd を設定している節の近くとし、コメントには compose の `group_add` では ssh 経由のログインに届かない理由を残す。
   `proxy` グループは Debian の base-passwd が固定で持つ gid 13 で、sidecar の `user: "13:13"` と同じ番号である
2. `images/devcontainer-base/examples/docker-compose.yaml` から `group_add: ["13"]` とその直上のコメントを外す。
   利用例はこの版以降の base と組で読まれるもので、イメージが所属を持てば compose 側の指定は二重になる。
   access log の volume に付いているコメントはそのまま残す

### やらないこと

- karakuri 自身の `.devcontainer/docker-compose.yaml` の `group_add`。
  pin が 2.5.0 の間は所属を持たないイメージで動くので、外すのは pin を上げるチケットと同時に行う
- `packages/egress-guard/tests/verify-l7.sh` へのログイン経路の検査の追加（`su node` で `/etc/group` 由来の補助グループを組んで読む形）。
  karakuri の pin を上げるまで通らないので、同じく pin のチケットで足す
- devcontainer-base のタグ打ちと karakuri の pin 上げ。
  0028 → 0029a と同じ型で、edge の検証を挟んで別チケットで行う
- runtime-base への同じ変更。sshd を持たず、access log もマウントしないので対象外

### 検収

edge のイメージをビルドしてから確認する。

- `docker run --rm -u root <edge> su node -c 'id -Gn'` の出力に `proxy` が含まれる（sshd と同じく `/etc/group` から補助グループを組む経路）
- `docker run --rm <edge> id -Gn` の出力にも `proxy` が含まれる（`docker exec` 経路の後退が無い）

## 保証

### 新たに宣言する保証

- なし。台帳 B-a「この記録はエージェントのコンテナから読めるが、書き換えられない」は入り方を限定しておらず、この変更はその約束を ssh 経由のシェルでも成立させるものである。約束の文面は増えない

### 維持する保証

- B-a「この記録はエージェントのコンテナから読めるが、書き換えられない」（`docs/guarantees.md` 502 行付近）——読める側を ssh 経由にも広げる変更であり、書き換えられない側は `:ro` マウントと group の `r--` がそのまま担う

### 廃止する保証

- なし。所属を足すだけで、既存の入り方と権限は変えない
