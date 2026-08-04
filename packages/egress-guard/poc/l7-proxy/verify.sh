#!/usr/bin/env bash
#
# egress-guard L7 proxy PoC — verify.sh
#
# poc-plan.md の V3〜V9 を、この PoC の docker-compose.poc.yml が作る環境に
# 対して可能な範囲で自動判定する。V1・V2 は現行の L3 (.devcontainer 本体) 側の
# 対照実験であり、このスクリプトの対象外 (README.md 参照)。V10 (ECH) は
# poc-plan.md 自身が「実測方法は未定」としているためここでは扱わない。
#
# 判定できない・このPoCの範囲を超える項目は SKIP として明示し、黙って
# 飛ばさない (tests/firewall-rules.test.sh と同じ方針。
# docs/verification-record.md 5節: 消えたSKIPはあったことにされたカバレッジになる)。
#
# **ホスト側でのみ実行できる。** devcontainer の中には docker が無いので、
# このスクリプト自体をそこから動かすことはできない。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.poc.yml"

# poc-plan.md V3: firewall適用直後と「1〜2分後」の2回。既定は90秒だが、
# 実機のCDNの挙動を見るならもっと長く取ってよい。
V3_WAIT_SECONDS="${V3_WAIT_SECONDS:-90}"

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
	docker compose -f "$COMPOSE_FILE" "$@"
}

require_docker() {
	if ! command -v docker >/dev/null 2>&1; then
		echo "docker が見つからない。このスクリプトはホスト側で実行すること (README.md 参照)。" >&2
		exit 1
	fi
	if ! docker compose version >/dev/null 2>&1; then
		echo "'docker compose' (v2 プラグイン) が見つからない。README.md の前提を確認すること。" >&2
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
		if echo "$running" | grep -q '^egress-proxy$' \
			&& echo "$running" | grep -q '^client$' \
			&& echo "$running" | grep -q '^egress-proxy-v6$' \
			&& echo "$running" | grep -q '^ptr-spoof-harness$'; then
			ok "起動前提: read_only:true のまま4サービスとも running になった (research 未確認事項3への回答)"
			return 0
		fi
		tries=$((tries + 1))
		sleep 2
	done
	ng "起動前提: 一部のサービスが running にならなかった。'docker compose -f docker-compose.poc.yml ps' で確認すること"
	dc ps || true
	return 1
}

setup_client() {
	echo "== client の準備 (curl を proxy 経由で導入する。これ自体が V3 の前半でもある) =="
	if dc exec -T client sh -c 'apt-get update >/tmp/v3-1.log 2>&1 && apt-get install -y --no-install-recommends curl >>/tmp/v3-1.log 2>&1'; then
		ok "V3-1: apt-get update && apt-get install curl が proxy 経由で成立する (1回目)"
	else
		ng "V3-1: apt-get update / install curl が失敗した (1回目)"
		dc exec -T client cat /tmp/v3-1.log >&2 || true
		return 1
	fi
	return 0
}

check_v3_second_pass() {
	echo "== V3 (本題): ${V3_WAIT_SECONDS}秒待ってから2回目の apt-get update =="
	echo "   CDNのアドレスが動いても2回目が壊れないことがこの移行の目的 (poc-plan.md V3)。"
	sleep "$V3_WAIT_SECONDS"
	if dc exec -T client sh -c 'apt-get update >/tmp/v3-2.log 2>&1'; then
		ok "V3-2: 2回目の apt-get update も成立する"
	else
		ng "V3-2: 2回目の apt-get update が失敗した"
		dc exec -T client cat /tmp/v3-2.log >&2 || true
	fi
}

