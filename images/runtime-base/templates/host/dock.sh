#!/usr/bin/env bash
set -euo pipefail

# MSYS_NO_PATHCONV=1 は Git Bash(MSYS2) のパス変換を止める。先頭が `/` の
# 引数（コンテナ内の絶対パス）を Windows パスへ変換されると、docker exec に
# 渡したパスがコンテナ内に存在しないものへ化ける。`--secrets-ok` /
# `--stdio` の secret 判定（`test -f /run/secrets/...`）はまさにこれで
# 常に false になっていた（実機で確認済みの不具合）。ここは呼び出しごとに
# `env MSYS_NO_PATHCONV=1` を前置きするのではなく、スクリプト冒頭で export
# する形に寄せている。dock.sh は独立したプロセスとして起動されるので、この
# export は呼び出し元のシェルへは漏れない。以後このファイルが呼ぶ docker の
# 全呼び出し（コンテナ特定・起動・secret 判定・exec）に一律で効く。
export MSYS_NO_PATHCONV=1

# dock.sh — dev container へ入るためのホスト側スクリプト。
#
# compose project 名・service 名・workspace はすべて引数で受け取り、
# コンテナ名や workspace のパスを組み立てない。規約の吸収（compose project
# 名の付け方・workspace のパス）は呼び出し側の仕事にする。karakuri の
# 配布物には規約を仮定する薄いラッパーは含めない。
#
#   dock.sh -p <compose-project> [-s <service>] [-w <workspace>] [<mode>]
#
# <service> の既定は "dev"。<workspace> を省略すると docker exec に -w を
# 渡さず、コンテナの WORKDIR に従う。
#
# モード（省略時は対話 zsh）:
#
#   --stdio           ~/.ssh/config の ProxyCommand から呼ばれ、コンテナ内の
#                      sshd を inetd モードで起動して stdin/stdout を SSH の
#                      トランスポートにする（下の CONTRACT を参照）。secret
#                      が未注入なら fail closed で exit 1 にする。
#   --ensure-running   対象コンテナを起動して終了する。stdout に何も出さない。
#   --secrets-ok       secret が注入済みかを判定して exit 0 / 1 を返す。
#                      stdout・stderr は空。コンテナの起動状態は変えない
#                      （判定を打っただけで起動するのは呼び出し側から見て
#                      予想外である）。
#
# 判定は /run/secrets/SSH_AUTHORIZED_KEYS の有無で行い、root で実行する。
# /run/secrets の所有と mode を決めるのは注入側であり、既定ユーザーで読める
# 保証を判定側が前提にすると、注入側が権限を締めた瞬間に「注入済みなのに
# 未注入と誤判定する」形で壊れる。/run が tmpfs である以上、SSH 鍵の有無は
# 「この起動に対して注入を実行したか」と同義であり、同じ 1 回の注入で入る
# 他の secret の有無とも一致する。
#
# ~/.ssh/config での使い方（PORT-FORWARDING.md も参照）:
#
#   Host devc-<your-project>
#     HostName <your-project>-dev
#
#   Host devc-*
#     ProxyCommand /path/to/dock.sh -p %h --stdio
#
# %h は Host ブロックの HostName に展開される。HostName に compose project
# 名そのものを書いておけば、`ssh devc-<your-project>` を打ったときに
# ProxyCommand へ -p の値がそのまま渡る。

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
  dock.sh -p <compose-project> [-s <service>] [-w <workspace>]
  dock.sh -p <compose-project> [-s <service>] --stdio
  dock.sh -p <compose-project> [-s <service>] --ensure-running
  dock.sh -p <compose-project> [-s <service>] --secrets-ok

Options:
  -p <compose-project>  compose project label to match (required)
  -s <service>          compose service label to match (default: dev)
  -w <workspace>        docker exec -w value (default: container's WORKDIR;
                        used by the default mode only)

Modes:
  (default)         Open an interactive zsh session in the dev container.
  --stdio           Run sshd over stdin/stdout for SSH ProxyCommand. Fails
                    closed (exit 1, no stdout) when secrets are not injected.
  --ensure-running  Start the container if it is not running, then exit.
  --secrets-ok      Exit 0 if secrets are injected, 1 otherwise. Never
                    starts the container and never prints anything.
EOF
}

project=""
service=""
workspace=""
mode="shell"
mode_flag=""

