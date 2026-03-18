//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Compression
import CryptoKit
public import LibSignalClient

public enum BackupRestoreState: Int, Codable {
    /// Has never restored from a backup in this database's history
    case none = 0
    /// Finished restoring a backup but still has post-restore steps to complete.
    case unfinalized = 100
    /// Backup restore is complete, nothing else to do.
    case finalized = 200
}

public struct BackupCdnInfo {
    public let fileInfo: AttachmentDownloads.CdnInfo
    public let metadataHeader: BackupNonce.MetadataHeader
}

// MARK: - Chat Archive V2 Contracts

public struct ArchiveChunk: Codable, Equatable {
    public static let currentSchemaVersion: UInt8 = 1

    public let schemaVersion: UInt8
    public let chunkId: String
    public let threadId: String
    public let startTimestampMs: UInt64
    public let endTimestampMs: UInt64
    public let messageCount: UInt32

    public init(
        chunkId: String,
        threadId: String,
        startTimestampMs: UInt64,
        endTimestampMs: UInt64,
        messageCount: UInt32,
        schemaVersion: UInt8 = ArchiveChunk.currentSchemaVersion,
    ) {
        self.schemaVersion = schemaVersion
        self.chunkId = chunkId
        self.threadId = threadId
        self.startTimestampMs = startTimestampMs
        self.endTimestampMs = endTimestampMs
        self.messageCount = messageCount
    }
}

public struct ArchiveIndexEntry: Codable, Equatable {
    public static let currentSchemaVersion: UInt8 = 1

    public let schemaVersion: UInt8
    public let threadId: String
    public let chunkId: String
    public let startTimestampMs: UInt64
    public let endTimestampMs: UInt64

    public init(
        threadId: String,
        chunkId: String,
        startTimestampMs: UInt64,
        endTimestampMs: UInt64,
        schemaVersion: UInt8 = ArchiveIndexEntry.currentSchemaVersion,
    ) {
        self.schemaVersion = schemaVersion
        self.threadId = threadId
        self.chunkId = chunkId
        self.startTimestampMs = startTimestampMs
        self.endTimestampMs = endTimestampMs
    }
}

public struct ArchiveStorageEnvelope: Codable, Equatable {
    public static let currentSchemaVersion: UInt8 = 1

    public let schemaVersion: UInt8
    public let chunk: ArchiveChunk
    public let encryptedPayload: Data

    public init(
        chunk: ArchiveChunk,
        encryptedPayload: Data,
        schemaVersion: UInt8 = ArchiveStorageEnvelope.currentSchemaVersion,
    ) {
        self.schemaVersion = schemaVersion
        self.chunk = chunk
        self.encryptedPayload = encryptedPayload
    }
}

public enum ChatArchiveManagerError: Error, Equatable {
    case unimplemented
}

public protocol ChatArchiveManager {
    func archiveOldMessages(threadId: String) async throws
    func loadArchivedChunk(chunkId: String) async throws -> [ArchiveChunk]
}

public class ChatArchiveManagerImpl: ChatArchiveManager {
    private let planner: ChatArchiveChunkPlanner
    private let compression: ChatArchiveCompression
    private let encryption: ChatArchiveEncryption
    private let keyProvider: ChatArchiveKeyProvider
    private let repository: ChatArchiveRepository
    private let indexStore: ChatArchiveIndexStore

    public init(
        planner: ChatArchiveChunkPlanner = MonthlyChatArchiveChunkPlanner(),
        compression: ChatArchiveCompression = ZstdChatArchiveCompressionAdapter(),
        encryption: ChatArchiveEncryption = AESGCMChatArchiveEncryption(),
        keyProvider: ChatArchiveKeyProvider = DeterministicChatArchiveKeyProvider(rootKeyMaterial: Data(repeating: 0x11, count: 32)),
        repository: ChatArchiveRepository = FileSystemChatArchiveRepository(
            rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("chat-archive-v2", isDirectory: true)
        ),
        indexStore: ChatArchiveIndexStore = InMemoryChatArchiveIndexStore(),
    ) {
        self.planner = planner
        self.compression = compression
        self.encryption = encryption
        self.keyProvider = keyProvider
        self.repository = repository
        self.indexStore = indexStore
    }

    public func archiveOldMessages(threadId: String) async throws {
        throw ChatArchiveManagerError.unimplemented
    }

    public func loadArchivedChunk(chunkId: String) async throws -> [ArchiveChunk] {
        throw ChatArchiveManagerError.unimplemented
    }

