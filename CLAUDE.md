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
