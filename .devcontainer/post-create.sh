#!/usr/bin/env bash

## setup-codex
npm install -g @openai/codex

## setup-git-credential
# github.com への認証を gh のトークンに委ねる。VS Code が注入する credential helper は
# tmp パス依存で docker exec 接続では機能しないため、接続方法に依らず push できるようにする。
# gh は .env.container の GH_TOKEN で認証済みの前提。未認証時は何もしない。
if gh auth status >/dev/null 2>&1; then
  gh auth setup-git
fi
