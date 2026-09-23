import AppKit
import Defaults
import ImageIO
import Sauce
import SwiftData
import Vision

@Model
class HistoryItem {
  static var supportedPins: Set<String> {
    // "a" reserved for select all
    // "q" reserved for quit
    // "v" reserved for paste
    // "w" reserved for close window
    // "z" reserved for undo/redo
    var keys = Set([
      "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l",
      "m", "n", "o", "p", "r", "s", "t", "u", "x", "y"
    ])

    if let deleteKey = KeyChord.deleteKey,
       let character = Sauce.shared.character(for: Int(deleteKey.QWERTYKeyCode), cocoaModifiers: []) {
      keys.remove(character)
    }

    if let pinKey = KeyChord.pinKey,
       let character = Sauce.shared.character(for: Int(pinKey.QWERTYKeyCode), cocoaModifiers: []) {
      keys.remove(character)
    }
    if let previewKey = KeyChord.previewKey,
       let character = Sauce.shared.character(for: Int(previewKey.QWERTYKeyCode), cocoaModifiers: []) {
      keys.remove(character)
    }

    return keys
  }

  @MainActor
  static var availablePins: [String] {
    availablePins(in: History.shared.all.compactMap {
      if $0.isPinned { return $0.item }
      return nil
    })
  }

  @MainActor
  static func availablePins(in items: [HistoryItem]) -> [String] {
    let assignedPins = Set(items.compactMap(\.pin))
    return Array(supportedPins.subtracting(assignedPins))
  }

  @MainActor
  static var randomAvailablePin: String { availablePins.randomElement() ?? "" }

  private static let transientTypes: [String] = [
    NSPasteboard.PasteboardType.modified.rawValue,
    NSPasteboard.PasteboardType.fromMaccy.rawValue,
    NSPasteboard.PasteboardType.linkPresentationMetadata.rawValue,
    NSPasteboard.PasteboardType.customWebKitPasteboardData.rawValue,
    NSPasteboard.PasteboardType.source.rawValue,
    NSPasteboard.PasteboardType.customChromiumWebData.rawValue,
    NSPasteboard.PasteboardType.chromiumSourceUrl.rawValue,
    NSPasteboard.PasteboardType.chromiumSourceToken.rawValue,
    NSPasteboard.PasteboardType.notesRichText.rawValue
  ]
  private static let imageTypes: [NSPasteboard.PasteboardType] = StorageType.images.types

  var application: String?
  var firstCopiedAt: Date = Date.now
  var lastCopiedAt: Date = Date.now
  var numberOfCopies: Int = 1
  var pin: String?
  var title = ""

  @Relationship(deleteRule: .cascade, inverse: \HistoryItemContent.item)
  var contents: [HistoryItemContent] = []


  init(contents: [HistoryItemContent] = []) {
    self.firstCopiedAt = firstCopiedAt
    self.lastCopiedAt = lastCopiedAt
    self.contents = contents
  }

  func supersedes(_ item: HistoryItem) -> Bool {
    return item.contents
      .filter { content in
        !Self.transientTypes.contains(content.type)
      }
      .allSatisfy { content in
        contents.contains(where: { $0.type == content.type && $0.hasSameData(as: content) })
      }
  }

