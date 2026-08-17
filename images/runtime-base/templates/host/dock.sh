#!/usr/bin/env bash
set -euo pipefail

# dock.sh — dev container へ入るためのホスト側スクリプト。
#
# 既定（引数省略）は dev container の中で対話 zsh を開く。
# --stdio は ~/.ssh/config の ProxyCommand から呼ばれ、コンテナ内の sshd を
# inetd モードで起動して stdin/stdout を SSH のトランスポートにする
# （詳細は下の CONTRACT を参照）。
#
# ~/.ssh/config での使い方（PORT-FORWARDING.md も参照）:
#
#   Host devc-*
#     ProxyCommand /path/to/dock.sh %h --stdio
#
# %h は Host ブロックの HostName に展開される。したがって
#
#   Host devc-<project>
#     HostName <project>
#
# のように書いておけば、`ssh devc-<project>` を打ったときに ProxyCommand へ
# プロジェクト名がそのまま渡る。

# ---------------------------------------------------------------------------
# CONTRACT (--stdio mode)
#
# In --stdio mode, fd 1 IS the SSH transport. ssh(1) feeds the SSH protocol
# through this process's stdin/stdout instead of a TCP socket, so the following
# are hard invariants. Violating any of them corrupts the stream and the
# connection fails with an opaque error such as
# "Bad packet length" or "kex_exchange_identification".
#
#   1. NOTHING but SSH protocol bytes may reach stdout.
#      Every diagnostic goes to stderr (>&2). Every command run before the
#      exec must have its stdout redirected (>/dev/null). This includes any
#      command added in the future -- docker start, docker inspect, echo,
#      set -x, a progress spinner, a shell prompt from a sourced rc file.
#
#   2. NEVER allocate a TTY. Use `docker exec -i`, never `-it`.
#      A pty applies line discipline (echo, CR/LF translation, ^C handling)
#      which mangles binary protocol data.
#
#   3. Do not read from stdin. It belongs to ssh(1).
#      No prompts, no `read`, no interactive confirmation. If a precondition
#      cannot be satisfied, fail with a stderr message and a non-zero exit.
#
#   4. Always `exec` into sshd. No wrapper process, no trailing commands.
#      This keeps EOF and signal propagation intact so the container-side
#      sshd exits when ssh(1) does, leaving no orphan processes.
#
#   5. Run sshd as root (-u root). It drops privileges after authenticating.
#
#   6. Keep `sshd -e`. It logs to stderr instead of syslog, which surfaces
#      auth failures directly in the ssh(1) client's output.
#
#   7. Fail closed. Preconditions are checked before the exec, never after --
#      once a single byte is written to stdout, the stream is committed.
# ---------------------------------------------------------------------------

usage() {
    cat >&2 <<'EOF'
Usage:
  dock <project>
  dock <project> --stdio

Modes:
  default   Open an interactive zsh session in the dev container.
  --stdio   Run sshd over stdin/stdout for SSH ProxyCommand.
EOF
}

project=""
mode="shell"

for arg in "$@"; do
    case "$arg" in
        --stdio)
            mode="stdio"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $arg" >&2
            usage
            exit 1
            ;;
        *)
            if [[ -n "$project" ]]; then
                echo "Unexpected argument: $arg" >&2
                usage
                exit 1
            fi
            project="$arg"
            ;;
    esac
done

if [[ -z "$project" ]]; then
    usage
    exit 1
fi

