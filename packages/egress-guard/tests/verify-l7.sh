#!/usr/bin/env bash
#
# egress-guard L7 — 実機の判定を常設化したスクリプト。
#
# packages/egress-guard/poc/l7-proxy/verify.sh が確かめていた項目を引き継ぎ、
# 対象を本実装（このリポジトリの .devcontainer/docker-compose.yaml）へ向ける。
# 新しく、proxy 環境変数を無視した直接接続の遮断と、ACL 変更にイメージの
# 再ビルドが要ることの 2 項目を足す。
#
# 判定できない・対象を超える項目は SKIP として明示し、黙って飛ばさない
# (docs/verification-record.md 5節: 消えた SKIP はあったことにされたカバレッジ
# になる)。
#
# **ホスト側でのみ実行できる。** devcontainer の中には docker が無い。
# pnpm test からは呼ばない（同じ理由。ルート package.json の verify:l7 から
# 直接叩く）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/.devcontainer/docker-compose.yaml"
PROXY_TEMPLATE_DIR="$REPO_ROOT/packages/egress-guard/templates/proxy"
PTR_HARNESS_SCRIPT="$SCRIPT_DIR/ptr-spoof-harness.py"

# COMPOSE_FILE 自身の `name: karakuri-dev` と named volume (karakuri-claude-config
# 等) は開発者が実際に使っているスタックのものそのもの。-p で別プロジェクトに
# し、volume 名も上書きして、この検証がその開発者のスタック (Claude 設定・
# コマンド履歴) に触れないようにする。
PROJECT="karakuri-verify-l7"
ISOLATION_OVERLAY="$(mktemp)"
trap 'rm -f "$ISOLATION_OVERLAY"' EXIT
cat >"$ISOLATION_OVERLAY" <<EOF
services:
  dev:
    container_name: karakuri-verify-l7-dev-container
volumes:
  karakuri-bashhistory:
    name: karakuri-verify-l7-bashhistory
  karakuri-claude-config:
    name: karakuri-verify-l7-claude-config
  karakuri-codex-config:
    name: karakuri-verify-l7-codex-config
  karakuri-proxy-log:
    name: karakuri-verify-l7-proxy-log
EOF

# apt-get update の 1〜2回目の間隔。既定は90秒だが、実機のCDNの挙動を見るなら
# もっと長く取ってよい (poc/l7-proxy/verify.sh の V3 を引き継ぐ)。
APT_RECHECK_WAIT_SECONDS="${APT_RECHECK_WAIT_SECONDS:-90}"

# 終了時にスタックを畳まない (ログを見ながらデバッグしたいとき用)。
KEEP_UP="${KEEP_UP:-0}"

PASS=0
FAIL=0
SKIP=0

ok() {
	PASS=$((PASS + 1))
	printf '  ok   %s\n' "$1"
}

ng() {
	FAIL=$((FAIL + 1))
	printf '  FAIL %s\n' "$1" >&2
}

skip() { # <label> <reason>
	SKIP=$((SKIP + 1))
	printf '  SKIP %s (%s)\n' "$1" "$2"
}

dc() {
	docker compose -f "$COMPOSE_FILE" -f "$ISOLATION_OVERLAY" -p "$PROJECT" "$@"
}

# dev で curl を実行する。**戻り値の 2 が肝。**
#
#   0 = curl が成功した
#   1 = curl は動いたが失敗した (proxy が拒否した、到達できない等)
#   2 = **判定不能。** curl そのものを実行できなかった
#
# 2 を 1 と混ぜてはいけない。「接続が失敗すること」を成功条件にしている項目
# では、道具が無くて失敗したのか proxy が拒否したのかを区別しないと ok が
# 偽陽性になる (poc/l7-proxy/verify.sh の同名関数のコメントに記録がある実例)。
dev_curl() {
	local out rc
	out="$(dc exec -T dev curl "$@" 2>&1)"
	rc=$?
	case "$rc" in
	126 | 127) return 2 ;;
	esac
	if printf '%s\n' "$out" | grep -qE 'executable file not found|OCI runtime exec failed|is not running'; then
		return 2
	fi
	printf '%s' "$out"
	return "$rc"
}

require_docker() {
	if ! command -v docker >/dev/null 2>&1; then
		echo "docker が見つからない。このスクリプトはホスト側で実行すること。" >&2
		exit 1
	fi
	if ! docker compose version >/dev/null 2>&1; then
		echo "'docker compose' (v2 プラグイン) が見つからない。" >&2
		exit 1
	fi
}

