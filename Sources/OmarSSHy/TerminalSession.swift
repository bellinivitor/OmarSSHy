import AppKit
import SwiftTerm
import SwiftUI

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    nonisolated let id = UUID()
    let title: String
    @Published private(set) var hasEnded = false
    @Published private(set) var exitStatus: Int32?

    fileprivate let view: LocalProcessTerminalView
    private let terminalDelegate = RemoteTerminalDelegate()
    private var onExit: ((Int32?) -> Void)?

    init(title: String, arguments: [String], onExit: @escaping (Int32?) -> Void = { _ in }) {
        self.title = title
        self.onExit = onExit

        var options = TerminalOptions.default
        options.termName = "xterm-256color"
        options.scrollback = 2_500
        options.cursorStyle = .steadyBar
        options.maximumOscBytes = 64 * 1_024
        options.enableOsc8Hyperlinks = false

        view = LocalProcessTerminalView(
            frame: CGRect(x: 0, y: 0, width: 720, height: 360),
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            options: options
        )
        let ink = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1)
        let red = NSColor(srgbRed: 228 / 255.0, green: 0, blue: 43 / 255.0, alpha: 1)
        view.nativeBackgroundColor = .white
        view.nativeForegroundColor = ink
        view.caretColor = red
        view.selectedTextBackgroundColor = red.withAlphaComponent(0.13)
        view.selectedTextForegroundColor = ink
        view.minimumContrastRatio = 4.5
        view.optionAsMetaKey = false
        view.linkReporting = .none
        view.resolvesLinksAgainstShellDirectory = false
        view.processDelegate = self
        view.terminalDelegate = terminalDelegate

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = options.termName
        environment["TERM_PROGRAM"] = "OmarSSHy"
        environment["COLORTERM"] = "truecolor"
        view.startProcess(
            executable: "/usr/bin/ssh",
            args: arguments,
            environment: environment.map { "\($0.key)=\($0.value)" }
        )
    }

    func stop() {
        guard !hasEnded else { return }
        view.terminate()
    }

    private func finish(_ status: Int32?) {
        guard !hasEnded else { return }
        exitStatus = status
        hasEnded = true
        let callback = onExit
        onExit = nil
        callback?(status)
    }
}

extension TerminalSession: LocalProcessTerminalViewDelegate {
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        finish(exitCode)
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        finish(nil)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

@MainActor
private final class RemoteTerminalDelegate: TerminalViewDelegate {
    // Keep PTY resize and input handling while denying clipboard and link
    // requests sent by remote output. Manual copy and paste still work.
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        (source as? LocalProcessTerminalView)?.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        (source as? LocalProcessTerminalView)?.send(source: source, data: data)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

struct TerminalSurface: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> Container {
        let container = Container()
        container.install(session.view)
        return container
    }

    func updateNSView(_ container: Container, context: Context) {
        container.install(session.view)
    }

    static func dismantleNSView(_ container: Container, coordinator: ()) {
        container.removeTerminal()
    }

    final class Container: NSView {
        private weak var terminal: LocalProcessTerminalView?
        private var wantsTerminalFocus = false

        func install(_ terminal: LocalProcessTerminalView) {
            guard terminal.superview !== self else { return }
            removeTerminal()
            self.terminal = terminal
            addSubview(terminal)
            needsLayout = true
            wantsTerminalFocus = true
            requestTerminalFocus()
        }

        func removeTerminal() {
            if let terminal, terminal.superview === self {
                terminal.removeFromSuperview()
            }
            terminal = nil
            wantsTerminalFocus = false
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let notifications = NotificationCenter.default
            for event in [NSWindow.didBecomeKeyNotification, NSWindow.didEndSheetNotification] {
                notifications.removeObserver(self, name: event, object: nil)
                if let window {
                    notifications.addObserver(self, selector: #selector(windowAllowsFocus(_:)), name: event, object: window)
                }
            }
            requestTerminalFocus()
        }

        override func layout() {
            super.layout()
            let inset = bounds.insetBy(dx: 12, dy: 10)
            guard let terminal, !inset.isEmpty, terminal.frame != inset else { return }
            terminal.setFrameOrigin(inset.origin)
            terminal.setFrameSize(inset.size)
        }

        @objc private func windowAllowsFocus(_ notification: Notification) {
            requestTerminalFocus()
        }

        private func requestTerminalFocus() {
            guard wantsTerminalFocus else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.wantsTerminalFocus, let terminal = self.terminal,
                      terminal.superview === self,
                      let window = self.window, window.isKeyWindow, window.attachedSheet == nil else { return }
                self.wantsTerminalFocus = !window.makeFirstResponder(terminal)
            }
        }
    }
}
