//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
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
    public init() {}

    public func archiveOldMessages(threadId: String) async throws {
        throw ChatArchiveManagerError.unimplemented
    }

    public func loadArchivedChunk(chunkId: String) async throws -> [ArchiveChunk] {
        throw ChatArchiveManagerError.unimplemented
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