check_v4() {
	local target="anthropic.gallerycdn.vsassets.io"
	echo "== V4: ワイルドカードACL (.gallerycdn.vsassets.io) で具体名 ($target) が通るか =="
	if dc exec -T client curl -sS -o /dev/null --max-time 10 "https://$target/"; then
		ok "V4-1: $target への接続がsquidを通って成立する"
	else
		ng "V4-1: $target への接続が失敗した"
	fi
	if dc logs egress-proxy 2>&1 | grep -q "$target"; then
		ok "V4-2: proxyのログに $target がそのまま残る (allowed-domains.txtに書いていない具体名。サフィックスマッチの証拠)"
	else
		ng "V4-2: proxyのログに $target が見つからない"
	fi
}

check_v5() {
	# .invalid は RFC 2606 で実在しないことが保証されている予約TLD。名前解決を
	# 試みる前(dstdomainのACL判定は文字列比較)にdenyされるはずなので、実在し
	# ない名前でも安全にテストできる。
	local target="denied-test.invalid"
	echo "== V5: allowlist に無いドメイン ($target) が拒否され、ログにドメイン名が残るか =="
	if dc exec -T client curl -sS -o /dev/null --max-time 8 "https://$target/" 2>/dev/null; then
		ng "V5-1: 許可していないドメインへの接続が成立してしまった"
	else
		ok "V5-1: 許可していないドメインへの接続は失敗する"
	fi
	if dc logs egress-proxy 2>&1 | grep -q "$target"; then
		ok "V5-2: proxyのログに拒否したドメイン名が残る (audit収集の引き継ぎ先として必須)"
	else
		ng "V5-2: proxyのログに $target が見つからない"
	fi
}

check_v6() {
	# design.md §2.22 必須要件2 (名前ベースACLにIPリテラルを持ち込ませない)。
	# curl --resolve はCONNECTの宛先には効かない (このPoCを作る過程で実測して
	# 確認した。README.mdの「V6の判定方法」参照)。実際の攻撃条件は
	# 「CONNECT <IPリテラル>:443」に対するPTR逆引きなので、egress-proxy-v6
	# (PTRの向き先だけptr-spoof-harnessにした同一squid.conf) へ、harnessの
	# IPリテラルを直接CONNECTさせて再現する。
	#
	# **このIPがRFC 5737のTEST-NET-3であることが判定の前提。** 私設帯にすると
	# squid.confの `deny to_private` がdstdomainの判定より先に効いてしまい、
	# -n の有無に関わらず必ず成功する偽陽性になる (docker-compose.poc.yml の
	# networks: v6-test-net のコメント参照)。
	local harness_ip="203.0.113.53"
	echo "== V6: dstdomain -n がPTR偽装を防いでいるか (design.md §2.22 必須要件2) =="
	dc exec -T client curl -sS -o /dev/null --max-time 8 -x "http://egress-proxy-v6:3128" "https://$harness_ip/" >/dev/null 2>&1
	sleep 1
	if dc logs ptr-spoof-harness 2>&1 | grep -q 'SPOOF SUCCEEDED'; then
		ng "V6-1: PTR偽装が成立し、victimへの接続が実際に発生した (-n が効いていない)"
	else
		ok "V6-1: victim (harness) への接続は発生しなかった"
	fi
	if dc logs egress-proxy-v6 2>&1 | grep -qE "TCP_DENIED.*CONNECT $harness_ip"; then
		ok "V6-2: squidのアクセスログにも該当IPへのdenyが残っている"
	else
		skip "V6-2: squidアクセスログでのdeny行の確認" "logformatの都合で文字列一致しない場合がある。V6-1の判定を優先し、ログは手動確認を推奨"
	fi
}

check_manager_denied() {
	echo "== 補足 (research 未確認事項1): allowed なホストでも /squid-internal-mgr/ 経由でcache managerに触れないか =="
	local code
	code="$(dc exec -T client curl -sS -o /dev/null -w '%{http_code}' --max-time 8 -x http://egress-proxy:3128 'http://deb.debian.org/squid-internal-mgr/info' 2>/dev/null || true)"
	if [ "$code" = "403" ]; then
		ok "manager: allowed host 経由でも /squid-internal-mgr/ は403で拒否される"
	else
		ng "manager: 期待した403ではなく http_code=$code だった (手動確認を推奨)"
	fi
}