    public func archivePreparedMessages(
        threadId: String,
        messages: [ArchiveSourceMessage],
        maxMessagesPerChunk: Int? = 1000,
        deleteHotRows: () throws -> Void,
    ) throws {
        let chunks = planner.planChunks(
            threadId: threadId,
            messages: messages,
            maxMessagesPerChunk: maxMessagesPerChunk,
        )

        if chunks.isEmpty {
            return
        }

        var written = [ArchiveChunk]()

        do {
            for chunk in chunks {
                let serializedChunk = try JSONEncoder().encode(chunk)
                let compressed = try compression.compress(data: serializedChunk, level: 3)
                let key = keyProvider.archiveKey(for: chunk.chunkId)
                let encrypted = try encryption.encrypt(compressed, key: key)

                do {
                    try repository.writeArchive(
                        threadId: threadId,
                        chunkId: chunk.chunkId,
                        encryptedPayload: encrypted,
                        overwrite: false,
                    )
                } catch let error as ChatArchiveRepositoryError where error == .archiveAlreadyExists {
                    // Idempotent retry: existing archive is treated as already-written.
                }

                written.append(chunk)
            }

            try deleteHotRows()

            for chunk in written {
                indexStore.insert(
                    ArchiveIndexEntry(
                        threadId: chunk.threadId,
                        chunkId: chunk.chunkId,
                        startTimestampMs: chunk.startTimestampMs,
                        endTimestampMs: chunk.endTimestampMs,
                    )
                )
            }
        } catch {
            for chunk in written {
                try? repository.deleteArchive(threadId: threadId, chunkId: chunk.chunkId)
                indexStore.delete(threadId: threadId, chunkId: chunk.chunkId)
            }
            throw error
        }
    }
}

public struct ArchiveSourceMessage: Equatable {
    public let messageId: String
    public let timestampMs: UInt64
    public let text: String

    public init(messageId: String, timestampMs: UInt64, text: String = "") {
        self.messageId = messageId
        self.timestampMs = timestampMs
        self.text = text
    }
}

private struct ArchiveSourceMessagePayload: Codable, Equatable {
    let schemaVersion: UInt8
    let messages: [ArchiveSourceMessageCodable]

    init(messages: [ArchiveSourceMessage]) {
        self.schemaVersion = 1
        self.messages = messages.map { ArchiveSourceMessageCodable(messageId: $0.messageId, timestampMs: $0.timestampMs, text: $0.text) }
    }
}

private struct ArchiveSourceMessageCodable: Codable, Equatable {
    let messageId: String
    let timestampMs: UInt64
    let text: String
}

public struct ChatArchiveParityHarness {
    private let planner: ChatArchiveChunkPlanner
    private let compression: ChatArchiveCompression
    private let encryption: ChatArchiveEncryption
    private let keyProvider: ChatArchiveKeyProvider

    public init(
        planner: ChatArchiveChunkPlanner = MonthlyChatArchiveChunkPlanner(),
        compression: ChatArchiveCompression = ZstdChatArchiveCompressionAdapter(),
        encryption: ChatArchiveEncryption = AESGCMChatArchiveEncryption(),
        keyProvider: ChatArchiveKeyProvider,
    ) {
        self.planner = planner
        self.compression = compression
        self.encryption = encryption
        self.keyProvider = keyProvider
    }

    public func archive(
        threadId: String,
        messages: [ArchiveSourceMessage],
        maxMessagesPerChunk: Int? = 1000,
    ) throws -> [String: Data] {
        let chunks = planner.planChunks(threadId: threadId, messages: messages, maxMessagesPerChunk: maxMessagesPerChunk)
        var payloads = [String: Data]()

        for chunk in chunks {
            let chunkMessages = messages
                .filter { $0.timestampMs >= chunk.startTimestampMs && $0.timestampMs <= chunk.endTimestampMs }
                .sorted {
                    if $0.timestampMs == $1.timestampMs {
                        return $0.messageId < $1.messageId
                    }
                    return $0.timestampMs < $1.timestampMs
                }

            let serialized = try JSONEncoder().encode(ArchiveSourceMessagePayload(messages: chunkMessages))
            let compressed = try compression.compress(data: serialized, level: 3)
            let encrypted = try encryption.encrypt(compressed, key: keyProvider.archiveKey(for: chunk.chunkId))
            payloads[chunk.chunkId] = encrypted
        }

        return payloads
    }

    public func restore(
        archivedPayloadsByChunkId: [String: Data],
    ) throws -> [ArchiveSourceMessage] {
        var restored = [ArchiveSourceMessage]()

        for (chunkId, encryptedPayload) in archivedPayloadsByChunkId {
            let decrypted = try encryption.decrypt(encryptedPayload, key: keyProvider.archiveKey(for: chunkId))
            let serialized = try compression.decompress(data: decrypted)
            let payload = try JSONDecoder().decode(ArchiveSourceMessagePayload.self, from: serialized)
            restored.append(contentsOf: payload.messages.map { ArchiveSourceMessage(messageId: $0.messageId, timestampMs: $0.timestampMs, text: $0.text) })
        }

        return restored.sorted {
            if $0.timestampMs == $1.timestampMs {
                return $0.messageId < $1.messageId
            }
            return $0.timestampMs < $1.timestampMs
        }
    }
}

