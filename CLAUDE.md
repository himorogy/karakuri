kuda-phase: mvp

Bash は読み取り先が静的に決まる形で書く。`cd` を使わず絶対パスで指定し（git は `-C`）、
検索は対象ディレクトリを絞る（追跡ファイルだけでよいなら `git grep`）。`cd X && grep ... file`
やリポジトリ全体への `grep -r` は読み取り先が確定しないため、`.claude/settings.json` の
`Read()` deny ルールに当たるかを判定できず、確認を求められて止まる。`defaultMode` が
`bypassPermissions` でも deny は評価されるので止まる。worktree で作業する間に頻出する。
