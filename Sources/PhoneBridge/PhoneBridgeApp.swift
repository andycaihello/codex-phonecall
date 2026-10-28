import AppKit
import Foundation

@main
struct PhoneBridgeApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = PhoneBridgeDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class PhoneBridgeDelegate: NSObject, NSApplicationDelegate {
    private var model: BridgeModel?
    private var statusItem: NSStatusItem?
    private var closing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = BridgeModel()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "phone.connection", accessibilityDescription: "通话桥")
        item.button?.toolTip = "通话桥 · 后台运行"
        let menu = NSMenu()
        menu.addItem(withTitle: "通话桥 · 后台运行", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let open = menu.addItem(withTitle: "在浏览器打开控制台", action: #selector(openConsole), keyEquivalent: "")
        open.target = self
        let copy = menu.addItem(withTitle: "复制控制台地址", action: #selector(copyConsole), keyEquivalent: "")
        copy.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出通话桥", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        item.menu = menu; statusItem = item
        // Starting the service never opens a window or launches a browser. Codex
        // explicitly opens the returned console URL in its own right panel.
    }
    @objc private func openConsole() {
        guard let url = model?.captionWeb.url else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func copyConsole() {
        guard let url = model?.captionWeb.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if closing { return .terminateLater }
        closing = true
        Task { @MainActor in
            let clean = await model.session.shutdownForQuit()
            closing = false
            if !clean {
                let alert = NSAlert()
                alert.messageText = "请先结束语音并恢复音频"
                alert.informativeText = "在 Codex 停止语音聊天，然后在通话桥控制台恢复音频，再退出后台。"
                alert.addButton(withTitle: "知道了")
                alert.runModal()
            }
            sender.reply(toApplicationShouldTerminate: clean)
        }
        return .terminateLater
    }
}
