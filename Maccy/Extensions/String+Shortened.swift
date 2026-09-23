extension String {
  func shortened(to maxLength: Int) -> String {
    guard let end = index(startIndex, offsetBy: maxLength, limitedBy: endIndex) else { return self }
    return String(self[..<end])
  }
}
