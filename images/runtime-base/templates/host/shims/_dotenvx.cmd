@echo off
setlocal
rem host/shims/_dotenvx.cmd — Windows 用の _dotenvx ラッパー
rem
rem pnpm の run-script は Windows で cmd.exe から起動するため、拡張子の無い
rem POSIX シェルスクリプト（_dotenvx）は PATHEXT に該当せず解決されない。
rem この .cmd 1本だけを配り、.ps1 は配らない（pnpm の run-script は cmd.exe
rem を使うので、PowerShell から直接叩く経路は契約に無い）。
rem
rem 判定の意味論は _dotenvx（POSIX 側）と同一: DOTENV_PRIVATE_KEY* が環境に
rem あるときだけ実体を起動し、無ければ実体を一度も起動せずに非ゼロで終わる。
rem
rem `set DOTENV_PRIVATE_KEY` は名前が前方一致する変数だけを列挙し、1件も
rem 無ければ errorlevel 1 を返す。`env | grep` 相当の行走査と違い、値の中身
rem を行として読まないため、改行を含む値を持つ無関係な変数に影響されない。
set DOTENV_PRIVATE_KEY >nul 2>&1
if errorlevel 1 (
  echo _dotenvx: no DOTENV_PRIVATE_KEY* found in the environment 1>&2
  echo _dotenvx:   supply it via 'karakuri-run', or set it directly as an 1>&2
  echo _dotenvx:   environment variable ^(e.g. from CI secrets^) 1>&2
  exit /b 1
)

rem call を使うのは、解決先が別の .cmd/.bat（npm の bin スタブ等）だった
rem 場合に制御が戻らず errorlevel の伝播が漏れる、という古典的な罠を避ける
rem ため。call が無いと、解決先がバッチファイルのときこの行で処理が
rem そちらへ移ってしまい、以降の exit /b が実行されないまま終わる。
call dotenvx %*
exit /b %errorlevel%
