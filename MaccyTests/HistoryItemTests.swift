import XCTest
import Defaults
import SwiftData
@testable import Maccy

// swiftlint:disable force_try
@MainActor
class HistoryItemTests: XCTestCase {
  func testImagePayloadLivesOnDiskAndSurvivesReload() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "Storage.sqlite")
    let bytes = Data(repeating: 42, count: 1_024 * 1_024)
    var filename: String?
    do {
      let container = try ModelContainer(for: HistoryItem.self, configurations: ModelConfiguration(url: url))
      let context = ModelContext(container)
      let content = HistoryItemContent(type: "public.png", value: bytes)
      context.insert(HistoryItem(contents: [content]))
      try context.save()
      XCTAssertNil(content.value, "The observable model must not retain image bytes")
      XCTAssertEqual(content.payloadSize, bytes.count)
      filename = try XCTUnwrap(content.payloadFile)
    }
    let reopened = try ModelContainer(for: HistoryItem.self, configurations: ModelConfiguration(url: url))
    let content = try XCTUnwrap(ModelContext(reopened).fetch(FetchDescriptor<HistoryItemContent>()).first)
    XCTAssertEqual(content.payloadFile, filename)
    XCTAssertNil(content.value)
    XCTAssertEqual(try content.readData(), bytes)
    XCTAssertNil(content.value, "Reading a payload must not cache it in the model")
  }

  func testLegacyDatabaseMigratesLosslesslyAndOnlyOnce() throws {
    let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "LegacyStorage", withExtension: "sqlite"))
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "Storage.sqlite")
    try FileManager.default.copyItem(at: fixture, to: url)
    try Storage.backupBeforePayloadMigration(at: url)
    let backup = directory.appending(path: "Storage.before-payload-files.sqlite")
    XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    let container = try ModelContainer(for: HistoryItem.self, configurations: ModelConfiguration(url: url))
    let originals = try ModelContext(container).fetch(FetchDescriptor<HistoryItemContent>())
    let expected = Dictionary(uniqueKeysWithValues: originals.map { ($0.type, $0.value) })
    XCTAssertEqual(try Storage.migratePayloads(in: container), 2)
    XCTAssertEqual(try Storage.migratePayloads(in: container), 0)
    let migrated = try ModelContext(container).fetch(FetchDescriptor<HistoryItemContent>())
    XCTAssertEqual(migrated.count, 2)
    for content in migrated {
      XCTAssertEqual(try content.readData(), expected[content.type]!)
      XCTAssertEqual(content.storageVersion, 1)
      if content.type == "public.tiff" {
        XCTAssertNil(content.value)
        XCTAssertNotNil(content.fileURL)
        XCTAssertNotNil(content.item?.scaledImage(to: NSSize(width: 16, height: 16)))
      } else {
        XCTAssertNil(content.payloadFile)
      }
    }
    // A second backup request must not overwrite the original pre-migration copy.
    let before = try Data(contentsOf: backup)
    try Storage.backupBeforePayloadMigration(at: url)
    XCTAssertEqual(try Data(contentsOf: backup), before)
  }

  func testLargeNonImagePayloadAlsoUsesDisk() throws {
    let data = Data(repeating: 7, count: ContentFileStore.largePayloadThreshold)
    let content = HistoryItemContent(type: "com.apple.webarchive", value: data)
    XCTAssertNil(content.value)
    XCTAssertEqual(try content.readData(), data)
    let text = HistoryItemContent(type: "public.utf8-plain-text", value: Data("small".utf8))
    XCTAssertNil(text.payloadFile)
    XCTAssertEqual(text.value, Data("small".utf8))
  }

  func testDuplicateDetectionUsesPayloadMetadata() throws {
    let bytes = Data(repeating: 1, count: 256)
    let first = HistoryItemContent(type: "public.png", value: bytes)
    let second = HistoryItemContent(type: "public.png", value: bytes)
    let different = HistoryItemContent(type: "public.png", value: Data(repeating: 2, count: 256))
    XCTAssertNotEqual(first.payloadFile, second.payloadFile)
    XCTAssertTrue(first.hasSameData(as: second))
    XCTAssertFalse(first.hasSameData(as: different))
    XCTAssertNil(first.value)
    XCTAssertNil(second.value)
  }

  func testDiskFileCleanupKeepsReferencedFiles() throws {
    let store = ContentFileStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let live = try store.write(Data([1, 2, 3]))
    let unused = try store.write(Data([4, 5, 6]))
    try store.removeUnreferencedFiles(keeping: [live])
    XCTAssertEqual(try store.read(live), Data([1, 2, 3]))
    XCTAssertThrowsError(try store.read(unused))
    XCTAssertThrowsError(try store.url(for: "../outside.blob"))
    try store.removeUnreferencedFiles(keeping: [])
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).isEmpty)
  }

  func testDiskWriteFailureIsReported() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data([1]).write(to: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ContentFileStore(directory: directory)
    XCTAssertThrowsError(try store.write(Data([1, 2, 3])))
  }

  func testThumbnailIsDownsampledWithoutRetainingOriginal() throws {
    let image = NSImage(size: NSSize(width: 2_000, height: 1_000), flipped: false) { rect in
      NSColor.blue.setFill()
      rect.fill()
      return true
    }
    let content = HistoryItemContent(type: "public.tiff", value: try XCTUnwrap(image.tiffRepresentation))
    let item = HistoryItem(contents: [content])
    let thumbnail = try XCTUnwrap(item.scaledImage(to: NSSize(width: 100, height: 100), scale: 1))
    XCTAssertEqual(thumbnail.size, NSSize(width: 100, height: 50))
    var bounds = CGRect(origin: .zero, size: thumbnail.size)
    let bitmap = try XCTUnwrap(thumbnail.cgImage(forProposedRect: &bounds, context: nil, hints: nil))
    XCTAssertLessThanOrEqual(bitmap.width, 100)
    XCTAssertLessThanOrEqual(bitmap.height, 100)
    XCTAssertNil(content.value)
  }

  func testDiskImageCanBeCopiedToPasteboard() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let clipboard = Clipboard(pasteboard: pasteboard)
    let bytes = Data(repeating: 42, count: 256)
    let content = HistoryItemContent(type: "public.png", value: bytes)
    let item = HistoryItem(contents: [content])
    XCTAssertTrue(clipboard.copy(item))
    XCTAssertEqual(pasteboard.data(forType: .png), bytes)
    XCTAssertNil(content.value)
  }

  func testMissingDiskFileDoesNotOverwriteClipboard() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("existing clipboard", forType: .string)
    let clipboard = Clipboard(pasteboard: pasteboard)
    let content = HistoryItemContent(type: "public.png", value: Data([1, 2, 3]))
    try FileManager.default.removeItem(at: XCTUnwrap(content.fileURL))
    XCTAssertFalse(clipboard.copy(HistoryItem(contents: [content])))
    XCTAssertEqual(pasteboard.string(forType: .string), "existing clipboard")
  }

  func testTitleForString() {
    let title = "foo"
    let item = historyItem(title)
    XCTAssertEqual(item.title, title)
  }

  func testTitleWithWhitespaces() {
    let title = "   foo bar   "
    let item = historyItem(title)
    XCTAssertEqual(item.title, "···foo bar···")
  }

  func testTitleWithNewlines() {
    let title = "\nfoo\nbar\n"
    let item = historyItem(title)
    XCTAssertEqual(item.title, "⏎foo⏎bar⏎")
  }

  func testTitleWithTabs() {
    let title = "\tfoo\tbar\t"
    let item = historyItem(title)
    XCTAssertEqual(item.title, "⇥foo⇥bar⇥")
  }

  // U+FFFC arrives from rich text with inline attachments and hangs CoreText
  // on macOS 26. See https://github.com/p0deje/Maccy/issues/1520.
  func testTitleWithObjectReplacementCharacters() {
    let item = historyItem("\u{FFFC}foo\u{FFFC}bar\u{FFFC}")
    XCTAssertEqual(item.title, "foobar")
  }

  func testTitleWithOnlyObjectReplacementCharacters() {
    let item = historyItem("\u{FFFC}\u{FFFC}")
    XCTAssertEqual(item.title, "")
  }

  func testTitleWithRTF() {
    let rtf = NSAttributedString(string: "foo").rtf(
      from: NSRange(0...2),
      documentAttributes: [:]
    )
    let item = historyItem(rtf, .rtf)
    XCTAssertEqual(item.title, "foo")
  }

  func testTitleWithHTML() {
    let html = "<a href='#'>foo</a>".data(using: .utf8)
    let item = historyItem(html, .html)
    XCTAssertEqual(item.title, "foo")
  }

  func testImage() {
    let image = NSImage(named: "NSBluetoothTemplate")!
    let item = historyItem(image)
    XCTAssertEqual(item.title, "")
  }

  func testFile() {
    let url = URL(fileURLWithPath: "/tmp/foo.bar")
    let item = historyItem(url)
    XCTAssertEqual(item.title, "file:///tmp/foo.bar")
  }

  func testFileWithEscapedChars() {
    let url = URL(fileURLWithPath: "/tmp/产品培训/产品培训.txt")
    let item = historyItem(url)
    XCTAssertEqual(item.title, "file:///tmp/产品培训/产品培训.txt")
  }

  func testTextFromUniversalClipboard() {
    let url = URL(fileURLWithPath: "/tmp/foo.bar")
    let fileURLContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.fileURL.rawValue,
      value: url.dataRepresentation
    )
    let textContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.string.rawValue,
      value: url.lastPathComponent.data(using: .utf8)
    )
    let universalClipboardContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
      value: "".data(using: .utf8)
    )
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = [fileURLContent, textContent, universalClipboardContent]
    item.title = item.generateTitle()
    XCTAssertEqual(item.title, "foo.bar")
  }

  func testImageFromUniversalClipboard() {
    let url = Bundle(for: type(of: self)).url(forResource: "guy", withExtension: "jpeg")!
    let fileURLContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.fileURL.rawValue,
      value: url.dataRepresentation
    )
    let universalClipboardContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
      value: "".data(using: .utf8)
    )
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = [fileURLContent, universalClipboardContent]
    XCTAssertEqual(item.image!.tiffRepresentation, NSImage(data: try! Data(contentsOf: url))!.tiffRepresentation)
  }

  func testFileFromUniversalClipboard() {
    let url = URL(fileURLWithPath: "/tmp/foo.bar")
    let fileURLContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.fileURL.rawValue,
      value: url.dataRepresentation
    )
    let universalClipboardContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
      value: "".data(using: .utf8)
    )
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = [fileURLContent, universalClipboardContent]
    item.title = item.generateTitle()
    XCTAssertEqual(item.title, "file:///tmp/foo.bar")
  }

  func testItemWithoutData() {
    let item = historyItem(nil)
    XCTAssertEqual(item.title, "")
  }

  func testSeveralItemsCanHaveEmptyPin() {
    let item1 = historyItem("foo")
    item1.pin = ""
    let item2 = historyItem("bar")
    item2.pin = ""
    XCTAssertNoThrow(try Storage.shared.context.save())
    XCTAssertEqual(item1.pin, "")
    XCTAssertEqual(item2.pin, "")
  }

  private func historyItem(_ value: String?) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: value?.data(using: .utf8)
      )
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.title = item.generateTitle()

    return item
  }

  private func historyItem(_ data: Data?, _ type: NSPasteboard.PasteboardType) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: type.rawValue,
        value: data
      )
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.title = item.generateTitle()

    return item
  }

  private func historyItem(_ value: NSImage) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.tiff.rawValue,
        value: value.tiffRepresentation!
      )
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.title = item.generateTitle()

    return item
  }

  private func historyItem(_ value: URL) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.fileURL.rawValue,
        value: value.dataRepresentation
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: value.lastPathComponent.data(using: .utf8)
      )
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.title = item.generateTitle()

    return item
  }
}
// swiftlint:enable force_try
