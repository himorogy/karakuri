#!/usr/bin/env bash
#
# プロジェクト側 post-create.sh の雛形。
# .devcontainer/post-create.sh としてコピーし、要らない節を削る。
#
# postCreateCommand から呼ばれる。**egress-guard が適用されるより前**に走るため、
# ここでの外向き通信は制限されない。逆に言えば、firewall の適用後に外から取ってくる
# 作業は成立しないので、取得を伴うものはこの段階に置く。

set -eu

## setup-codex
# エージェント CLI をイメージに焼かず、ここで入れる。prod 環境のイメージに
# 含めないため。codex を使わないなら削る。
npm install -g @openai/codex

## setup-git-credential
# github.com への認証を gh のトークンに委ねる。VS Code が注入する credential helper は
# tmp パス依存で docker exec 接続では機能しないため、接続方法に依らず push できるようにする。
# gh は .env.container の GH_TOKEN で認証済みの前提。未認証時は何もしない。
if gh auth status >/dev/null 2>&1; then
  gh auth setup-git
fi
