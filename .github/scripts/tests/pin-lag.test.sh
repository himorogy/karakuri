#!/usr/bin/env bash
#
# .github/scripts/pin-lag.sh の判定をネットワークなしで検証する。上流の版・
# advisory の照会結果・schedule.json はすべて呼び出し時の引数として与え、
# 本物の npm / gh api / nodejs.org へは一切出ない。
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PIN_LAG="$SCRIPT_DIR/pin-lag.sh"

PASS=0
FAIL=0

ok() {
	PASS=$((PASS + 1))
	printf '  ok   %s\n' "$1"
}

ng() {
	FAIL=$((FAIL + 1))
	printf '  FAIL %s\n' "$1" >&2
}

# --- lag ------------------------------------------------------------------

echo "lag"

out="$("$PIN_LAG" lag 11.20.0 11.25.0)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "minor 5" ]; then
	ok "pnpm 相当の遅れ (11.20.0 -> 11.25.0) は minor 5"
else
	ng "pnpm 相当の遅れ (11.20.0 -> 11.25.0) は minor 5 (rc=$rc out=$out)"
fi

out="$("$PIN_LAG" lag 2.19.2 2.23.0)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "minor 4" ]; then
	ok "dotenvx 相当の遅れ (2.19.2 -> 2.23.0) は minor 4"
else
	ng "dotenvx 相当の遅れ (2.19.2 -> 2.23.0) は minor 4 (rc=$rc out=$out)"
fi

out="$("$PIN_LAG" lag 1.2.0 1.2.3)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "patch 3" ]; then
	ok "patch のみの遅れは patch 3"
else
	ng "patch のみの遅れは patch 3 (rc=$rc out=$out)"
fi

out="$("$PIN_LAG" lag 1.4.0 2.0.0)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "major 1" ]; then
	ok "major の遅れは major 1"
else
	ng "major の遅れは major 1 (rc=$rc out=$out)"
fi

out="$("$PIN_LAG" lag 1.2.3 1.2.3)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "none" ]; then
	ok "固定値と上流の最新が同一のとき none"
else
	ng "固定値と上流の最新が同一のとき none (rc=$rc out=$out)"
fi

out="$("$PIN_LAG" lag v0.19.1 0.19.1)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "none" ]; then
	ok "v0.19.1 と 0.19.1 は同一の版として扱われる"
else
	ng "v0.19.1 と 0.19.1 は同一の版として扱われる (rc=$rc out=$out)"
fi

out="$("$PIN_LAG" lag 0.18.0 v0.19.1)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "minor 1" ]; then
	ok "crit 相当の遅れ (0.18.0 -> v0.19.1) は v の有無を無視して minor 1"
else
	ng "crit 相当の遅れ (0.18.0 -> v0.19.1) は v の有無を無視して minor 1 (rc=$rc out=$out)"
fi

# major.minor.patch の3桁は一致するが文字列としては異なる版
# （プレリリース識別子違い等）は、patch 0（0版遅れに読める）ではなく
# 種別不明を示す differs を返す。
out="$("$PIN_LAG" lag 1.2.3-alpha 1.2.3-beta)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "differs 0" ]; then
	ok "3桁一致・文字列不一致は differs 0（patch 0 には丸めない）"
else
	ng "3桁一致・文字列不一致は differs 0（patch 0 には丸めない） (rc=$rc out=$out)"
fi

# 否定対照: 上流の版を取得できないとき、none を返して黙るのではなく
# 取得できない旨を返す。
out="$("$PIN_LAG" lag 1.2.3 "")"
rc=$?
if [ "$rc" -ne 0 ] && [ "$out" = "latest-unavailable" ] && [ "$out" != "none" ]; then
	ok "否定対照: 上流の版が取得できないとき none ではなく latest-unavailable を返す"
else
	ng "否定対照: 上流の版が取得できないとき none ではなく latest-unavailable を返す (rc=$rc out=$out)"
fi

# 否定対照: 固定値を読み出せないとき（ARG の行が消えた・名前が変わった場合を
# 含む）読めない旨を返す。
out="$("$PIN_LAG" lag "" 1.2.3)"
rc=$?
if [ "$rc" -ne 0 ] && [ "$out" = "pinned-unreadable" ]; then
	ok "否定対照: 固定値を読み出せないとき pinned-unreadable を返す"
else
	ng "否定対照: 固定値を読み出せないとき pinned-unreadable を返す (rc=$rc out=$out)"
fi

# --- advisory ---------------------------------------------------------------

echo "advisory"

out="$("$PIN_LAG" advisory no 0 "")"
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "not-checked" ]; then
	ok "照会に乗らない対象（node / crit / golang builder）は not-checked"
else
	ng "照会に乗らない対象は not-checked (rc=$rc out=$out)"
fi

