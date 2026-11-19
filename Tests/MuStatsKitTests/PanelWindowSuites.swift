import Testing

/// Every suite that opens a real panel, run one test at a time.
///
/// A panel becomes the key window as it opens, and a panel that loses key closes, as
/// a menu bar panel should. The app only ever has one. Two suites opening panels at
/// the same time took key from each other, and the first panel closed under its test.
@Suite("Panel windows", .serialized)
struct PanelWindowSuites {}
