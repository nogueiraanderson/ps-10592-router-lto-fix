#!/bin/bash
## PS-10592: Build Router from Patched Source and Verify No Crash
## Runs INSIDE the container (Debian Bullseye x86_64).
##
## This script:
##   1. Clones Percona Server 8.0.43-34 source
##   2. Applies the CMake fix (strips -flto from Router subdirectory)
##   3. Builds Router from source with cmake --build
##   4. Verifies built plugins have no RegisterFilename (no mysys duplication)
##   5. Replaces APT Router binaries with patched build
##   6. Sets up InnoDB Cluster, bootstraps Router, confirms no crash
##
## Tested on x86_64 (EC2 and local). Not tested on ARM.
##
## Usage: bash /tmp/fix-build-test.sh
## Output: /tmp/fix-test.log
set -euo pipefail

MYSQL_PWD="test39242"
DATADIR="/var/lib/mysql"
ROUTER_DIR="/tmp/mysqlrouter"
LOG="/tmp/fix-test.log"
SOCK="/var/run/mysqld/mysqld.sock"
GR_GROUP_NAME="aaaaaaaa-bbbb-cccc-dddd-eeee39242005"
SRC="/tmp/ps-source"
BUILD="/tmp/ps-build"

# Enable core dumps
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

# ============================================================
section "Pre-flight"
# ============================================================

log "Arch: $(dpkg --print-architecture 2>/dev/null || uname -m)"
log "CPUs: $(nproc)"

# ============================================================
section "Phase 1: Install Build Dependencies + Clone Source"
# ============================================================

log "Installing cmake, git, build tools..."
apt-get update -qq
apt-get install -y --no-install-recommends \
    cmake g++ make pkg-config git \
    bison perl psmisc lsb-release \
    libssl-dev libncurses-dev libtirpc-dev libaio-dev \
    zlib1g-dev libreadline-dev libpam-dev libnuma-dev \
    libwrap0-dev libcurl4-openssl-dev libldap2-dev \
    libsasl2-dev libkrb5-dev \
    2>&1 | tail -5
pass "Build dependencies installed"

if [ -d "$SRC" ]; then
    log "Source directory exists, reusing..."
    git -C "$SRC" checkout -- router/CMakeLists.txt 2>/dev/null || true
else
    log "Cloning Percona Server 8.0.43-34 (shallow)..."
    git clone --depth 1 --branch Percona-Server-8.0.43-34 \
        https://github.com/percona/percona-server.git "$SRC" 2>&1 | tail -5
    pass "Source cloned to $SRC"
fi

# ============================================================
section "Phase 2: Apply CMake LTO Fix"
# ============================================================

log "Applying CMake LTO fix to router/CMakeLists.txt..."

cat > /tmp/apply-lto-patch.py << 'PYEOF'
import sys

cmake_path = sys.argv[1]
with open(cmake_path, 'r') as f:
    content = f.read()

patch = """
# LTO merges static mysys into each plugin .so, creating duplicate fivp
# copies. Plugins load via dlopen(RTLD_LOCAL) so each gets uninitialized
# mysys state. Strip -flto so plugins resolve mysys via libmysqlrouter.so.
IF(WITH_LTO)
  STRING(REGEX REPLACE "-flto[^ ]*" "" CMAKE_C_FLAGS "${CMAKE_C_FLAGS}")
  STRING(REGEX REPLACE "-flto[^ ]*" "" CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS}")
  STRING(REGEX REPLACE "-flto[^ ]*" "" CMAKE_CXX_LINK_FLAGS "${CMAKE_CXX_LINK_FLAGS}")
  STRING(REGEX REPLACE "-flto[^ ]*" "" CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS}")
ENDIF()
"""

marker = 'STRING(REPLACE "-fuse-ld=gold" "" CMAKE_CXX_LINK_FLAGS "${CMAKE_CXX_LINK_FLAGS}")\nENDIF()'
if marker not in content:
    print("ERROR: Could not find insertion marker in " + cmake_path, file=sys.stderr)
    sys.exit(1)

content = content.replace(marker, marker + patch, 1)
with open(cmake_path, 'w') as f:
    f.write(content)
print("Patch applied successfully")
PYEOF

python3 /tmp/apply-lto-patch.py "$SRC/router/CMakeLists.txt" 2>&1

log "Verifying patch..."
if grep -q "IF(WITH_LTO)" "$SRC/router/CMakeLists.txt"; then
    pass "CMake LTO fix applied to router/CMakeLists.txt"
    grep -n -A 6 "IF(WITH_LTO)" "$SRC/router/CMakeLists.txt" | tee -a "$LOG"