set_mode() {
    if [[ -n "$mode_flag" && "$mode_flag" != "$1" ]]; then
        echo "dock: cannot combine ${mode_flag} and $1 — pick one mode" >&2
        exit 1
    fi
    mode_flag="$1"
    mode="$2"
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -p)
            [[ "$#" -ge 2 ]] || { echo "dock: -p requires a value" >&2; usage; exit 1; }
            project="$2"
            shift 2
            ;;
        -s)
            [[ "$#" -ge 2 ]] || { echo "dock: -s requires a value" >&2; usage; exit 1; }
            service="$2"
            shift 2
            ;;
        -w)
            [[ "$#" -ge 2 ]] || { echo "dock: -w requires a value" >&2; usage; exit 1; }
            workspace="$2"
            shift 2
            ;;
        --stdio)
            set_mode --stdio stdio
            shift
            ;;
        --ensure-running)
            set_mode --ensure-running ensure-running
            shift
            ;;
        --secrets-ok)
            set_mode --secrets-ok secrets-ok
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
        *)
            echo "Unexpected argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$project" ]]; then
    echo "dock: -p <compose-project> is required" >&2
    usage
    exit 1
fi

service="${service:-dev}"

# コンテナはコンテナ名の決め打ちではなく、compose 自身が付けるラベルで引く。
# `com.docker.compose.project` と `com.docker.compose.service` は
# docker/compose が生成するコンテナへ必ず付ける識別子で、project 名・
# service 名のどちらも compose ファイルの中身を読まずに厳密一致で引ける
# （karakuri.sh の karakuri-prod-shell と同じ規律）。
#
# -a を付けるのは、停止中のコンテナも引いて起動できるようにするため
# （devcontainer は使わないときコンテナを止めるのが普通の運用）。
cids="$(docker ps -a -q \
    --filter "label=com.docker.compose.project=${project}" \
    --filter "label=com.docker.compose.service=${service}")" || {
    echo "dock: 'docker ps' failed" >&2
    exit 1
}

if [[ -z "$cids" ]]; then
    echo "dock: no container for service '${service}' in compose project '${project}'. Start it first (e.g. open the project in your devcontainer tool), then try again" >&2
    exit 1
fi

# 複数件でも止める。「とりあえず 1 つ選ぶ」は、選んだことが利用者に見えない
# まま別のコンテナへ入ることになる（karakuri-prod-shell と同じ規律）。
if [[ "$(printf '%s\n' "$cids" | wc -l)" -gt 1 ]]; then
    echo "dock: multiple containers match service '${service}' in compose project '${project}' — cannot decide which one to enter" >&2
    exit 1
fi

container="$cids"

running="$(docker inspect -f '{{.State.Running}}' "$container")" || {
    echo "dock: 'docker inspect' failed for '${container}'" >&2
    exit 1
}

case "$mode" in
    # コンテナの起動状態を変えない。停止中なら、この起動に対する注入は
    # 起きていないと確定するので、docker exec で問い合わせるまでもなく
    # 未注入として扱う（/run は tmpfs で、停止のたびに空になる）。
    secrets-ok)
        if [[ "$running" != "true" ]]; then
            exit 1
        fi
        if docker exec -u root "$container" test -f /run/secrets/SSH_AUTHORIZED_KEYS >/dev/null 2>&1; then
            exit 0
        fi
        exit 1
        ;;

    ensure-running)
        if [[ "$running" != "true" ]]; then
            docker start "$container" >/dev/null
        fi
        exit 0
        ;;

    # fd 1 IS the SSH transport -- see CONTRACT at the top of this file.
    # Anything printed to stdout here breaks the connection.
    stdio)
        if [[ "$running" != "true" ]]; then
            docker start "$container" >/dev/null
        fi

        # Fail closed: 素通しすると sshd がパスワード認証へフォールバック
        # し、原因（secret が無い）から遠い症状になる。認可を求め直す代行も
        # しない（非対話の ssh 接続の裏で黙って認可を求めると応答できない
        # まま固まる）。
        if ! docker exec -u root "$container" test -f /run/secrets/SSH_AUTHORIZED_KEYS >/dev/null 2>&1; then
            echo "dock: secrets are not injected into '${container}'. Run 'karakuri-dock up -p ${project}' on the host, then reconnect" >&2
            exit 1
        fi

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
        exec docker exec \
            -i \
            -u root \
            "$container" \
            /usr/local/sbin/sshd-inetd
        ;;

    shell)
        if [[ "$running" != "true" ]]; then
            echo "Starting $container..." >&2
            docker start "$container" >/dev/null
        fi

        if [[ -n "$workspace" ]]; then
            exec docker exec \
                -it \
                -w "$workspace" \
                "$container" \
                zsh
        fi

        exec docker exec \
            -it \
            "$container" \
            zsh
        ;;
esac
