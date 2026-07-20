#!/usr/bin/env bats
# Tests for update.sh, run against a mocked `pct` and `ping` (tests/mocks/)
# so no real Proxmox host or containers are needed. Run with:
#   bats tests/

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export TEST_TMPDIR

    export LXC_UPDATE_LOGDIR="$TEST_TMPDIR/logs"
    export LXC_UPDATE_LOCKFILE="$TEST_TMPDIR/lock"
    export LXC_UPDATE_EXCLUDE_FILE="$TEST_TMPDIR/exclude.list"
    export MOCK_PCT_CALL_LOG="$TEST_TMPDIR/pct-calls.log"
    : > "$MOCK_PCT_CALL_LOG"

    unset MOCK_PCT_LIST MOCK_PCT_PKGMGR MOCK_PCT_FAIL_START MOCK_PCT_FAIL_UPDATE MOCK_PCT_FAIL_UPGRADE MOCK_PCT_FAIL_AUTOREMOVE

    export PATH="$BATS_TEST_DIRNAME/mocks:$PATH"
    SCRIPT="$BATS_TEST_DIRNAME/../update.sh"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "skips containers on the exclude list" {
    export MOCK_PCT_LIST="100:running 105:running"
    echo "105" > "$LXC_UPDATE_EXCLUDE_FILE"

    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipping container 105 (excluded)"* ]]
    [[ "$output" == *"1 succeeded, 0 failed, 1 skipped"* ]]
}

@test "updates a running container successfully" {
    export MOCK_PCT_LIST="100:running"

    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Finished container 100"* ]]
    [[ "$output" == *"1 succeeded, 0 failed, 0 skipped"* ]]
}

@test "starts a stopped container, updates it, and stops it again" {
    export MOCK_PCT_LIST="101:stopped"

    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q "^pct start 101$" "$MOCK_PCT_CALL_LOG"
    grep -q "^pct stop 101$" "$MOCK_PCT_CALL_LOG"
}

@test "failed apt-get update restores stopped state and is counted as failed" {
    export MOCK_PCT_LIST="102:stopped"
    export MOCK_PCT_FAIL_UPDATE="102"

    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed package update on 102 (apt)"* ]]
    [[ "$output" == *"0 succeeded, 1 failed, 0 skipped"* ]]
    grep -q "^pct stop 102$" "$MOCK_PCT_CALL_LOG"
}

@test "container that never becomes ready is stopped again and counted as failed" {
    export MOCK_PCT_LIST="103:stopped"
    export MOCK_PCT_FAIL_START="103"

    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Container 103 failed to start"* ]]
    grep -q "^pct stop 103$" "$MOCK_PCT_CALL_LOG"
}

@test "failed autoremove logs a warning but still counts as succeeded" {
    export MOCK_PCT_LIST="106:running"
    export MOCK_PCT_FAIL_AUTOREMOVE="106"

    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Package autoremove failed on 106 (apt) - update/upgrade still succeeded"* ]]
    [[ "$output" == *"Finished container 106"* ]]
    [[ "$output" == *"1 succeeded, 0 failed, 0 skipped"* ]]
}

@test "dry run makes no start/stop/exec calls" {
    export MOCK_PCT_LIST="100:running 101:stopped"

    run "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Dry run"* ]]
    ! grep -q "^pct exec" "$MOCK_PCT_CALL_LOG"
    ! grep -q "^pct start" "$MOCK_PCT_CALL_LOG"
}

@test "-c/--container targets a specific container and ignores the exclude list" {
    export MOCK_PCT_LIST="100:running 105:running"
    echo "105" > "$LXC_UPDATE_EXCLUDE_FILE"

    run "$SCRIPT" -c 105
    [ "$status" -eq 0 ]
    [[ "$output" == *"Finished container 105"* ]]
    [[ "$output" != *"Skipping container 105"* ]]
}

@test "-c accepts a comma-separated list of containers" {
    export MOCK_PCT_LIST="100:running 101:running 105:running"

    run "$SCRIPT" -c 100,105
    [ "$status" -eq 0 ]
    [[ "$output" == *"Finished container 100"* ]]
    [[ "$output" == *"Finished container 105"* ]]
    [[ "$output" != *"container 101"* ]]
}

@test "updates a dnf-based container successfully" {
    export MOCK_PCT_LIST="200:running"
    export MOCK_PCT_PKGMGR="200:dnf"

    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Finished container 200 (dnf)"* ]]
    [[ "$output" == *"1 succeeded, 0 failed, 0 skipped"* ]]
}

@test "updates a yum-based container successfully" {
    export MOCK_PCT_LIST="201:running"
    export MOCK_PCT_PKGMGR="201:yum"

    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Finished container 201 (yum)"* ]]
    [[ "$output" == *"1 succeeded, 0 failed, 0 skipped"* ]]
}

@test "failed dnf upgrade restores stopped state and is counted as failed" {
    export MOCK_PCT_LIST="202:stopped"
    export MOCK_PCT_PKGMGR="202:dnf"
    export MOCK_PCT_FAIL_UPGRADE="202"

    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed package upgrade on 202 (dnf)"* ]]
    [[ "$output" == *"0 succeeded, 1 failed, 0 skipped"* ]]
    grep -q "^pct stop 202$" "$MOCK_PCT_CALL_LOG"
}

@test "failed yum update restores stopped state and is counted as failed" {
    export MOCK_PCT_LIST="203:stopped"
    export MOCK_PCT_PKGMGR="203:yum"
    export MOCK_PCT_FAIL_UPDATE="203"

    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed package update on 203 (yum)"* ]]
    [[ "$output" == *"0 succeeded, 1 failed, 0 skipped"* ]]
    grep -q "^pct stop 203$" "$MOCK_PCT_CALL_LOG"
}

@test "failed dnf autoremove logs a warning but still counts as succeeded" {
    export MOCK_PCT_LIST="204:running"
    export MOCK_PCT_PKGMGR="204:dnf"
    export MOCK_PCT_FAIL_AUTOREMOVE="204"

    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Package autoremove failed on 204 (dnf) - update/upgrade still succeeded"* ]]
    [[ "$output" == *"Finished container 204 (dnf)"* ]]
    [[ "$output" == *"1 succeeded, 0 failed, 0 skipped"* ]]
}

@test "container with no supported package manager is counted as failed" {
    export MOCK_PCT_LIST="205:running"
    export MOCK_PCT_PKGMGR="205:zypper"

    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not detect a supported package manager on 205"* ]]
    [[ "$output" == *"0 succeeded, 1 failed, 0 skipped"* ]]
}