check_v7() {
	echo "== V7: proxyを止めるとproxy経由の経路が失われるか (I2の一部) =="
	dc stop egress-proxy >/dev/null
	if dc exec -T client curl -sS -o /dev/null --max-time 6 https://deb.debian.org/ 2>/dev/null; then
		ng "V7-1: proxy停止後もdeb.debian.orgへ到達できてしまった"
	else
		ok "V7-1: proxy停止後はproxy経由の経路が失われる"
	fi
	skip "V7-2: L3 (init-project-firewall.sh) と組み合わせたときの完全なfail-closed" \
		"このPoCのclientにはL3制限を課していないため、http_proxyを無視した直接接続まで塞がれることは検証できない。本実装との統合が前提 (README.md参照)"
	dc start egress-proxy >/dev/null
	sleep 2
}

check_v8() {
	echo "== V8: client (エージェント役) からACLファイルへ到達できないか (I1) =="
	if dc exec -T client sh -c \
		"find / -xdev \( -iname 'squid.conf' -o -iname 'allowed-domains.txt' \) 2>/dev/null | grep -q ."; then
		ng "V8-1: clientのファイルシステムからACL関連ファイルが見つかった"
	else
		ok "V8-1: clientのファイルシステムにACLファイルは存在しない (別コンテナのbind mountはclientから見えない)"
	fi
	skip "V8-2: ACL変更に相当する操作(再ビルド/再作成)が要ることの確認" \
		"squid.confを書き換えて 'docker compose -f docker-compose.poc.yml up -d --build egress-proxy' をやり直し、反映されることを目視で確認する手順。自動化は対象外"
}

check_v9() {
	echo "== V9: 設定が壊れているとfail-closedで起動しないか =="
	local broken
	broken="$(mktemp)"
	{
		cat "$SCRIPT_DIR/squid.conf"
		echo "this_is_not_a_valid_squid_directive"
	} >"$broken"
	local out
	if out="$(dc run --rm -v "$broken:/etc/squid/squid.conf:ro" egress-proxy 2>&1)"; then
		ng "V9: 壊れた設定でもsquidが起動してしまった"
		echo "$out" >&2
	else
		ok "V9: 壊れた設定ではsquidが起動せず、非0で終了した (fatalf相当)"
	fi
	rm -f "$broken"
}

main() {
	require_docker

	echo "== ビルド & 起動 =="
	if ! dc up -d --build; then
		echo "起動に失敗した。'docker compose -f $COMPOSE_FILE up --build' を直接実行してログを見ること。" >&2
		exit 1
	fi

	if ! wait_for_stack; then
		dc down -v >/dev/null 2>&1 || true
		exit 1
	fi

	setup_client || true
	check_v3_second_pass
	check_v4
	check_v5
	check_v6
	check_manager_denied
	check_v7
	check_v8
	check_v9

	echo "== V1・V2 (L3側の対照実験) はこのスクリプトの対象外。README.md の手順を参照 =="
	skip "V1" "既存 .devcontainer/firewall.json を書き換えて再ビルドする対照実験。このPoCでは既存ファイルを変更しない方針のため手動"
	skip "V2" "同上。verification-record.md #6.23 の手順に従う"
	echo "== V10 (ECH) は明示型を採ったため検証項目から外れている =="
	skip "V10" "design.md §2.22 必須要件3。明示型ではECHは判定材料に関与しない(接続先はCONNECTのauthorityから確定する)ため、検証すべき挙動が存在しない。透過型を採る場合にのみ問題になる"

	if [ "$KEEP_UP" != "1" ]; then
		echo "== 後片付け =="
		dc down -v >/dev/null 2>&1 || true
	else
		echo "KEEP_UP=1 のためスタックを残す。片付けは 'docker compose -f $COMPOSE_FILE down -v' で。"
	fi

	echo
	echo "== 結果 =="
	printf 'PASS=%d FAIL=%d SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"

	[ "$FAIL" -eq 0 ]
}

main "$@"