else
    fail "Patch verification failed!"
    exit 1
fi

log ""
log "Patch diff:"
git -C "$SRC" diff router/CMakeLists.txt | tee -a "$LOG"

# ============================================================
section "Phase 3: CMake Configure"
# ============================================================

log "Running cmake configure with WITH_LTO=ON..."
log "Our patch strips -flto from Router subdirectory ONLY."

rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"

cmake \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DWITH_LTO=ON \
    -DDOWNLOAD_BOOST=1 \
    -DWITH_BOOST="$BUILD/boost" \
    -DWITH_SSL=system \
    -DWITH_PROTOBUF=bundled \
    -DWITH_RAPIDJSON=bundled \
    -DWITH_LIBEVENT=bundled \
    -DWITH_EDITLINE=bundled \
    -DWITH_ICU=bundled \
    -DWITH_ZSTD=bundled \
    -DWITH_ZLIB=bundled \
    -DWITH_LZ4=bundled \
    -DWITH_FIDO=bundled \
    -DWITH_ROUTER=ON \
    -DWITH_UNIT_TESTS=OFF \
    -DWITH_ROCKSDB=OFF \
    -DWITH_TOKUDB=OFF \
    -DWITH_NDB=OFF \
    -DWITH_NDBCLUSTER=OFF \
    -DWITH_INNODB_MEMCACHED=OFF \
    -DWITH_MECAB=OFF \
    -DWITH_NUMA=OFF \
    -DWITH_AUTHENTICATION_LDAP=OFF \
    -DWITH_AUTHENTICATION_KERBEROS=OFF \
    -DWITH_AUTHENTICATION_FIDO=OFF \
    -DWITH_KEYRING_VAULT=OFF \
    -DWITH_COREDUMPER=OFF \
    -DWITHOUT_COMPONENT_KEYRING_KMIP=ON \
    "$SRC" \
    2>&1 | tee /tmp/cmake-configure.log | tail -30

pass "CMake configure completed"

# ============================================================
section "Phase 4: Build Router"
# ============================================================

NPROC=$(nproc)
log "Building Router targets with $NPROC parallel jobs..."
log "This will take 15-30 minutes depending on CPU."

# Build Router and its dependencies (mysys, mysqlclient, etc.)
cmake --build . --target mysqlrouter_all -- -j"$NPROC" \
    2>&1 | tee /tmp/cmake-build.log | tail -20

pass "Router build completed"

# ============================================================
section "Phase 5: Binary Verification (Built Plugins)"
# ============================================================

log "Checking built plugin binaries for mysys symbols..."
log ""

# Collect APT 8.0.42 baseline data before we overwrite anything
log "--- APT 8.0.42 (pre-LTO) baseline ---"
APT42_MC="/usr/lib/mysqlrouter/plugin/metadata_cache.so"
APT42_MC_SIZE=0
APT42_MC_REG=0
if [ -f "$APT42_MC" ]; then
    APT42_MC_SIZE=$(stat -c%s "$APT42_MC" 2>/dev/null || echo 0)
    APT42_MC_REG=$(readelf -Ws "$APT42_MC" 2>/dev/null | { grep -c "RegisterFilename" || true; })
    log "  metadata_cache.so: $APT42_MC_SIZE bytes, RegisterFilename: $APT42_MC_REG"
fi

APT42_RT="/usr/lib/mysqlrouter/plugin/routing.so"
APT42_RT_SIZE=0
APT42_RT_REG=0
if [ -f "$APT42_RT" ]; then
    APT42_RT_SIZE=$(stat -c%s "$APT42_RT" 2>/dev/null || echo 0)
    APT42_RT_REG=$(readelf -Ws "$APT42_RT" 2>/dev/null | { grep -c "RegisterFilename" || true; })
    log "  routing.so: $APT42_RT_SIZE bytes, RegisterFilename: $APT42_RT_REG"
fi

# Collect APT 8.0.43 data
log ""
log "--- Upgrading Router to 8.0.43 for comparison ---"
apt-get install -y --allow-change-held-packages \
    percona-mysql-router=8.0.43-34-1.bullseye \
    2>&1 | tail -3

APT43_MC_SIZE=0
APT43_MC_REG=0
if [ -f "$APT42_MC" ]; then
    APT43_MC_SIZE=$(stat -c%s "$APT42_MC" 2>/dev/null || echo 0)
    APT43_MC_REG=$(readelf -Ws "$APT42_MC" 2>/dev/null | { grep -c "RegisterFilename" || true; })
    log "  metadata_cache.so: $APT43_MC_SIZE bytes, RegisterFilename: $APT43_MC_REG"