  func generateTitle() -> String {
    guard !hasImage else {
      Task {
        self.performTextRecognition()
      }
      return ""
    }

    // 1k characters is trade-off for performance
    var title = previewableText
      .shortened(to: 1_000)
      .removingScalarsUnsafeForTitleLayout()

    if Defaults[.showSpecialSymbols] {
      if let range = title.range(of: "^ +", options: .regularExpression) {
        title = title.replacingOccurrences(of: " ", with: "·", range: range)
      }
      if let range = title.range(of: " +$", options: .regularExpression) {
        title = title.replacingOccurrences(of: " ", with: "·", range: range)
      }
      title = title
        .replacingOccurrences(of: "\n", with: "⏎")
        .replacingOccurrences(of: "\t", with: "⇥")
    } else {
      title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return title
  }

  var previewableText: String {
    if !fileURLs.isEmpty {
      fileURLs
        .compactMap { $0.absoluteString.removingPercentEncoding }
        .joined(separator: "\n")
    } else if let text = text, !text.isEmpty {
      text
    } else if let rtf = rtf, !rtf.string.isEmpty {
      rtf.string
    } else if let html = html, !html.string.isEmpty {
      html.string
    } else {
      title
    }
  }

  var fileURLs: [URL] {
    guard !universalClipboardText else {
      return []
    }

    return allContentData([.fileURL])
      .compactMap { URL(dataRepresentation: $0, relativeTo: nil, isAbsolute: true) }
  }

  var htmlData: Data? { contentData([.html]) }
  var html: NSAttributedString? {
    guard let data = htmlData else {
      return nil
    }

    return NSAttributedString(html: data, documentAttributes: nil)
  }

  var imageData: Data? {
    var data: Data?
    data = contentData(Self.imageTypes)
    if data == nil, universalClipboardImage, let url = fileURLs.first {
      data = try? Data(contentsOf: url)
    }

    return data
  }

  // Checking image presence must not decode and retain every image in the list.
  var hasImage: Bool {
    contents.contains { Self.imageTypes.contains(NSPasteboard.PasteboardType($0.type)) } || universalClipboardImage
  }

  var image: NSImage? {
    guard let data = imageData else { return nil }
    return NSImage(data: data)
  }

  var imagePixelSize: NSSize? {
    guard let source = imageSource(),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
    return NSSize(width: width.doubleValue, height: height.doubleValue)
  }

  func scaledImage(to bounds: NSSize, scale: CGFloat = 2) -> NSImage? {
    guard let source = imageSource(),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
    let pixelSize = NSSize(width: width.doubleValue, height: height.doubleValue)
    let dpiX = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
    let dpiY = (properties[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue ?? 72
    var size = NSSize(width: pixelSize.width * 72 / max(1, dpiX), height: pixelSize.height * 72 / max(1, dpiY))
    if let orientation = properties[kCGImagePropertyOrientation] as? NSNumber,
       (5...8).contains(orientation.intValue) {
      size = NSSize(width: size.height, height: size.width)
    }
    guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
    let ratio = min(1, bounds.width / size.width, bounds.height / size.height)
    let displaySize = NSSize(width: size.width * ratio, height: size.height * ratio)
    let maxPixels = max(1, min(max(pixelSize.width, pixelSize.height), max(displaySize.width, displaySize.height) * scale))
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: Int(ceil(maxPixels)),
      kCGImageSourceShouldCacheImmediately: true
    ]
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: thumbnail, size: displaySize)
  }

  private func imageSource() -> CGImageSource? {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    if let content = contents.first(where: { Self.imageTypes.contains(NSPasteboard.PasteboardType($0.type)) }) {
      if let url = content.fileURL {
        return CGImageSourceCreateWithURL(url as CFURL, options)
      }
      if let data = content.data {
        return CGImageSourceCreateWithData(data as CFData, options)
      }
    } else if universalClipboardImage, let url = fileURLs.first {
      return CGImageSourceCreateWithURL(url as CFURL, options)
    }
    return nil
  }

  var rtfData: Data? { contentData([.rtf]) }
  var rtf: NSAttributedString? {
    guard let data = rtfData else {
      return nil
    }

    return NSAttributedString(rtf: data, documentAttributes: nil)
  }

  var text: String? {
    guard let data = contentData([.string]) else {
      return nil
    }

    return String(data: data, encoding: .utf8)
  }

  var modified: Int? {
    guard let data = contentData([.modified]),
          let modified = String(data: data, encoding: .utf8) else {
      return nil
    }

    return Int(modified)
  }

  var fromMaccy: Bool { hasContent([.fromMaccy]) }
  var universalClipboard: Bool { hasContent([.universalClipboard]) }

  private var universalClipboardImage: Bool { universalClipboard && fileURLs.first?.pathExtension == "jpeg" }
  private var universalClipboardText: Bool {
    universalClipboard && hasContent([.html, .tiff, .png, .jpeg, .rtf, .string, .heic])
  }

  private func hasContent(_ types: [NSPasteboard.PasteboardType]) -> Bool {
    contents.contains { types.contains(NSPasteboard.PasteboardType($0.type)) && $0.hasValue }
  }

  private func contentData(_ types: [NSPasteboard.PasteboardType]) -> Data? {
    let content = contents.first(where: { content in
      return types.contains(NSPasteboard.PasteboardType(content.type))
    })

    return content?.data
  }

  private func allContentData(_ types: [NSPasteboard.PasteboardType]) -> [Data] {
    return contents
      .filter { types.contains(NSPasteboard.PasteboardType($0.type)) }
      .compactMap { $0.data }
  }

  private func performTextRecognition() {
    guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return
    }

    let requestHandler = VNImageRequestHandler(cgImage: cgImage)
    let request = VNRecognizeTextRequest(completionHandler: recognizeTextHandler)
    request.recognitionLevel = .fast

    do {
      try requestHandler.perform([request])
    } catch {
      print("Unable to perform the request: \(error).")
    }
  }

  private func recognizeTextHandler(request: VNRequest, error: Error?) {
    guard let observations = request.results as? [VNRecognizedTextObservation] else {
      return
    }

    let recognizedStrings = observations.compactMap { observation in
      return observation.topCandidates(1).first?.string
    }

    self.title = recognizedStrings.joined(separator: "\n")
  }
}
