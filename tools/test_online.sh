#!/bin/bash
# Online autotest (M6): upstream's online scenarios (upstream/tools/
# online-qa.sh) on the PC null build, each against a lobby server started
# here on 127.0.0.1, with the bots it needs. Exit code is the verdict.
#
#   tools/test_online.sh                 every scenario
#   tools/test_online.sh race restart    some only
#
# Scenarios:
#   race      join a lobby, chat with the bot (the filter stars its second
#             line), race it, get a place and see its skid marks
#   custom    the same with a custom kart on both sides
#   practice  start alone, drop out, leave and rejoin, race alone until the
#             bot joins, drop out, race it, see it drop out, drop out
#   spectate  watch the server's demo lobby through a race
#   watch     watch two bots race in a lobby of our own; their skid marks
#             must show on the spectator cameras
#   reject    a server that moved on to another protocol: the game must
#             show THIS VERSION IS TOO OLD, not a lost connection
#   restart   the server restarts mid-race and repeats its race ids: the
#             game must come back through the browser into the next race
#   wiiu      the race scenario with the Wii U build in Cemu
#             (tools/cemu_run.sh); in the default list when Cemu is there
#   console   the race scenario on the Wii U itself (tools/wiiu.py run,
#             which starts it on the TV): the server listens on this PC's
#             LAN address and the build is pointed there. Never in the
#             default list.
#
# Never talks to any server but its own: the client is built with
# DK_NET_TEST_HOST=127.0.0.1 (Makefile) and test builds refuse dcvmu.com
# anyway (port/netlink_port.c). The game runs at real speed
# (DKU_REALTIME=1, port/plat_headless.c) because the server and bots keep
# wall-clock time. Needs Go (the server is upstream/server).
#
#   PORT=7536 tools/test_online.sh       another UDP port
#   TIMEOUT=360                          seconds a scenario may take
#                                        (spectate gets at least 600)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
SERVER_DIR=$ROOT/upstream/server
PORT=${PORT:-7535}
TIMEOUT=${TIMEOUT:-360}
JOBS=${JOBS:-$(nproc)}
OUT=$ROOT/build/test-online
GOBIN_DIR=$ROOT/build/go
mkdir -p "$OUT" "$GOBIN_DIR"
export GOCACHE=$ROOT/build/go/cache GOTOOLCHAIN=local