public struct ChatArchivePerformanceMetric: Equatable {
    public let chunkId: String
    public let originalBytes: Int
    public let compressedBytes: Int
    public let compressionRatio: Double
    public let decompressDurationMs: Double

    public init(
        chunkId: String,
        originalBytes: Int,
        compressedBytes: Int,
        compressionRatio: Double,
        decompressDurationMs: Double,
    ) {
        self.chunkId = chunkId
        self.originalBytes = originalBytes
        self.compressedBytes = compressedBytes
        self.compressionRatio = compressionRatio
        self.decompressDurationMs = decompressDurationMs
    }
}

public struct ChatArchiveBenchmarkReport: Equatable {
    public let metrics: [ChatArchivePerformanceMetric]

    public var averageCompressionRatio: Double {
        guard !metrics.isEmpty else { return 0 }
        return metrics.map(\.compressionRatio).reduce(0, +) / Double(metrics.count)
    }

    public var averageDecompressDurationMs: Double {
        guard !metrics.isEmpty else { return 0 }
        return metrics.map(\.decompressDurationMs).reduce(0, +) / Double(metrics.count)
    }

    public func toMarkdown() -> String {
        var lines = [
            "| chunk_id | original_bytes | compressed_bytes | compression_ratio | decompress_ms |",
            "| --- | ---: | ---: | ---: | ---: |",
        ]
        for metric in metrics {
            lines.append("| \(metric.chunkId) | \(metric.originalBytes) | \(metric.compressedBytes) | \(String(format: \"%.4f\", metric.compressionRatio)) | \(String(format: \"%.3f\", metric.decompressDurationMs)) |")
        }
        return lines.joined(separator: "\n")
    }

    public func toCSV() -> String {
        var lines = ["chunk_id,original_bytes,compressed_bytes,compression_ratio,decompress_ms"]
        for metric in metrics {
            lines.append("\(metric.chunkId),\(metric.originalBytes),\(metric.compressedBytes),\(metric.compressionRatio),\(metric.decompressDurationMs)")
        }
        return lines.joined(separator: "\n")
    }
}

public struct ChatArchiveBenchmarkSuite {
    private let planner: ChatArchiveChunkPlanner
    private let compression: ChatArchiveCompression

    public init(
        planner: ChatArchiveChunkPlanner = MonthlyChatArchiveChunkPlanner(),
        compression: ChatArchiveCompression = ZstdChatArchiveCompressionAdapter(),
    ) {
        self.planner = planner
        self.compression = compression
    }

    public func run(
        threadId: String,
        messages: [ArchiveSourceMessage],
        maxMessagesPerChunk: Int? = 1000,
    ) throws -> ChatArchiveBenchmarkReport {
        let chunks = planner.planChunks(threadId: threadId, messages: messages, maxMessagesPerChunk: maxMessagesPerChunk)
        var metrics = [ChatArchivePerformanceMetric]()

        for chunk in chunks {
            let chunkMessages = messages
                .filter { $0.timestampMs >= chunk.startTimestampMs && $0.timestampMs <= chunk.endTimestampMs }
                .sorted {
                    if $0.timestampMs == $1.timestampMs {
                        return $0.messageId < $1.messageId
                    }
                    return $0.timestampMs < $1.timestampMs
                }
            let payload = ArchiveSourceMessagePayload(messages: chunkMessages)
            let raw = try JSONEncoder().encode(payload)
            let compressed = try compression.compress(data: raw, level: 3)

            let start = Date()
            _ = try compression.decompress(data: compressed)
            let decompressMs = Date().timeIntervalSince(start) * 1000

            let ratio = raw.isEmpty ? 0 : Double(compressed.count) / Double(raw.count)
            metrics.append(
                ChatArchivePerformanceMetric(
                    chunkId: chunk.chunkId,
                    originalBytes: raw.count,
                    compressedBytes: compressed.count,
                    compressionRatio: ratio,
                    decompressDurationMs: decompressMs,
                )
            )
        }

        return ChatArchiveBenchmarkReport(metrics: metrics)
    }
}

public protocol ChatArchiveChunkPlanner {
    func planChunks(
        threadId: String,
        messages: [ArchiveSourceMessage],
        maxMessagesPerChunk: Int?,
    ) -> [ArchiveChunk]
}

public struct MonthlyChatArchiveChunkPlanner: ChatArchiveChunkPlanner {
    public init() {}