# 照会に乗らない対象は、遅れの有無にかかわらず not-checked が付く
# （advisory は lag を引数に取らないので、これは呼び出し方そのものが担保する）。
out="$("$PIN_LAG" advisory no 0 '[{"ghsa_id":"irrelevant"}]')"
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "not-checked" ]; then
	ok "not-checked は照会結果の中身に関わらず一定"
else
	ng "not-checked は照会結果の中身に関わらず一定 (rc=$rc out=$out)"
fi

out="$("$PIN_LAG" advisory yes 0 "[]")"
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "checked-none" ]; then
	ok "照会して該当なしのとき checked-none"
else
	ng "照会して該当なしのとき checked-none (rc=$rc out=$out)"
fi

out="$("$PIN_LAG" advisory yes 0 '[{"ghsa_id":"GHSA-xxxx"}]')"
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "checked-alert" ]; then
	ok "固定値が advisory の影響範囲に入るとき checked-alert"
else
	ng "固定値が advisory の影響範囲に入るとき checked-alert (rc=$rc out=$out)"
fi

# 否定対照: 照会に失敗したとき、該当なしとして checked-none 側へ通らず、
# 照会できなかった旨（check-failed）を返す。
out="$("$PIN_LAG" advisory yes 1 "")"
rc=$?
if [ "$rc" -ne 0 ] && [ "$out" = "check-failed" ] && [ "$out" != "checked-none" ]; then
	ok "否定対照: advisory 照会の失敗は checked-none に化けず check-failed を返す"
else
	ng "否定対照: advisory 照会の失敗は checked-none に化けず check-failed を返す (rc=$rc out=$out)"
fi

# 照会コマンド自体は成功終了したが、応答が壊れている場合も check-failed。
out="$("$PIN_LAG" advisory yes 0 "not-json")"
rc=$?
if [ "$rc" -ne 0 ] && [ "$out" = "check-failed" ]; then
	ok "応答が JSON 配列でないときも check-failed"
else
	ng "応答が JSON 配列でないときも check-failed (rc=$rc out=$out)"
fi

# 否定対照: 照会して該当なしだった対象・照会に乗らない対象・照会に失敗した
# 対象は、いずれも同じ値では返らない。
not_checked="$("$PIN_LAG" advisory no 0 "")"
checked_none="$("$PIN_LAG" advisory yes 0 "[]")"
check_failed="$("$PIN_LAG" advisory yes 1 "" 2>/dev/null || true)"
checked_alert="$("$PIN_LAG" advisory yes 0 '[{"ghsa_id":"g"}]')"
if [ "$not_checked" != "$checked_none" ] &&
	[ "$not_checked" != "$check_failed" ] &&
	[ "$checked_none" != "$check_failed" ] &&
	[ "$checked_alert" != "$checked_none" ] &&
	[ "$checked_alert" != "$not_checked" ] &&
	[ "$checked_alert" != "$check_failed" ]; then
	ok "否定対照: not-checked / checked-none / check-failed / checked-alert は互いに異なる値"
else
	ng "否定対照: not-checked / checked-none / check-failed / checked-alert は互いに異なる値 (not_checked=$not_checked checked_none=$checked_none check_failed=$check_failed checked_alert=$checked_alert)"
fi

# 不変性: 想定していない余分な引数（node の残り日数のような、advisory が
# 本来受け取らない値）を渡しても not-checked / checked-none / checked-alert
# は値だけでなく終了コード（いずれも 0）も変わらない。値は同じだが rc だけ
# 変える変異（例: 余分な引数を受けて中身は checked-alert のまま return 1 する）
# は文字列比較だけでは捕まらないため、rc も併せて見る。
advisory_extra_ok=1
for extra in "" 0 1 46 9999; do
	out="$("$PIN_LAG" advisory no 0 "" "$extra")"; rc=$?
	[ "$out" = "not-checked" ] && [ "$rc" -eq 0 ] || advisory_extra_ok=0

	out="$("$PIN_LAG" advisory yes 0 "[]" "$extra")"; rc=$?
	[ "$out" = "checked-none" ] && [ "$rc" -eq 0 ] || advisory_extra_ok=0

	out="$("$PIN_LAG" advisory yes 0 '[{"ghsa_id":"g"}]' "$extra")"; rc=$?
	[ "$out" = "checked-alert" ] && [ "$rc" -eq 0 ] || advisory_extra_ok=0
done
if [ "$advisory_extra_ok" -eq 1 ]; then
	ok "advisory: 余分な引数を渡しても値と終了コードのどちらも変わらない"
else
	ng "advisory: 余分な引数を渡しても値と終了コードのどちらも変わらない"
fi

# --- node-schedule ------------------------------------------------------------

echo "node-schedule"

SCHEDULE='{"v24":{"maintenance":"2026-10-20","end":"2028-04-30"}}'