wait_for_stack() {
	echo "== スタックの起動待ち =="
	local tries=0
	local max_tries=30
	while [ "$tries" -lt "$max_tries" ]; do
		local running
		running="$(dc ps --status running --format '{{.Service}}' 2>/dev/null || true)"
		if echo "$running" | grep -q '^dev$' && echo "$running" | grep -q '^egress-proxy$'; then
			ok "起動前提: dev と egress-proxy が running になった"
			return 0
		fi
		tries=$((tries + 1))
		sleep 2
	done
	ng "起動前提: 一部のサービスが running にならなかった"
	echo "--- docker compose ps -a ---" >&2
	dc ps -a >&2 || true
	local svc
	for svc in dev egress-proxy; do
		echo "--- logs: $svc ---" >&2
		dc logs --no-log-prefix --tail 40 "$svc" >&2 2>&1 || true
	done
	return 1
}

# 素の `docker compose up` は features / postCreateCommand / postStartCommand を
# 飛ばす (docs/conventions.md「環境変数の置き場」の前提)。init-project-firewall.sh
# は devcontainer.json の postStartCommand でしか呼ばれないため、dev には
# まだ最終テーブルが無い。ここで postStartCommand と同じ内容を明示的に当てる。
apply_firewall() {
	echo "== dev へファイアウォールを適用 (postStartCommand と同じ内容) =="
	if dc exec -T -u root dev /usr/local/bin/init-project-firewall.sh; then
		ok "dev にファイアウォールを適用した"
		return 0
	fi
	ng "dev へのファイアウォール適用が失敗した"
	return 1
}

# egress-proxy のアクセスログはファイル (/var/log/squid/access.log) にあり、
# dev からは同じ named volume を :ro でマウントした /var/log/egress-proxy 越しに
# 読む (README.md「proxy のログを読む」)。dev から読めることは group_add: ["13"]
# の効果そのものでもある。
proxy_log_has() { # <needle>
	dc exec -T dev sh -c "cat /var/log/egress-proxy/access.log 2>/dev/null" | grep -q -- "$1"
}

check_apt_first_pass() {
	echo "== apt-get update が proxy 経由で成立するか (1回目) =="
	if dc exec -T -u root dev sh -c 'apt-get update >/tmp/verify-l7-apt-1.log 2>&1'; then
		ok "apt-get update が proxy 経由で成立する (1回目)"
	else
		ng "apt-get update が失敗した (1回目)"
		dc exec -T -u root dev cat /tmp/verify-l7-apt-1.log >&2 || true
	fi
}

check_apt_second_pass() {
	echo "== ${APT_RECHECK_WAIT_SECONDS}秒待ってから2回目の apt-get update =="
	echo "   CDNのアドレスが動いても2回目が壊れないことがL7へ移行する目的そのもの。"
	sleep "$APT_RECHECK_WAIT_SECONDS"
	if dc exec -T -u root dev sh -c 'apt-get update >/tmp/verify-l7-apt-2.log 2>&1'; then
		ok "2回目の apt-get update も成立する"
	else
		ng "2回目の apt-get update が失敗した"
		dc exec -T -u root dev cat /tmp/verify-l7-apt-2.log >&2 || true
	fi
}

check_leading_dot_domains() {
	# firewall.json の allowDomains に ".gallerycdn.vsassets.io" /
	# ".gallery.vsassets.io" を先頭ドットで書いてある。ここには書いていない
	# 具体名 (publisher名) で通ることが、先頭ドットのサフィックスマッチが
	# 効いた証拠になる。
	local targets="anthropic.gallerycdn.vsassets.io anthropic.gallery.vsassets.io"
	echo "== 先頭ドットで許可したドメインの、書いていない具体名への接続 =="
	local target
	for target in $targets; do
		dev_curl -sS -o /dev/null --max-time 10 "https://$target/" >/dev/null 2>&1
		case $? in
		0) ok "$target への接続が proxy を通って成立する" ;;
		2) skip "$target" "dev で curl を実行できなかった" ;;
		*) ng "$target への接続が失敗した" ;;
		esac
		if proxy_log_has "$target"; then
			ok "proxyのログに $target が残る (allowDomainsに書いていない具体名。サフィックスマッチの証拠)"
		else
			ng "proxyのログに $target が見つからない"
		fi
	done
}

