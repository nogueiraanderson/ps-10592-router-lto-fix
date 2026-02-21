# PS-10592: MySQL Router SIGSEGV Fix (LTO)
# Requires: Docker on x86_64 (EC2 or local). Not tested on ARM.

container := "ps-10592-test"
image := "ps-10592-bullseye"

# Build the Debian Bullseye test image (Percona 8.0.42 packages)
build:
    docker build -t {{image}} reproduce/

# Reproduce the crash: upgrade Router to 8.0.43 (LTO), confirm SIGSEGV
crash-test: build
    docker rm -f {{container}} 2>/dev/null || true
    docker run -d --name {{container}} \
        --cap-add SYS_PTRACE --ulimit core=-1 \
        {{image}} sleep infinity
    docker cp reproduce/crash-test.sh {{container}}:/tmp/crash-test.sh
    docker exec {{container}} bash /tmp/crash-test.sh
    @echo ""
    @echo "Copy logs: docker cp {{container}}:/tmp/crash-test.log ."

# Build Router from patched source (no LTO), confirm no crash
fix-test: build
    docker rm -f {{container}} 2>/dev/null || true
    docker run -d --name {{container}} \
        --cap-add SYS_PTRACE --ulimit core=-1 \
        {{image}} sleep infinity
    docker cp reproduce/fix-build-test.sh {{container}}:/tmp/fix-build-test.sh
    docker exec {{container}} bash /tmp/fix-build-test.sh
    @echo ""
    @echo "Copy logs: docker cp {{container}}:/tmp/fix-test.log ."

# Clean up container
clean:
    docker rm -f {{container}} 2>/dev/null || true

# Shell into the test container
shell:
    docker exec -it {{container}} bash