out="$("$PIN_LAG" node-schedule "$SCHEDULE" 24 2026-09-03)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "47 605" ]; then
	ok "v24 は 2026-09-03 時点で maintenance まで47日・EOLまで605日"
else
	ng "v24 は 2026-09-03 時点で maintenance まで47日・EOLまで605日 (rc=$rc out=$out)"
fi

out="$("$PIN_LAG" node-schedule "$SCHEDULE" v24 2026-09-03)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "47 605" ]; then
	ok "v 前置きを付けたバージョン指定でも同じ結果になる"
else
	ng "v 前置きを付けたバージョン指定でも同じ結果になる (rc=$rc out=$out)"
fi

out="$("$PIN_LAG" node-schedule "$SCHEDULE" 26 2026-09-03)"
rc=$?
if [ "$rc" -ne 0 ] && [ "$out" = "schedule-unavailable" ]; then
	ok "schedule.json に無い系統は schedule-unavailable"
else
	ng "schedule.json に無い系統は schedule-unavailable (rc=$rc out=$out)"
fi

# --- severity -----------------------------------------------------------------

echo "severity"

out="$("$PIN_LAG" severity "none" "checked-none")"
if [ "$out" = "info" ]; then
	ok "遅れなし + advisory 該当なし -> info"
else
	ng "遅れなし + advisory 該当なし -> info (out=$out)"
fi

# 中心の保証: major の遅れがあっても、advisory の影響を受けていなければ
# 深刻度は info に留まる。遅れの大きさや種別だけでは alert にならない。
out="$("$PIN_LAG" severity "major 5" "checked-none")"
if [ "$out" = "info" ]; then
	ok "major 5 の遅れ + advisory 該当なし -> それでも info（STATUS を上げない）"
else
	ng "major 5 の遅れ + advisory 該当なし -> それでも info（STATUS を上げない）(out=$out)"
fi

# 遅れが無くても、advisory の影響下にあれば alert になる。
out="$("$PIN_LAG" severity "none" "checked-alert")"
if [ "$out" = "alert" ]; then
	ok "遅れなし + advisory 該当あり -> alert（遅れが無くても alert になりうる）"
else
	ng "遅れなし + advisory 該当あり -> alert（遅れが無くても alert になりうる）(out=$out)"
fi

# 遅れが patch 1つでも、advisory があれば alert になる。
out="$("$PIN_LAG" severity "patch 1" "checked-alert")"
if [ "$out" = "alert" ]; then
	ok "patch 1 の遅れ + advisory 該当あり -> alert"
else
	ng "patch 1 の遅れ + advisory 該当あり -> alert (out=$out)"
fi

# 照会に乗らない対象（not-checked）では、遅れが大きくても alert にならない。
out="$("$PIN_LAG" severity "major 9" "not-checked")"
if [ "$out" = "info" ]; then
	ok "not-checked の対象は遅れが大きくても info に留まる"
else
	ng "not-checked の対象は遅れが大きくても info に留まる (out=$out)"
fi

# 深刻度は alert / info の2値のみであることの直接の確認。
seen_values=""
for lag in "none" "major 9" "patch 1"; do
	for adv in "not-checked" "checked-none" "checked-alert"; do
		v="$("$PIN_LAG" severity "$lag" "$adv")"
		case "$v" in
			alert | info) : ;;
			*)
				ng "severity が alert / info 以外の値を返した (lag=$lag adv=$adv v=$v)"
				;;
		esac
		seen_values="${seen_values}${v} "
	done
done
if ! printf '%s' "$seen_values" | grep -qw warn; then
	ok "severity は alert / info の2値のみを返し、warn を返さない"
else
	ng "severity は alert / info の2値のみを返し、warn を返さない (seen_values=$seen_values)"
fi

# 不変性: node の残り日数のような、severity が本来受け取らない値を追加の
# 引数として渡しても深刻度は値だけでなく終了コード（常に 0）も変わらない。
# severity が日数を引数に取らないことは署名を見れば分かるが、将来 severity
# 内で余分な引数を判定に使う変異（値は同じだが rc だけ変える形を含む）が
# 入っても、ここが赤くなって気づける形にしておく。
severity_days_ok=1
for days in 0 1 46 9999; do
	out="$("$PIN_LAG" severity "patch 1" "checked-none" "$days")"; rc=$?
	[ "$out" = info ] && [ "$rc" -eq 0 ] || severity_days_ok=0

	out="$("$PIN_LAG" severity "none" "checked-alert" "$days")"; rc=$?
	[ "$out" = alert ] && [ "$rc" -eq 0 ] || severity_days_ok=0
done
if [ "$severity_days_ok" -eq 1 ]; then
	ok "severity: 残り日数相当の追加引数を渡しても値と終了コードのどちらも変わらない"
else
	ng "severity: 残り日数相当の追加引数を渡しても値と終了コードのどちらも変わらない"
fi

# --- result --------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