check_denied_domain() {
	# .invalid は RFC 2606 で実在しないことが保証されている予約TLD。
	local target="denied-test.invalid"
	echo "== allowlist に無いドメイン ($target) が拒否され、ログに名前が残るか =="
	dev_curl -sS -o /dev/null --max-time 8 "https://$target/" >/dev/null 2>&1
	case $? in
	0) ng "許可していないドメインへの接続が成立してしまった" ;;
	2) skip "$target" "dev で curl を実行できなかった。proxy が拒否したのか道具が無いのか区別できない" ;;
	*) ok "許可していないドメインへの接続は失敗する" ;;
	esac
	if proxy_log_has "$target"; then
		ok "proxyのログに拒否したドメイン名が残る"
	else
		ng "proxyのログに $target が見つからない"
	fi
}

check_manager_denied() {
	echo "== allowed なホストでも /squid-internal-mgr/ 経由で cache manager に触れないか =="
	local code rc
	code="$(dev_curl -sS -o /dev/null -w '%{http_code}' --max-time 8 -x http://egress-proxy:3128 'http://nodejs.org/squid-internal-mgr/info' 2>/dev/null)"
	rc=$?
	if [ "$rc" -eq 2 ]; then
		skip "manager" "dev で curl を実行できなかった"
	elif [ "$code" = "403" ]; then
		ok "allowed host 経由でも /squid-internal-mgr/ は403で拒否される"
	else
		ng "期待した403ではなく http_code=$code だった (手動確認を推奨)"
	fi
}

check_proxy_stop_breaks_egress() {
	echo "== proxy を止めると proxy 経由の経路が失われるか =="
	dev_curl -sS -o /dev/null --max-time 10 https://nodejs.org/ >/dev/null 2>&1
	local before=$?
	if [ "$before" -eq 2 ]; then
		skip "proxy停止" "dev で curl を実行できなかった"
		return
	fi
	if [ "$before" -ne 0 ]; then
		skip "proxy停止" "proxy を止める前から nodejs.org へ到達できていない。停止後に失敗しても proxy を止めたためとは言えない"
		return
	fi
	dc stop egress-proxy >/dev/null
	dev_curl -sS -o /dev/null --max-time 6 https://nodejs.org/ >/dev/null 2>&1
	case $? in
	0) ng "proxy停止後もnodejs.orgへ到達できてしまった" ;;
	2) skip "proxy停止" "dev で curl を実行できなかった" ;;
	*) ok "停止前は到達でき、proxy停止後は経路が失われる" ;;
	esac
	dc start egress-proxy >/dev/null
	sleep 2
}

check_acl_absent_in_dev() {
	# squid.conf 自体は探さない。egress-guard の package.json の files は
	# templates を含み、runtime-base はグローバル install を消さないため、dev には
	# $(npm root -g) 配下に templates/proxy/squid.conf (雛形そのもの) が存在
	# しうる。この雛形の ACL は allowed-domains.txt という別ファイルへの参照で
	# しかなく、そのファイル自体は proxy イメージのビルド時にしか作られない
	# (templates/proxy/Dockerfile の acl ステージ) ので、dev には無い。ここで
	# 確認したいのは、その生成物 (allowed-domains.txt) が dev から見えないこと。
	echo "== dev (エージェントのコンテナ) のファイルシステムに ACL (allowed-domains.txt) が無いか =="
	if dc exec -T dev sh -c \
		"find / -xdev -iname 'allowed-domains.txt' 2>/dev/null | grep -q ."; then
		ng "dev のファイルシステムから allowed-domains.txt が見つかった"
	else
		ok "dev のファイルシステムに allowed-domains.txt は存在しない"
	fi
}

check_direct_bypass_blocked() {
	# この束が成立しているかどうかを最終的に決める項目。proxy 環境変数を
	# 無視して直接つなごうとしても、縮小した最終テーブルが落とす
	# (L7 と L3 を組み合わせた状態でだけ成立する)。
	echo "== proxy を無視した直接接続が塞がれるか (L7+L3 の組み合わせでのみ成立) =="
	local out rc
	out="$(dc exec -T dev sh -c \
		'env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY curl -sS -o /dev/null --max-time 5 https://1.1.1.1/' 2>&1)"
	rc=$?
	# dev_curl と同じ判定不能の検出。ここは dc exec を自前で呼んでいるので
	# dev_curl を経由せず、同じ grep を独立に掛ける。無いと dev コンテナが
	# 落ちている・exec が拒否された場合の rc=1 が「直接接続は失われる」の
	# ok に混ざる — この項目は束の成否を決めるので、道具が無くて落ちたのか
	# proxy を回避できなかったのかを混ぜてはいけない。
	if printf '%s\n' "$out" | grep -qE 'executable file not found|OCI runtime exec failed|is not running'; then
		skip "直接接続" "dev で curl を実行できなかった"
		return
	fi
	case "$rc" in
	126 | 127) skip "直接接続" "dev で curl を実行できなかった" ;;
	0) ng "proxy を無視した直接接続が成立してしまった" ;;
	*) ok "proxy を無視した直接接続は失われる ($out)" ;;
	esac
}

