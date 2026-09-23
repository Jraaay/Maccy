// swiftlint:disable file_length
import AppKit.NSRunningApplication
import Defaults
import Foundation
import Logging
import Observation
import Sauce
import Settings
import SwiftData

@Observable
class History: ItemsContainer { // swiftlint:disable:this type_body_length
  static let shared = History()
  let logger = Logger(label: "org.p0deje.Maccy")

  var items: [HistoryItemDecorator] = []
  var pasteStack: PasteStack?

  var pinnedItems: [HistoryItemDecorator] { items.filter(\.isPinned) }
  var unpinnedItems: [HistoryItemDecorator] { items.filter(\.isUnpinned) }

  var searchQuery: String = "" {
    didSet {
      guard searchQuery != oldValue else { return }
      scheduleSearch()
    }
  }

  var pressedShortcutItem: HistoryItemDecorator? {
    guard let event = NSApp.currentEvent else {
      return nil
    }

    let modifierFlags = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting(.capsLock)

    guard HistoryItemAction(modifierFlags) != .unknown else {
      return nil
    }

    let key = Sauce.shared.key(for: Int(event.keyCode))
    return items.first { $0.shortcuts.contains(where: { $0.key == key }) }
  }

  private let sorter = Sorter()
  @ObservationIgnored private var searchTask: Task<Void, Never>?
  @ObservationIgnored private var searchWorker: Task<[Search.Match], Never>?
  @ObservationIgnored private var searchGeneration = 0
  @ObservationIgnored private var shortcutItems: [HistoryItemDecorator] = []

  @ObservationIgnored
  private var sessionLog: [Int: HistoryItem] = [:]

  // The distinction between `all` and `items` is the following:
  // - `all` stores all history items, even the ones that are currently hidden by a search
  // - `items` stores only visible history items, updated during a search
  @ObservationIgnored
  var all: [HistoryItemDecorator] = [] {
    didSet {
      // Invalidate in-flight results when entries are inserted, removed or reordered.
      searchGeneration += 1
      searchTask?.cancel()
      searchWorker?.cancel()
      if !searchQuery.isEmpty { scheduleSearch() }
    }
  }

  init() {
    Task {
      for await _ in Defaults.updates(.searchMode, initial: false) {
        scheduleSearch()
      }
    }

    Task {
      for await _ in Defaults.updates(.pasteByDefault, initial: false) {
        updateShortcuts()
      }
    }

    Task {
      for await _ in Defaults.updates(.sortBy, initial: false) {
        try? await load()
      }
    }

    Task {
      for await _ in Defaults.updates(.pinTo, initial: false) {
        try? await load()
      }
    }

    Task {
      for await _ in Defaults.updates(.showSpecialSymbols, initial: false) {
        for item in items {
          await updateTitle(item: item, title: item.item.generateTitle())
        }
      }
    }

    Task {
      for await _ in Defaults.updates(.imageMaxHeight, initial: false) {
        for item in items {
          await item.cleanupImages()
        }
      }
    }
  }

