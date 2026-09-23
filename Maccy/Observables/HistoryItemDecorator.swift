import AppKit.NSWorkspace
import Defaults
import Foundation
import Observation
import Sauce

@Observable
class HistoryItemDecorator: Identifiable, Hashable, HasVisibility {
  static func == (lhs: HistoryItemDecorator, rhs: HistoryItemDecorator) -> Bool {
    return lhs.id == rhs.id
  }

  static var previewImageSize: NSSize { NSScreen.forPopup?.visibleFrame.size ?? NSSize(width: 2048, height: 1536) }
  static var thumbnailImageSize: NSSize { NSSize(width: 340, height: Defaults[.imageMaxHeight]) }

  let id = UUID()

  var title: String = "" {
    didSet {
      guard title != oldValue else { return }
      cachedAttributedTitle = nil
      highlightRanges = []
    }
  }
  private var highlightRanges: [Range<String.Index>] = []
  private var isHighlighted = false
  @ObservationIgnored private var cachedAttributedTitle: AttributedString?
  @ObservationIgnored private var cachedHighlightStyle: HighlightMatch?

  // SwiftUI's lazy rows only request this for content being rendered.
  var attributedTitle: AttributedString? {
    guard isHighlighted, !title.isEmpty else { return nil }
    let ranges = highlightRanges
    let style = Defaults[.highlightMatch]
    if let cachedAttributedTitle, cachedHighlightStyle == style { return cachedAttributedTitle }
    let value = makeAttributedTitle(ranges, style: style)
    cachedHighlightStyle = style
    cachedAttributedTitle = value
    return value
  }

  var isVisible: Bool = true
  var selectionIndex: Int = -1
  var isSelected: Bool {
    return selectionIndex != -1
  }
  var shortcuts: [KeyShortcut] = []

  var application: String? {
    if item.universalClipboard {
      return "iCloud"
    }

    guard let bundle = item.application,
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
    else {
      return nil
    }

    return url.deletingPathExtension().lastPathComponent
  }

  var hasImage: Bool { item.hasImage }

  var previewImageGenerationTask: Task<(), Error>?
  var thumbnailImageGenerationTask: Task<(), Error>?
  var previewImage: NSImage?
  var previewText: String {
    item.previewableText
  }
  var thumbnailImage: NSImage?
  var applicationImage: ApplicationImage

  // 10k characters seems to be more than enough on large displays
  var text: String { previewText.shortened(to: 10_000) }

  var isPinned: Bool { item.pin != nil }
  var isUnpinned: Bool { item.pin == nil }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  private(set) var item: HistoryItem
  
  var multiSelectionIndex: Int? {
    guard AppState.shared.navigator.isMultiSelectInProgress else {
      return nil
    }
    return selectionIndex
  }
  
  // Describe the complete item independently of its potentially truncated visual content.
  var accessibilityLabel: String {
    var parts: [String] = []
    if hasImage, let size = item.imagePixelSize {
      parts.append(String(format: NSLocalizedString("history_item_image_accessibility_label_no_app", comment: ""), Int(size.width), Int(size.height)))
    } else {
      parts.append(title)
    }
    if let application = application {
      parts.append(application)
    }
    if isPinned {
      parts.append(NSLocalizedString("history_item_pinned_accessibility_value", comment: ""))
    }
    if let index = multiSelectionIndex {
      parts.append(String(format: NSLocalizedString("history_item_selected_accessibility_value", comment: ""), index + 1, AppState.shared.navigator.selection.count))
    }
    return parts.joined(separator: ", ")
  }

  init(_ item: HistoryItem, shortcuts: [KeyShortcut] = []) {
    self.item = item
    self.shortcuts = shortcuts
    self.title = item.title
    self.applicationImage = ApplicationImageCache.shared.getImage(item: item)

    synchronizeItemPin()
    synchronizeItemTitle()
  }

  @MainActor
  func ensureThumbnailImage() {
    guard hasImage else {
      return
    }
    guard thumbnailImage == nil else {
      return
    }
    guard thumbnailImageGenerationTask == nil else {
      return
    }
    thumbnailImageGenerationTask = Task { [weak self] in
      guard !Task.isCancelled else { return }
      self?.generateThumbnailImage()
    }
  }

  @MainActor
  func ensurePreviewImage() {
    guard hasImage else {
      return
    }
    guard previewImage == nil else {
      return
    }
    guard previewImageGenerationTask == nil else {
      return
    }
    previewImageGenerationTask = Task { [weak self] in
      guard !Task.isCancelled else { return }
      self?.generatePreviewImage()
    }
  }

  @MainActor
  func asyncGetPreviewImage() async -> NSImage? {
    if let image = previewImage {
      return image
    }
    ensurePreviewImage()
    _ = await previewImageGenerationTask?.result
    return previewImage
  }

  @MainActor
  func cleanupImages() {
    thumbnailImageGenerationTask?.cancel()
    thumbnailImageGenerationTask = nil
    thumbnailImage?.recache()
    thumbnailImage = nil
    cleanupPreviewImage()
  }

  @MainActor
  func cleanupPreviewImage() {
    previewImageGenerationTask?.cancel()
    previewImageGenerationTask = nil
    previewImage?.recache()
    previewImage = nil
  }

  @MainActor
  private func generateThumbnailImage() {
    thumbnailImage = item.scaledImage(to: HistoryItemDecorator.thumbnailImageSize)
  }

  @MainActor
  private func generatePreviewImage() {
    previewImage = item.scaledImage(to: HistoryItemDecorator.previewImageSize)
  }

  @MainActor
  func sizeImages() {
    generatePreviewImage()
    generateThumbnailImage()
  }

  func highlight(_ query: String, _ ranges: [Range<String.Index>]) {
    let active = !query.isEmpty
    guard isHighlighted != active || highlightRanges != ranges else { return }
    cachedAttributedTitle = nil
    isHighlighted = active
    highlightRanges = ranges
  }

  private func makeAttributedTitle(_ ranges: [Range<String.Index>], style: HighlightMatch) -> AttributedString {
    var attributedString = AttributedString(title.shortened(to: 500))
    for range in ranges {
      if let lowerBound = AttributedString.Index(range.lowerBound, within: attributedString),
         let upperBound = AttributedString.Index(range.upperBound, within: attributedString) {
        switch style {
        case .bold:
          attributedString[lowerBound..<upperBound].font = .bold(.body)()
        case .italic:
          attributedString[lowerBound..<upperBound].font = .italic(.body)()
        case .underline:
          attributedString[lowerBound..<upperBound].underlineStyle = .single
        default:
          attributedString[lowerBound..<upperBound].backgroundColor = .findHighlightColor
          attributedString[lowerBound..<upperBound].foregroundColor = .black
        }
      }
    }

    return attributedString
  }

  @MainActor
  func togglePin() {
    if item.pin != nil {
      item.pin = nil
      shortcuts = []
    } else {
      let pin = HistoryItem.randomAvailablePin
      item.pin = pin
    }
  }

  private func synchronizeItemPin() {
    _ = withObservationTracking {
      item.pin
    } onChange: { [weak self] in
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        if let pin = self.item.pin {
          self.shortcuts = KeyShortcut.create(character: pin)
        }
        self.synchronizeItemPin()
      }
    }
  }

  private func synchronizeItemTitle() {
    _ = withObservationTracking {
      item.title
    } onChange: { [weak self] in
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.title = self.item.title
        self.synchronizeItemTitle()
      }
    }
  }
}