check_acl_needs_rebuild() {
	# firewall.json を変更 -> 再ビルドすれば ACL が変わること (前半) と、
	# 今動いている egress-proxy にはそれを待たずに反映される経路が無いこと
	# (後半) の2つを見る。後半は tmp_ctx 側では確認できない — あのイメージは
	# 現行の egress-proxy から一度も読まれないため、コンテナ自体を調べる。
	echo "== firewall.json の変更にイメージの再ビルドが要るか =="
	local marker="rebuild-marker-test.invalid"
	local tmp_ctx
	tmp_ctx="$(mktemp -d)"
	trap 'rm -rf "$tmp_ctx"' RETURN

	if ! command -v jq >/dev/null 2>&1; then
		skip "ACL再ビルド" "jq が無く、変更後の firewall.json を組み立てられない"
		return
	fi

	jq --arg d ".$marker" '.allowDomains += [$d]' \
		"$REPO_ROOT/.devcontainer/firewall.json" >"$tmp_ctx/firewall.json"
	mkdir "$tmp_ctx/proxy"
	cp "$PROXY_TEMPLATE_DIR/squid.conf" "$tmp_ctx/proxy/squid.conf"

	local image="egress-guard-verify-l7-rebuild-check"
	local build_out
	if ! build_out="$(docker build -q -f "$PROXY_TEMPLATE_DIR/Dockerfile" -t "$image" "$tmp_ctx" 2>&1)"; then
		ng "変更後の firewall.json でのビルドが失敗した"
		echo "$build_out" >&2
		return
	fi

	local acl_after
	acl_after="$(docker run --rm --entrypoint cat "$image" /etc/squid/allowed-domains.txt 2>/dev/null)"
	if printf '%s\n' "$acl_after" | grep -q "$marker"; then
		ok "再ビルドすれば新しい allowDomains がイメージに焼き込まれる"
	else
		ng "再ビルドしても $marker が ACL に現れなかった"
	fi

	docker rmi "$image" >/dev/null 2>&1 || true

	local running_id
	running_id="$(dc ps -q egress-proxy 2>/dev/null)"
	if [ -z "$running_id" ]; then
		skip "ACL差し替え経路" "egress-proxy のコンテナIDを取得できなかった"
		return
	fi

	local mounts
	mounts="$(docker inspect --format '{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}' "$running_id" 2>/dev/null)"
	if printf '%s\n' "$mounts" | grep -q '^/etc/squid'; then
		ng "egress-proxy に /etc/squid 配下を指す mount がある（ACLを外から差し替える経路になりうる）"
	else
		ok "egress-proxy に /etc/squid 配下を指す mount は無い（ACLはイメージに焼き込まれたものだけ）"
	fi

	if dc exec -T egress-proxy sh -c 'echo x >> /etc/squid/allowed-domains.txt' >/dev/null 2>&1; then
		ng "実行中の egress-proxy の ACL ファイルへ書き込めてしまった (read_only が効いていない)"
	else
		ok "実行中の egress-proxy の ACL ファイルへは書き込めない (read_only)"
	fi
}

check_config_fail_closed() {
	echo "== 設定が壊れていると fail-closed で起動しないか =="
	local broken
	broken="$(mktemp)"
	{
		cat "$PROXY_TEMPLATE_DIR/squid.conf"
		echo "this_is_not_a_valid_squid_directive"
	} >"$broken"
	local out
	if out="$(dc run --rm -v "$broken:/etc/squid/squid.conf:ro" egress-proxy 2>&1)"; then
		ng "壊れた設定でも squid が起動してしまった"
		echo "$out" >&2
	else
		ok "壊れた設定では squid が起動せず、非0で終了した"
	fi
	rm -f "$broken"
}

