import Foundation
import Logging
import SwiftData

@Model
class HistoryItemContent {
  var type: String = ""
  // Retain the original column for lossless, resumable migration of older stores.
  // New image/large payloads leave this nil; callers must use `data`.
  var value: Data?
  var payloadFile: String?
  var payloadSize: Int?
  var payloadDigest: String?
  var storageVersion: Int?

  @Relationship
  var item: HistoryItem?

  var hasValue: Bool { payloadFile != nil || value != nil }

  var fileURL: URL? {
    guard let payloadFile else { return nil }
    return try? ContentFileStore.shared.url(for: payloadFile)
  }

  var data: Data? {
    get {
      do { return try readData() } catch {
        Logger(label: "org.p0deje.Maccy").error("Cannot read clipboard payload: \(error)")
        return nil
      }
    }
    set {
      do {
        try store(newValue)
      } catch {
        // Disk-full/permission failures must never discard a newly copied item.
        value = newValue
        payloadFile = nil
        payloadSize = newValue?.count
        payloadDigest = nil
        storageVersion = nil
        Logger(label: "org.p0deje.Maccy").error("Keeping clipboard payload inline after disk write failed: \(error)")
      }
    }
  }

  init(type: String, value: Data? = nil) {
    self.type = type
    self.data = value
  }

  func readData() throws -> Data? {
    if let payloadFile { return try ContentFileStore.shared.read(payloadFile) }
    return value
  }

  func migratePayload() throws {
    guard storageVersion == nil else { return }
    try store(try readData())
  }

  func hasSameData(as other: HistoryItemContent) -> Bool {
    if let payloadDigest, let otherDigest = other.payloadDigest {
      return payloadSize == other.payloadSize && payloadDigest == otherDigest
    }
    return data == other.data
  }

  private func store(_ data: Data?) throws {
    var file: String?
    if let data, ContentFileStore.shouldStoreOnDisk(type: type, size: data.count) {
      file = try ContentFileStore.shared.write(data)
    }
    // Do not change any persistent properties until the complete file is on disk.
    value = file == nil ? data : nil
    payloadFile = file
    payloadSize = data?.count
    payloadDigest = data.map(ContentFileStore.digest)
    storageVersion = 1
  }
}
