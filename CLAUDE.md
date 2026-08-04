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

## 進行中の作業（2026-08-04 時点。片付いたらこの節を消すこと）

`feat/monorepo-firewall` で基底プロファイルを選択制にし、`audit` モードで宛先を実測した。手順と結果は
`packages/egress-guard/docs/measuring-egress.md`。**残っているのは確認の 1 周分。**

1. **再ビルドが要る。** `.devcontainer/firewall.json` を `mode: "enforce"` に戻し、`profile` に `openai` を追加した。**反映は再ビルド後**
2. **再ビルド後に codex で 1 往復して、通ることを確かめる。**

   ```sh
   codex exec --sandbox read-only --skip-git-repo-check "Answer in one short sentence: what is 2+2?"
   ```

   通れば `openai` バンドルの 2 ドメインで足りると確定する。落ちたら `ipset list egress-audit-v4` に積まれたものが次の候補。**`measuring-egress.md` の「未解決」の項（`172.64.144.52`）はこれで決着する**