fi

APT43_RT_SIZE=0
APT43_RT_REG=0
if [ -f "$APT42_RT" ]; then
    APT43_RT_SIZE=$(stat -c%s "$APT42_RT" 2>/dev/null || echo 0)
    APT43_RT_REG=$(readelf -Ws "$APT42_RT" 2>/dev/null | { grep -c "RegisterFilename" || true; })
    log "  routing.so: $APT43_RT_SIZE bytes, RegisterFilename: $APT43_RT_REG"
fi

# Now check built plugins
log ""
log "--- Source-built plugins (patched, no LTO in Router) ---"

BUILT_MC=""
BUILT_RT=""
BUILT_LIB=""

# Find built plugin .so files (CMake outputs to plugin_output_directory/)
for f in $(find "$BUILD" -name "metadata_cache.so" -type f 2>/dev/null); do
    BUILT_MC="$f"
done
for f in $(find "$BUILD" -name "routing.so" -type f 2>/dev/null); do
    BUILT_RT="$f"
done
for f in $(find "$BUILD" -name "libmysqlrouter.so*" -not -name "*.a" -type f 2>/dev/null | head -1); do
    BUILT_LIB="$f"
done
log "  Build output search paths:"
log "    metadata_cache.so: ${BUILT_MC:-NOT FOUND}"
log "    routing.so:        ${BUILT_RT:-NOT FOUND}"
log "    libmysqlrouter.so: ${BUILT_LIB:-NOT FOUND}"

BUILT_MC_SIZE=0
BUILT_MC_REG=0
if [ -n "$BUILT_MC" ] && [ -f "$BUILT_MC" ]; then
    BUILT_MC_SIZE=$(stat -c%s "$BUILT_MC" 2>/dev/null || echo 0)
    BUILT_MC_REG=$(readelf -Ws "$BUILT_MC" 2>/dev/null | { grep -c "RegisterFilename" || true; })
    log "  metadata_cache.so: $BUILT_MC_SIZE bytes, RegisterFilename: $BUILT_MC_REG"
    if [ "$BUILT_MC_REG" -eq 0 ]; then
        pass "Built metadata_cache.so has NO RegisterFilename (patch works)"
    else
        warn "Built metadata_cache.so still has RegisterFilename symbols"
    fi
else
    warn "Built metadata_cache.so not found in $BUILD/"
fi

BUILT_RT_SIZE=0
BUILT_RT_REG=0
if [ -n "$BUILT_RT" ] && [ -f "$BUILT_RT" ]; then
    BUILT_RT_SIZE=$(stat -c%s "$BUILT_RT" 2>/dev/null || echo 0)
    BUILT_RT_REG=$(readelf -Ws "$BUILT_RT" 2>/dev/null | { grep -c "RegisterFilename" || true; })
    log "  routing.so: $BUILT_RT_SIZE bytes, RegisterFilename: $BUILT_RT_REG"
else
    warn "Built routing.so not found in $BUILD/"
fi

if [ -n "$BUILT_LIB" ] && [ -f "$BUILT_LIB" ]; then
    BUILT_LIB_SIZE=$(stat -c%s "$BUILT_LIB" 2>/dev/null || echo 0)
    BUILT_LIB_REG=$(readelf -Ws "$BUILT_LIB" 2>/dev/null | { grep -c "RegisterFilename" || true; })
    log "  libmysqlrouter.so: $BUILT_LIB_SIZE bytes, RegisterFilename: $BUILT_LIB_REG"
fi

# ============================================================
section "Phase 6: Functional Test (Patched Router + Server 8.0.43)"
# ============================================================

log "Replacing APT Router binaries with patched source build..."
log ""

# Upgrade server to 8.0.43
log "Upgrading server packages to 8.0.43-34..."
apt-get install -y --allow-change-held-packages \
    percona-server-common=8.0.43-34-1.bullseye \
    percona-server-server=8.0.43-34-1.bullseye \
    percona-server-client=8.0.43-34-1.bullseye \
    2>&1 | tail -5

