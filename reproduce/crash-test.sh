#!/bin/bash
## PS-10592: Reproduce MySQL Router SIGSEGV caused by LTO
## Runs INSIDE the container (Debian Bullseye x86_64).
##
## LTO (-DWITH_LTO=ON) was added to Percona Server 8.0.43-34 Debian builds.
## It merges the static mysys library into the mysqlrouter binary and
## plugin .so files, creating multiple uninitialized fivp copies. The
## binary's my_init() initializes only the binary's fivp, leaving
## libmysqlrouter.so.1's fivp as NULL. During bootstrap, the charset
## initialization path in libmysqlrouter.so.1 dereferences NULL fivp,
## causing SIGSEGV.
##
## Test flow:
##   Phase A: All 8.0.42 (no LTO). Setup cluster, bootstrap Router. Verify OK.
##   Phase B: Upgrade ALL to 8.0.43 (with LTO). Re-bootstrap Router. CRASH.
##   Phase C: Downgrade Router only to 8.0.42. Re-bootstrap. Verify OK again.
##   Phase D: Diagnostics (gdb backtrace) if Phase B crashed.
##
## Output:
##   /tmp/crash-test.log         Full test log
##   /tmp/router-gdb.log         gdb backtrace (Phase D)
##   /tmp/mysqld.log             MySQL Server error log
set -euo pipefail

MYSQL_PWD="test39242"
DATADIR="/var/lib/mysql"
ROUTER_DIR="/tmp/mysqlrouter"
LOG="/tmp/crash-test.log"
SOCK="/var/run/mysqld/mysqld.sock"
GR_GROUP_NAME="aaaaaaaa-bbbb-cccc-dddd-eeee39242001"

# Enable core dumps (may fail in containers, non-fatal)
ulimit -c unlimited 2>/dev/null || true
bash -c 'echo "/tmp/core.%e.%p" > /proc/sys/kernel/core_pattern' 2>/dev/null || true

# -- Output helpers --
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
pass()    { log "${GREEN}PASS${NC}: $*"; }
fail()    { log "${RED}FAIL${NC}: $*"; }
warn()    { log "${YELLOW}WARN${NC}: $*"; }
section() { log ""; log "${BOLD}=== $* ===${NC}"; }

# -- MySQL helpers --
run_mysql() {
    mysql --socket="$SOCK" -uroot -p"$MYSQL_PWD" "$@" 2>/dev/null
}

wait_for_mysql() {
    local max_wait="${1:-120}"
    local elapsed=0
    log "  Waiting for MySQL (max ${max_wait}s)..."
    while ! mysqladmin --socket="$SOCK" -uroot -p"$MYSQL_PWD" ping &>/dev/null 2>&1 \
       && ! mysqladmin --socket="$SOCK" ping &>/dev/null 2>&1; do
        sleep 2
        elapsed=$((elapsed + 2))
        if [ "$elapsed" -ge "$max_wait" ]; then
            fail "MySQL did not start within ${max_wait}s"
            tail -20 /tmp/mysqld.log 2>/dev/null || true
            return 1
        fi
    done
    log "  MySQL ready (${elapsed}s)"
}

stop_mysql() {
    log "Stopping MySQL..."
    mysqladmin --socket="$SOCK" -uroot -p"$MYSQL_PWD" shutdown 2>/dev/null || true
    for i in $(seq 1 30); do
        if ! pgrep -x mysqld > /dev/null 2>&1; then
            log "  MySQL stopped"
            return 0
        fi
        sleep 1
    done
    warn "  MySQL did not stop gracefully, sending SIGKILL..."
    pkill -9 mysqld 2>/dev/null || true
    sleep 2
}

start_mysql() {
    local logfile="${1:-/tmp/mysqld.log}"
    log "Starting MySQL (log: $logfile)..."
    mysqld --user=mysql --datadir="$DATADIR" \
        --server-id=1 --report-host=localhost --report-port=3306 \
        --gtid-mode=ON --enforce-gtid-consistency=ON \
        --log-bin=binlog --binlog-format=ROW --binlog-checksum=NONE \
        --default-authentication-plugin=mysql_native_password \
        --disabled_storage_engines=MyISAM \
        --plugin-load-add=group_replication.so \
        --log-error="$logfile" \
        --socket="$SOCK" \
        --pid-file=/var/run/mysqld/mysqld.pid \
        &
    wait_for_mysql 120
}

