import AppKit
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
  }

  struct Match: Sendable {
    let id: UUID
    var score: Double?
    var ranges: [Range<String.Index>] = []
  }

  func search(string: String, within: [Searchable]) -> [SearchResult] {
    let objects = Dictionary(uniqueKeysWithValues: within.map { ($0.id, $0) })
    return Self.search(
      string: string,
      documents: within.map { Document(id: $0.id, title: $0.title) },
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
    isCancelled: () -> Bool = { false }
  ) -> [Match] {
    guard !isCancelled() else { return [] }
    guard !string.isEmpty else { return documents.map { Match(id: $0.id) } }

    switch mode {
    case .exact:
      return exactSearch(string, documents, isCancelled)
    case .regexp:
      return regexSearch(string, documents, isCancelled)
    case .fuzzy:
      return fuzzySearch(string, documents, isCancelled)
    case .mixed:
      let exact = exactSearch(string, documents, isCancelled)
      guard exact.isEmpty, !isCancelled() else { return exact }
      let regex = regexSearch(string, documents, isCancelled)
      guard regex.isEmpty, !isCancelled() else { return regex }
      return fuzzySearch(string, documents, isCancelled)
    }
  }

  private static func exactSearch(
    _ query: String, _ documents: [Document], _ isCancelled: () -> Bool
  ) -> [Match] {
    var results: [Match] = []
    for document in documents {
      guard !isCancelled() else { return [] }
      if let range = document.title.range(of: query, options: .caseInsensitive) {
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
