// Keyboard events run on the main thread; retain Swift 5 compatibility with the Swift 6 dependency.
@preconcurrency import KeyboardShortcuts
import Sauce

extension Sauce {
  func key(shortcut: KeyboardShortcuts.Name) -> Key? {
    if let shortcut = KeyboardShortcuts.Shortcut(name: shortcut) {
      return Sauce.shared.key(for: shortcut.carbonKeyCode)
    } else {
      return nil
    }
  }
}
