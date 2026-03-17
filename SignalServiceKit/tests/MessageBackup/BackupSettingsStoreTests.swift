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

    override func setUp() {
        super.setUp()
        db = InMemoryDB()
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
}

// MARK: -

private extension BackupSettingsStore {
    func setLastBackupDetails(_ date: Date, tx: DBWriteTransaction) {
        setLastBackupDetails(date: date, backupFileSizeBytes: 1, backupMediaSizeBytes: 1, tx: tx)
    }
}