SERVER_IP=127.0.0.1
scenarios=(race custom practice spectate watch reject restart)
ls "$HOME"/Applications/Cemu-*.AppImage >/dev/null 2>&1 && scenarios+=(wiiu)
[[ $# -gt 0 ]] && scenarios=("$@")
if [[ " ${scenarios[*]} " == *" console "* ]]; then
    [[ ${#scenarios[@]} == 1 ]] || { echo "test_online: run console on its own" >&2; exit 2; }
    CONSOLE=${WIIU_IP:-$(cat .wiiu-console 2>/dev/null || true)}
    [[ -n $CONSOLE ]] || { echo "test_online: no console address (tools/wiiu.py set-ip)" >&2; exit 2; }
    # This PC's address on the console's network: the one server it may use.
    SERVER_IP=$(ip -4 route get "$CONSOLE" | sed -n 's/.* src \([0-9.]*\).*/\1/p')
    [[ -n $SERVER_IP ]] || { echo "test_online: no route to $CONSOLE" >&2; exit 2; }
fi

command -v go >/dev/null || { echo "test_online: go not found (see PORT_PLAN.md, Needs Aisling)" >&2; exit 2; }
if ss -Hlun "sport = :$PORT" 2>/dev/null | grep -q .; then
    echo "test_online: UDP $PORT is in use (another server?); set PORT" >&2
    exit 2
fi

pids=()
server_pid=""
stop_server() {
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    server_pid=""
}
stop_bots() {
    for p in ${pids[@]+"${pids[@]}"}; do
        kill "$p" 2>/dev/null || true
        wait "$p" 2>/dev/null || true
    done
    pids=()
}
client_pid=""
stop_client() {
    if [[ -n "$client_pid" ]] && kill -0 "$client_pid" 2>/dev/null; then
        kill "$client_pid" 2>/dev/null || true
        wait "$client_pid" 2>/dev/null || true
    fi
    client_pid=""
}
trap 'stop_client; stop_server; stop_bots' EXIT

echo "test_online: building the lobby server and bot"
go build -C "$SERVER_DIR" -o "$GOBIN_DIR/lobby" ./cmd/dreamkarts-lobby
go build -C "$SERVER_DIR" -o "$GOBIN_DIR/bot" ./cmd/dk-bot

start_server() {   # start_server <log> [server flags]
    local log=$1; shift
    : > "$log"
    # No word list download: the server falls back at once to a cached
    # copy, here a one-word list, plus BLORP for the chat check. (With no
    # list at all it retries for 10 s before it serves, and a restarted
    # server must answer within the game's 6 s.)
    printf 'DKUTESTWORD\n' > "$OUT/words.txt"
    "$GOBIN_DIR/lobby" -listen "$SERVER_IP:$PORT" -words-extra BLORP -words-url '' -words-cache "$OUT/words.txt" "$@" >> "$log" 2>&1 &
    server_pid=$!
    for _ in $(seq 1 50); do
        grep -q ":$PORT" "$log" 2>/dev/null && return 0
        kill -0 "$server_pid" 2>/dev/null || { echo "server died:"; cat "$log"; exit 1; } >&2
        sleep 0.2
    done
    echo "server did not start:" >&2; cat "$log" >&2; exit 1
}
bot() {   # bot <delay-seconds> [bot flags], in the background
    local delay=$1; shift
    ( sleep "$delay"; exec "$GOBIN_DIR/bot" -addr "$SERVER_IP:$PORT" "$@" ) >> "$OUT/$scenario-bot.log" 2>&1 &
    pids+=("$!")
}
start_bots() {
    [[ ${#bot_args[@]} -gt 0 ]] && bot "$bot_delay" "${bot_args[@]}"
    [[ ${#bot2_args[@]} -gt 0 ]] && bot "$bot_delay" "${bot2_args[@]}"
    return 0
}
build_client() {   # build_client <cflags>: sets bin
    local tag=online-$scenario
    if [[ $scenario == wiiu || $scenario == console ]]; then
        bin=build/wiiu-gx2-autotest-$tag/DreamKartsU.wuhb
        rm -f "$bin"
        make -s -j"$JOBS" -f Makefile.wiiu VARIANT=autotest TAG="$tag" \
            EXTRA_CFLAGS="$1 -DDK_NET_PORT=$PORT -DDK_NET_TEST_HOST=$SERVER_IP" \
            > "$OUT/$scenario-build.log" 2>&1 ||
            { cat "$OUT/$scenario-build.log"; echo "   build failed" >&2; return 1; }
        return 0
    fi
    bin=build/host-null-autotest-$tag/dreamkartsu
    rm -f "$bin"
    make -s -j"$JOBS" BACKEND=null VARIANT=autotest TAG="$tag" EXTRA_CFLAGS="$1 -DDK_NET_PORT=$PORT" \
        > "$OUT/$scenario-build.log" 2>&1 ||
        { cat "$OUT/$scenario-build.log"; echo "   build failed" >&2; return 1; }
}
run_client() {   # run_client: until PASS or FAIL; on the cue line, restart the server
    local log=$OUT/$scenario.log start cued=0 bots_cued=0 limit=$TIMEOUT save=$OUT/$scenario-save
    [[ $scenario == spectate && $limit -lt 600 ]] && limit=600
    : > "$log"
    if [[ $scenario == wiiu ]]; then
        # Cemu passes the game's sockets to the PC's, so 127.0.0.1 is here.
        tools/cemu_run.sh "$bin" "$limit" "$OUT/wiiu-cemu" 30 > /dev/null 2>&1 || true
        cp "$OUT/wiiu-cemu/log.txt" "$log" 2>/dev/null || true
        grep -aq 'DK AUTOTEST: PASS' "$log"
        return
    fi
    if [[ $scenario == console ]]; then
        python3 tools/wiiu.py run "$bin" > "$OUT/console-run.log" 2>&1 ||
            { cat "$OUT/console-run.log"; return 1; }
        timeout $((limit + 30)) python3 tools/wiiu.py log --for "$limit" --until 'DK AUTOTEST: (PASS|FAIL)' > "$log" 2>&1 || true
        echo "   the game stays open on the console: once the server stops it shows"
        echo "   LOST CONNECTION TO THE SERVER; close it from the HOME menu"
        grep -aq 'DK AUTOTEST: PASS' "$log"
        return
    fi
    rm -rf "$save" && mkdir -p "$save"
    DKU_REALTIME=1 DKU_SAVE_DIR=$save SDL_AUDIODRIVER=dummy "$bin" > "$log" 2>&1 &
    client_pid=$!
    start=$(date +%s)
    while kill -0 "$client_pid" 2>/dev/null; do
        if grep -aq 'DK AUTOTEST: PASS' "$log"; then stop_client; return 0; fi
        if grep -aq 'DK AUTOTEST: FAIL' "$log"; then stop_client; return 1; fi
        if [[ -n $cue && $cued == 0 ]] && grep -aFq -- "$cue" "$log"; then
            cued=1
            echo "   cue seen: restarting the server"
            stop_server
            start_server "$OUT/$scenario-server.log" ${server_flags[@]+"${server_flags[@]}"}
        fi
        if [[ -n $bot_cue && $bots_cued == 0 ]] && grep -aFq -- "$bot_cue" "$log"; then
            bots_cued=1
            start_bots
        fi
        if (( $(date +%s) - start > limit )); then
            echo "   timed out after $limit s"
            stop_client
            return 1
        fi
        sleep 0.5
    done
    client_pid=""
    grep -aq 'DK AUTOTEST: PASS' "$log"
}

PATHFILE=$SERVER_DIR/cmd/dk-bot/emerald-beach.path
results=()
failed=0
for scenario in "${scenarios[@]}"; do
    echo "== $scenario"
    server_flags=()
    cue=""
    bot_cue=""
    want=""
    bot_args=()
    bot2_args=()
    bot_delay=0
    case $scenario in
        race)
            cflags="-DDK_AT_ONLINE"
            bot_args=(-name AT-JOBEN -lobby 8 -start -start-delay 28s -race 69 -skid -path "$PATHFILE"
                      -chat "HELLO FROM BOT;YOU ARE A BLORPHEAD" -for 5m)
            want="[1-9][0-9]* remote skid marks" ;;
        custom)
            cflags="-DDK_AT_ONLINE -DDK_AT_CUSTOM"
            bot_args=(-name AT-JOBEN -lobby 8 -start -start-delay 28s -race 69 -skid -path "$PATHFILE"
                      -chat "HELLO FROM BOT;YOU ARE A BLORPHEAD" -colour 8 -custom 2,3,4 -for 5m)
            want="[1-9][0-9]* remote skid marks" ;;
        practice)
            cflags="-DDK_AT_ONLINE -DDK_AT_PRACTICE -DDK_AT_LOBBY=6"
            # The bot must arrive during the race after the rejoin.
            bot_args=(-name AT-JOBEN -lobby 6 -retire 6s -for 150s)
            bot_cue="(the first was race"
            bot_delay=2 ;;
        spectate)
            cflags="-DDK_AT_ONLINE -DDK_AT_SPECTATE"
            ;;   # the server races bots forever in lobby 10
        watch)
            cflags="-DDK_AT_ONLINE -DDK_AT_SPECTATE -DDK_AT_LOBBY=7"
            bot_args=(-name AT-JOBEN -lobby 7 -start -start-delay 28s -race 69 -skid -path "$PATHFILE" -for 5m)
            bot2_args=(-name AT-RICKY -lobby 7 -start -start-delay 28s -race 72 -skid -path "$PATHFILE" -for 5m)
            want="[1-9][0-9]* remote skid marks" ;;
        reject)
            cflags="-DDK_AT_ONLINE -DDK_AT_REJECT"
            server_flags=(-reject-proto 9) ;;
        wiiu|console)
            cflags="-DDK_AT_ONLINE"
            bot_args=(-name AT-JOBEN -lobby 8 -start -start-delay 28s -race 69 -skid -path "$PATHFILE"
                      -chat "HELLO FROM BOT;YOU ARE A BLORPHEAD" -for 8m)
            # Cemu drops every remote sample after the first (net.c's 64-bit
            # "stale" compare comes out wrong there; the console and the
            # big-endian PC build store them all, log 2026-11-08), so the
            # bot's kart stands on the grid and lays no marks: only the
            # console is asked for them.
            [[ $scenario == console ]] && want="[1-9][0-9]* remote skid marks" ;;
        restart)
            cflags="-DDK_AT_ONLINE -DDK_AT_RESTART -DDK_AT_LOBBY=5"
            server_flags=(-race-seed 40)
            cue="restart the server now" ;;
        *) echo "unknown scenario $scenario" >&2; exit 2 ;;
    esac
    status=1
    if build_client "$cflags"; then
        : > "$OUT/$scenario-bot.log"
        start_server "$OUT/$scenario-server.log" ${server_flags[@]+"${server_flags[@]}"}
        [[ -n $bot_cue ]] || start_bots
        run_client && status=0 || status=$?
        if [[ $status == 0 && -n $want ]] && ! grep -aq -- "$want" "$OUT/$scenario.log"; then
            echo "   log has no \"$want\""
            status=1
        fi
        stop_server
        stop_bots
    fi
    verdict=$(grep -a "DK AUTOTEST: \|DK ONLINE: error\|DK PRACTICE: .*[0-9], [0-9]* in the lobby\|DK RESTART: in race\|DK ONLINE: race over\|DK ONLINE: watched" \
        "$OUT/$scenario.log" 2>/dev/null | tail -2 | tr '\n' ' ' || true)
    [[ -n $verdict ]] || verdict="no verdict line; see $OUT/$scenario.log"
    if [[ $status == 0 ]]; then results+=("PASS $scenario: $verdict"); else results+=("FAIL $scenario: $verdict"); failed=1; fi
    echo "   ${results[${#results[@]}-1]}"
done

echo "== online (local $SERVER_IP:$PORT)"
printf '%s\n' "${results[@]}"
[[ $failed == 0 ]] && echo "test_online: PASS" || echo "test_online: FAIL"
exit "$failed"