    public func planChunks(
        threadId: String,
        messages: [ArchiveSourceMessage],
        maxMessagesPerChunk: Int? = nil,
    ) -> [ArchiveChunk] {
        guard !messages.isEmpty else { return [] }

        let sortedMessages = messages.sorted {
            if $0.timestampMs == $1.timestampMs {
                return $0.messageId < $1.messageId
            }
            return $0.timestampMs < $1.timestampMs
        }

        let safeLimit = max(maxMessagesPerChunk ?? Int.max, 1)

        var result = [ArchiveChunk]()
        var currentMonthKey: String?
        var currentChunkMessages = [ArchiveSourceMessage]()
        var monthPart = 1

        func flushCurrentChunk() {
            guard let monthKey = currentMonthKey, !currentChunkMessages.isEmpty else { return }
            let chunkId = monthPart == 1
                ? "\(threadId)_\(monthKey)"
                : "\(threadId)_\(monthKey)_\(monthPart)"

            let startTimestampMs = currentChunkMessages.first?.timestampMs ?? 0
            let endTimestampMs = currentChunkMessages.last?.timestampMs ?? 0

            result.append(
                ArchiveChunk(
                    chunkId: chunkId,
                    threadId: threadId,
                    startTimestampMs: startTimestampMs,
                    endTimestampMs: endTimestampMs,
                    messageCount: UInt32(currentChunkMessages.count)
                )
            )

            currentChunkMessages.removeAll(keepingCapacity: true)
            monthPart += 1
        }

        for message in sortedMessages {
            let monthKey = Self.monthKey(timestampMs: message.timestampMs)

            if currentMonthKey == nil {
                currentMonthKey = monthKey
            }

            if currentMonthKey != monthKey {
                flushCurrentChunk()
                currentMonthKey = monthKey
                monthPart = 1
            }

            currentChunkMessages.append(message)

            if currentChunkMessages.count >= safeLimit {
                flushCurrentChunk()
            }
        }

        flushCurrentChunk()

        return result
    }

    private static func monthKey(timestampMs: UInt64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000)
        return Self.monthFormatter.string(from: date)
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy_MM"
        return formatter
    }()
}

public enum ChatArchiveCompressionError: Error, Equatable {
    case compressionFailed
    case decompressionFailed
}

public struct ArchiveCompressionBenchmark: Equatable {
    public let originalBytes: Int
    public let compressedBytes: Int
    public let compressDurationMs: Double
    public let decompressDurationMs: Double

    public var compressionRatio: Double {
        guard originalBytes > 0 else { return 0 }
        return Double(compressedBytes) / Double(originalBytes)
    }
}

public protocol ChatArchiveCompression {
    func compress(data: Data, level: Int) throws -> Data
    func decompress(data: Data) throws -> Data
    func benchmark(payloads: [Data], level: Int) -> [ArchiveCompressionBenchmark]
}

/// Adapter API named for zstd integration. The current backend uses zlib via
/// Apple's Compression framework and can be swapped to native zstd later
/// without changing call sites.
public struct ZstdChatArchiveCompressionAdapter: ChatArchiveCompression {
    public init() {}

    public func compress(data: Data, level: Int = 3) throws -> Data {
        // `level` is reserved for native zstd tuning and ignored by this backend.
        _ = level
        guard !data.isEmpty else { return Data() }
        return try Self.performCompression(data: data, operation: COMPRESSION_STREAM_ENCODE)
    }

    public func decompress(data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        return try Self.performCompression(data: data, operation: COMPRESSION_STREAM_DECODE)
    }

    public func benchmark(payloads: [Data], level: Int = 3) -> [ArchiveCompressionBenchmark] {
        payloads.compactMap { payload in
            let compressStart = Date()
            guard let compressed = try? compress(data: payload, level: level) else {
                return nil
            }
            let compressMs = Date().timeIntervalSince(compressStart) * 1000

            let decompressStart = Date()
            guard let decompressed = try? decompress(data: compressed), decompressed == payload else {
                return nil
            }
            let decompressMs = Date().timeIntervalSince(decompressStart) * 1000

            return ArchiveCompressionBenchmark(
                originalBytes: payload.count,
                compressedBytes: compressed.count,
                compressDurationMs: compressMs,
                decompressDurationMs: decompressMs
            )
        }
    }

    private static func performCompression(
        data: Data,
        operation: compression_stream_operation,
    ) throws -> Data {
        var stream = compression_stream()
        var status = compression_stream_init(&stream, operation, COMPRESSION_ZLIB)
        guard status != COMPRESSION_STATUS_ERROR else {
            throw operation == COMPRESSION_STREAM_ENCODE
                ? ChatArchiveCompressionError.compressionFailed
                : ChatArchiveCompressionError.decompressionFailed
        }
        defer {
            compression_stream_destroy(&stream)
        }

        let dstBufferSize = 64 * 1024
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: dstBufferSize)
        defer {
            dstBuffer.deallocate()
        }

        return try data.withUnsafeBytes { rawSourceBuffer in
            guard let sourceBaseAddress = rawSourceBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Data()
            }

            stream.src_ptr = sourceBaseAddress
            stream.src_size = data.count

            var output = Data()

