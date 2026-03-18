//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import XCTest

@testable import SignalServiceKit

class BackupSettingsStoreTests: XCTestCase {
    private var db: InMemoryDB!
    private var backupSettingsStore = BackupSettingsStore()
    private var tempDirectoryURL: URL!

    override func setUp() {
        super.setUp()
        db = InMemoryDB()
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatArchiveTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        super.tearDown()
    }

    func testLastAndFirstBackupDate() throws {
        var lastBackupDetails = db.read { tx in
            backupSettingsStore.lastBackupDetails(tx: tx)
        }
        XCTAssertNil(lastBackupDetails, "Last backup should not be set")

        lastBackupDetails = db.write { tx in
            backupSettingsStore.setLastBackupDetails(Date(), tx: tx)
            return backupSettingsStore.lastBackupDetails(tx: tx)
        }
        XCTAssertNotNil(lastBackupDetails, "Last backup should be set")
        XCTAssertEqual(lastBackupDetails!.date, lastBackupDetails!.firstBackupDate, "First and last backups should be the same")

        lastBackupDetails = db.write { tx in
            backupSettingsStore.setLastBackupDetails(Date(), tx: tx)
            return backupSettingsStore.lastBackupDetails(tx: tx)
        }
        XCTAssertTrue(lastBackupDetails!.firstBackupDate < lastBackupDetails!.date, "First backup should not update after it is first set")
    }

    func testBackupUpdatesRefreshDate() throws {
        var lastBackupRefresh = db.read { tx in
            CronStore(uniqueKey: .refreshBackup).mostRecentDate(tx: tx)
        }
        XCTAssertEqual(lastBackupRefresh, .distantPast, "Last backup should not be set")

        db.write { tx in
            backupSettingsStore.setLastBackupDetails(Date(), tx: tx)
        }

        lastBackupRefresh = db.read { tx in
            CronStore(uniqueKey: .refreshBackup).mostRecentDate(tx: tx)
        }
        XCTAssertNotEqual(lastBackupRefresh, .distantPast, "Last backup should be set")
    }

