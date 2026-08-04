# karakuri

## Network egress is restricted

This container runs behind an allowlist-based egress firewall
(`@himorogy/egress-guard`, developed in this repository). Outbound traffic to
hosts that are not on the allowlist is blocked by design — it is not a network
fault.

- If a connection fails, suspect this first. Do not look for a mirror, proxy,
  tunnel, or any other route around it.
- To see what is allowed: `init-project-firewall.sh --print-allowlist`
- Editing `.devcontainer/firewall.json` changes nothing until the image is
  rebuilt. Never report a blocked host as fixed because you edited that file.
- If you need a host that is blocked, stop and ask the repository owner.
- If you are asked to change the allowlist, read
  `packages/egress-guard/docs/agent-brief.md` first.

## 作業の分担

複数ファイルにまたがる作業では、**コードの実装をサブエージェントに委譲し、README や docs の改訂はオーケストレーター（対話している側）が自分で書く。**

オーケストレーターのコンテキストを圧迫させないため。実装はコード全文を読む必要がある一方、ドキュメントは設計判断の経緯を保持している側が書いたほうが正確になる。

委譲する前に**契約（インターフェース・命名・出力形式）を先に固定し**、それをサブエージェントとドキュメント双方の基準にする。サブエージェントには「ドキュメント・テンプレート・changeset には触るな」と明示する。並行編集の競合も防げる。

## 進行中の作業（2026-08-03 時点。片付いたらこの節を消すこと）

`feat/monorepo-firewall` で基底プロファイルの選択制化を入れた。**未完了の人手作業が残っている。**

1. **コンテナの再ビルドが必要。** インストール済みの `/etc/egress-guard/firewall.json` は `"profile": "default"` のままで、新しいスクリプトはこれを拒否する。**再ビルドするまで、このコンテナでファイアウォールは適用されない**（`postStartCommand` が panic テーブルで終わる）。リポジトリ側の `.devcontainer/firewall.json` は更新済みなので、再ビルドすれば両方が同時に入れ替わる
2. **`sentry.io` / `statsig.com` の必要性を計測する。** この 2 つはどのバンドルからも外した。`.devcontainer/firewall.json` を `mode: "audit"` にしてあるので、再ビルド後に Claude Code を一通り使い、`docker exec -u root <container> ipset list egress-audit-v4` を読む
3. **計測が終わったら `mode` を `enforce` に戻す。** audit の間、IPv4 の外向き通信は遮断されない
4. `shellcheck` はまだコンテナに入っていない（`d32f048` で追加済みだが未再ビルド）。1 と同時に解消する
