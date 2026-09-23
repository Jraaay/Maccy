import Foundation
import SwiftData
import SQLite3
import Logging

@MainActor
class Storage {
  static let shared = Storage()

  var container: ModelContainer
  var context: ModelContext { container.mainContext }
  var size: String {
    let manager = FileManager.default
    let payloads = (try? manager.contentsOfDirectory(
      at: ContentFileStore.shared.directory, includingPropertiesForKeys: [.fileSizeKey]
    )) ?? []
    let files = [url, URL(fileURLWithPath: url.path + "-wal")] + payloads
    let bytes = files.reduce(Int64(0)) { total, file in
      total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    return bytes > 0 ? ByteCountFormatter().string(fromByteCount: bytes) : ""
  }

  private var payloadCleanupTask: Task<Void, Never>?

  private let url = AppDelegate.isTesting
    ? ContentFileStore.shared.directory.appending(path: "Storage.sqlite")
    : URL.applicationSupportDirectory.appending(path: "Maccy/Storage.sqlite")

  init() {
    var config = ModelConfiguration(url: url)

    #if DEBUG
    if AppDelegate.isTesting {
      config = ModelConfiguration(isStoredInMemoryOnly: true)
    }
    #endif

    var migratePayloads = !config.isStoredInMemoryOnly
    if migratePayloads {
      do { try Self.backupBeforePayloadMigration(at: url) } catch {
        migratePayloads = false
        Logger(label: "org.p0deje.Maccy").error("Payload migration postponed: cannot back up database: \(error)")
      }
    }

    do {
      container = try ModelContainer(for: HistoryItem.self, configurations: config)
    } catch let error {
      fatalError("Cannot load database: \(error.localizedDescription).")
    }
    if migratePayloads {
      do {
        _ = try cleanupOrphanedContents()
        _ = try Self.migratePayloads(in: container)
        try removeUnreferencedPayloads()
      } catch {
        // Saved batches are complete. Unsaved rows retain their original inline data
        // and will be retried next launch; no one-shot UserDefaults migration flag.
        Logger(label: "org.p0deje.Maccy").error("Payload migration will resume next launch: \(error)")
      }
    }
  }

  @discardableResult
  static func migratePayloads(in container: ModelContainer) throws -> Int {
    var count = 0
    while true {
      let migrated = try autoreleasepool {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<HistoryItemContent>(
          predicate: #Predicate { $0.storageVersion == nil }
        )
        descriptor.fetchLimit = 16
        let contents = try context.fetch(descriptor)
        for content in contents { try content.migratePayload() }
        try context.save()
        return contents.count
      }
      count += migrated
      if migrated == 0 { return count }
    }
  }

  func saveAndCleanPayloads(discardMigrationBackup: Bool = false) throws {
    try context.save()
    try removeUnreferencedPayloads()
    if discardMigrationBackup {
      let backup = url.deletingLastPathComponent().appending(path: "Storage.before-payload-files.sqlite")
      if FileManager.default.fileExists(atPath: backup.path) {
        try FileManager.default.removeItem(at: backup)
      }
    }
  }

  func schedulePayloadCleanup() {
    guard payloadCleanupTask == nil else { return }
    payloadCleanupTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(30)) } catch { return }
      guard let self else { return }
      defer { payloadCleanupTask = nil }
      do { try saveAndCleanPayloads() } catch {
        Logger(label: "org.p0deje.Maccy").error("Cannot clean unused clipboard files: \(error)")
      }
    }
  }

  func removeUnreferencedPayloads() throws {
    // A separate context observes durable references only, after the caller saves.
    let context = ModelContext(container)
    var descriptor = FetchDescriptor<HistoryItemContent>()
    descriptor.propertiesToFetch = [\.payloadFile]
    let references = try context.fetch(descriptor).compactMap(\.payloadFile)
    try ContentFileStore.shared.removeUnreferencedFiles(keeping: Set(references))
  }

  static func backupBeforePayloadMigration(at url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let backup = url.deletingLastPathComponent().appending(path: "Storage.before-payload-files.sqlite")
    guard !FileManager.default.fileExists(atPath: backup.path) else { return }
    let temporary = backup.appendingPathExtension("partial")
    var source: OpaquePointer?
    var destination: OpaquePointer?
    defer {
      sqlite3_close(source)
      sqlite3_close(destination)
      try? FileManager.default.removeItem(at: temporary)
    }
    guard sqlite3_open_v2(url.path, &source, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
      throw CocoaError(.fileReadUnknown)
    }
    // A new/already migrated store needs no legacy backup. This also avoids
    // recreating deleted history in a backup after the user clears it.
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    if sqlite3_prepare_v2(source,
                         "SELECT 1 FROM ZHISTORYITEMCONTENT WHERE ZSTORAGEVERSION IS NULL LIMIT 1",
                         -1, &statement, nil) == SQLITE_OK,
       sqlite3_step(statement) == SQLITE_DONE { return }
    sqlite3_finalize(statement)
    statement = nil
    guard sqlite3_open(temporary.path, &destination) == SQLITE_OK,
          let operation = sqlite3_backup_init(destination, "main", source, "main") else {
      throw CocoaError(.fileWriteUnknown)
    }
    let result = sqlite3_backup_step(operation, -1)
    let finish = sqlite3_backup_finish(operation)
    guard result == SQLITE_DONE, finish == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    guard sqlite3_close(destination) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    destination = nil
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    // sqlite3_backup includes committed WAL pages, unlike copying the .sqlite file.
    try FileManager.default.moveItem(at: temporary, to: backup)
  }

  func cleanupOrphanedContents() throws -> Int {
    let descriptor = FetchDescriptor<HistoryItemContent>(
      predicate: #Predicate { $0.item == nil }
    )
    let count = try context.fetchCount(descriptor)
    guard count > 0 else {
      return 0
    }

    try context.delete(
      model: HistoryItemContent.self,
      where: #Predicate { $0.item == nil }
    )
    context.processPendingChanges()
    try context.save()

    return count
  }

  // Titles stored before the sanitization in `HistoryItem.generateTitle()` may
  // contain scalars that hang CoreText on macOS 26. Such an item makes Maccy
  // spin at 100% CPU on every launch without ever drawing its window, so the
  // store has to be healed before the history is first rendered.
  // See https://github.com/p0deje/Maccy/issues/1520.
  func sanitizeTitles() throws -> Int {
    let items = try context.fetch(FetchDescriptor<HistoryItem>())
    var count = 0

    for item in items where item.title.containsScalarsUnsafeForTitleLayout {
      item.title = item.title.removingScalarsUnsafeForTitleLayout()
      count += 1
    }

    guard count > 0 else {
      return 0
    }

    context.processPendingChanges()
    try context.save()

    return count
  }
}
