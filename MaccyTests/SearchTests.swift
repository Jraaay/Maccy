import XCTest
import Defaults
@testable import Maccy

class SearchTests: XCTestCase {
  let savedSearchMode = Defaults[.searchMode]
  var items: [Search.Searchable]!

  override func tearDown() {
    super.tearDown()
    Defaults[.searchMode] = savedSearchMode
  }

  @MainActor
  func testSimpleSearch() { // swiftlint:disable:this function_body_length
    Defaults[.searchMode] = Search.Mode.exact
    items = [
      HistoryItemDecorator(historyItemWithTitle("foo bar baz")),
      HistoryItemDecorator(historyItemWithTitle("foo bar zaz")),
      HistoryItemDecorator(historyItemWithTitle("xxx yyy zzz"))
    ]

    XCTAssertEqual(search(""), [
      Search.SearchResult(score: nil, object: items[0], ranges: []),
      Search.SearchResult(score: nil, object: items[1], ranges: []),
      Search.SearchResult(score: nil, object: items[2], ranges: [])
    ])
    XCTAssertEqual(search("z"), [
      Search.SearchResult(
        score: nil,
        object: items[0],
        ranges: [range(from: 10, to: 10, in: items[0])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[1],
        ranges: [range(from: 8, to: 8, in: items[1])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[2],
        ranges: [range(from: 8, to: 8, in: items[2])]
      )
    ])
    XCTAssertEqual(search("foo"), [
      Search.SearchResult(
        score: nil,
        object: items[0],
        ranges: [range(from: 0, to: 2, in: items[0])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[1],
        ranges: [range(from: 0, to: 2, in: items[1])]
      )
    ])
    XCTAssertEqual(search("za"), [
      Search.SearchResult(
        score: nil,
        object: items[1],
        ranges: [range(from: 8, to: 9, in: items[1])]
      )
    ])
    XCTAssertEqual(search("yyy"), [
      Search.SearchResult(
        score: nil,
        object: items[2],
        ranges: [range(from: 4, to: 6, in: items[2])]
      )
    ])
    XCTAssertEqual(search("fbb"), [])
    XCTAssertEqual(search("m"), [])
  }

  @MainActor
  func testFuzzySearch() { // swiftlint:disable:this function_body_length
    Defaults[.searchMode] = Search.Mode.fuzzy
    items = [
      HistoryItemDecorator(historyItemWithTitle("foo bar baz")),
      HistoryItemDecorator(historyItemWithTitle("foo bar zaz")),
      HistoryItemDecorator(historyItemWithTitle("xxx yyy zzz"))
    ]

    XCTAssertEqual(search(""), [
      Search.SearchResult(score: nil, object: items[0], ranges: []),
      Search.SearchResult(score: nil, object: items[1], ranges: []),
      Search.SearchResult(score: nil, object: items[2], ranges: [])
    ])
    XCTAssertEqual(search("z"), [
      Search.SearchResult(
        score: 0.08,
        object: items[1],
        ranges: [range(from: 8, to: 8, in: items[1]), range(from: 10, to: 10, in: items[1])]
      ),
      Search.SearchResult(
        score: 0.08,
        object: items[2],
        ranges: [range(from: 8, to: 10, in: items[2])]
      ),
      Search.SearchResult(
        score: 0.1,
        object: items[0],
        ranges: [range(from: 10, to: 10, in: items[0])]
      )
    ])
    XCTAssertEqual(search("foo"), [
      Search.SearchResult(
        score: 0.0,
        object: items[0],
        ranges: [range(from: 0, to: 2, in: items[0])]
      ),
      Search.SearchResult(
        score: 0.0,
        object: items[1],
        ranges: [range(from: 0, to: 2, in: items[1])]
      )
    ])
    XCTAssertEqual(search("za"), [
      Search.SearchResult(
        score: 0.08,
        object: items[1],
        ranges: [range(from: 5, to: 5, in: items[1]), range(from: 8, to: 9, in: items[1])]
      ),
      Search.SearchResult(
        score: 0.54,
        object: items[0],
        ranges: [range(from: 5, to: 5, in: items[0]), range(from: 9, to: 10, in: items[0])]
      ),
      Search.SearchResult(
        score: 0.58,
        object: items[2],
        ranges: [range(from: 8, to: 10, in: items[2])]
      )
    ])
    XCTAssertEqual(search("yyy"), [
      Search.SearchResult(
        score: 0.04,
        object: items[2],
        ranges: [range(from: 4, to: 6, in: items[2])]
      )
    ])
    XCTAssertEqual(search("fbb"), [
      Search.SearchResult(
        score: 0.6666666666666666,
        object: items[0],
        ranges: [
          range(from: 0, to: 0, in: items[0]),
          range(from: 4, to: 4, in: items[0]),
          range(from: 8, to: 8, in: items[0])
        ]
      ),
      Search.SearchResult(
        score: 0.6666666666666666,
        object: items[1],
        ranges: [range(from: 0, to: 0, in: items[1]), range(from: 4, to: 4, in: items[1])])
    ])
    XCTAssertEqual(search("m"), [])
  }

  @MainActor
  func testRegexpSearch() { // swiftlint:disable:this function_body_length
    Defaults[.searchMode] = Search.Mode.regexp
    items = [
      HistoryItemDecorator(historyItemWithTitle("foo bar baz")),
      HistoryItemDecorator(historyItemWithTitle("foo bar zaz")),
      HistoryItemDecorator(historyItemWithTitle("xxx yyy zzz"))
    ]

    XCTAssertEqual(search(""), [
      Search.SearchResult(score: nil, object: items[0], ranges: []),
      Search.SearchResult(score: nil, object: items[1], ranges: []),
      Search.SearchResult(score: nil, object: items[2], ranges: [])
    ])
    XCTAssertEqual(search("z+"), [
      Search.SearchResult(
        score: nil,
        object: items[0],
        ranges: [range(from: 10, to: 10, in: items[0])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[1],
        ranges: [range(from: 8, to: 8, in: items[1])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[2],
        ranges: [range(from: 8, to: 10, in: items[2])]
      )
    ])
    XCTAssertEqual(search("z*"), [
      Search.SearchResult(
        score: nil,
        object: items[0],
        ranges: [range(from: 0, to: -1, in: items[0])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[1],
        ranges: [range(from: 0, to: -1, in: items[1])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[2],
        ranges: [range(from: 0, to: -1, in: items[2])]
      )
    ])
    XCTAssertEqual(search("^foo"), [
      Search.SearchResult(
        score: nil,
        object: items[0], ranges: [range(from: 0, to: 2, in: items[0])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[1], ranges: [range(from: 0, to: 2, in: items[1])]
      )
    ])
    XCTAssertEqual(search(" za"), [
      Search.SearchResult(
        score: nil,
        object: items[1],
        ranges: [range(from: 7, to: 9, in: items[1])]
      )
    ])
    XCTAssertEqual(search("[y]+"), [
      Search.SearchResult(
        score: nil,
        object: items[2],
        ranges: [range(from: 4, to: 6, in: items[2])]
      )
    ])
    XCTAssertEqual(search("fbb"), [])
    XCTAssertEqual(search("m"), [])
  }

  func testSnapshotSearchUnicodeAndInvalidRegex() {
    let title = "你好 👩🏽‍💻 café CAFE"
    let document = Search.Document(id: UUID(), title: title)
    for (query, mode) in [("👩🏽‍💻", Search.Mode.exact), ("c.fé", .regexp), ("你好", .fuzzy)] {
      let matches = Search.search(string: query, documents: [document], mode: mode)
      XCTAssertEqual(matches.count, 1)
      XCTAssertEqual(matches.first?.id, document.id)
      for range in matches[0].ranges {
        XCTAssertFalse(String(title[range]).isEmpty)
      }
    }
    XCTAssertTrue(Search.search(string: "[", documents: [document], mode: .regexp).isEmpty)
    XCTAssertEqual(Search.search(string: "cafe", documents: [document], mode: .exact).count, 1)
  }

  func testMixedFallbackPreservesPriority() {
    let documents = ["foo", "f.o", "fob"].map { Search.Document(id: UUID(), title: $0) }
    XCTAssertEqual(Search.search(string: "f.o", documents: documents, mode: .mixed).map(\.id),
                   [documents[1].id])
    XCTAssertEqual(Search.search(string: "^foo", documents: documents, mode: .mixed).map(\.id),
                   [documents[0].id])
    XCTAssertFalse(Search.search(string: "fbo", documents: documents, mode: .mixed).isEmpty)
  }

  func testCancellationDiscardsPartialMatches() {
    let documents = (0..<100).map { Search.Document(id: UUID(), title: "entry \($0)") }
    for mode in Search.Mode.allCases {
      var checks = 0
      let matches = Search.search(string: "entry", documents: documents, mode: mode) {
        checks += 1
        return checks > 10
      }
      XCTAssertTrue(matches.isEmpty)
      XCTAssertLessThan(checks, documents.count)
    }
  }

  func testFuzzyWindowKeepsValidUnicodeIndices() {
    let title = "你好 " + String(repeating: "a", count: 6_000)
    let document = Search.Document(id: UUID(), title: title)
    let matches = Search.search(string: "你好", documents: [document], mode: .fuzzy)
    XCTAssertEqual(matches.count, 1)
    XCTAssertEqual(String(title[matches[0].ranges[0]]), "你好")
  }

  func testSearch9999EntriesOffMainThread() async {
    let documents = (0..<9_999).map {
      Search.Document(id: UUID(), title: "Clipboard entry \($0): 开发记录 café " + String(repeating: "text ", count: 12))
    }
    for mode in Search.Mode.allCases {
      let result = await Task.detached {
        let start = ContinuousClock.now
        let matches = Search.search(string: "Clipboard", documents: documents, mode: mode)
        return (matches.count, Thread.isMainThread, start.duration(to: .now))
      }.value
      XCTAssertEqual(result.0, 9_999)
      XCTAssertFalse(result.1)
      print("SEARCH_BENCHMARK 9999 entries mode=\(mode.rawValue) duration=\(result.2)")
    }
  }

  func testIndexedSearchPreservesUnicodeMatchesAndRanges() async {
    let units = [
      "a", "A", "é", "e\u{301}", "ß", "SS", "ﬃ", "ffi", "Æ", "ae", "K", "k",
      "İ", "i", "ı", "I", "Σ", "σ", "ς", "ǅ", "ǆ", "ｶﾞ", "ガ", "か", "Ａ",
      "각", "각", "ᄀ", "ᅡ", "\u{301}", "\u{323}", "\u{FE0F}", "\u{200D}",
      "👩🏽‍💻", "👩", "🏽", "👨‍👩‍👧‍👦", "💻", "\0", "क़", "क़", "क", "ا", "أ",
      "\u{34F}", "\u{200B}", "\u{AD}", "\r\n", "\r", "\n", "目标", "开发"
    ]
    let titles = units + units.map { "prefix \($0) suffix" } + units.map { $0 + "\u{301}\u{323}a" }
    let documents = titles.map { Search.Document(id: UUID(), title: $0) }
    let queries = units + ["s", "f", "fi", "ss", "e", "prefix", "suffix", "不存在", "", "^prefix"]
    let index = Search.Index()
    for query in queries {
      for mode in [Search.Mode.exact, .mixed] {
        let expected = Search.search(string: query, documents: documents, mode: mode)
        let actual = await index.search(string: query, documents: documents, mode: mode)
        XCTAssertEqual(actual, expected, "query=\(query.debugDescription) mode=\(mode)")
      }
    }
  }

  func testIndexedSearchAcrossCheckpointsAndFalseCandidates() async {
    let index = Search.Index()
    let leads = ["x", "é", "e\u{301}", "👩🏽‍💻", "ß", "각", "ｶﾞ", "开发"]
    for lead in leads {
      for padding in [0, 1, 30, 31, 32, 33, 62, 63, 64, 65, 127] {
        let text = String(repeating: lead, count: padding)
        let documents = [
          text + "目标tokenA end", text + "CAFE end", text + "ss ffi i k a",
          "café " + text + " cafe", text + "a\u{301}\u{323} END", text + "无结果"
        ].map { Search.Document(id: UUID(), title: $0) }
        for query in ["目标tokena", "TOKENA", "cafe", "ss", "ffi", "i", "k", "a", "END", "___absent___"] {
          let expected = Search.search(string: query, documents: documents, mode: .exact)
          let actual = await index.search(string: query, documents: documents, mode: .exact)
          XCTAssertEqual(actual, expected, "lead=\(lead.debugDescription) padding=\(padding) query=\(query)")
        }
      }
    }
  }

  func testIndexMatchesReferenceOnDeterministicMixedUnicodeText() async {
    let units = ["t", "a", "r", "g", "e", "T", " ", "é", "e\u{301}", "ß", "İ", "👩🏽‍💻",
                 "\u{AD}", "\u{34F}", "\u{200D}", "\u{FEFF}", "\u{2060}", "\r\n", "\0", "目标", "开发", "麗"]
    var seed: UInt64 = 42
    func next(_ bound: Int) -> Int {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1
      return Int((seed >> 32) % UInt64(bound))
    }
    let documents = (0..<256).map { _ -> Search.Document in
      var title = ""
      for _ in 0..<100 { title += units[next(units.count)] }
      return Search.Document(id: UUID(), title: title)
    }
    let index = Search.Index()
    for query in ["target", "tArGeT", "a", "e", "i", "s", "ss", "ffi", "目标", "开发", "麗", "\n", "\0", "A B"] {
      let actual = await index.search(string: query, documents: documents, mode: .exact)
      XCTAssertEqual(actual, Search.search(string: query, documents: documents, mode: .exact), query)
    }
  }

  func testIndexInvalidatesByteChangesAndRemovesDeletedDocuments() async {
    let index = Search.Index()
    let id = UUID()
    let composed = Search.Document(id: id, title: String(repeating: "é", count: 64) + " target")
    let decomposed = Search.Document(id: id, title: String(repeating: "e\u{301}", count: 64) + " target")
    XCTAssertEqual(composed.title, decomposed.title)
    await index.prepare(documents: [composed])
    for document in [composed, decomposed, Search.Document(id: id, title: "different") ] {
      let result = await index.search(string: "target", documents: [document], mode: .exact)
      XCTAssertEqual(result, Search.search(string: "target", documents: [document], mode: .exact))
    }
    await index.retain(documentIDs: [])
    let count = await index.documentCount
    let bytes = await index.indexedByteCount
    XCTAssertEqual(count, 0)
    XCTAssertEqual(bytes, 0)
  }

  func testCancelledIndexedSearchReturnsNoResults() async {
    let index = Search.Index()
    let documents = (0..<100).map { Search.Document(id: UUID(), title: "entry \($0)") }
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await index.search(string: "entry", documents: documents, mode: .exact)
    }
    let result = await task.value
    XCTAssertTrue(result.isEmpty)
  }

  private func search(_ string: String) -> [Search.SearchResult] {
    return Search().search(string: string, within: items)
  }

  // swiftlint:disable:next identifier_name
  private func range(from: Int, to: Int, in item: HistoryItemDecorator) -> Range<String.Index> {
    let startIndex = item.title.startIndex
    let lowerBound = item.title.index(startIndex, offsetBy: from)
    let upperBound = item.title.index(startIndex, offsetBy: to + 1)

    return lowerBound..<upperBound
  }

  @MainActor
  private func historyItemWithTitle(_ value: String?) -> HistoryItem {
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
}
