import AppKit
import Combine

/// Tracks the last few clipboard string entries while the app is running.
@MainActor
final class ClipboardHistory: ObservableObject {
    @Published private(set) var recentStrings: [String] = []

    private let pasteboard: NSPasteboard
    private var changeCount: Int
    private var timer: Timer?
    private let maxEntries = 3

    init(pollInterval: TimeInterval = 0.75, pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        changeCount = pasteboard.changeCount
        captureCurrentString() // Seed with whatever is on the clipboard now

        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.captureIfChanged()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    deinit {
        timer?.invalidate()
    }

    /// Manually polls the clipboard immediately (useful before consuming the values).
    func refresh() {
        captureIfChanged(force: true)
    }

    private func captureIfChanged(force: Bool = false) {
        let currentChangeCount = pasteboard.changeCount
        guard force || currentChangeCount != changeCount else { return }
        changeCount = currentChangeCount
        captureCurrentString()
    }

    private func captureCurrentString() {
        guard let string = pasteboard.string(forType: .string) else { return }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if recentStrings.first == trimmed { return }

        var updated = recentStrings.filter { $0 != trimmed }
        updated.insert(trimmed, at: 0)
        if updated.count > maxEntries {
            updated = Array(updated.prefix(maxEntries))
        }
        recentStrings = updated
    }
}