            repeat {
                stream.dst_ptr = dstBuffer
                stream.dst_size = dstBufferSize

                status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))

                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let written = dstBufferSize - stream.dst_size
                    if written > 0 {
                        output.append(dstBuffer, count: written)
                    }
                default:
                    throw operation == COMPRESSION_STREAM_ENCODE
                        ? ChatArchiveCompressionError.compressionFailed
                        : ChatArchiveCompressionError.decompressionFailed
                }
            } while status == COMPRESSION_STATUS_OK

            return output
        }
    }
}

public protocol ChatArchiveKeyProvider {
    func archiveKey(for archiveIdentifier: String) -> SymmetricKey
}

public struct DeterministicChatArchiveKeyProvider: ChatArchiveKeyProvider {
    private let rootKeyMaterial: Data

    public init(rootKeyMaterial: Data) {
        self.rootKeyMaterial = rootKeyMaterial
    }

    public func archiveKey(for archiveIdentifier: String) -> SymmetricKey {
        var material = Data(archiveIdentifier.utf8)
        material.append(rootKeyMaterial)
        let digest = SHA256.hash(data: material)
        return SymmetricKey(data: Data(digest))
    }
}

public enum ChatArchiveEncryptionError: Error, Equatable {
    case invalidCiphertext
    case decryptionFailed
}

public protocol ChatArchiveEncryption {
    func encrypt(_ plaintext: Data, key: SymmetricKey) throws -> Data
    func decrypt(_ ciphertext: Data, key: SymmetricKey) throws -> Data
}

public struct AESGCMChatArchiveEncryption: ChatArchiveEncryption {
    public init() {}

    public func encrypt(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)

        guard let combined = sealed.combined else {
            throw ChatArchiveEncryptionError.invalidCiphertext
        }

        return combined
    }

    public func decrypt(_ ciphertext: Data, key: SymmetricKey) throws -> Data {
        do {
            let sealed = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(sealed, using: key)
        } catch {
            throw ChatArchiveEncryptionError.decryptionFailed
        }
    }
}

public enum ChatArchiveRepositoryError: Error, Equatable {
    case archiveAlreadyExists
    case archiveNotFound
    case corruptArchive
}

public protocol ChatArchiveRepository {
    func archiveURL(threadId: String, chunkId: String) -> URL
    func writeArchive(threadId: String, chunkId: String, encryptedPayload: Data, overwrite: Bool) throws
    func readArchive(threadId: String, chunkId: String) throws -> Data
    func deleteArchive(threadId: String, chunkId: String) throws
}

public struct FileSystemChatArchiveRepository: ChatArchiveRepository {
    private let rootURL: URL
    private let fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    public func archiveURL(threadId: String, chunkId: String) -> URL {
        rootURL
            .appendingPathComponent(threadId, isDirectory: true)
            .appendingPathComponent("\(chunkId).arc", isDirectory: false)
    }

    public func writeArchive(
        threadId: String,
        chunkId: String,
        encryptedPayload: Data,
        overwrite: Bool = false,
    ) throws {
        let fileURL = archiveURL(threadId: threadId, chunkId: chunkId)

        if fileManager.fileExists(atPath: fileURL.path), !overwrite {
            throw ChatArchiveRepositoryError.archiveAlreadyExists
        }

        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try encryptedPayload.write(to: fileURL, options: .atomic)
    }

    public func readArchive(threadId: String, chunkId: String) throws -> Data {
        let fileURL = archiveURL(threadId: threadId, chunkId: chunkId)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw ChatArchiveRepositoryError.archiveNotFound
        }

        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else {
            throw ChatArchiveRepositoryError.corruptArchive
        }
        return data
    }

    public func deleteArchive(threadId: String, chunkId: String) throws {
        let fileURL = archiveURL(threadId: threadId, chunkId: chunkId)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw ChatArchiveRepositoryError.archiveNotFound
        }
        try fileManager.removeItem(at: fileURL)
    }
}

public enum ChatArchiveIndexMigration {
    public static let createTableSQL = """
    CREATE TABLE IF NOT EXISTS archive_index (
        thread_id TEXT NOT NULL,
        chunk_id TEXT NOT NULL,
        start_ts INTEGER NOT NULL,
        end_ts INTEGER NOT NULL,
        PRIMARY KEY (thread_id, chunk_id)
    );
    """

    public static let createRangeLookupIndexSQL = """
    CREATE INDEX IF NOT EXISTS archive_index_thread_range
    ON archive_index (thread_id, start_ts, end_ts);
    """
}

public protocol ChatArchiveIndexStore {
    func insert(_ entry: ArchiveIndexEntry)
    func delete(threadId: String, chunkId: String)
    func query(threadId: String, from startTimestampMs: UInt64, to endTimestampMs: UInt64) -> [ArchiveIndexEntry]
}

