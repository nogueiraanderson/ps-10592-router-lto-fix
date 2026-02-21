# PS-10592: MySQL Router SIGSEGV Fix (LTO)

CMake patch for MySQL Router SIGSEGV caused by `-DWITH_LTO=ON` in
Percona Server 8.0.43+ Debian packages.

## Problem

Percona Server 8.0.43-34 introduced `-DWITH_LTO=ON` in
`build-ps/debian/rules`
([commit 5964e341](https://github.com/percona/percona-server/commit/5964e341),
[PKG-870](https://perconadev.atlassian.net/browse/PKG-870)).
LTO merges the static `mysys` convenience library into multiple
components that previously shared a single copy. In 8.0.42 (no LTO),
only `libmysqlrouter.so.1` contained mysys. Under LTO, both the
`mysqlrouter` binary and plugins like `metadata_cache.so` get their own
embedded copies. Each copy has its own `fivp` file info vector pointer
(`mysys/my_file.cc`, anonymous namespace, internal linkage per object).

The crash occurs because `my_init()` in the binary resolves at link time
to the binary's own embedded copy (LTO inlined it). This initializes
only the binary's `fivp`. `libmysqlrouter.so.1`'s `fivp` is never
initialized because its `my_init()` is never called. During bootstrap,
`mysql_real_connect` in `libmysqlrouter.so.1` calls
`mysql_init_character_set` -> `my_charset_get_by_name` -> `my_open` ->
`RegisterFilename`, which dereferences the library's NULL `fivp`,
causing SIGSEGV. The crash backtrace confirms every frame in the crash
path is in `libmysqlrouter.so.1` (see `evidence/crash-backtrace.txt`).

The plugin duplication is a secondary effect: `metadata_cache.so` grows
from 85KB to 7,667KB (90x larger) and gains its own `RegisterFilename`
symbol. This would cause the same crash during metadata cache runtime,
but bootstrap crashes first. `routing.so` is not affected (0
`RegisterFilename` symbols in both versions).

## Affected Versions

- Percona MySQL Router 8.0.43-34 (confirmed crash, reproduced)
- Percona MySQL Router 8.0.44-35 (LTO still in `debian/rules`)
- Percona MySQL Router 8.0.45-36 (LTO still in `debian/rules`)

Docker Hub images are not affected (Dockerfiles do not pass
`-DWITH_LTO=ON`; LTO is added only in `build-ps/debian/rules`).

## The Fix

Strip `-flto` flags from the Router subdirectory in
`router/CMakeLists.txt`. The same file already uses this pattern to
strip `-fuse-ld=gold` for certain Clang versions (lines 37-38).

See [router-lto-fix.patch](router-lto-fix.patch) for the exact change.

## Verification

Built Router from the patched `Percona-Server-8.0.43-34` source on a
native x86_64 EC2 instance (c7i.8xlarge, Debian Bullseye, GCC 10).
Three-way comparison of the crash-path plugin (`metadata_cache.so`):

| Binary | LTO | Size | RegisterFilename | Bootstrap |
|--------|-----|------|-----------------|-----------|
| APT 8.0.42-33 | No | 85KB | 0 | Clean |
| APT 8.0.43-34 | Yes | 7,667KB | 1 | SIGSEGV |
| Source-built 8.0.43-34 (patched) | No | 513KB | 0 | Clean |

The patched build eliminates `RegisterFilename` from the crash-path
plugins. These plugins resolve mysys symbols via the PLT to
`libmysqlrouter.so.1`, the same behavior as 8.0.42.
`rest_metadata_cache.so` still has 3 `RegisterFilename` symbols in the
patched build; REST plugins are not loaded during bootstrap but may
warrant separate investigation for runtime stability. See
`evidence/binary-analysis.txt` for full readelf data.

## Reproduction

The `reproduce/` directory contains Docker-based scripts to reproduce
the crash and verify the fix. Requires Docker and
[just](https://github.com/casey/just).

```bash
# Reproduce the SIGSEGV (upgrades Router to 8.0.43 LTO inside container)
just crash-test

# Build Router from patched source and verify no crash
just fix-test

# Shell into the test container for manual investigation
just shell

# Clean up
just clean
```

The crash test takes a few minutes. The fix test builds Router from
source inside the container, which takes 15-30 minutes depending on CPU.
Tested on x86_64 (EC2 and local). Not tested on ARM.

## Workaround

Pin Router to the pre-LTO version while keeping Server at 8.0.43+:

```bash
apt install percona-mysql-router=8.0.42-33-1.bullseye
```

Router 8.0.42 uses its own private libraries and communicates with the
server via the MySQL wire protocol (backward compatible).

## References

- [JIRA PS-10592](https://perconadev.atlassian.net/browse/PS-10592):
  This bug
- [JIRA PS-10017](https://perconadev.atlassian.net/browse/PS-10017):
  Feature request for LTO in release binaries
- [JIRA PKG-870](https://perconadev.atlassian.net/browse/PKG-870):
  Packaging commit that added `-DWITH_LTO=ON`
- [Forum #39242](https://forums.percona.com/t/mysql-router-crash-sigsegv-after-percona-8-0-43-upgrade/39242):
  Original user report
- [GitHub diff 8.0.42 vs 8.0.43](https://github.com/percona/percona-server/compare/Percona-Server-8.0.42-33...Percona-Server-8.0.43-34):
  Shows the `-DWITH_LTO=ON` addition in `debian/rules`
