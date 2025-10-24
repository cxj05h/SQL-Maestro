import SwiftUI
import Combine
import AppKit
import Security

// MARK: - About Window Controller
final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()

    private let viewModel = AboutViewModel()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 340),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "About SQLMaestro"
        window.isReleasedWhenClosed = false
        window.center()
        window.level = .floating

        super.init(window: window)

        let hosting = NSHostingController(rootView: AboutView(viewModel: viewModel) {
            window.performClose(nil)
        })

        window.contentViewController = hosting
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window = window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        viewModel.refresh()
    }
}

// MARK: - View Model
@MainActor
final class AboutViewModel: ObservableObject {
    @Published private(set) var currentVersion: String
    @Published private(set) var buildNumber: String
    @Published private(set) var latestVersion: String?
    @Published private(set) var latestReleasePage: URL?
    @Published private(set) var isUpdateAvailable: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let latestReleaseURL = URL(string: "https://api.github.com/repos/cxj05h/SQL-Maestro/releases/latest")
    private let releasesPageURL = URL(string: "https://github.com/cxj05h/SQL-Maestro/releases")
    private let userAgent: String

    init(bundle: Bundle = .main) {
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info["CFBundleVersion"] as? String ?? "?"

        currentVersion = version
        buildNumber = build
        userAgent = "SQLMaestro/\(version)"
    }

    func refresh() {
        guard let url = latestReleaseURL else { return }

        isLoading = true
        errorMessage = nil

        Task { @MainActor in
            do {
                var request = URLRequest(url: url)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

                let (data, response) = try await URLSession.shared.data(for: request)

                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw AboutViewModelError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
                }

                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let release = try decoder.decode(GitHubRelease.self, from: data)

                latestVersion = release.tagName
                latestReleasePage = release.htmlUrl
                updateStatus()
            } catch {
                errorMessage = Self.describe(error)
            }

            isLoading = false
        }
    }

    func openReleasesPage() {
        if let direct = latestReleasePage {
            NSWorkspace.shared.open(direct)
        } else if let url = releasesPageURL {
            NSWorkspace.shared.open(url)
        }
    }

    func requestAdminPassword() -> String? {
        // Show custom password dialog
        let alert = NSAlert()
        alert.messageText = "Administrator Password Required"
        alert.informativeText = "SQLMaestro needs your administrator password to remove the quarantine attribute after updating the app."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        passwordField.placeholderString = "Enter your password"
        alert.accessoryView = passwordField

        alert.window.initialFirstResponder = passwordField

        let response = alert.runModal()

        guard response == .alertFirstButtonReturn else {
            return nil
        }

        let password = passwordField.stringValue
        guard !password.isEmpty else {
            return nil
        }

        return password
    }

    func runUpdateInTerminal() {
        // First, request admin password using custom dialog
        guard let password = requestAdminPassword() else {
            return // User cancelled
        }

        // Escape password for shell - need to escape single quotes too
        let escapedPassword = password
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "'\\''")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")

        // Create the update commands as a shell script
        let updateCommands = """
        clear
        echo "========================================="
        echo "SQLMaestro Update Script"
        echo "========================================="
        echo ""
        echo "Step 1: Updating Homebrew..."
        brew update
        echo ""
        echo "Step 2: Upgrading SQLMaestro..."
        brew upgrade --cask sql-maestro
        UPDATE_EXIT_CODE=$?
        echo ""
        if [ $UPDATE_EXIT_CODE -eq 0 ]; then
            echo "Step 3: Removing quarantine attribute..."
            echo "Authenticating with sudo..."
            printf '%s\\n' '\(escapedPassword)' | sudo -S xattr -rd com.apple.quarantine "/Applications/SQLMaestro.app"
            XATTR_EXIT_CODE=$?

            if [ $XATTR_EXIT_CODE -eq 0 ]; then
                echo "Quarantine attribute removed successfully."
                echo ""
                echo "========================================="
                echo "Update complete!"
                echo "========================================="
                echo ""
                echo "SQLMaestro will now restart..."
                echo "Closing current instance..."
                killall SQLMaestro 2>/dev/null
                sleep 2
                echo "Launching updated version..."
                open -a "SQLMaestro"
                exit 0
            else
                echo ""
                echo "========================================="
                echo "WARNING: Could not remove quarantine!"
                echo "========================================="
                echo ""
                echo "The update was successful, but the quarantine"
                echo "attribute could not be removed automatically."
                echo ""
                echo "Before restarting SQLMaestro, please run:"
                echo "sudo xattr -rd com.apple.quarantine \\"/Applications/SQLMaestro.app\\""
                echo ""
                echo "Press any key to close (DO NOT restart yet)..."
                read -n 1 -s
                exit 1
            fi
        else
            echo "========================================="
            echo "Update failed!"
            echo "========================================="
            echo ""
            echo "Please check the error messages above."
            echo ""
            echo "Press any key to close this window..."
            read -n 1 -s
            exit 1
        fi
        """

        // Write script to temporary file and use 'open' to launch it
        // This approach doesn't require Terminal automation permission
        let tempDir = FileManager.default.temporaryDirectory
        let scriptPath = tempDir.appendingPathComponent("sqlmaestro_update_\(UUID().uuidString).command")

        do {
            // Write the script with .command extension (opens in Terminal automatically)
            try updateCommands.write(to: scriptPath, atomically: true, encoding: .utf8)

            // Make it executable
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

            // Use 'open' to launch the .command file in Terminal
            // This doesn't require automation permission
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [scriptPath.path]

            try process.run()

            // Clean up the script file after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                try? FileManager.default.removeItem(at: scriptPath)
            }

        } catch {
            print("Failed to create or run update script: \(error)")

            // Show error to user
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Update Failed"
                alert.informativeText = """
                Could not create update script. Error: \(error.localizedDescription)

                You can run this command manually in Terminal:
                brew update && brew upgrade --cask sql-maestro
                """
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Copy Command")
                alert.addButton(withTitle: "OK")

                let response = alert.runModal()

                if response == .alertFirstButtonReturn {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString("brew update && brew upgrade --cask sql-maestro", forType: .string)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        ToastPresenter.show("Command copied to clipboard", duration: 2.0)
                    }
                }
            }
        }
    }

    private func updateStatus() {
        guard let latest = latestVersion else {
            isUpdateAvailable = false
            return
        }

        let current = SemanticVersion(currentVersion)
        let remote = SemanticVersion(latest)

        if let current = current, let remote = remote {
            isUpdateAvailable = remote > current
        } else {
            // Fallback to string compare if parsing fails
            isUpdateAvailable = latest.compare(currentVersion, options: .numeric) == .orderedDescending
        }
    }

    private static func describe(_ error: Error) -> String {
        if let err = error as? AboutViewModelError {
            return err.localizedDescription
        }
        return error.localizedDescription
    }
}