public final class InMemoryChatArchiveIndexStore: ChatArchiveIndexStore {
    private var entries = [ArchiveIndexEntry]()

    public init() {}

    public func insert(_ entry: ArchiveIndexEntry) {
        entries.removeAll { $0.threadId == entry.threadId && $0.chunkId == entry.chunkId }
        entries.append(entry)
    }

    public func delete(threadId: String, chunkId: String) {
        entries.removeAll { $0.threadId == threadId && $0.chunkId == chunkId }
    }

    public func query(threadId: String, from startTimestampMs: UInt64, to endTimestampMs: UInt64) -> [ArchiveIndexEntry] {
        entries
            .filter { entry in
                guard entry.threadId == threadId else { return false }
                let overlaps = entry.startTimestampMs <= endTimestampMs && entry.endTimestampMs >= startTimestampMs
                return overlaps
            }
            .sorted { lhs, rhs in
                if lhs.startTimestampMs == rhs.startTimestampMs {
                    return lhs.chunkId < rhs.chunkId
                }
                return lhs.startTimestampMs < rhs.startTimestampMs
            }
    }
}

public struct ArchiveRange: Equatable, Hashable {
    public let startTimestampMs: UInt64
    public let endTimestampMs: UInt64

    public init(startTimestampMs: UInt64, endTimestampMs: UInt64) {
        self.startTimestampMs = startTimestampMs
        self.endTimestampMs = endTimestampMs
    }
}

public final class ArchiveGapDetector {
    private var emittedGapKeys = Set<String>()

    public init() {}

    public func detectGaps(
        threadId: String,
        requestedRange: ArchiveRange,
        availableRanges: [ArchiveRange],
    ) -> [ArchiveRange] {
        let normalizedAvailable = availableRanges
            .filter { $0.endTimestampMs >= requestedRange.startTimestampMs && $0.startTimestampMs <= requestedRange.endTimestampMs }
            .sorted { $0.startTimestampMs < $1.startTimestampMs }

        var gaps = [ArchiveRange]()
        var cursor = requestedRange.startTimestampMs

        for range in normalizedAvailable {
            let overlapStart = max(range.startTimestampMs, requestedRange.startTimestampMs)
            let overlapEnd = min(range.endTimestampMs, requestedRange.endTimestampMs)
            if overlapStart > cursor {
                gaps.append(ArchiveRange(startTimestampMs: cursor, endTimestampMs: overlapStart - 1))
            }
            if overlapEnd == UInt64.max {
                cursor = UInt64.max
            } else {
                cursor = max(cursor, overlapEnd + 1)
            }
            if cursor > requestedRange.endTimestampMs { break }
        }

        if cursor <= requestedRange.endTimestampMs {
            gaps.append(ArchiveRange(startTimestampMs: cursor, endTimestampMs: requestedRange.endTimestampMs))
        }

        return gaps
    }

    public func emitNewGaps(
        threadId: String,
        requestedRange: ArchiveRange,
        availableRanges: [ArchiveRange],
    ) -> [ArchiveRange] {
        let gaps = detectGaps(threadId: threadId, requestedRange: requestedRange, availableRanges: availableRanges)
        return gaps.filter { gap in
            let key = "\(threadId):\(gap.startTimestampMs)-\(gap.endTimestampMs)"
            return emittedGapKeys.insert(key).inserted
        }
    }
}

public protocol ChatArchiveLoader {
    func loadChunk(threadId: String, chunkId: String) async throws -> ArchiveChunk
}

public struct ChatArchiveAsyncLoader: ChatArchiveLoader {
    private let repository: ChatArchiveRepository
    private let encryption: ChatArchiveEncryption
    private let compression: ChatArchiveCompression
    private let keyProvider: ChatArchiveKeyProvider

    public init(
        repository: ChatArchiveRepository,
        encryption: ChatArchiveEncryption,
        compression: ChatArchiveCompression,
        keyProvider: ChatArchiveKeyProvider,
    ) {
        self.repository = repository
        self.encryption = encryption
        self.compression = compression
        self.keyProvider = keyProvider
    }

    public func loadChunk(threadId: String, chunkId: String) async throws -> ArchiveChunk {
        try Task.checkCancellation()

        let encrypted = try repository.readArchive(threadId: threadId, chunkId: chunkId)
        try Task.checkCancellation()

        let key = keyProvider.archiveKey(for: chunkId)
        let compressed = try encryption.decrypt(encrypted, key: key)
        try Task.checkCancellation()

        let serialized = try compression.decompress(data: compressed)
        try Task.checkCancellation()

        return try JSONDecoder().decode(ArchiveChunk.self, from: serialized)
    }
}

public struct ChatArchiveTimelineMerger {
    public init() {}