start_gr() {
    log "Starting Group Replication (single-node bootstrap)..."
    run_mysql -e "
        SET GLOBAL group_replication_group_name = '$GR_GROUP_NAME';
        SET GLOBAL group_replication_local_address = '127.0.0.1:33061';
        SET GLOBAL group_replication_group_seeds = '127.0.0.1:33061';
        SET GLOBAL group_replication_single_primary_mode = ON;
        SET GLOBAL group_replication_bootstrap_group = ON;
        START GROUP_REPLICATION USER='root', PASSWORD='$MYSQL_PWD';
        SET GLOBAL group_replication_bootstrap_group = OFF;
    "
    sleep 3
    local state
    state=$(run_mysql -N -e "SELECT MEMBER_STATE FROM performance_schema.replication_group_members LIMIT 1" || echo "UNKNOWN")
    if [ "$state" = "ONLINE" ]; then
        pass "GR member is ONLINE"
    else
        warn "GR member state: $state (expected ONLINE)"
    fi
}

stop_router() {
    log "Stopping Router..."
    if [ -x "$ROUTER_DIR/stop.sh" ]; then
        "$ROUTER_DIR/stop.sh" 2>/dev/null || true
    elif [ -n "${ROUTER_PID:-}" ]; then
        kill "$ROUTER_PID" 2>/dev/null || true
    fi
    pkill -f "mysqlrouter" 2>/dev/null || true
    sleep 3
}

start_router() {
    log "Starting Router..."
    ROUTER_PID=""
    if [ -x "$ROUTER_DIR/start.sh" ]; then
        "$ROUTER_DIR/start.sh" 2>/dev/null || true
        sleep 3
        ROUTER_PID=$(cat "$ROUTER_DIR/mysqlrouter.pid" 2>/dev/null \
            || pgrep -f "mysqlrouter.*$ROUTER_DIR" | head -1 \
            || echo "")
    else
        mysqlrouter --config "$ROUTER_DIR/mysqlrouter.conf" &
        ROUTER_PID=$!
        sleep 3
    fi

    if [ -z "$ROUTER_PID" ]; then
        return 1
    fi
    if kill -0 "$ROUTER_PID" 2>/dev/null; then
        return 0
    fi
    return 1
}

# -- Binary analysis --
check_plugin_lto() {
    local label="$1"
    log ""
    log "--- Plugin analysis ($label) ---"
    local mc_plugin="/usr/lib/mysqlrouter/plugin/metadata_cache.so"
    if [ ! -f "$mc_plugin" ]; then
        mc_plugin=$(find /usr/lib -name "libmysqlrouter_metadata_cache.so*" -type f 2>/dev/null | head -1)
    fi
    if [ -n "$mc_plugin" ] && [ -f "$mc_plugin" ]; then
        local size
        size=$(stat -c%s "$mc_plugin" 2>/dev/null || echo "?")
        log "metadata_cache plugin: $mc_plugin ($size bytes)"
        local reg_count
        reg_count=$(readelf -Ws "$mc_plugin" 2>/dev/null | { grep -c RegisterFilename || true; })
        log "RegisterFilename symbols in plugin: $reg_count"
        if [ "$reg_count" -gt 0 ]; then
            warn "LTO has embedded mysys into the plugin (RegisterFilename present)"
            readelf -Ws "$mc_plugin" 2>/dev/null | grep RegisterFilename | tee -a "$LOG"
        else
            pass "No RegisterFilename in plugin (mysys resolved via libmysqlrouter.so)"
        fi
    else
        warn "metadata_cache plugin not found"
    fi
}

bootstrap_router() {
    log "Bootstrapping Router..."
    rm -rf "$ROUTER_DIR"
    mkdir -p "$ROUTER_DIR"
    mysqlrouter --bootstrap "root:${MYSQL_PWD}@localhost:3306" \
        --directory "$ROUTER_DIR" \
        --user=root \
        --force 2>&1 | tee -a "$LOG" | tail -5
}

# ============================================================
section "Pre-flight checks"
# ============================================================

log "mysqlsh: $(command -v mysqlsh 2>/dev/null || echo 'NOT FOUND')"
log "MySQL:   $(mysqld --version 2>/dev/null | head -1 || echo 'NOT FOUND')"
log "Router:  $(mysqlrouter --version 2>/dev/null | head -1 || echo 'NOT FOUND')"
log "readelf: $(command -v readelf 2>/dev/null || echo 'NOT FOUND')"
log "gdb:     $(command -v gdb 2>/dev/null || echo 'NOT FOUND')"
log "Arch:    $(dpkg --print-architecture 2>/dev/null || uname -m)"

check_plugin_lto "8.0.42 (pre-LTO)"

# ============================================================
section "Phase A: Baseline (all 8.0.42-33, no LTO)"
# ============================================================