  @MainActor
  func load() async throws {
    let descriptor = FetchDescriptor<HistoryItem>()
    let results = try Storage.shared.context.fetch(descriptor)
    all = sorter.sort(results).map { HistoryItemDecorator($0) }
    items = all

    limitHistorySize(to: Defaults[.size])

    updateShortcuts()
    // Ensure that panel size is proper *after* loading all items.
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  private func limitHistorySize(to maxSize: Int) {
    let unpinned = all.filter(\.isUnpinned)
    if unpinned.count >= maxSize {
      unpinned[maxSize...].forEach(delete)
    }
  }

  @MainActor
  func insertIntoStorage(_ item: HistoryItem) throws {
    logger.info("Inserting item with id '\(item.title)'")
    Storage.shared.context.insert(item)
    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.save()
  }

  @discardableResult
  @MainActor
  func add(_ item: HistoryItem) -> HistoryItemDecorator {
    if #available(macOS 15.0, *) {
      try? History.shared.insertIntoStorage(item)
    } else {
      // On macOS 14 the history item needs to be inserted into storage directly after creating it.
      // It was already inserted after creation in Clipboard.swift
    }

    var removedItemIndex: Int?
    if let existingHistoryItem = findSimilarItem(item) {
      if isModified(item) == nil {
        transferContents(from: existingHistoryItem, to: item)
      }
      item.firstCopiedAt = existingHistoryItem.firstCopiedAt
      item.numberOfCopies += existingHistoryItem.numberOfCopies
      item.pin = existingHistoryItem.pin
      item.title = existingHistoryItem.title
      if !item.fromMaccy {
        item.application = existingHistoryItem.application
      }
      logger.info("Removing duplicate item '\(item.title)'")
      removedItemIndex = all.firstIndex(where: { $0.item == existingHistoryItem })
      if let removedItemIndex {
        cleanup(all[removedItemIndex])
      }
      deleteFromStorage(existingHistoryItem)
      if let removedItemIndex {
        all.remove(at: removedItemIndex)
      }
    } else {
      Task {
        Notifier.notify(body: item.title, sound: .write)
      }
    }

    // Remove exceeding items. Do this after the item is added to avoid removing something
    // if a duplicate was found as then the size already stayed the same.
    limitHistorySize(to: Defaults[.size] - 1)

    sessionLog[Clipboard.shared.changeCount] = item

    var itemDecorator: HistoryItemDecorator
    if let pin = item.pin {
      itemDecorator = HistoryItemDecorator(item, shortcuts: KeyShortcut.create(character: pin))
      if let removedItemIndex {
        // If pin to bottom -> last element should be inserted to the removedItemIndex - 1
        // Or to the last all array place.
        all.insert(itemDecorator, at: min(removedItemIndex, all.count))
      }
    } else {
      itemDecorator = HistoryItemDecorator(item)

      let sortedItems = sorter.sort(all.map(\.item) + [item])
      if let index = sortedItems.firstIndex(of: item) {
        all.insert(itemDecorator, at: index)
      }

      items = all
      updateUnpinnedShortcuts()
      AppState.shared.popup.needsResize = true
    }

    Storage.shared.schedulePayloadCleanup()
    return itemDecorator
  }

  @MainActor
  private func withLogging(_ msg: String, _ block: () throws -> Void) rethrows {
    func dataCounts() -> String {
      let historyItemCount = try? Storage.shared.context.fetchCount(FetchDescriptor<HistoryItem>())
      let historyContentCount = try? Storage.shared.context.fetchCount(FetchDescriptor<HistoryItemContent>())
      return "HistoryItem=\(historyItemCount ?? 0) HistoryItemContent=\(historyContentCount ?? 0)"
    }

    logger.info("\(msg) Before: \(dataCounts())")
    try? block()
    logger.info("\(msg) After: \(dataCounts())")
  }