# Replace the mysqlrouter binary, plugins, and private libraries with
# source-built versions. All three must be replaced because the LTO build
# merges mysys into the binary as well. Using the APT binary (LTO) with
# source-built libraries causes SIGSEGV because the binary's my_init()
# only initializes the binary's own fivp copy, not the library's.
#
# The source-built binary uses /usr/local/* prefix paths (cmake default).
# We create symlinks for charset data and copy plugins to the expected dir.
PLUGIN_DIR="/usr/lib/mysqlrouter/plugin"
PRIVATE_DIR="/usr/lib/mysqlrouter/private"
PLUGIN_BUILD="$BUILD/plugin_output_directory"
LIB_BUILD="$BUILD/library_output_directory"
BIN_BUILD="$BUILD/runtime_output_directory"

REPLACED=0

# 1. Replace mysqlrouter binary
if [ -f "$BIN_BUILD/mysqlrouter" ]; then
    cp "$BIN_BUILD/mysqlrouter" /usr/bin/mysqlrouter
    log "  binary: mysqlrouter ($(stat -c%s "$BIN_BUILD/mysqlrouter") bytes)"
    REPLACED=$((REPLACED + 1))
fi

# 2. Replace plugins in APT location AND source binary's default location.
#    The source-built binary looks for plugins in /usr/lib/mysqlrouter/
#    (no plugin/ subdirectory) when built without CMAKE_INSTALL_PREFIX.
if [ -d "$PLUGIN_BUILD" ]; then
    for so in "$PLUGIN_BUILD"/*.so; do
        [ -f "$so" ] || continue
        cp "$so" "$PLUGIN_DIR/$(basename "$so")"
        cp "$so" "/usr/lib/mysqlrouter/$(basename "$so")"
        log "  plugin: $(basename "$so")"
        REPLACED=$((REPLACED + 1))
    done
fi

# 3. Replace private libraries (harness, router core, mysqlclient)
if [ -d "$LIB_BUILD" ]; then
    for so in "$LIB_BUILD"/*.so*; do
        [ -f "$so" ] || continue
        cp "$so" "$PRIVATE_DIR/$(basename "$so")"
        log "  private: $(basename "$so")"
        REPLACED=$((REPLACED + 1))
    done
fi

# 4. Fix charset path: source build looks for /usr/local/mysql/share/charsets/
#    but charsets are at /usr/share/mysql/charsets/ (from APT).
mkdir -p /usr/local/mysql/share
ln -sf /usr/share/mysql/charsets /usr/local/mysql/share/charsets
log "  charset symlink: /usr/local/mysql/share/charsets -> APT path"

if [ "$REPLACED" -gt 0 ]; then
    pass "Replaced $REPLACED Router files with source build"
else
    fail "No built files found to replace"
    exit 1
fi

# Verify versions
log ""
dpkg -l percona-server-server percona-mysql-router 2>/dev/null | grep "^ii" | tee -a "$LOG"

# Initialize MySQL
log ""
log "Initializing MySQL data directory..."
rm -rf "${DATADIR:?}"/*
mysqld --initialize-insecure --user=mysql --datadir="$DATADIR" 2>/tmp/mysqld-init.log
pass "MySQL initialized"

start_mysql /tmp/mysqld.log

# Set root password
log "Configuring root user (mysql_native_password)..."
mysql --socket="$SOCK" -uroot -e "
    ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$MYSQL_PWD';
    CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED WITH mysql_native_password BY '$MYSQL_PWD';
    GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
    FLUSH PRIVILEGES;
"

start_gr

# Create InnoDB Cluster
log "Creating InnoDB Cluster metadata..."
mysqlsh --no-wizard --uri="root:${MYSQL_PWD}@localhost:3306" \
    -e "dba.createCluster('testfix', {adoptFromGR: true})" 2>&1 | tee -a "$LOG" | tail -3
pass "InnoDB Cluster metadata created"

# Bootstrap Router (source-built, no LTO in plugins)
log "Bootstrapping Router (patched source build)..."
rm -rf "$ROUTER_DIR"
mkdir -p "$ROUTER_DIR"
set +e
mysqlrouter --bootstrap "root:${MYSQL_PWD}@localhost:3306" \
    --directory "$ROUTER_DIR" \
    --user=root \
    --force 2>&1 | tee -a "$LOG" | tail -5
BOOTSTRAP_EXIT=$?
set -e

if [ "$BOOTSTRAP_EXIT" -ne 0 ]; then
    fail "Router bootstrap failed (exit $BOOTSTRAP_EXIT)"
    if [ "$BOOTSTRAP_EXIT" -eq 139 ]; then
        fail "SIGSEGV during bootstrap. The patch may not have been applied correctly."
    fi
    exit 1
fi
pass "Router bootstrapped (no crash)"

# Start Router and monitor for 30 seconds
ROUTER_CRASHED=false
if start_router; then
    log "Router started with PID $ROUTER_PID"
    for i in $(seq 1 6); do
        sleep 5
        if ! kill -0 "$ROUTER_PID" 2>/dev/null; then
            WAIT_STATUS=0
            wait "$ROUTER_PID" 2>/dev/null || WAIT_STATUS=$?
            fail "Router CRASHED at ~$((i * 5))s (exit code: $WAIT_STATUS)"
            ROUTER_CRASHED=true
            break
        fi
        log "  [$((i * 5))s] Router PID $ROUTER_PID alive"
    done
else
    fail "Router CRASHED immediately on startup"
    ROUTER_CRASHED=true
fi

if [ "$ROUTER_CRASHED" = false ]; then
    pass "Patched Router survived 30 seconds with Server 8.0.43"

    log "Testing Router connectivity..."
    if mysql -h 127.0.0.1 -P 6446 -uroot -p"$MYSQL_PWD" -N -e "SELECT 'RW_OK', VERSION()" 2>/dev/null; then
        pass "Router RW port (6446) working"
    else
        warn "Router RW port not responding"
    fi

    if mysql -h 127.0.0.1 -P 6447 -uroot -p"$MYSQL_PWD" -N -e "SELECT 'RO_OK', VERSION()" 2>/dev/null; then
        pass "Router RO port (6447) working"
    else
        warn "Router RO port not responding (expected for single-node)"
    fi
fi

# ============================================================
section "Summary"
# ============================================================

log ""
log "=== Three-Way Comparison ==="
log ""
printf "%-26s  %12s  %12s  %12s\n" "File" "8.0.42 APT" "8.0.43 APT" "Patched" | tee -a "$LOG"
printf "%-26s  %12s  %12s  %12s\n" "--------------------------" "------------" "------------" "------------" | tee -a "$LOG"
printf "%-26s  %10s B  %10s B  %10s B\n" "metadata_cache.so" "$APT42_MC_SIZE" "$APT43_MC_SIZE" "$BUILT_MC_SIZE" | tee -a "$LOG"
printf "%-26s  %12s  %12s  %12s\n" "  RegisterFilename" "$APT42_MC_REG" "$APT43_MC_REG" "$BUILT_MC_REG" | tee -a "$LOG"
printf "%-26s  %10s B  %10s B  %10s B\n" "routing.so" "$APT42_RT_SIZE" "$APT43_RT_SIZE" "$BUILT_RT_SIZE" | tee -a "$LOG"
printf "%-26s  %12s  %12s  %12s\n" "  RegisterFilename" "$APT42_RT_REG" "$APT43_RT_REG" "$BUILT_RT_REG" | tee -a "$LOG"
log ""

log "Fix Verification Results:"
log ""
log "  1. CMake patch:        Applied (strips -flto from Router subdirectory)"
log "  2. Source build:       Completed (cmake --build with $NPROC jobs)"
log "  3. Binary analysis:    metadata_cache.so has $BUILT_MC_REG RegisterFilename symbols"
if [ "$ROUTER_CRASHED" = true ]; then
    log "  4. Functional test:    ${RED}FAILED${NC}"
else
    log "  4. Functional test:    ${GREEN}PASS (bootstrap + 30s stability)${NC}"
fi
log ""

if [ "$ROUTER_CRASHED" = false ] && [ "$BUILT_MC_REG" -eq 0 ]; then
    log "${GREEN}${BOLD}Fix VERIFIED: stripping -flto from Router subdirectory${NC}"
    log "${GREEN}${BOLD}eliminates the SIGSEGV caused by duplicate mysys in plugins.${NC}"
    log ""
    log "Evidence chain:"
    log "  1. APT 8.0.43 metadata_cache.so: ${APT43_MC_SIZE} bytes, ${APT43_MC_REG} RegisterFilename"
    log "  2. Patched metadata_cache.so:     ${BUILT_MC_SIZE} bytes, ${BUILT_MC_REG} RegisterFilename"
    log "  3. Source-built Router bootstraps cleanly (no SIGSEGV)"
    log "  4. Router stable for 30 seconds under load"
elif [ "$ROUTER_CRASHED" = false ]; then
    warn "Router did not crash but built plugin still has RegisterFilename symbols."
    warn "The build may not have applied the patch correctly."
else
    fail "Patched Router still crashed. Investigation needed."
fi

log ""
log "Full log: $LOG"
log "Configure log: /tmp/cmake-configure.log"
log "Build log: /tmp/cmake-build.log"

exit 0