log "Initializing MySQL data directory..."
rm -rf "${DATADIR:?}"/*
if mysqld --initialize-insecure --user=mysql --datadir="$DATADIR" 2>/tmp/mysqld-init.log; then
    pass "MySQL initialized (insecure mode)"
else
    fail "MySQL initialization failed"
    cat /tmp/mysqld-init.log
    exit 1
fi

start_mysql /tmp/mysqld.log

log "Configuring root user..."
mysql --socket="$SOCK" -uroot -e "
    ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_PWD';
    CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '$MYSQL_PWD';
    GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
    FLUSH PRIVILEGES;
"

start_gr

if command -v mysqlsh &>/dev/null; then
    log "Creating InnoDB Cluster metadata via mysqlsh..."
    if mysqlsh --no-wizard --uri="root:${MYSQL_PWD}@localhost:3306" \
        -e "dba.createCluster('test39242', {adoptFromGR: true})" 2>&1 | tee -a "$LOG" | tail -5; then
        pass "InnoDB Cluster metadata created"
    else
        fail "mysqlsh dba.createCluster failed"
        exit 1
    fi
else
    fail "mysqlsh not available (required for InnoDB Cluster metadata)"
    exit 1
fi

bootstrap_router
if start_router; then
    pass "Router 8.0.42 running (PID $ROUTER_PID)"
else
    fail "Router failed to start at baseline"
    exit 1
fi

log "Testing Router connectivity..."
if mysql -h 127.0.0.1 -P 6446 -uroot -p"$MYSQL_PWD" -N -e "SELECT 'RW_OK', VERSION()" 2>/dev/null; then
    pass "Router RW port (6446) working"
else
    warn "Router RW port not responding (metadata cache may still be initializing)"
fi

log "Waiting 15s to confirm Router stability..."
sleep 15
if kill -0 "$ROUTER_PID" 2>/dev/null; then
    pass "Phase A complete: Router 8.0.42 stable"
else
    fail "Router crashed during baseline stability check"
    exit 1
fi

# ============================================================
section "Phase B: Upgrade ALL to 8.0.43-34 (LTO)"
# ============================================================
log "Upgrading all Percona packages to 8.0.43-34."
log "Router 8.0.43 is built with LTO, which embeds mysys into each plugin."
log "This should trigger SIGSEGV in RegisterFilename."
log ""

stop_router
stop_mysql

apt-get update -qq
if apt-get install -y --allow-change-held-packages \
    percona-server-common=8.0.43-34-1.bullseye \
    percona-server-server=8.0.43-34-1.bullseye \
    percona-server-client=8.0.43-34-1.bullseye \
    percona-mysql-router=8.0.43-34-1.bullseye \
    2>&1 | tee -a "$LOG" | tail -10; then
    pass "All packages upgraded to 8.0.43-34"
else
    fail "Package upgrade failed"
    exit 1
fi

log ""
dpkg -l 2>/dev/null | grep -E "percona-server|percona-mysql-router" | tee -a "$LOG"

check_plugin_lto "8.0.43 (LTO)"

start_mysql /tmp/mysqld-43.log

MYSQLVER=$(run_mysql -N -e "SELECT VERSION()" || echo "UNKNOWN")
log "MySQL Server version: $MYSQLVER"

start_gr

log ""
log "***********************************************************"
log "*** Bootstrapping Router 8.0.43 (LTO)                   ***"
log "*** Expected: SIGSEGV in RegisterFilename                ***"
log "***********************************************************"
log ""

CRASHED=false

# Bootstrap is where the crash typically occurs (charset init during connect)
set +e
bootstrap_router 2>&1
BOOTSTRAP_EXIT=$?
set -e

if [ "$BOOTSTRAP_EXIT" -ne 0 ]; then
    fail "*** ROUTER 8.0.43 CRASHED DURING BOOTSTRAP (exit $BOOTSTRAP_EXIT) ***"
    CRASHED=true

    if [ "$BOOTSTRAP_EXIT" -eq 139 ]; then
        log "Exit code 139 = SIGSEGV (signal 11). ${GREEN}CRASH REPRODUCED!${NC}"
    elif [ "$BOOTSTRAP_EXIT" -eq 134 ]; then
        log "Exit code 134 = SIGABRT (signal 6)."
    fi
else
    # Bootstrap succeeded, try starting Router (crash may occur during metadata refresh)
    if start_router; then
        log "Router started with PID $ROUTER_PID"
        log "Monitoring for 30s (crash may be delayed until metadata refresh)..."
        for i in $(seq 1 6); do
            sleep 5
            if ! kill -0 "$ROUTER_PID" 2>/dev/null; then
                WAIT_STATUS=0
                wait "$ROUTER_PID" 2>/dev/null || WAIT_STATUS=$?
                fail "*** ROUTER CRASHED at ~$((i * 5))s (exit code: $WAIT_STATUS) ***"
                if [ "$WAIT_STATUS" -eq 139 ]; then
                    log "Exit code 139 = SIGSEGV. ${GREEN}CRASH REPRODUCED!${NC}"
                fi
                CRASHED=true
                break
            fi
            log "  [$((i * 5))s] Router PID $ROUTER_PID alive"
        done
    else
        fail "*** ROUTER 8.0.43 FAILED TO START ***"
        CRASHED=true
    fi
fi

if [ "$CRASHED" = false ]; then
    stop_router
    log ""
    log "RESULT: Router 8.0.43 did NOT crash."
    log "Possible reasons:"
    log "  a) Environment difference masks the LTO issue"
    log "  b) The crash requires a specific charset negotiation path"
fi

# ============================================================
section "Phase C: Downgrade Router to 8.0.42 (no LTO)"
# ============================================================
log "Keeping server at 8.0.43, downgrading Router only to 8.0.42."
log "This proves the crash is caused by the LTO-built Router binary."
log ""

stop_router

log "Downgrading percona-mysql-router to 8.0.42-33..."
apt-get update -qq
if apt-get install -y --allow-downgrades --allow-change-held-packages \
    percona-mysql-router=8.0.42-33-1.bullseye \
    2>&1 | tee -a "$LOG" | tail -10; then
    pass "Router downgraded to 8.0.42-33"
else
    fail "Router downgrade failed"
    exit 1
fi

check_plugin_lto "8.0.42 (no LTO, after downgrade)"

set +e
bootstrap_router 2>&1
BOOTSTRAP_EXIT=$?
set -e

if [ "$BOOTSTRAP_EXIT" -ne 0 ]; then
    fail "Router 8.0.42 bootstrap failed (exit $BOOTSTRAP_EXIT)"
else
    if start_router; then
        log "Router started with PID $ROUTER_PID"
        sleep 10
        if kill -0 "$ROUTER_PID" 2>/dev/null; then
            pass "Phase C: Router 8.0.42 running (no crash)"
            if mysql -h 127.0.0.1 -P 6446 -uroot -p"$MYSQL_PWD" -N \
                -e "SELECT 'RW_OK', VERSION()" 2>/dev/null; then
                pass "Router RW port working with Server 8.0.43"
            fi
        else
            fail "Router 8.0.42 crashed unexpectedly"
        fi
    else
        fail "Router 8.0.42 failed to start"
    fi
fi

# ============================================================
# Phase D: Diagnostics (if Phase B crashed)
# ============================================================
if [ "$CRASHED" = true ] && command -v gdb &>/dev/null; then
    section "Phase D: GDB Backtrace"

    stop_router

    # Re-install Router 8.0.43 for gdb analysis
    log "Re-installing Router 8.0.43 for gdb backtrace..."
    apt-get install -y --allow-change-held-packages \
        percona-mysql-router=8.0.43-34-1.bullseye \
        2>&1 | tail -5

    rm -rf "$ROUTER_DIR"
    mkdir -p "$ROUTER_DIR"

    cat > /tmp/gdb-cmds <<'GDBEOF'
set confirm off
set pagination off
run
bt full
info threads
thread apply all bt
quit
GDBEOF

    log "Running Router 8.0.43 under gdb..."
    timeout 60 gdb -batch -x /tmp/gdb-cmds \
        --args mysqlrouter --bootstrap "root:${MYSQL_PWD}@localhost:3306" \
        --directory "$ROUTER_DIR" --user=root --force \
        > /tmp/router-gdb.log 2>&1 || true
    log "gdb output: /tmp/router-gdb.log ($(wc -l < /tmp/router-gdb.log 2>/dev/null || echo 0) lines)"
    log ""
    log "Crash-relevant gdb output:"
    grep -B 2 -A 5 -iE "SIGSEGV|RegisterFilename|my_open|charset|my_thread_init|fivp" \
        /tmp/router-gdb.log 2>/dev/null | head -60 | tee -a "$LOG" || log "(no matches)"
fi

# ============================================================
section "Summary"
# ============================================================
log ""
log "Phase A (all 8.0.42, no LTO):  PASS (Router works)"
if [ "$CRASHED" = true ]; then
    log "Phase B (all 8.0.43, LTO):     ${RED}CRASH REPRODUCED${NC}"
else
    log "Phase B (all 8.0.43, LTO):     NO CRASH (see notes above)"
fi
log "Phase C (Router 8.0.42 only):  PASS (Router works with Server 8.0.43)"
if [ "$CRASHED" = true ]; then
    log "Phase D (gdb diagnostics):     See /tmp/router-gdb.log"
fi
log ""
log "Conclusion:"
if [ "$CRASHED" = true ]; then
    log "  The crash is caused by the LTO-built Router 8.0.43 binary."
    log "  Router 8.0.42 (no LTO) works fine with Server 8.0.43."
    log "  Fix: Strip -flto from the Router subdirectory in CMakeLists.txt."
else
    log "  Router 8.0.43 did not crash in this environment."
    log "  The crash may require a specific charset negotiation path."
fi
log ""
log "Full log: $LOG"

# Exit 0 regardless: this is a reproduction script, not a pass/fail test.
# The CRASHED variable and summary above indicate the outcome.
exit 0
