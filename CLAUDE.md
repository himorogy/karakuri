# karakuri

## Network egress is restricted

This container runs behind an allowlist-based egress firewall
(`@himorogy/egress-guard`, developed in this repository). A blocked connection
is by design, not a fault.

- Do not look for a mirror, proxy, tunnel, or any other way around it.
- What is allowed: `init-project-firewall.sh --print-allowlist`
- An allowed host that starts failing means stale addresses (resolved at
  startup; CDNs move). Re-apply once: `sudo init-project-firewall.sh` — it only
  re-resolves, so do not retry it.
- Editing `.devcontainer/firewall.json` does nothing until the image is rebuilt.
  Never report a blocked host as fixed because you edited it.
- Anything else: stop and ask the repository owner. Before changing the
  allowlist, read `packages/egress-guard/docs/agent-brief.md`.

## 作業の分担

複数ファイルにまたがる作業では、**コードの実装をサブエージェントに委譲し、README や docs の改訂はオーケストレーター（対話している側）が自分で書く。**

オーケストレーターのコンテキストを圧迫させないため。実装はコード全文を読む必要がある一方、ドキュメントは設計判断の経緯を保持している側が書いたほうが正確になる。

委譲する前に**契約（インターフェース・命名・出力形式）を先に固定し**、それをサブエージェントとドキュメント双方の基準にする。サブエージェントには「ドキュメント・テンプレート・changeset には触るな」と明示する。並行編集の競合も防げる。
