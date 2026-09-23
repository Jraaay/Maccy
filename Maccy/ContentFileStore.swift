import CryptoKit
import Foundation
import UniformTypeIdentifiers

// Immutable files: write the file before saving its database reference. Replaced
// files are removed only after a successful database save, never in a model setter.
struct ContentFileStore {
  static let shared: ContentFileStore = {
    let directory: URL
    if AppDelegate.isTesting {
      directory = FileManager.default.temporaryDirectory
        .appending(path: "Maccy-test-payloads-\(ProcessInfo.processInfo.processIdentifier)")
    } else {
      directory = URL.applicationSupportDirectory.appending(path: "Maccy/Contents")
    }
    return ContentFileStore(directory: directory)
  }()

  let directory: URL
  static let largePayloadThreshold = 256 * 1_024

  static func shouldStoreOnDisk(type: String, size: Int) -> Bool {
    UTType(type)?.conforms(to: .image) == true || size >= largePayloadThreshold
  }

  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  func url(for name: String) throws -> URL {
    guard name.hasSuffix(".blob"), UUID(uuidString: String(name.dropLast(5))) != nil else {
      throw CocoaError(.fileReadInvalidFileName)
    }
    return directory.appending(path: name)
  }

  func write(_ data: Data) throws -> String {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
    )
    let name = UUID().uuidString + ".blob"
    let destination = try url(for: name)
    try data.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    let handle = try FileHandle(forWritingTo: destination)
    defer { try? handle.close() }
    try handle.synchronize()
    return name
  }

  func read(_ name: String) throws -> Data {
    // The returned mapping lives only for the caller's operation, not in SwiftData.
    try Data(contentsOf: url(for: name), options: .mappedIfSafe)
  }

  func removeUnreferencedFiles(keeping names: Set<String>) throws {
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
      let name = url.lastPathComponent
      guard (try? self.url(for: name)) != nil, !names.contains(name) else { continue }
      try FileManager.default.removeItem(at: url)
    }
  }
}