# コンテナはコンテナ名の決め打ちではなく、compose 自身が付けるラベルで引く。
# `com.docker.compose.project` と `com.docker.compose.service` は
# docker/compose が生成するコンテナへ必ず付ける識別子で、project 名・
# service 名のどちらも compose ファイルの中身を読まずに厳密一致で引ける。
# ラベルは compose 自身がコンテナへ焼き込む識別子であり、こちらが名前を
# 組み立てて一致を期待するものではない（karakuri.sh の karakuri-prod-shell
# と同じ規律。examples/docker-compose.yaml の container_name は
# `<project>-devcontainer` で、以前この関数が組み立てていた
# `<project>-dev-container` とは一致しない。名前の組み立てに頼ると、
# こういう食い違いがそのまま「見つからない」や「別プロジェクトへ入る」に
# なる）。
#
# compose project 名は `<project>-dev`（karakuri-dev-inject / dev-inject.sh
# が使っている規約と同じ）。service 名は `dev`（examples/docker-compose.yaml
# の services: を参照）。
compose_project="${project}-dev"
service="dev"

# -a を付けるのは、停止中のコンテナも引いて起動できるようにするため
# （devcontainer は使わないときコンテナを止めるのが普通の運用）。
cids="$(docker ps -a -q \
    --filter "label=com.docker.compose.project=${compose_project}" \
    --filter "label=com.docker.compose.service=${service}")" || {
    echo "dock: 'docker ps' failed" >&2
    exit 1
}

if [[ -z "$cids" ]]; then
    echo "dock: no container for service '${service}' in compose project '${compose_project}'. The dev container for '${project}' has not been created yet — its compose project name should be '${compose_project}' (open the project in the IDE / devcontainer extension first)" >&2
    exit 1
fi

# 複数件でも止める。「とりあえず 1 つ選ぶ」は、選んだことが利用者に見えない
# まま別のコンテナへ入ることになる（karakuri-prod-shell と同じ規律）。
if [[ "$(printf '%s\n' "$cids" | wc -l)" -gt 1 ]]; then
    echo "dock: multiple containers match service '${service}' in compose project '${compose_project}' — cannot decide which one to enter" >&2
    exit 1
fi

container="$cids"

# workspace は shell モードでのみ使う。devcontainer.json の workspaceFolder
# の規約（/workspaces/<project>）に合わせたもので、--stdio 側では使わない。
workspace="/workspaces/${project}"

running="$(docker inspect -f '{{.State.Running}}' "$container")"

if [[ "$running" != "true" ]]; then
    echo "Starting $container..." >&2
    docker start "$container" >/dev/null
fi

case "$mode" in
    shell)
        exec env \
            MSYS_NO_PATHCONV=1 \
            docker exec \
            -it \
            -w "$workspace" \
            "$container" \
            zsh
        ;;
    # fd 1 IS the SSH transport -- see CONTRACT at the top of this file.
    # Anything printed to stdout here breaks the connection.
    stdio)
        # /usr/local/sbin/sshd-inetd を絶対パスで直接 exec する。
        #
        # 以前はこれに `command -v sshd-inetd >/dev/null && exec sshd-inetd
        # || exec /usr/sbin/sshd -i -e` というフォールバックが付いていたが、
        # 実害があったので削った。sshd-inetd を持たない古いイメージの
        # コンテナに対して、黙って `/usr/sbin/sshd -i -e` を直接起動して
        # しまっていたためである。sshd-inetd ラッパー（images/devcontainer-base
        # /Dockerfile 参照）は起動のたびに `mkdir -p /run/sshd` と
        # `ssh-keygen -A` を行うが、それを飛ばすと
        # "Missing privilege separation directory: /run/sshd" という、原因から
        # 遠いエラーになる（/run は compose で tmpfs にされており、コンテナ
        # 起動のたびに空になる）。移行の保険として入れていたフォールバックが、
        # 実際には失敗を隠して原因の分かりにくいエラーに変換していた。
        # ラッパーを持たないイメージに対しては、フォールバックを削ったことで
        # `docker exec` が "executable file not found" で明示的に失敗する
        # ようになる。
        #
        # 絶対パスで書くのは PATH 解決に依存させないため（sh -c を挟む
        # 必要も無くなる）。
        exec env \
            MSYS_NO_PATHCONV=1 \
            docker exec \
            -i \
            -u root \
            "$container" \
            /usr/local/sbin/sshd-inetd
        ;;
esac