  @MainActor
  func clear() {
    withLogging("Clearing history") {
      all.forEach { item in
        if item.isUnpinned {
          cleanup(item)
        }
      }
      all.removeAll(where: \.isUnpinned)
      sessionLog.removeValues { $0.pin == nil }
      items = all

      try? Storage.shared.context.transaction {
        try? Storage.shared.context.delete(
          model: HistoryItem.self,
          where: #Predicate { $0.pin == nil }
        )
        try? Storage.shared.context.delete(
          model: HistoryItemContent.self,
          where: #Predicate { $0.item?.pin == nil }
        )
      }
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.saveAndCleanPayloads(discardMigrationBackup: true)
    }

    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  func clearAll() {
    withLogging("Clearing all history") {
      all.forEach { item in
        cleanup(item)
      }
      all.removeAll()
      sessionLog.removeAll()
      items = all

      do {
        let context = Storage.shared.context
        try context.transaction {
          // Bulk deletion cannot remove children with live inverse relationships.
          try context.delete(
            model: HistoryItemContent.self,
            where: #Predicate { $0.item == nil }
          )
          try context.delete(model: HistoryItem.self)
          try context.delete(model: HistoryItemContent.self)
        }
      } catch {
        logger.error("Failed to clear storage: \(String(reflecting: error))")
      }
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.saveAndCleanPayloads(discardMigrationBackup: true)
    }

    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  func delete(_ item: HistoryItemDecorator?) {
    guard let item else { return }

    cleanup(item)
    withLogging("Removing history item") {
      deleteFromStorage(item.item)
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.saveAndCleanPayloads(discardMigrationBackup: true)
    }

    all.removeAll { $0 == item }
    items.removeAll { $0 == item }
    sessionLog.removeValues { $0 == item.item }

    updateUnpinnedShortcuts()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  private func transferContents(from existingItem: HistoryItem, to newItem: HistoryItem) {
    deleteContents(of: newItem)
    newItem.contents = existingItem.contents
    existingItem.contents = []
  }

  @MainActor
  private func deleteFromStorage(_ item: HistoryItem) {
    deleteContents(of: item)
    Storage.shared.context.delete(item)
  }

  @MainActor
  private func deleteContents(of item: HistoryItem) {
    item.contents.forEach(Storage.shared.context.delete)
  }

  @MainActor
  func releaseImageCaches() {
    // Closing an NSPanel does not necessarily dismantle its SwiftUI rows.
    for item in all {
      if item.thumbnailImage != nil || item.previewImage != nil ||
          item.thumbnailImageGenerationTask != nil || item.previewImageGenerationTask != nil {
        item.cleanupImages()
      }
    }
  }

  @MainActor
  private func cleanup(_ item: HistoryItemDecorator) {
    item.cleanupImages()
  }

  @MainActor
  func select(_ item: HistoryItemDecorator?, flags modifierFlags: NSEvent.ModifierFlags) {
    guard let item else {
      return
    }

    if modifierFlags.isEmpty {
      AppState.shared.popup.close()
      guard Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault]) else { return }
      if Defaults[.pasteByDefault] {
        Clipboard.shared.paste()
      }
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        AppState.shared.popup.close()
        guard Clipboard.shared.copy(item.item) else { return }
      case .paste:
        AppState.shared.popup.close()
        guard Clipboard.shared.copy(item.item) else { return }
        Clipboard.shared.paste()
      case .pasteWithoutFormatting:
        AppState.shared.popup.close()
        guard Clipboard.shared.copy(item.item, removeFormatting: true) else { return }
        Clipboard.shared.paste()
      case .unknown:
        return
      }
    }

    Task {
      searchQuery = ""
    }
  }

