---
status: close
type: fix
base: main
targets:
  - packages/egress-guard/scripts/init-project-firewall.sh
  - packages/egress-guard/tests/firewall-rules.test.sh
  - packages/egress-guard/CHANGELOG.md
  - packages/egress-guard/package.json
  - docs/guarantees.md
verify:
  - pnpm lint:sh
  - pnpm lint
  - pnpm test
---

# L7 の anchor 検査が、起動中の proxy を待たずに panic へ落ちるのを止める

## 内容

L7 実現層の firewall 適用は、最終テーブルを当てた後に proxy 経由で anchor へ CONNECT し、`200` が返るかを見る（`verify_anchor_reachable`）。
この検査は curl を1回だけ打ち、`200` 以外はすべて失敗として panic テーブルへ落ちる。proxy がまだ listen していないときの `000` も同じ扱いになる。

このため、dev と egress-proxy がほぼ同時に起動した直後に適用が走ると、squid が listen を始める前に検査が走って panic へ落ちる。

- `host-tools/dock.sh` の `--ensure-running` は、鍵（`/run/secrets/SSH_AUTHORIZED_KEYS`）が無いとき project 全体を stop → start で作り直し、直後に firewall を当てる。
  - rebuild の直後は `/run` が空の tmpfs なので、必ずこの経路に入る。
  - 失敗すると鍵の注入まで進まず、次の `dock up` もまた作り直しから始まるので、毎回同じところで落ちる。
  - 2026-10-16 に devcontainer-base 3.0.0 / egress-proxy 1.1.0 で再現した。squid の `Accepting HTTP Socket connections` と dock の失敗が同じ秒に出ており、access.log に CONNECT は残っていなかった。
  - 同じコンテナで、作り直しを挟まずにスクリプトを当て直すと通った。
- `postStartCommand` の経路も同じ競合を持つ。compose の `depends_on` は proxy の起動を待つだけで、listen までは待たない。

直すのはスクリプトの側で、dock.sh は変えない。検査の側で待てば、どちらの経路も塞がる。

### 変えるもの

- `verify_anchor_reachable`: proxy がまだ接続を受け付けない間（CONNECT の応答が得られない `000`）だけ、有限の時間、間隔を置いて検査を繰り返す。
  - 間隔はおよそ 1 秒、待つ上限は合計でおよそ 30 秒とする。上限に達しても受け付けなければ、今までどおり非ゼロ終了で panic へ落ちる。
  - proxy が応答して `200` 以外を返したとき（ACL による拒否の `403` など）は、待たずにその場で失敗にする。拒否は待っても変わらないため。
  - 待っている間はその旨を適用ログに出す。黙って最大 30 秒止まると、利用者からはハングと区別がつかない。
  - テストが実時間で待たずに済む形にする。
- `tests/firewall-rules.test.sh`: 保証節のテスト名で、次の3つを足す。
  - 最初の数回は `000`、その後に `200` を返す proxy で、0 で終わる。
  - `000` を返し続ける proxy で、非ゼロ終了し panic テーブルへ落ちる。
  - `403` を返す proxy で、検査を繰り返さない。
- `CHANGELOG.md` と `package.json`: Patch として 0.5.1 を足す（npm には出ず、イメージにのみ届く）。

### 届け方（人間の手作業）

スクリプトは runtime-base に焼き込まれ、devcontainer-base はそれを FROM で受け取る。
利用側へ届くのは、マージ後に人間が `runtime-base-v2.0.1` を打ち、`:2` の更新を待ってから `devcontainer-base-v3.0.1` を打ったときである。順序は入れ替えられない。

確かめること（検収で人間が見る。タグを打つ前に行う）:

- devcontainer-base 3.0.0 で動いている利用側のコンテナに、このブランチの `init-project-firewall.sh` を `docker cp` で `/usr/local/bin/` へ上書きする。
  - `docker stop` / `docker start` ではコンテナの書き込み層が残るので、dock の作り直しを経ても差し替えは消えない
  - `:edge` は使えない。devcontainer-base の `:edge` は `runtime-base:2` を FROM にするため、runtime-base のタグを打つまで新しいスクリプトが入らない
- `/run/secrets/SSH_AUTHORIZED_KEYS` が無い状態（コンテナを再起動すれば `/run` が空になる）で `dock up` を打ち、作り直しの直後の firewall の適用が通って、鍵の注入まで進むこと
- 適用ログに、待った旨の行が出ること（squid が先に listen していた回は出ないことがある）

### やらないこと

- `host-tools/dock.sh` を変えること（作り直しの条件、firewall の失敗時に鍵の注入へ進むかどうか）
- compose の `depends_on` に healthcheck を足すこと（egress-proxy イメージと雛形の変更になる）
- L3 実現層の anchor 検査（DNS の解決）に待ちを入れること
- タグを打つこと・GHCR へ push すること
- 検査の深さ: 待つ上限と間隔の境界値（上限ちょうどで受け付けた場合など）は検査しない。上限に達するまでに受け付けたら通る、受け付けなければ落ちる、の2つだけを見る

## 保証

### 新たに宣言する保証

- L7 実現層で anchor がある場合、proxy がまだ接続を受け付けていない間は有限の時間だけ検査を繰り返し、その間に proxy 経由で anchor へ届けば、最終テーブルを適用して 0 で終わる（テスト: "an anchor check waits for a proxy that is still starting"）
- L7 実現層で、待つ上限までに proxy が接続を受け付けなければ、非ゼロ終了し panic テーブルへ落ちる（テスト: "a proxy that never accepts falls back to the panic table"）
- L7 実現層で、proxy が応答して CONNECT を拒んだときは、検査を繰り返さずに失敗する（テスト: "a denied CONNECT to the anchor is not retried"）

### 維持する保証

- 台帳「L7 実現層で anchor がある場合、proxy 経由で anchor に届かなければ非ゼロ終了し panic テーブルへ落ちる」（テスト: "a denied CONNECT to the anchor exits non-zero" / "a denied CONNECT to the anchor falls back to the panic table"）
- 台帳「L7 実現層では、dev 側の DNS が外部名を解決できない構成でも、proxy 経由で anchor に届く限り、最終テーブルを適用して 0 で終わる」

### 廃止する保証

- なし