    func testArchiveChunkContractRoundTrip() throws {
        let value = ArchiveChunk(
            chunkId: "thread123_2024_01",
            threadId: "thread123",
            startTimestampMs: 1_704_067_200_000,
            endTimestampMs: 1_706_745_599_000,
            messageCount: 1000,
        )

        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ArchiveChunk.self, from: encoded)

        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.schemaVersion, ArchiveChunk.currentSchemaVersion)
    }

    func testArchiveIndexEntryContractRoundTrip() throws {
        let value = ArchiveIndexEntry(
            threadId: "thread123",
            chunkId: "thread123_2024_01",
            startTimestampMs: 1_704_067_200_000,
            endTimestampMs: 1_706_745_599_000,
        )

        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ArchiveIndexEntry.self, from: encoded)

        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.schemaVersion, ArchiveIndexEntry.currentSchemaVersion)
    }

    func testArchiveStorageEnvelopeContractRoundTrip() throws {
        let chunk = ArchiveChunk(
            chunkId: "thread123_2024_01",
            threadId: "thread123",
            startTimestampMs: 1_704_067_200_000,
            endTimestampMs: 1_706_745_599_000,
            messageCount: 1000,
        )
        let value = ArchiveStorageEnvelope(chunk: chunk, encryptedPayload: Data([0x01, 0x02, 0x03]))

        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ArchiveStorageEnvelope.self, from: encoded)

        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.schemaVersion, ArchiveStorageEnvelope.currentSchemaVersion)
    }

    func testChatArchiveManagerSkeletonArchiveMethod() async {
        let manager: ChatArchiveManager = ChatArchiveManagerImpl()

        do {
            try await manager.archiveOldMessages(threadId: "thread123")
            XCTFail("Expected unimplemented error")
        } catch let error as ChatArchiveManagerError {
            XCTAssertEqual(error, .unimplemented)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testChatArchiveManagerSkeletonLoadMethod() async {
        let manager: ChatArchiveManager = ChatArchiveManagerImpl()

        do {
            _ = try await manager.loadArchivedChunk(chunkId: "thread123_2024_01")
            XCTFail("Expected unimplemented error")
        } catch let error as ChatArchiveManagerError {
            XCTAssertEqual(error, .unimplemented)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMonthlyChunkPlannerGroupsByMonthDeterministically() {
        let planner = MonthlyChatArchiveChunkPlanner()
        let messages = [
            ArchiveSourceMessage(messageId: "b", timestampMs: 1_704_067_200_000), // 2024-01-01
            ArchiveSourceMessage(messageId: "a", timestampMs: 1_704_067_200_000), // same ts; sorted by id
            ArchiveSourceMessage(messageId: "c", timestampMs: 1_706_745_600_000), // 2024-02-01
        ]

        let chunks = planner.planChunks(threadId: "thread123", messages: messages, maxMessagesPerChunk: nil)

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].chunkId, "thread123_2024_01")
        XCTAssertEqual(chunks[0].messageCount, 2)
        XCTAssertEqual(chunks[1].chunkId, "thread123_2024_02")
        XCTAssertEqual(chunks[1].messageCount, 1)
    }

    func testMonthlyChunkPlannerSplitsByMessageLimit() {
        let planner = MonthlyChatArchiveChunkPlanner()
        let messages = [
            ArchiveSourceMessage(messageId: "m1", timestampMs: 1_704_067_200_000),
            ArchiveSourceMessage(messageId: "m2", timestampMs: 1_704_067_201_000),
            ArchiveSourceMessage(messageId: "m3", timestampMs: 1_704_067_202_000),
        ]

        let chunks = planner.planChunks(threadId: "thread123", messages: messages, maxMessagesPerChunk: 2)

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].chunkId, "thread123_2024_01")
        XCTAssertEqual(chunks[0].messageCount, 2)
        XCTAssertEqual(chunks[1].chunkId, "thread123_2024_01_2")
        XCTAssertEqual(chunks[1].messageCount, 1)
    }

    func testCompressionAdapterRoundTrip() throws {
        let adapter = ZstdChatArchiveCompressionAdapter()
        let payload = Data(repeating: 0x41, count: 64 * 1024)

        let compressed = try adapter.compress(data: payload, level: 3)
        let decompressed = try adapter.decompress(data: compressed)

        XCTAssertEqual(decompressed, payload)
        XCTAssertLessThan(compressed.count, payload.count)
    }

    func testCompressionAdapterCorruptionFailsDecompression() throws {
        let adapter = ZstdChatArchiveCompressionAdapter()
        let payload = Data(repeating: 0x42, count: 32 * 1024)
        let compressed = try adapter.compress(data: payload, level: 3)
        let corrupted = compressed.prefix(max(1, compressed.count / 4))

        XCTAssertThrowsError(try adapter.decompress(data: Data(corrupted)))
    }

    func testCompressionAdapterBenchmarkProducesMetrics() {
        let adapter = ZstdChatArchiveCompressionAdapter()
        let payloads = [
            Data(repeating: 0x41, count: 8 * 1024),
            Data(repeating: 0x42, count: 32 * 1024),
        ]

        let results = adapter.benchmark(payloads: payloads, level: 3)

        XCTAssertEqual(results.count, payloads.count)
        XCTAssertTrue(results.allSatisfy { $0.originalBytes > 0 })
        XCTAssertTrue(results.allSatisfy { $0.compressedBytes > 0 })
    }

    func testArchiveEncryptionRoundTrip() throws {
        let encryptor = AESGCMChatArchiveEncryption()
        let keyProvider = DeterministicChatArchiveKeyProvider(rootKeyMaterial: Data(repeating: 0xAA, count: 32))
        let key = keyProvider.archiveKey(for: "thread123_2024_01")
        let payload = Data("hello archive".utf8)

        let ciphertext = try encryptor.encrypt(payload, key: key)
        let plaintext = try encryptor.decrypt(ciphertext, key: key)

        XCTAssertEqual(plaintext, payload)
    }

    func testArchiveEncryptionUsesFreshNoncePerEncryption() throws {
        let encryptor = AESGCMChatArchiveEncryption()
        let keyProvider = DeterministicChatArchiveKeyProvider(rootKeyMaterial: Data(repeating: 0xAB, count: 32))
        let key = keyProvider.archiveKey(for: "thread123_2024_01")
        let payload = Data("same payload".utf8)

        let c1 = try encryptor.encrypt(payload, key: key)
        let c2 = try encryptor.encrypt(payload, key: key)

        XCTAssertNotEqual(c1, c2)
    }

    func testArchiveEncryptionFailsWithWrongKey() throws {
        let encryptor = AESGCMChatArchiveEncryption()
        let keyProvider = DeterministicChatArchiveKeyProvider(rootKeyMaterial: Data(repeating: 0xAC, count: 32))
        let wrongKeyProvider = DeterministicChatArchiveKeyProvider(rootKeyMaterial: Data(repeating: 0xAD, count: 32))

        let key = keyProvider.archiveKey(for: "thread123_2024_01")
        let wrongKey = wrongKeyProvider.archiveKey(for: "thread123_2024_01")
        let payload = Data("secret payload".utf8)

        let ciphertext = try encryptor.encrypt(payload, key: key)

        XCTAssertThrowsError(try encryptor.decrypt(ciphertext, key: wrongKey))
    }

    func testFileSystemRepositoryWriteReadDeleteFlow() throws {
        let repository = FileSystemChatArchiveRepository(rootURL: tempDirectoryURL)
        let payload = Data([0x01, 0x02, 0x03])

        try repository.writeArchive(threadId: "thread123", chunkId: "thread123_2024_01", encryptedPayload: payload, overwrite: false)
        let loaded = try repository.readArchive(threadId: "thread123", chunkId: "thread123_2024_01")
        XCTAssertEqual(loaded, payload)

        try repository.deleteArchive(threadId: "thread123", chunkId: "thread123_2024_01")
        XCTAssertThrowsError(try repository.readArchive(threadId: "thread123", chunkId: "thread123_2024_01"))
    }

    func testFileSystemRepositoryRejectsOverwriteByDefault() throws {
        let repository = FileSystemChatArchiveRepository(rootURL: tempDirectoryURL)
        let payload = Data([0xAA])

        try repository.writeArchive(threadId: "thread123", chunkId: "thread123_2024_01", encryptedPayload: payload, overwrite: false)

        XCTAssertThrowsError(
            try repository.writeArchive(threadId: "thread123", chunkId: "thread123_2024_01", encryptedPayload: payload, overwrite: false)
        )
    }

    func testFileSystemRepositoryDetectsCorruptArchive() throws {
        let repository = FileSystemChatArchiveRepository(rootURL: tempDirectoryURL)
        let fileURL = repository.archiveURL(threadId: "thread123", chunkId: "thread123_2024_01")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: fileURL)

        XCTAssertThrowsError(try repository.readArchive(threadId: "thread123", chunkId: "thread123_2024_01"))
    }

    func testArchiveIndexStoreInsertQueryDeleteFlow() {
        let store = InMemoryChatArchiveIndexStore()
        let jan = ArchiveIndexEntry(
            threadId: "thread123",
            chunkId: "thread123_2024_01",
            startTimestampMs: 1_704_067_200_000,
            endTimestampMs: 1_706_745_599_000,
        )
        let feb = ArchiveIndexEntry(
            threadId: "thread123",
            chunkId: "thread123_2024_02",
            startTimestampMs: 1_706_745_600_000,
            endTimestampMs: 1_709_251_199_000,
        )

        store.insert(jan)
        store.insert(feb)

        let januaryOnly = store.query(
            threadId: "thread123",
            from: 1_704_067_200_000,
            to: 1_706_745_599_000
        )
        XCTAssertEqual(januaryOnly.map(\.chunkId), ["thread123_2024_01"])

        store.delete(threadId: "thread123", chunkId: "thread123_2024_01")
        let afterDelete = store.query(
            threadId: "thread123",
            from: 1_704_067_200_000,
            to: 1_709_251_199_000
        )
        XCTAssertEqual(afterDelete.map(\.chunkId), ["thread123_2024_02"])
    }

    func testArchiveIndexMigrationSqlContainsExpectedArtifacts() {
        XCTAssertTrue(ChatArchiveIndexMigration.createTableSQL.contains("archive_index"))
        XCTAssertTrue(ChatArchiveIndexMigration.createTableSQL.contains("thread_id"))
        XCTAssertTrue(ChatArchiveIndexMigration.createRangeLookupIndexSQL.contains("archive_index_thread_range"))
    }

    func testArchivalTransactionSuccessPath() throws {
        let indexStore = InMemoryChatArchiveIndexStore()
        let repository = FileSystemChatArchiveRepository(rootURL: tempDirectoryURL)
        let manager = ChatArchiveManagerImpl(
            repository: repository,
            indexStore: indexStore,
        )
        let messages = [
            ArchiveSourceMessage(messageId: "m1", timestampMs: 1_704_067_200_000),
            ArchiveSourceMessage(messageId: "m2", timestampMs: 1_704_067_201_000),
        ]

        var deleteCalled = false
        try manager.archivePreparedMessages(threadId: "thread123", messages: messages) {
            deleteCalled = true
        }

        XCTAssertTrue(deleteCalled)
        let indexed = indexStore.query(
            threadId: "thread123",
            from: 1_704_067_200_000,
            to: 1_704_067_201_000
        )
        XCTAssertEqual(indexed.count, 1)
    }

    func testArchivalTransactionRollsBackOnDeleteFailure() {
        let indexStore = InMemoryChatArchiveIndexStore()
        let repository = FileSystemChatArchiveRepository(rootURL: tempDirectoryURL)
        let manager = ChatArchiveManagerImpl(
            repository: repository,
            indexStore: indexStore,
        )
        let messages = [
            ArchiveSourceMessage(messageId: "m1", timestampMs: 1_704_067_200_000),
            ArchiveSourceMessage(messageId: "m2", timestampMs: 1_704_067_201_000),
        ]

        XCTAssertThrowsError(
            try manager.archivePreparedMessages(threadId: "thread123", messages: messages) {
                throw NSError(domain: "test", code: 1)
            }
        )

        let indexed = indexStore.query(
            threadId: "thread123",
            from: 1_704_067_200_000,
            to: 1_704_067_201_000
        )
        XCTAssertEqual(indexed.count, 0)
    }

    func testArchivalTransactionIsIdempotentOnRetry() throws {
        let indexStore = InMemoryChatArchiveIndexStore()
        let repository = FileSystemChatArchiveRepository(rootURL: tempDirectoryURL)
        let manager = ChatArchiveManagerImpl(
            repository: repository,
            indexStore: indexStore,
        )
        let messages = [
            ArchiveSourceMessage(messageId: "m1", timestampMs: 1_704_067_200_000),
            ArchiveSourceMessage(messageId: "m2", timestampMs: 1_704_067_201_000),
        ]

        try manager.archivePreparedMessages(threadId: "thread123", messages: messages) {}
        try manager.archivePreparedMessages(threadId: "thread123", messages: messages) {}

        let indexed = indexStore.query(
            threadId: "thread123",
            from: 1_704_067_200_000,
            to: 1_704_067_201_000
        )
        XCTAssertEqual(indexed.count, 1)
    }

    func testArchiveGapDetectorFindsMissingRanges() {
        let detector = ArchiveGapDetector()
        let requested = ArchiveRange(startTimestampMs: 10, endTimestampMs: 30)
        let available = [
            ArchiveRange(startTimestampMs: 10, endTimestampMs: 14),
            ArchiveRange(startTimestampMs: 20, endTimestampMs: 24),
        ]

        let gaps = detector.detectGaps(threadId: "thread123", requestedRange: requested, availableRanges: available)
        XCTAssertEqual(
            gaps,
            [
                ArchiveRange(startTimestampMs: 15, endTimestampMs: 19),
                ArchiveRange(startTimestampMs: 25, endTimestampMs: 30),
            ]
        )
    }

    func testArchiveGapDetectorEmitsRangeOnce() {
        let detector = ArchiveGapDetector()
        let requested = ArchiveRange(startTimestampMs: 100, endTimestampMs: 120)

        let first = detector.emitNewGaps(threadId: "thread123", requestedRange: requested, availableRanges: [])
        let second = detector.emitNewGaps(threadId: "thread123", requestedRange: requested, availableRanges: [])

        XCTAssertEqual(first, [ArchiveRange(startTimestampMs: 100, endTimestampMs: 120)])
        XCTAssertEqual(second, [])
    }

    func testAsyncLoaderRoundTrip() async throws {
        let repository = FileSystemChatArchiveRepository(rootURL: tempDirectoryURL)
        let encryption = AESGCMChatArchiveEncryption()
        let compression = ZstdChatArchiveCompressionAdapter()
        let keyProvider = DeterministicChatArchiveKeyProvider(rootKeyMaterial: Data(repeating: 0x21, count: 32))

        let chunk = ArchiveChunk(
            chunkId: "thread123_2024_01",
            threadId: "thread123",
            startTimestampMs: 1_704_067_200_000,
            endTimestampMs: 1_706_745_599_000,
            messageCount: 100
        )
        let serialized = try JSONEncoder().encode(chunk)
        let compressed = try compression.compress(data: serialized, level: 3)
        let encrypted = try encryption.encrypt(compressed, key: keyProvider.archiveKey(for: chunk.chunkId))
        try repository.writeArchive(threadId: "thread123", chunkId: chunk.chunkId, encryptedPayload: encrypted, overwrite: false)

        let loader = ChatArchiveAsyncLoader(
            repository: repository,
            encryption: encryption,
            compression: compression,
            keyProvider: keyProvider,
        )

        let loaded = try await loader.loadChunk(threadId: "thread123", chunkId: chunk.chunkId)
        XCTAssertEqual(loaded, chunk)
    }

    func testAsyncLoaderFailsWithWrongKey() async throws {
        let repository = FileSystemChatArchiveRepository(rootURL: tempDirectoryURL)
        let encryption = AESGCMChatArchiveEncryption()
        let compression = ZstdChatArchiveCompressionAdapter()
        let goodKeyProvider = DeterministicChatArchiveKeyProvider(rootKeyMaterial: Data(repeating: 0x22, count: 32))
        let wrongKeyProvider = DeterministicChatArchiveKeyProvider(rootKeyMaterial: Data(repeating: 0x23, count: 32))

        let chunk = ArchiveChunk(
            chunkId: "thread123_2024_01",
            threadId: "thread123",
            startTimestampMs: 1_704_067_200_000,
            endTimestampMs: 1_706_745_599_000,
            messageCount: 100
        )
        let serialized = try JSONEncoder().encode(chunk)
        let compressed = try compression.compress(data: serialized, level: 3)
        let encrypted = try encryption.encrypt(compressed, key: goodKeyProvider.archiveKey(for: chunk.chunkId))
        try repository.writeArchive(threadId: "thread123", chunkId: chunk.chunkId, encryptedPayload: encrypted, overwrite: false)

        let loader = ChatArchiveAsyncLoader(
            repository: repository,
            encryption: encryption,
            compression: compression,
            keyProvider: wrongKeyProvider,
        )

        do {
            _ = try await loader.loadChunk(threadId: "thread123", chunkId: chunk.chunkId)
            XCTFail("Expected loader to fail with wrong key")
        } catch {
            XCTAssertTrue(true)
        }
    }

    func testAsyncLoaderHonorsCancellation() async throws {
        let repository = FileSystemChatArchiveRepository(rootURL: tempDirectoryURL)
        let loader = ChatArchiveAsyncLoader(
            repository: repository,
            encryption: AESGCMChatArchiveEncryption(),
            compression: ZstdChatArchiveCompressionAdapter(),
            keyProvider: DeterministicChatArchiveKeyProvider(rootKeyMaterial: Data(repeating: 0x24, count: 32)),
        )

        let task = Task {
            try await loader.loadChunk(threadId: "thread123", chunkId: "thread123_2024_01")
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(true)
        }
    }

    func testTimelineMergerOrdersMessagesChronologically() {
        let merger = ChatArchiveTimelineMerger()
        let archived = [
            ArchiveSourceMessage(messageId: "a1", timestampMs: 1000),
            ArchiveSourceMessage(messageId: "a2", timestampMs: 1500),
        ]
        let hot = [
            ArchiveSourceMessage(messageId: "h1", timestampMs: 1200),
            ArchiveSourceMessage(messageId: "h2", timestampMs: 1800),
        ]

        let merged = merger.merge(hotMessages: hot, archivedMessages: archived)

        XCTAssertEqual(merged.map(\.messageId), ["a1", "h1", "a2", "h2"])
    }

    func testTimelineMergerDeduplicatesByMessageIdPreferringHotMessage() {
        let merger = ChatArchiveTimelineMerger()
        let archived = [
            ArchiveSourceMessage(messageId: "shared", timestampMs: 1000),
            ArchiveSourceMessage(messageId: "archivedOnly", timestampMs: 900),
        ]
        let hot = [
            ArchiveSourceMessage(messageId: "shared", timestampMs: 1100),
            ArchiveSourceMessage(messageId: "hotOnly", timestampMs: 1200),
        ]

        let merged = merger.merge(hotMessages: hot, archivedMessages: archived)

        XCTAssertEqual(merged.map(\.messageId), ["archivedOnly", "shared", "hotOnly"])
        XCTAssertEqual(merged.first(where: { $0.messageId == "shared" })?.timestampMs, 1100)
    }

    func testSchedulerSkipsWhenNotEligible() async {
        let scheduler = ChatArchiveBackgroundScheduler()

        let notIdle = await scheduler.canRun(
            conditions: ChatArchiveSchedulerConditions(isAppIdle: false, isCharging: true, isLowCpuUsage: true)
        )
        XCTAssertEqual(notIdle, .skipped(.appNotIdle))

        let notCharging = await scheduler.canRun(
            conditions: ChatArchiveSchedulerConditions(isAppIdle: true, isCharging: false, isLowCpuUsage: true)
        )
        XCTAssertEqual(notCharging, .skipped(.notCharging))

        let highCpu = await scheduler.canRun(
            conditions: ChatArchiveSchedulerConditions(isAppIdle: true, isCharging: true, isLowCpuUsage: false)
        )
        XCTAssertEqual(highCpu, .skipped(.cpuTooBusy))
    }

    func testSchedulerRunsWhenEligibleAndRecordsTelemetry() async throws {
        let scheduler = ChatArchiveBackgroundScheduler()
        var didRun = false

        let result = try await scheduler.runIfEligible(
            conditions: ChatArchiveSchedulerConditions(isAppIdle: true, isCharging: true, isLowCpuUsage: true),
            job: {
                didRun = true
            }
        )

        XCTAssertEqual(result, .started)
        XCTAssertTrue(didRun)

        let telemetry = await scheduler.telemetry
        XCTAssertNotNil(telemetry.lastRunStartAt)
        XCTAssertNotNil(telemetry.lastRunFinishAt)
        XCTAssertEqual(telemetry.lastResult, .started)
    }

    func testSchedulerAbortFlow() async throws {
        let scheduler = ChatArchiveBackgroundScheduler()
        await scheduler.requestAbort()

        let result = try await scheduler.runIfEligible(
            conditions: ChatArchiveSchedulerConditions(isAppIdle: true, isCharging: true, isLowCpuUsage: true),
            job: {
                XCTFail("Job should not run when scheduler abort is requested")
            }
        )

        XCTAssertEqual(result, .aborted)
        let telemetry = await scheduler.telemetry
        XCTAssertEqual(telemetry.lastResult, .aborted)
    }

    func testThrottleLimitPerWindowIsEnforced() async {
        let policy = ChatArchiveThrottlePolicy(
            maxRunsPerWindow: 1,
            windowDuration: 60,
            baseBackoff: 1,
            maxBackoff: 8,
        )
        let store = ChatArchiveRunThrottleStore(policy: policy)

        XCTAssertTrue(await store.shouldAllowRun(now: Date(timeIntervalSince1970: 100)))
        await store.registerRunStart(now: Date(timeIntervalSince1970: 100))
        XCTAssertFalse(await store.shouldAllowRun(now: Date(timeIntervalSince1970: 101)))
    }

    func testExponentialBackoffIncreasesOnRepeatedFailures() async {
        let policy = ChatArchiveThrottlePolicy(
            maxRunsPerWindow: 10,
            windowDuration: 60,
            baseBackoff: 1,
            maxBackoff: 8,
        )
        let store = ChatArchiveRunThrottleStore(policy: policy)

        await store.registerFailure(reason: "error1", now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(await store.retryCount, 1)
        XCTAssertFalse(await store.shouldAllowRun(now: Date(timeIntervalSince1970: 100.5)))
        XCTAssertTrue(await store.shouldAllowRun(now: Date(timeIntervalSince1970: 101.1)))

        await store.registerFailure(reason: "error2", now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(await store.retryCount, 2)
        XCTAssertFalse(await store.shouldAllowRun(now: Date(timeIntervalSince1970: 201.5)))
        XCTAssertTrue(await store.shouldAllowRun(now: Date(timeIntervalSince1970: 202.1)))
    }

    func testSchedulerRecordsRetryCountAndFailureReason() async {
        let scheduler = ChatArchiveBackgroundScheduler(
            throttleStore: ChatArchiveRunThrottleStore(
                policy: ChatArchiveThrottlePolicy(
                    maxRunsPerWindow: 10,
                    windowDuration: 60,
                    baseBackoff: 1,
                    maxBackoff: 8,
                )
            )
        )

        do {
            _ = try await scheduler.runIfEligible(
                conditions: ChatArchiveSchedulerConditions(isAppIdle: true, isCharging: true, isLowCpuUsage: true),
                job: {
                    throw NSError(domain: "archive", code: 42)
                }
            )
            XCTFail("Expected failure")
        } catch {
            let telemetry = await scheduler.telemetry
            XCTAssertEqual(telemetry.retryCount, 1)
            XCTAssertNotNil(telemetry.lastFailureReason)
        }
    }

    func testArchiveRestoreParityEndToEnd() throws {
        let keyProvider = DeterministicChatArchiveKeyProvider(rootKeyMaterial: Data(repeating: 0x31, count: 32))
        let harness = ChatArchiveParityHarness(keyProvider: keyProvider)

        let messages = [
            ArchiveSourceMessage(messageId: "m1", timestampMs: 1_704_067_200_000, text: "hello"),
            ArchiveSourceMessage(messageId: "m2", timestampMs: 1_704_067_201_000, text: "world"),
            ArchiveSourceMessage(messageId: "m3", timestampMs: 1_706_745_600_000, text: "from feb"),
        ]

        let archived = try harness.archive(threadId: "thread123", messages: messages, maxMessagesPerChunk: 2)
        let restored = try harness.restore(archivedPayloadsByChunkId: archived)

        XCTAssertEqual(restored, messages)
    }

    func testArchiveRestoreParityAcrossBoundaries() throws {
        let keyProvider = DeterministicChatArchiveKeyProvider(rootKeyMaterial: Data(repeating: 0x32, count: 32))
        let harness = ChatArchiveParityHarness(keyProvider: keyProvider)

        let messages = [
            ArchiveSourceMessage(messageId: "jan-end", timestampMs: 1_706_745_599_000, text: "jan"),
            ArchiveSourceMessage(messageId: "feb-start", timestampMs: 1_706_745_600_000, text: "feb"),
        ]

        let archived = try harness.archive(threadId: "thread123", messages: messages, maxMessagesPerChunk: nil)
        let restored = try harness.restore(archivedPayloadsByChunkId: archived)

        XCTAssertEqual(restored, messages)
    }

    func testArchiveRestoreFailsWithWrongKey() throws {
        let goodProvider = DeterministicChatArchiveKeyProvider(rootKeyMaterial: Data(repeating: 0x33, count: 32))
        let badProvider = DeterministicChatArchiveKeyProvider(rootKeyMaterial: Data(repeating: 0x34, count: 32))
        let goodHarness = ChatArchiveParityHarness(keyProvider: goodProvider)
        let badHarness = ChatArchiveParityHarness(keyProvider: badProvider)

        let messages = [
            ArchiveSourceMessage(messageId: "m1", timestampMs: 1_704_067_200_000, text: "secret")
        ]

        let archived = try goodHarness.archive(threadId: "thread123", messages: messages, maxMessagesPerChunk: nil)

        XCTAssertThrowsError(try badHarness.restore(archivedPayloadsByChunkId: archived))
    }

    func testBenchmarkSuiteProducesMetrics() throws {
        let suite = ChatArchiveBenchmarkSuite()
        let messages = [
            ArchiveSourceMessage(messageId: "m1", timestampMs: 1_704_067_200_000, text: "hello"),
            ArchiveSourceMessage(messageId: "m2", timestampMs: 1_704_067_201_000, text: "world"),
            ArchiveSourceMessage(messageId: "m3", timestampMs: 1_706_745_600_000, text: "more data"),
        ]

        let report = try suite.run(threadId: "thread123", messages: messages, maxMessagesPerChunk: 2)

        XCTAssertFalse(report.metrics.isEmpty)
        XCTAssertTrue(report.metrics.allSatisfy { $0.originalBytes > 0 })
        XCTAssertTrue(report.metrics.allSatisfy { $0.compressedBytes > 0 })
    }

    func testBenchmarkReportFormats() {
        let report = ChatArchiveBenchmarkReport(metrics: [
            ChatArchivePerformanceMetric(
                chunkId: "thread123_2024_01",
                originalBytes: 1000,
                compressedBytes: 500,
                compressionRatio: 0.5,
                decompressDurationMs: 12.3,
            )
        ])

        let markdown = report.toMarkdown()
        let csv = report.toCSV()

        XCTAssertTrue(markdown.contains("chunk_id"))
        XCTAssertTrue(markdown.contains("thread123_2024_01"))
        XCTAssertTrue(csv.contains("chunk_id,original_bytes,compressed_bytes"))
        XCTAssertTrue(csv.contains("thread123_2024_01,1000,500"))
    }

    func testSecurityValidatorDetectsNoPlaintextLeakageForEncryptedPayload() throws {
        let encryptor = AESGCMChatArchiveEncryption()
        let key = DeterministicChatArchiveKeyProvider(rootKeyMaterial: Data(repeating: 0x41, count: 32))
            .archiveKey(for: "thread123_2024_01")
        let plaintext = Data("super_secret_message_payload".utf8)
        let encrypted = try encryptor.encrypt(plaintext, key: key)

        let validator = ChatArchiveSecurityValidator()
        let leaked = validator.containsKnownPlaintext(
            encryptedBlob: encrypted,
            knownTokens: ["super_secret_message_payload", "secret_message"]
        )

        XCTAssertFalse(leaked)
    }

    func testSecurityChecklistCompletion() throws {
        let encryptor = AESGCMChatArchiveEncryption()
        let key = DeterministicChatArchiveKeyProvider(rootKeyMaterial: Data(repeating: 0x42, count: 32))
            .archiveKey(for: "thread123_2024_01")
        let encrypted = try encryptor.encrypt(Data("hello".utf8), key: key)

        let checklist = ChatArchiveSecurityValidator().validateChecklist(
            encryptedBlob: encrypted,
            knownTokens: ["hello"],
            keyScopeValidated: true,
            wrongKeyBehaviorValidated: true,
        )

        XCTAssertTrue(checklist.noPlaintextAtRest)
        XCTAssertTrue(checklist.isComplete)
    }
}

// MARK: -

private extension BackupSettingsStore {
    func setLastBackupDetails(_ date: Date, tx: DBWriteTransaction) {
        setLastBackupDetails(date: date, backupFileSizeBytes: 1, backupMediaSizeBytes: 1, tx: tx)
    }
}
