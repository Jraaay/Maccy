import AppKit
import Darwin
import Defaults
import Fuse

class Search {
  enum Mode: String, CaseIterable, Identifiable, CustomStringConvertible, Defaults.Serializable, Sendable {
    case exact
    case fuzzy
    case regexp
    case mixed

    var id: Self { self }

    var description: String {
      switch self {
      case .exact:
        return NSLocalizedString("Exact", tableName: "GeneralSettings", comment: "")
      case .fuzzy:
        return NSLocalizedString("Fuzzy", tableName: "GeneralSettings", comment: "")
      case .regexp:
        return NSLocalizedString("Regex", tableName: "GeneralSettings", comment: "")
      case .mixed:
        return NSLocalizedString("Mixed", tableName: "GeneralSettings", comment: "")
      }
    }
  }

  struct SearchResult: Equatable {
    var score: Double?
    var object: Searchable
    var ranges: [Range<String.Index>] = []
  }

  typealias Searchable = HistoryItemDecorator

  // Only immutable values cross to the search worker; SwiftData and observable UI
  // objects stay on the main thread.
  struct Document: Sendable {
    let id: UUID
    let title: String
    // Immutable snapshots carry an identity so warm searches need not rescan
    // every title just to decide whether its index is still valid.
    let revision = UUID()
  }

  struct Match: Sendable, Equatable {
    let id: UUID
    var score: Double?
    var ranges: [Range<String.Index>] = []
  }

