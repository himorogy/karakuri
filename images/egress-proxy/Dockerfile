# egress-proxy — prebuilt L7 sidecar image for egress-guard's `layer: "l7"`.
#
# squid の据え方 (非 root、-N、ACL の場所、mgr 拒否、dstdomain -n) はここに
# 焼き込み、利用側に残すのは firewall.json から ACL と mode を焼く操作
# (egress-proxy-bake) だけにする。詳しい経緯は
# docs/archive/egress-guard-design.md §2.23、squid.conf 自体の個々の設定行
# の理由はそのファイルのコメントを参照。
#
# 単一ステージ。init-project-firewall.sh と templates/ は packages/egress-guard
# (このリポジトリ、ビルド元コミットのソースそのもの) から named build context
# `egress-guard` で受け取る。

FROM debian:bookworm-slim

# --no-install-recommends keeps out cachemgr's cgi and the other pieces this
# CONNECT-only, no-ssl_bump configuration never exercises but that would
# otherwise still ship in the image. jq is the only external command
# --print-proxy-acl and egress-proxy-bake use; bash is already part of the
# base image's essential set (init-project-firewall.sh has a bash shebang).
RUN apt-get update \
    && apt-get install -y --no-install-recommends squid jq \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# read_only: true at the container level (see 0036's compose example) means
# /var/spool/squid and /run have to exist before the tmpfs mounts land on
# top of them at startup; /var/log/squid is the mount point for the named
# volume the access log lives on. Nothing is written into the image layer.
RUN mkdir -p /var/spool/squid /var/log/squid /run

# init-project-firewall.sh and the three firewall.json templates come from
# packages/egress-guard in this repo. The build context is
# images/egress-proxy, so they're supplied as a named build context (same
# shape as runtime-base's env-guard context): pass
# `--build-context egress-guard=packages/egress-guard` (GitHub Actions:
# docker/build-push-action's build-contexts input). Without it, the COPY
# below fails.
COPY --from=egress-guard scripts/init-project-firewall.sh /usr/local/bin/init-project-firewall.sh
COPY --from=egress-guard templates/firewall.json templates/firewall.audit.json templates/firewall.example.json /usr/share/egress-guard/templates/
COPY squid.conf /etc/squid/squid.conf
COPY bin/egress-proxy-bake /usr/local/bin/egress-proxy-bake

# allowed-domains.txt starts empty; egress-proxy-bake overwrites it (and
# possibly squid.conf) in the consuming image's own build. Both are
# proxy:proxy so that a `RUN egress-proxy-bake` placed after `USER proxy` in
# the consumer's Dockerfile can write them without needing write access to
# /etc/squid itself (egress-proxy-bake replaces file contents in place
# rather than renaming, precisely so this ownership is enough).
RUN chown root:root /usr/local/bin/init-project-firewall.sh \
    && chmod 755 /usr/local/bin/init-project-firewall.sh \
    && chown root:root /usr/share/egress-guard/templates/*.json \
    && chmod 644 /usr/share/egress-guard/templates/*.json \
    && chmod 755 /usr/local/bin/egress-proxy-bake \
    && touch /etc/squid/allowed-domains.txt \
    && chown proxy:proxy /etc/squid/allowed-domains.txt /etc/squid/squid.conf

EXPOSE 3128

# Runs as proxy (uid 13) from the start rather than letting Squid drop
# privileges into it: with every capability dropped at the container level,
# Squid's own privilege-drop step has nothing to drop into and segfaults.
# http_port 3128 is unprivileged, so starting here costs nothing. Consumers
# that add `RUN egress-proxy-bake` after `FROM` inherit this USER as-is.
USER proxy

ENTRYPOINT ["squid", "-N", "-f", "/etc/squid/squid.conf"]
