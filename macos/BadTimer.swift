import SwiftUI
import AppKit

@MainActor final class TimerModel: ObservableObject {
    @Published var names: [String] = []
    @Published var running = -1
    @Published var seconds: UInt64 = 0
    @Published var message = ""
    @Published var blocked = false
    private var opened = false
    private var refresh: Timer?

    init() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/bad-timer")
        let env = ProcessInfo.processInfo.environment
        let config = env["BAD_TIMER_CONFIG"] ?? base.appendingPathComponent("config.json").path
        let history = env["BAD_TIMER_HISTORY"] ?? base.appendingPathComponent("history.jsonl").path
        guard bt_open(config, history) == 0 else {
            blocked = true
            message = "Cannot open timer: \(String(cString: bt_error())).\nCheck config/history and close any other timer. Recover unfinished sessions in the TUI."
            return
        }
        opened = true
        names = (0..<bt_count()).map { index in
            var probe: UInt8 = 0
            let count = bt_name(index, &probe, 0)
            var bytes = [UInt8](repeating: 0, count: count)
            _ = bt_name(index, &bytes, count)
            return String(decoding: bytes.dropLast(), as: UTF8.self)
        }
        refresh = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }

    func update() {
        guard opened, !blocked else { return }
        if bt_elapsed(&seconds) != 0 {
            blocked = true
            message = "Clock failed: \(String(cString: bt_error())). Quit and recover in the TUI."
        }
        running = bt_running()
    }

    func select(_ index: Int) {
        guard !blocked else { return }
        if bt_select(index) != 0 {
            blocked = true
            message = "Save failed: \(String(cString: bt_error())). History may contain part or all of the change. Do not retry; quit and inspect/recover history in the TUI."
        }
        update()
    }

    func quit() -> Bool {
        guard opened else { return true }
        // A known failed save must not be retried, even during termination.
        if !blocked && bt_select(-1) != 0 {
            blocked = true
            message = "Save on quit failed. History is uncertain; do not retry. Quit again, then inspect/recover it in the TUI."
            let alert = NSAlert()
            alert.messageText = "Could not save the running timer"
            alert.informativeText = message
            alert.runModal()
            return false
        }
        if bt_close() != 0 {
            // Clock errors may leave a live session: keep the lock and offer an explicit choice.
            let alert = NSAlert()
            alert.messageText = "Leave this session unfinished?"
            alert.informativeText = "The timer could not be saved. You must recover it in the TUI on restart."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit without saving")
            return alert.runModal() == .alertSecondButtonReturn
        }
        opened = false
        refresh?.invalidate()
        return true
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = TimerModel()
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.quit() ? .terminateNow : .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct BadTimerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("Bad Timer", id: "timer") { TimerView(model: delegate.model) }
            .windowResizability(.contentSize)
    }
}

struct TimerView: View {
    @ObservedObject var model: TimerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.running < 0 ? "Stopped" : "Running: \(model.names[model.running])")
                .font(.headline)
            Text(String(format: "%02llu:%02llu:%02llu", model.seconds / 3600,
                        model.seconds / 60 % 60, model.seconds % 60))
                .font(.system(size: 36, design: .monospaced))
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.names.indices, id: \.self) { index in
                        Button { model.select(index) } label: {
                            HStack {
                                Text(model.names[index])
                                Spacer()
                                Text(model.running == index ? "Stop" : "Start")
                            }.frame(maxWidth: .infinity)
                        }.disabled(model.blocked)
                    }
                }
            }.frame(height: 240)
            if !model.message.isEmpty {
                Text(model.message).font(.callout).textSelection(.enabled)
            }
            Text("Selecting another activity switches timers. Quit saves the running session.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 390)
    }
}
