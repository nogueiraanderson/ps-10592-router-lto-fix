FROM debian:bullseye

ENV DEBIAN_FRONTEND=noninteractive

# Prerequisites (python3 needed by fix-build-test.sh patcher)
RUN apt-get update && apt-get install -y --no-install-recommends \
    gnupg2 curl ca-certificates python3 lsb-release \
    && rm -rf /var/lib/apt/lists/*

# Percona APT repository via percona-release
RUN curl -fsSL https://repo.percona.com/apt/percona-release_latest.bullseye_all.deb \
    -o /tmp/percona-release.deb \
    && dpkg -i /tmp/percona-release.deb \
    && rm /tmp/percona-release.deb \
    && percona-release setup ps80

# Block service starts during package install (standard Docker practice)
RUN printf '#!/bin/sh\nexit 101' > /usr/sbin/policy-rc.d \
    && chmod +x /usr/sbin/policy-rc.d

# Install Percona 8.0.42-33 on a SINGLE filesystem.
# Router is self-contained (no external .so deps). The crash trigger is LTO
# merging mysys into plugin .so files. Upgrade to 8.0.43 + readelf analysis
# confirms the mechanism.
RUN apt-get update && apt-get install -y \
    percona-server-common=8.0.42-33-1.bullseye \
    percona-server-server=8.0.42-33-1.bullseye \
    percona-server-client=8.0.42-33-1.bullseye \
    percona-mysql-router=8.0.42-33-1.bullseye

# MySQL Shell for InnoDB Cluster metadata creation
RUN apt-get install -y percona-mysql-shell || \
    echo "WARNING: percona-mysql-shell not available"

# Diagnostic tools (strace/gdb for Phase D, readelf for RPATH checks)
RUN apt-get install -y strace gdb procps net-tools binutils

# Keep APT lists for upgrade operations in test phases
RUN apt-get update

# Runtime directories
RUN mkdir -p /var/run/mysqld /var/run/mysqlrouter /var/lib/mysqlrouter \
    && chown mysql:mysql /var/run/mysqld /var/run/mysqlrouter /var/lib/mysqlrouter

CMD ["sleep", "infinity"]