# dev の default network 上に、dev とは別の使い捨てコンテナを立てて curl を
# 実行する。dev 自身は最終テーブルで縛られているため、dev から出すと
# egress-proxy 以外への接続を試す判定 (PTR 偽装など) が dev の firewall に
# 先に落とされてしまう。同じネットワーク上の別コンテナは dev の iptables の
# 対象ではない。戻り値の意味は dev_curl と同じ (2 = 判定不能)。
probe_curl() {
	local dev_id image
	dev_id="$(dc ps -q dev 2>/dev/null)"
	if [ -z "$dev_id" ]; then
		return 2
	fi
	image="$(docker inspect --format '{{.Config.Image}}' "$dev_id" 2>/dev/null)"
	if [ -z "$image" ]; then
		return 2
	fi
	local out rc
	out="$(docker run --rm --network "${PROJECT}_default" "$image" curl "$@" 2>&1)"
	rc=$?
	case "$rc" in
	125 | 126 | 127) return 2 ;;
	esac
	printf '%s' "$out"
	return "$rc"
}

check_ptr_spoof() {
	# design.md §2.23 必須要件2 (名前ベースACLにIPリテラルを持ち込ませない)。
	# egress-proxy と同じ Dockerfile / squid.conf / firewall.json から、DNS の
	# 向き先だけ ptr-spoof-harness にした egress-proxy-v6 を、この検証のためだけの
	# overlay で追加する。詳しい構成は
	# packages/egress-guard/poc/l7-proxy/docker-compose.poc.yml の同名サービスと
	# その README を参照 (private レンジだと `deny to_private` が dstdomain の
	# 判定より先に効いてしまい偽陽性になるため TEST-NET-3 を使う)。
	echo "== dstdomain -n が PTR 偽装を防いでいるか (design.md §2.23 必須要件 2) =="

	if [ ! -f "$PTR_HARNESS_SCRIPT" ]; then
		skip "PTR偽装" "ptr-spoof-harness.py が見つからない"
		return
	fi

	local harness_ip="203.0.113.53"
	local overlay
	overlay="$(mktemp)"
	trap 'rm -f "$overlay"' RETURN
	cat >"$overlay" <<EOF
services:
  egress-proxy-v6:
    build:
      context: $REPO_ROOT/.devcontainer
      dockerfile: proxy/Dockerfile
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    user: "13:13"
    read_only: true
    tmpfs:
      - /var/spool/squid:uid=13,gid=13
      - /var/log/squid:uid=13,gid=13
      - /run:uid=13,gid=13
    dns:
      - $harness_ip
    depends_on:
      - ptr-spoof-harness
    networks:
      default: {}
      v6-test-net: {}
  ptr-spoof-harness:
    image: python:3-alpine
    environment:
      PTR_FAKE_NAME: "nodejs.org"
    volumes:
      - $PTR_HARNESS_SCRIPT:/harness.py:ro
    command: ["python3", "/harness.py"]
    networks:
      v6-test-net:
        ipv4_address: $harness_ip
networks:
  v6-test-net:
    ipam:
      config:
        - subnet: 203.0.113.0/24
EOF

	dcv6() {
		docker compose -f "$COMPOSE_FILE" -f "$ISOLATION_OVERLAY" -f "$overlay" -p "$PROJECT" "$@"
	}

	if ! dcv6 up -d --build egress-proxy-v6 ptr-spoof-harness; then
		ng "PTR偽装検証用のサービスを起動できなかった"
		dcv6 logs --no-log-prefix egress-proxy-v6 ptr-spoof-harness >&2 2>&1 || true
	else
		# egress-proxy-v6 は dev の最終テーブルの許可先 (egress-proxy 自身) では
		# ないので dev_curl は使えない (probe_curl 参照)。
		probe_curl -sS -o /dev/null --max-time 8 -x "http://egress-proxy-v6:3128" "https://$harness_ip/" >/dev/null 2>&1
		local rc=$?
		if [ "$rc" -eq 2 ]; then
			skip "PTR偽装" "default network 上の使い捨てコンテナで curl を実行できなかった"
		elif ! dcv6 exec -T egress-proxy-v6 sh -c "cat /var/log/squid/access.log 2>/dev/null" | grep -q "$harness_ip"; then
			# poc/l7-proxy/verify.sh の V6 と同じ前提条件: リクエストが proxy
			# まで届いたことを先に確かめる。届いていなければ「victim へ接続
			# しなかった」のが -n の効果なのか、そもそも egress-proxy-v6 に
			# 到達しなかっただけなのか区別できない。
			skip "PTR偽装" "egress-proxy-v6 のログに $harness_ip 宛のリクエストが無い。proxy まで届いていないため -n の効果を判定できない"
		else
			sleep 1
			if dcv6 logs --no-log-prefix ptr-spoof-harness 2>&1 | grep -q 'SPOOF SUCCEEDED'; then
				ng "PTR偽装が成立し、harnessへの接続が実際に発生した (-n が効いていない)"
			else
				ok "リクエストは proxy に届いたが、harness (victim) への接続は発生しなかった"
			fi
			if dcv6 exec -T egress-proxy-v6 sh -c "cat /var/log/squid/access.log 2>/dev/null" | grep -qE "TCP_DENIED.*CONNECT $harness_ip"; then
				ok "squidのアクセスログにも該当IPへのdenyが残っている"
			else
				skip "squidアクセスログでのdeny行の確認" "logformatの都合で文字列一致しない場合がある"
			fi
		fi
	fi

	dcv6 rm -sf egress-proxy-v6 ptr-spoof-harness >/dev/null 2>&1 || true
	docker network rm "${PROJECT}_v6-test-net" >/dev/null 2>&1 || true
}