    public func merge(
        hotMessages: [ArchiveSourceMessage],
        archivedMessages: [ArchiveSourceMessage],
    ) -> [ArchiveSourceMessage] {
        var byId = [String: ArchiveSourceMessage]()

        for message in archivedMessages {
            byId[message.messageId] = message
        }
        for message in hotMessages {
            byId[message.messageId] = message
        }

        return byId.values.sorted {
            if $0.timestampMs == $1.timestampMs {
                return $0.messageId < $1.messageId
            }
            return $0.timestampMs < $1.timestampMs
        }
    }
}

public struct ChatArchiveSchedulerConditions: Equatable {
    public let isAppIdle: Bool
    public let isCharging: Bool
    public let isLowCpuUsage: Bool

    public init(isAppIdle: Bool, isCharging: Bool, isLowCpuUsage: Bool) {
        self.isAppIdle = isAppIdle
        self.isCharging = isCharging
        self.isLowCpuUsage = isLowCpuUsage
    }
}

public enum ChatArchiveSchedulerSkipReason: Equatable {
    case appNotIdle
    case notCharging
    case cpuTooBusy
    case throttled
}

public enum ChatArchiveSchedulerRunResult: Equatable {
    case started
    case skipped(ChatArchiveSchedulerSkipReason)
    case aborted
}

public struct ChatArchiveSchedulerTelemetry: Equatable {
    public var lastRunStartAt: Date?
    public var lastRunFinishAt: Date?
    public var lastResult: ChatArchiveSchedulerRunResult?
    public var retryCount: Int
    public var lastFailureReason: String?

    public init(
        lastRunStartAt: Date? = nil,
        lastRunFinishAt: Date? = nil,
        lastResult: ChatArchiveSchedulerRunResult? = nil,
        retryCount: Int = 0,
        lastFailureReason: String? = nil,
    ) {
        self.lastRunStartAt = lastRunStartAt
        self.lastRunFinishAt = lastRunFinishAt
        self.lastResult = lastResult
        self.retryCount = retryCount
        self.lastFailureReason = lastFailureReason
    }
}

public struct ChatArchiveThrottlePolicy: Equatable {
    public let maxRunsPerWindow: Int
    public let windowDuration: TimeInterval
    public let baseBackoff: TimeInterval
    public let maxBackoff: TimeInterval

    public init(
        maxRunsPerWindow: Int,
        windowDuration: TimeInterval,
        baseBackoff: TimeInterval,
        maxBackoff: TimeInterval,
    ) {
        self.maxRunsPerWindow = max(1, maxRunsPerWindow)
        self.windowDuration = max(1, windowDuration)
        self.baseBackoff = max(0.1, baseBackoff)
        self.maxBackoff = max(self.baseBackoff, maxBackoff)
    }

    public static let `default` = ChatArchiveThrottlePolicy(
        maxRunsPerWindow: 3,
        windowDuration: 60 * 60,
        baseBackoff: 30,
        maxBackoff: 15 * 60,
    )
}

public actor ChatArchiveRunThrottleStore {
    private let policy: ChatArchiveThrottlePolicy
    private var recentRunStarts = [Date]()
    private var retryCountInternal = 0
    private var nextAllowedAt: Date?
    private var lastFailureReason: String?

    public init(policy: ChatArchiveThrottlePolicy = .default) {
        self.policy = policy
    }

    public func shouldAllowRun(now: Date = Date()) -> Bool {
        prune(now: now)
        if let nextAllowedAt, now < nextAllowedAt {
            return false
        }
        return recentRunStarts.count < policy.maxRunsPerWindow
    }

    public func registerRunStart(now: Date = Date()) {
        prune(now: now)
        recentRunStarts.append(now)
    }

    public func registerSuccess() {
        retryCountInternal = 0
        nextAllowedAt = nil
        lastFailureReason = nil
    }

    public func registerFailure(reason: String, now: Date = Date()) {
        retryCountInternal += 1
        let factor = pow(2.0, Double(max(0, retryCountInternal - 1)))
        let backoff = min(policy.maxBackoff, policy.baseBackoff * factor)
        nextAllowedAt = now.addingTimeInterval(backoff)
        lastFailureReason = reason
    }

    public var retryCount: Int { retryCountInternal }
    public var failureReason: String? { lastFailureReason }

    private func prune(now: Date) {
        let floor = now.addingTimeInterval(-policy.windowDuration)
        recentRunStarts.removeAll { $0 < floor }
    }
}

