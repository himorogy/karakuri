# 0020-l7-sidecar-and-branch

### ドメインを 1 つも書かない L7 設定での sidecar の起動

- テスト困難 `allowDomains` が空（または `allowCidrs` だけ）の L7 設定でも、proxy の sidecar は起動し、allowlist に無い宛先を拒否する（ACL の出力が空になったとき、焼き込んだ `allowed-domains.txt` が 0 行になる。Squid が空のファイルベース `dstdomain` ACL を fatal として扱う場合、この設定では sidecar が起動しないことになる。判定には実際に `squid -k parse` を回す必要があり、ACL の出力側の検査だけでは届かない）
