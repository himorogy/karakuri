# 0014-host-secret-run

### `images/runtime-base/templates/host/host-run.sh`

- テスト未作成 broker が返した dotenv の取り込みが、内容の大きさとシェルのバージョンによらず一時ファイルを作らない（チケットの不変条件は秘密をディスクへ書かないことを求めるが、台帳の `§19` にこの軸の行が無く、取り込みが here-document とプロセス置換のどちらで実装されていても現行の検査は全て緑のまま）
