# Chat Archive V2 Rollout and Kill-Switch Playbook

## Rollout Stages

1. Internal Only (0% external): Enable in internal builds for smoke checks.
2. Canary (1-5%): Enable by deterministic bucket with monitoring.
3. Limited (10-25%): Expand if crash/latency/error budgets remain green.
4. Broad (50-100%): Complete rollout once all gates pass.

## Runtime Gates

- Compile-time gate: `BuildFlags.ChatArchive.storageLayerV2`
- Runtime toggle: `DebugFlags.chatArchiveStorageV2`
- Kill switch: `ChatArchiveRolloutController(killSwitchEnabled: true)`

## Monitoring Checklist

- Archive load failures by reason
- Decrypt/decompress latency distribution
- Scroll hitching/frame drops near archived boundaries
- Archive job success/failure trend and retry counts

## Kill-Switch Procedure

1. Set kill switch to ON.
2. Verify `isFeatureEnabled(deviceBucket:)` returns false for all buckets.
3. Confirm no new archive jobs start.
4. Confirm timeline loader remains on hot storage fallback.
5. Record incident timeline and rollback owner.

## Validation

- Stage-specific toggles validated in tests.
- Kill-switch path validated in tests.
- Rollout bucket logic deterministic by device bucket.
