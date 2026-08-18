#!/usr/bin/env bash

## setup-codex
npm install -g @openai/codex

## setup-git-credential
# github.com への認証を gh のトークンに委ねる。VS Code が注入する credential helper は
# tmp パス依存で docker exec 接続では機能しないため、接続方法に依らず push できるようにする。
# gh は .env.container の GH_TOKEN で認証済みの前提。未認証時は何もしない。
#
# この repo の devcontainer は bootstrap 規律で devcontainer-base 1.2.0 に pin して
# おり (.devcontainer/Dockerfile)、そこには GIT_ASKPASS も credential helper の
# 打ち消しも入っていない。したがってここはまだ必要である。
#
# pin を「打ち消しを持つ版」へ上げたら、この節は消してよい。base が github.com の
# helper を打ち消し、認証を GIT_ASKPASS -> /run/secrets/GH_TOKEN へ固定するので、
# ここが書く helper は github.com については呼ばれなくなる (壊れはしないが死に設定に
# なる。images/runtime-base/README.md の「git の認証（github.com）」)。
if gh auth status >/dev/null 2>&1; then
  gh auth setup-git
fi