public actor ChatArchiveBackgroundScheduler {
    private(set) var telemetry = ChatArchiveSchedulerTelemetry()
    private var shouldAbort = false
    private let throttleStore: ChatArchiveRunThrottleStore

    public init(throttleStore: ChatArchiveRunThrottleStore = ChatArchiveRunThrottleStore()) {
        self.throttleStore = throttleStore
    }

    public func canRun(conditions: ChatArchiveSchedulerConditions) -> ChatArchiveSchedulerRunResult {
        if !conditions.isAppIdle {
            return .skipped(.appNotIdle)
        }
        if !conditions.isCharging {
            return .skipped(.notCharging)
        }
        if !conditions.isLowCpuUsage {
            return .skipped(.cpuTooBusy)
        }
        return .started
    }

    public func requestAbort() {
        shouldAbort = true
    }

    public func runIfEligible(
        conditions: ChatArchiveSchedulerConditions,
        job: () async throws -> Void,
    ) async throws -> ChatArchiveSchedulerRunResult {
        let eligibility = canRun(conditions: conditions)
        guard eligibility == .started else {
            telemetry.lastResult = eligibility
            return eligibility
        }

        if await !throttleStore.shouldAllowRun() {
            telemetry.lastResult = .skipped(.throttled)
            return .skipped(.throttled)
        }

        await throttleStore.registerRunStart()

        telemetry.lastRunStartAt = Date()

        if shouldAbort {
            shouldAbort = false
            telemetry.lastRunFinishAt = Date()
            telemetry.lastResult = .aborted
            return .aborted
        }

        do {
            try await job()
            await throttleStore.registerSuccess()
        } catch {
            await throttleStore.registerFailure(reason: String(describing: error))
            telemetry.retryCount = await throttleStore.retryCount
            telemetry.lastFailureReason = await throttleStore.failureReason
            throw error
        }

        if shouldAbort {
            shouldAbort = false
            telemetry.lastRunFinishAt = Date()
            telemetry.lastResult = .aborted
            return .aborted
        }

        telemetry.lastRunFinishAt = Date()
        telemetry.lastResult = .started
        telemetry.retryCount = await throttleStore.retryCount
        telemetry.lastFailureReason = await throttleStore.failureReason
        return .started
    }
}

public protocol BackupArchiveManager {

    // MARK: - Interact with remotes

    /// Fetch the CDN info for the current backup
    func backupCdnInfo(
        backupKey: MessageRootBackupKey,
        backupAuth: BackupServiceAuth,
    ) async throws -> BackupCdnInfo

    /// Download the encrypted backup for the current user to a local file.
    func downloadEncryptedBackup(
        backupKey: MessageRootBackupKey,
        backupAuth: BackupServiceAuth,
        progress: OWSProgressSink?,
    ) async throws -> URL

    /// Upload the local encrypted backup identified by the given metadata for
    /// the current user.
    func uploadEncryptedBackup(
        backupKey: MessageRootBackupKey,
        metadata: Upload.EncryptedBackupUploadMetadata,
        auth: ChatServiceAuth,
        progress: OWSProgressSink?,
    ) async throws -> Upload.Result<Upload.EncryptedBackupUploadMetadata>

    // MARK: - Export

    /// Export an encrypted backup binary to a local file.
    /// - SeeAlso `uploadEncryptedBackup`
    func exportEncryptedBackup(
        localIdentifiers: LocalIdentifiers,
        backupPurpose: BackupExportPurpose,
        progress: OWSProgressSink?,
    ) async throws -> Upload.EncryptedBackupUploadMetadata

#if TESTABLE_BUILD
    /// Export a plaintext backup binary at the returned file URL, for use in
    /// integration tests.
    func exportPlaintextBackupForTests(
        localIdentifiers: LocalIdentifiers,
    ) async throws -> URL
#endif

    // MARK: - Import

    /// Returns whether this device has ever successfully restored from a backup
    /// and committed the contents to the database.
    func backupRestoreState(tx: DBReadTransaction) -> BackupRestoreState

    /// Import a backup from the encrypted binary file at the given local URL.
    /// - SeeAlso ``downloadEncryptedBackup(localIdentifiers:auth:)``
    func importEncryptedBackup(
        fileUrl: URL,
        localIdentifiers: LocalIdentifiers,
        isPrimaryDevice: Bool,
        source: BackupImportSource,
        progress: OWSProgressSink?,
    ) async throws

#if TESTABLE_BUILD
    /// Import a backup from the plaintext binary file at the given local URL.
    func importPlaintextBackupForTests(
        fileUrl: URL,
        localIdentifiers: LocalIdentifiers,
    ) async throws
#endif

    /// Call this if ``backupRestoreState(tx:)`` returns ``BackupRestoreState/unfinalized``.
    /// ``importEncryptedBackup(fileUrl:localIdentifiers:isPrimaryDevice:backupKey:backupPurpose:progress:)``
    /// will finalize on its own; however if this process is interrupted (by e.g. cancellation or app termination) callers MUST NOT import again
    /// but MUST call this method to finish the in-progress import finalization steps. This method is idempotent; import is not.
    func finalizeBackupImport(progress: OWSProgressSink?) async throws

    /// Schedule an SVRB restore.  This value is checked at the beginning of backup export
    /// and will block on a completing the SVRB fetch before beginning the export.
    func scheduleRestoreFromSVRBBeforeNextExport(tx: DBWriteTransaction)
}