// MARK: - Support Types
private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlUrl: URL?
}

private enum AboutViewModelError: Error {
    case badStatus(Int)

    var localizedDescription: String {
        switch self {
        case .badStatus(let status):
            return "GitHub returned status code \(status)."
        }
    }
}

private struct SemanticVersion: Comparable {
    let components: [Int]

    init?(_ version: String) {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let parts = cleaned.split(separator: ".")
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        components = numbers
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let maxCount = max(lhs.components.count, rhs.components.count)
        for index in 0..<maxCount {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left == right { continue }
            return left < right
        }
        return false
    }
}

// MARK: - View
private struct AboutView: View {
    @ObservedObject var viewModel: AboutViewModel
    let onClose: () -> Void

    private var appName: String {
        Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "SQLMaestro"
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)
                .shadow(radius: 8)

            VStack(spacing: 4) {
                Text(appName)
                    .font(.system(size: 20, weight: .semibold))

                Text("Version \(viewModel.currentVersion) (\(viewModel.buildNumber))")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

            statusBlock

            Divider()

            HStack(spacing: 12) {
                Button("Check Again") {
                    viewModel.refresh()
                }
                .disabled(viewModel.isLoading)

                Button("Open Releases Page") {
                    viewModel.openReleasesPage()
                }

                if viewModel.isUpdateAvailable {
                    Button("Update to Newest Version") {
                        viewModel.runUpdateInTerminal()
                    }
                    .foregroundColor(Theme.purple)
                }

                Spacer()

                Button("Close") {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, viewModel.isUpdateAvailable ? 10 : 0)
        }
        .padding(24)
        .frame(minWidth: 540, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
    }

    @ViewBuilder
    private var statusBlock: some View {
        if viewModel.isLoading {
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking for updates…")
                    .font(.system(size: 13))
            }
        } else if let error = viewModel.errorMessage {
            VStack(spacing: 6) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13))
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                Text("We’ll keep the current version details above.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
        } else if viewModel.isUpdateAvailable, let latest = viewModel.latestVersion {
            VStack(spacing: 6) {
                Label("Update available", systemImage: "arrow.down.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.purple)
                Text("Latest release: \(latest)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text("Install via Homebrew: brew update && brew upgrade --cask sql-maestro")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)
        } else {
            Label("You’re up to date", systemImage: "checkmark.seal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
        }
    }
}