  @MainActor
  func startPasteStack(selection: inout Selection<HistoryItemDecorator>, flags modifierFlags: NSEvent.ModifierFlags) {
    guard AppState.shared.multiSelectionEnabled else { return }
    guard let item = selection.first else { return }
    PasteStack.initializeIfNeeded()

    let stack = PasteStack(items: selection.items, modifierFlags: modifierFlags)
    pasteStack = stack

    logger.info("Initialising PasteStack with \(stack.items.count) items")
    logger.info("Copying \(item.item.title) from PasteStack")

    if modifierFlags.isEmpty {
      AppState.shared.popup.close()
      guard Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault]) else { return }
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        AppState.shared.popup.close()
        guard Clipboard.shared.copy(item.item) else { return }
      case .paste:
        AppState.shared.popup.close()
        guard Clipboard.shared.copy(item.item) else { return }
      case .pasteWithoutFormatting:
        AppState.shared.popup.close()
        guard Clipboard.shared.copy(item.item, removeFormatting: true) else { return }
        Clipboard.shared.paste()
      case .unknown:
        return
      }
    }

    Task {
      searchQuery = ""
    }
  }

  func handlePasteStack() {
    guard let stack = pasteStack else {
      return
    }

    guard let pasted = stack.items.first else {
      pasteStack = nil
      logger.info("PasteStack is empty")
      return
    }

    logger.info("PasteStack pasted \(pasted.item.title)")

    stack.items.removeFirst()

    guard let item = stack.items.first else {
      pasteStack = nil
      logger.info("PasteStack is empty")
      return
    }

    logger.info("Copying \(item.item.title) from PasteStack. \(stack.items.count) items remaining in stack.")

    Task {
      if stack.modifierFlags.isEmpty {
        guard await Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault]) else { pasteStack = nil; return }
      } else {
        switch HistoryItemAction(stack.modifierFlags) {
        case .copy:
          guard await Clipboard.shared.copy(item.item) else { pasteStack = nil; return }
        case .paste:
          guard await Clipboard.shared.copy(item.item) else { pasteStack = nil; return }
        case .pasteWithoutFormatting:
          guard await Clipboard.shared.copy(item.item, removeFormatting: true) else { pasteStack = nil; return }
        case .unknown:
          return
        }
      }
    }
  }

  func interruptPasteStack() {
    guard pasteStack != nil else {
      return
    }
    logger.info("Interrupting PasteStack")
    pasteStack = nil
  }

  @MainActor
  func togglePin(_ item: HistoryItemDecorator?) {
    guard let item else { return }

    item.togglePin()

    let sortedItems = sorter.sort(all.map(\.item))
    if let currentIndex = all.firstIndex(of: item),
       let newIndex = sortedItems.firstIndex(of: item.item) {
      all.remove(at: currentIndex)
      all.insert(item, at: newIndex)
    }

    items = all

    searchQuery = ""
    updateUnpinnedShortcuts()
    if item.isUnpinned {
      AppState.shared.navigator.scrollTarget = item.id
    }
  }

  @MainActor
  private func findSimilarItem(_ item: HistoryItem) -> HistoryItem? {
    if let duplicate = all.first(where: { $0.item != item && $0.item.supersedes(item) }) {
      return duplicate.item
    }

    return isModified(item)
  }

  private func isModified(_ item: HistoryItem) -> HistoryItem? {
    if let modified = item.modified, sessionLog.keys.contains(modified) {
      return sessionLog[modified]
    }

    return nil
  }

  private func scheduleSearch() {
    searchTask?.cancel()
    searchWorker?.cancel()
    searchGeneration += 1
    let generation = searchGeneration
    searchTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let query = searchQuery
      // Coalesce rapid keystrokes, but clear the search immediately.
      if !query.isEmpty {
        do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
      }
      guard !Task.isCancelled, generation == searchGeneration else { return }
      let mode = Defaults[.searchMode]
      let snapshot = all
      let documents = snapshot.map { Search.Document(id: $0.id, title: $0.title) }
      let matches: [Search.Match]
      if query.isEmpty {
        matches = documents.map { Search.Match(id: $0.id) }
      } else {
        let worker = Task.detached(priority: .userInitiated) {
          Search.search(string: query, documents: documents, mode: mode, isCancelled: { Task.isCancelled })
        }
        searchWorker = worker
        matches = await worker.value
      }
      guard !Task.isCancelled, generation == searchGeneration, query == searchQuery else { return }
      // OCR or an edit can change a title while its immutable snapshot is searched.
      guard zip(snapshot, documents).allSatisfy({ $0.title == $1.title }) else {
        scheduleSearch()
        return
      }
      let objects = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
      items = matches.compactMap { match in
        guard let item = objects[match.id] else { return nil }
        item.highlight(query, match.ranges)
        return item
      }
      updateUnpinnedShortcuts()
      if query.isEmpty {
        AppState.shared.navigator.select(item: items.first(where: \.isUnpinned))
      } else {
        AppState.shared.navigator.highlightFirst()
      }
      AppState.shared.popup.needsResize = true
      searchWorker = nil
    }
  }

  private func updateShortcuts() {
    for item in pinnedItems {
      if let pin = item.item.pin {
        item.shortcuts = KeyShortcut.create(character: pin)
      }
    }

    updateUnpinnedShortcuts()
  }

  @MainActor
  private func updateTitle(item: HistoryItemDecorator, title: String) {
    item.title = title
    item.item.title = title
    if !searchQuery.isEmpty { scheduleSearch() }
  }

  private func updateUnpinnedShortcuts() {
    let next = Array(items.lazy.filter { $0.isUnpinned && $0.isVisible }.prefix(9))
    for item in shortcutItems where item.isUnpinned && !next.contains(item) {
      item.shortcuts = []
    }
    for (index, item) in next.enumerated() {
      let shortcuts = KeyShortcut.create(character: String(index + 1))
      if item.shortcuts.map(\.key) != shortcuts.map(\.key) ||
          item.shortcuts.map(\.modifierFlags) != shortcuts.map(\.modifierFlags) {
        item.shortcuts = shortcuts
      }
    }
    shortcutItems = next
  }
}