  // Confined to one actor: obsolete searches can be cancelled without racing
  // updates to the cache. Only title text is indexed, never clipboard payloads.
  actor Index {
    private var entries: [UUID: IndexedTitle] = [:]

    var documentCount: Int { entries.count }
    var indexedByteCount: Int {
      entries.values.reduce(0) { $0 + $1.bytes.count + $1.checkpoints.count * MemoryLayout<Checkpoint>.stride }
    }

    func prepare(documents: [Document]) {
      retainCurrentDocuments(documents)
      for document in documents {
        guard !Task.isCancelled else { return }
        _ = indexedTitle(for: document)
      }
    }

    func search(string: String, documents: [Document], mode: Mode) -> [Match] {
      guard !Task.isCancelled else { return [] }
      retainCurrentDocuments(documents)
      // Keep the original matcher for complex queries. In particular, expanding
      // case folds (e.g. ß) and partial graphemes have different search semantics.
      guard (mode == .exact || mode == .mixed), !string.isEmpty,
            string.unicodeScalars.allSatisfy({
              $0.isASCII || (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
            }) else {
        return Search.search(string: string, documents: documents, mode: mode, isCancelled: { Task.isCancelled })
      }
      let needle = Self.fold(string)
      return Search.search(
        string: string, documents: documents, mode: mode, isCancelled: { Task.isCancelled },
        candidateRange: { document in
          let entry = self.indexedTitle(for: document)
          guard let offset = entry.candidateUTF16Offset(for: needle) else { return nil }
          let start = String.Index(utf16Offset: offset, in: document.title)
          return start..<document.title.endIndex
        }
      )
    }

    func retain(documentIDs: Set<UUID>) {
      entries = entries.filter { documentIDs.contains($0.key) }
    }

    private func retainCurrentDocuments(_ documents: [Document]) {
      retain(documentIDs: Set(documents.map(\.id)))
    }

    private func indexedTitle(for document: Document) -> IndexedTitle {
      if let entry = entries[document.id], entry.revision == document.revision { return entry }
      let entry = autoreleasepool { IndexedTitle(document: document) }
      entries[document.id] = entry
      return entry
    }

    private static func fold(_ string: String) -> [UInt8] {
      Array(string.folding(options: .caseInsensitive, locale: nil).decomposedStringWithCanonicalMapping.utf8)
    }

    private struct Checkpoint {
      let byteOffset: Int
      let utf16Offset: Int
    }

    private struct IndexedTitle {
      let revision: UUID
      var bytes: [UInt8] = []
      var checkpoints: [Checkpoint] = []

      init(document: Document) {
        revision = document.revision
        let title = document.title
        var start = title.startIndex
        var utf16Offset = 0
        // Start verification at a known original grapheme boundary before the
        // candidate. This preserves the original first match and its exact range.
        while start < title.endIndex {
          let end = title.index(start, offsetBy: 32, limitedBy: title.endIndex) ?? title.endIndex
          let chunk = String(title[start..<end])
          checkpoints.append(Checkpoint(byteOffset: bytes.count, utf16Offset: utf16Offset))
          bytes.append(contentsOf: Index.fold(chunk))
          utf16Offset += chunk.utf16.count
          start = end
        }
      }

      func candidateUTF16Offset(for needle: [UInt8]) -> Int? {
        guard !needle.isEmpty, bytes.count >= needle.count else { return nil }
        let offset: Int? = bytes.withUnsafeBytes { haystack in
          needle.withUnsafeBytes { pattern in
            guard let found = memmem(haystack.baseAddress!, haystack.count, pattern.baseAddress!, pattern.count) else {
              return nil
            }
            return haystack.baseAddress!.distance(to: UnsafeRawPointer(found))
          }
        }
        guard let offset else { return nil }
        var lower = 0
        var upper = checkpoints.count
        while lower < upper {
          let middle = (lower + upper) / 2
          if checkpoints[middle].byteOffset <= offset { lower = middle + 1 } else { upper = middle }
        }
        return checkpoints[lower - 1].utf16Offset
      }
    }
  }

  func search(string: String, within: [Searchable]) -> [SearchResult] {
    let objects = Dictionary(uniqueKeysWithValues: within.map { ($0.id, $0) })
    return Self.search(
      string: string,
      documents: within.map(\.searchDocument),
      mode: Defaults[.searchMode]
    ).compactMap { match in
      guard let object = objects[match.id] else { return nil }
      return SearchResult(score: match.score, object: object, ranges: match.ranges)
    }
  }

  static func search(
    string: String,
    documents: [Document],
    mode: Mode,
    isCancelled: () -> Bool = { false },
    candidateRange: ((Document) -> Range<String.Index>?)? = nil
  ) -> [Match] {
    guard !isCancelled() else { return [] }
    guard !string.isEmpty else { return documents.map { Match(id: $0.id) } }

    switch mode {
    case .exact:
      return exactSearch(string, documents, isCancelled, candidateRange)
    case .regexp:
      return regexSearch(string, documents, isCancelled)
    case .fuzzy:
      return fuzzySearch(string, documents, isCancelled)
    case .mixed:
      let exact = exactSearch(string, documents, isCancelled, candidateRange)
      guard exact.isEmpty, !isCancelled() else { return exact }
      let regex = regexSearch(string, documents, isCancelled)
      guard regex.isEmpty, !isCancelled() else { return regex }
      return fuzzySearch(string, documents, isCancelled)
    }
  }

  private static func exactSearch(
    _ query: String, _ documents: [Document], _ isCancelled: () -> Bool,
    _ candidateRange: ((Document) -> Range<String.Index>?)?
  ) -> [Match] {
    var results: [Match] = []
    for document in documents {
      guard !isCancelled() else { return [] }
      let bounds: Range<String.Index>
      if let candidateRange {
        guard let candidate = candidateRange(document) else { continue }
        bounds = candidate
      } else {
        bounds = document.title.startIndex..<document.title.endIndex
      }
      if let range = document.title.range(of: query, options: .caseInsensitive, range: bounds) {
        results.append(Match(id: document.id, ranges: [range]))
      }
    }
    return results
  }

  private static func regexSearch(
    _ query: String, _ documents: [Document], _ isCancelled: () -> Bool
  ) -> [Match] {
    // Compile once per query rather than once per history entry.
    guard let regex = try? NSRegularExpression(pattern: query) else { return [] }
    var results: [Match] = []
    for document in documents {
      guard !isCancelled() else { return [] }
      let title = document.title
      regex.enumerateMatches(in: title, options: .reportProgress, range: NSRange(title.startIndex..., in: title)) {
        match, _, stop in
        if isCancelled() {
          stop.pointee = true
        } else if let match, let range = Range(match.range, in: title) {
          results.append(Match(id: document.id, ranges: [range]))
          stop.pointee = true
        }
      }
    }
    return isCancelled() ? [] : results
  }

  private static func fuzzySearch(
    _ query: String, _ documents: [Document], _ isCancelled: () -> Bool
  ) -> [Match] {
    let fuse = Fuse(threshold: 0.7)
    let pattern = fuse.createPattern(from: query)
    var results: [Match] = []
    for document in documents {
      guard !isCancelled() else { return [] }
      // Preserve the original 5,001-character window without counting the whole title.
      let title = String(document.title.prefix(5_001))
      if let match = fuse.search(pattern, in: title) {
        // Build indices in the original string, including for long Unicode titles.
        let ranges = match.ranges.map { range in
          let lower = document.title.index(document.title.startIndex, offsetBy: range.lowerBound)
          let upper = document.title.index(lower, offsetBy: range.count)
          return lower..<upper
        }
        results.append(Match(id: document.id, score: match.score, ranges: ranges))
      }
    }
    guard !isCancelled() else { return [] }
    return results.sorted { ($0.score ?? 0) < ($1.score ?? 0) }
  }
}