main() {
	require_docker

	# 前回が KEEP_UP=1 で終わっていたら、karakuri-verify-l7-proxy-log 等の
	# 分離済み named volume が残ったままここに来る。上書き起動しても
	# egress-proxy の /var/log/squid は volume の中身をそのまま引き継ぐため、
	# 残った access.log に proxy_log_has が今回分と前回分の両方の行を見て
	# しまう (偽陽性)。ISOLATION_OVERLAY はまだ生きているので、ここで消しても
	# 触るのは分離済みの名前だけ — 開発者の実データには届かない。
	dc down -v >/dev/null 2>&1 || true

	echo "== ビルド & 起動 =="
	if ! dc up -d --build; then
		echo "起動に失敗した。'docker compose -f $COMPOSE_FILE -p $PROJECT up --build' を直接実行してログを見ること。" >&2
		exit 1
	fi

	if ! wait_for_stack; then
		if [ "$KEEP_UP" = "1" ]; then
			echo "KEEP_UP=1 のためスタックを残す。" >&2
		else
			dc down -v >/dev/null 2>&1 || true
		fi
		exit 1
	fi

	if ! apply_firewall; then
		if [ "$KEEP_UP" = "1" ]; then
			echo "KEEP_UP=1 のためスタックを残す。" >&2
		else
			dc down -v >/dev/null 2>&1 || true
		fi
		exit 1
	fi

	check_apt_first_pass
	check_apt_second_pass
	check_leading_dot_domains
	check_denied_domain
	check_ptr_spoof
	check_manager_denied
	check_direct_bypass_blocked
	check_proxy_stop_breaks_egress
	check_acl_absent_in_dev
	check_acl_needs_rebuild
	check_config_fail_closed

	# -v を付ける。karakuri-verify-l7-proxy-log は volume 名を分離済みなので
	# (上の ISOLATION_OVERLAY) 開発者の実データは消さないが、残したままだと
	# 次回実行時に前回の access.log を egress-proxy が引き継ぎ、
	# proxy_log_has が今回 curl していない行を拾って偽陽性の ok を出す
	# (判定できなかった項目を成功として数えないため、分離した volume は
	# 前回の記録ごと消す)。
	if [ "$KEEP_UP" != "1" ]; then
		echo "== 後片付け =="
		dc down -v >/dev/null 2>&1 || true
	else
		# ISOLATION_OVERLAY はこの時点で (EXIT trap により) 消えている。それを
		# 欠いたまま -v を案内すると、down -v は分離前の named volume 名
		# (karakuri-claude-config 等、compose ファイル自身が name: で固定して
		# いるもの) を消しにいく — 開発者の実データを壊しかねない。volume も
		# 含めて畳みたいなら KEEP_UP を外して再実行するよう案内する。
		echo "KEEP_UP=1 のためスタックを残す。片付けは 'docker compose -f $COMPOSE_FILE -p $PROJECT down' で（named volume は消えない。volume ごと畳むなら KEEP_UP を外して再実行すること）。"
	fi

	echo
	echo "== 結果 =="
	printf 'PASS=%d FAIL=%d SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"

	[ "$FAIL" -eq 0 ]
}

main "$@"
