#!/bin/bash
# Two-simulator E2E for the CKShare group-share flow.
#
# Owner sim (SplitFree-CloudA) creates a group and copies its invite link;
# participant sim (SplitFree-CloudB, a DIFFERENT iCloud account) accepts it
# through the app's DEBUG --accept-share-url hook and adds an expense; the
# owner then sees that expense. Both simulators must already exist and be
# signed into iCloud (one-time manual setup in Settings; 2FA needs a real
# account — an owner can't accept their own share, so the accounts must
# differ).
#
# Usage: Scripts/share-e2e.sh [group-name]
set -euo pipefail
cd "$(dirname "$0")/.."

SIM_A_NAME="SplitFree-CloudA" # owner
SIM_B_NAME="SplitFree-CloudB" # participant
GROUP="${1:-ShareE2E $(date +%m%d-%H%M%S)}"
DERIVED=build/DerivedData
XCB=(xcodebuild -project SplitFree.xcodeproj -scheme SplitFree -derivedDataPath "$DERIVED")

udid() {
    xcrun simctl list devices | grep "    $1 (" | grep -oE '[0-9A-F]{8}-[0-9A-F-]{27}' | head -1
}
A=$(udid "$SIM_A_NAME"); B=$(udid "$SIM_B_NAME")
[[ -n "$A" && -n "$B" ]] || { echo "Missing simulator(s): $SIM_A_NAME / $SIM_B_NAME"; exit 1; }

echo "=== Booting $SIM_A_NAME ($A) and $SIM_B_NAME ($B)"
xcrun simctl boot "$A" 2>/dev/null || true
xcrun simctl boot "$B" 2>/dev/null || true
xcrun simctl bootstatus "$A"
xcrun simctl bootstatus "$B"

echo "=== Building (once — both sims share the artifact)"
xcodegen generate --quiet
"${XCB[@]}" build-for-testing -destination "id=$A" -quiet

# Periodically nudges CloudKit on a sim while a test polls for synced data.
# icloud_sync fails silently on unsupported runtimes; relaunch-driven imports
# in the tests are the real fallback.
nudge() {
    while true; do sleep 10; xcrun simctl icloud_sync "$1" >/dev/null 2>&1 || true; done
}

run_test() { # udid test-name [ENV=val...]
    local dest="$1" test="$2"; shift 2
    env "$@" "${XCB[@]}" test-without-building -destination "id=$dest" \
        -only-testing:"SplitFreeUITests/ShareE2ETests/$test" -quiet
}

echo "=== [1/5] Owner creates '$GROUP' and copies the invite link"
run_test "$A" testOwnerCreatesGroupAndCopiesInviteLink "TEST_RUNNER_E2E_GROUP=$GROUP"

URL=$(xcrun simctl pbpaste "$A" 2>/dev/null || true)
if [[ "$URL" != https://www.icloud.com/share/* ]]; then
    # Pasteboard can be clobbered by host sync; the app logs the URL too.
    URL=$(xcrun simctl spawn "$A" log show --last 10m \
            --predicate 'subsystem == "com.sank.splitfree"' 2>/dev/null \
          | grep -oE 'https://www\.icloud\.com/share/[A-Za-z0-9#_-]+' | tail -1 || true)
fi
[[ "$URL" == https://www.icloud.com/share/* ]] || { echo "FAIL: no invite URL (got: '$URL')"; exit 1; }
echo "    invite: $URL"

echo "=== [2/5] Participant accepts the invite and adds an expense"
nudge "$B" & NUDGE_PID=$!
trap 'kill $NUDGE_PID 2>/dev/null || true' EXIT
run_test "$B" testParticipantJoinsAndAddsExpense \
    "TEST_RUNNER_E2E_GROUP=$GROUP" "TEST_RUNNER_E2E_SHARE_URL=$URL"
kill $NUDGE_PID 2>/dev/null || true

echo "=== [3/5] Owner sees the participant's expense"
nudge "$A" & NUDGE_PID=$!
run_test "$A" testOwnerSeesParticipantExpense "TEST_RUNNER_E2E_GROUP=$GROUP"
kill $NUDGE_PID 2>/dev/null || true

echo "=== [4/5] Participant leaves the group (delete-as-leave)"
run_test "$B" testParticipantLeavesGroup "TEST_RUNNER_E2E_GROUP=$GROUP"

echo "=== [5/5] Owner keeps the data, then deletes for everyone (cleanup)"
nudge "$A" & NUDGE_PID=$!
run_test "$A" testOwnerKeepsDataThenDeletes "TEST_RUNNER_E2E_GROUP=$GROUP"
kill $NUDGE_PID 2>/dev/null || true
trap - EXIT

echo "PASS: create -> invite -> accept -> two-way sync -> leave -> delete all green ('$GROUP')"
