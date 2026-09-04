kuda-phase: mvp

Bash では `cd` を使わず絶対パスで書く（git は `-C`）。`cd X && grep ... file` の形は
読み取り先が静的に決まらないため、`.claude/settings.json` の `Read()` deny ルールに
当たるかを判定できず、確認を求められて止まる。worktree で作業する間に頻出する。
