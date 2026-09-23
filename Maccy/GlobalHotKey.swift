import AppKit
// Keyboard events run on the main thread; retain Swift 5 compatibility with the Swift 6 dependency.
@preconcurrency import KeyboardShortcuts
import Sauce
import SwiftUI

class GlobalHotKey {
  typealias Handler = () -> Void

  static public var key: KeyEquivalent? { KeyboardShortcuts.Shortcut(name: .popup)?.toKeyEquivalent() }
  static public var modifierFlags: EventModifiers? { KeyboardShortcuts.Shortcut(name: .popup)?.toEventModifiers() }

  private var handler: Handler

  init(_ handler: @escaping Handler) {
    self.handler = handler
//    KeyboardShortcuts.onKeyDown(for: .popup, action: handler)
  }
}
