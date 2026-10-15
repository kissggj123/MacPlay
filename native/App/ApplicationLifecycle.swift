import AppKit
import Combine

@MainActor final class MacPlayApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    static weak var shared: MacPlayApplicationDelegate?
    private weak var model: PlayModel?
    private weak var mainWindow: NSWindow?
    private var openMainWindow: (() -> Void)?
    private var statusItem: NSStatusItem?
    private weak var statusLineItem: NSMenuItem?
    // Last menu content cache — objectWillChange fires for every @Published
    // change (`logs` alone ticks many times/second while streaming); the menu
    // only depends on these three.
    private var lastMenuRunning=false
    private var lastMenuReceiving=false
    private var lastMenuAddressCount=0
    private var lastMenuAddressKey=""
    private var modelObservation: AnyCancellable?
    private var windowObservation: NSObjectProtocol?
    private var terminating = false
    private var explicitWindowRequestUntil = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared=self
        windowObservation=NotificationCenter.default.addObserver(forName:NSWindow.didBecomeMainNotification,object:nil,queue:.main) { [weak self] notification in
            Task { @MainActor in
                guard let window=notification.object as? NSWindow,!(window is NSPanel),window.canBecomeMain else {return}
                self?.mainWindow=window
                window.delegate=self
            }
        }
    }

    func install(_ model: PlayModel, openMainWindow: @escaping () -> Void) {
        self.openMainWindow=openMainWindow
        Self.shared=self
        if self.model == nil {
            self.model=model
            modelObservation=model.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async {self?.updateMenusIfNeeded()}
            }
        }
        if let window=NSApp.windows.first(where:{!($0 is NSPanel) && $0.canBecomeMain}) {
            mainWindow=window;window.delegate=self
        }
        preferencesChanged()
        model.enableAutomaticUSBStart()
    }

    func preferencesChanged() {
        guard let model else {return}
        model.persistPreferences()
        if model.settings.backgroundEnabled == true {
            if statusItem == nil {
                statusItem=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
                let image=NSImage(systemSymbolName:"car.fill",accessibilityDescription:"NIO Play")
                image?.isTemplate=true
                statusItem?.button?.image=image
                statusItem?.button?.toolTip="NIO Play"
            }
        } else if let item=statusItem {
            NSStatusBar.system.removeStatusItem(item);statusItem=nil
            if mainWindow?.isVisible != true {model.showMainWindow()}
        }
        updateMenus()
    }

    private func statusTitle() -> String {
        guard let model, model.running else {return L("○ 未连接")}
        if let start=model.sessionStart {
            let minutes=max(0,Int(Date().timeIntervalSince(start)/60))
            return L("● 接收中 · \(minutes)分钟")
        }
        return L("● 接收中")
    }
    private func menu() -> NSMenu {
        let menu=NSMenu()
        menu.delegate=self
        guard let model else {return menu}
        // Read-only status line; minutes refreshed on open (menuWillOpen).
        let statusLine=NSMenuItem(title:statusTitle(),action:nil,keyEquivalent:"")
        statusLine.isEnabled=false
        menu.addItem(statusLine)
        statusLineItem=statusLine
        menu.addItem(.separator())
        func item(_ title:String,_ action:Selector,enabled:Bool=true) {
            let item=NSMenuItem(title:L(title),action:action,keyEquivalent:"")
            item.target=self;item.isEnabled=enabled;menu.addItem(item)
        }
        item("显示NIO Play",#selector(showMain))
        item("显示CarPlay",#selector(showCarPlay),enabled:model.running)
        menu.addItem(.separator())
        if model.running {menu.addItem(volumeItem())}
        item(model.receivingOrWaiting ? "停止接收" : "启动接收",#selector(toggleReceiver))
        menu.addItem(.separator())
        let launchItem=NSMenuItem(title:L("登录时启动"),action:#selector(toggleLaunchAtLogin),keyEquivalent:"")
        launchItem.target=self
        launchItem.state=model.launchAtLoginEnabled ? .on : .off
        menu.addItem(launchItem)
        let copyItem=NSMenuItem(title:L("复制车机地址"),action:#selector(copyCarAddress),keyEquivalent:"")
        copyItem.target=self
        copyItem.isEnabled=model.lanAddresses.contains{$0.iphoneUSB == false}
        menu.addItem(copyItem)
        menu.addItem(.separator())
        item("退出NIO Play",#selector(quit))
        return menu
    }
    // View-based slider sharing the audio tab's exact channel:
    // settings.volume (0-1) + sendAudioCommand() per tick (no file write).
    private func volumeItem() -> NSMenuItem {
        let item=NSMenuItem(title:L("媒体音量"),action:nil,keyEquivalent:"")
        let container=NSView(frame:NSRect(x:0,y:0,width:240,height:24))
        let slider=NSSlider(value:(model?.settings.volume ?? 1)*100,minValue:0,maxValue:100,target:self,action:#selector(volumeChanged(_:)))
        slider.frame=NSRect(x:12,y:4,width:216,height:18)
        slider.isContinuous=true
        slider.setAccessibilityLabel(L("媒体音量"))
        container.addSubview(slider)
        item.view=container
        return item
    }
    @objc private func volumeChanged(_ sender:NSSlider) {
        guard let model else {return}
        model.settings.volume=sender.doubleValue/100
        model.sendAudioCommand()
    }
    @objc private func toggleLaunchAtLogin() {
        guard let model else {return}
        model.setLaunchAtLogin(!model.launchAtLoginEnabled)
    }
    @objc private func copyCarAddress() {
        guard let model,let address=model.lanAddresses.first(where:{$0.iphoneUSB == false})?.address else {return}
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("https://\(address):8443",forType:.string)
    }
    // MARK: NSMenuDelegate
    func menuWillOpen(_ menu:NSMenu) {statusLineItem?.title=statusTitle()}
    func menuDidClose(_ menu:NSMenu) {model?.persistPreferences()}

    private func updateMenusIfNeeded() {
        guard let model else {return}
        guard model.running != lastMenuRunning
            || model.receivingOrWaiting != lastMenuReceiving
            || model.lanAddresses.count != lastMenuAddressCount
            || model.lanAddresses.first{$0.iphoneUSB == false}?.address != lastMenuAddressKey else {return}
        updateMenus()
    }
    private func updateMenus() {
        if let model {
            lastMenuRunning=model.running
            lastMenuReceiving=model.receivingOrWaiting
            lastMenuAddressCount=model.lanAddresses.count
            lastMenuAddressKey=model.lanAddresses.first{$0.iphoneUSB == false}?.address ?? ""
        }
        statusItem?.menu=menu()
    }
    func applicationDockMenu(_ sender:NSApplication) -> NSMenu? {menu()}
    @objc private func showMain() {
        explicitWindowRequestUntil=Date().addingTimeInterval(1)
        model?.showMainWindow()
    }
    func restoreMainWindow() -> Bool {
        guard let openMainWindow else {return false}
        explicitWindowRequestUntil=Date().addingTimeInterval(1)
        // SwiftUI can dispose of a closed Window scene. Asking the scene to open
        // also recreates it; enumerating NSApp.windows cannot restore that case.
        openMainWindow()
        NSApp.activate()
        if let window=mainWindow,NSApp.windows.contains(where:{$0 === window}) {
            if window.isMiniaturized {window.deminiaturize(nil)}
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }
    @objc private func showCarPlay() {model?.showCarPlayWindow()}
    func prepareCarPlayPresentation() {
        explicitWindowRequestUntil=Date().addingTimeInterval(1)
        // Ordering a minimized window can restore it. Keep the main window's
        // minimized/hidden state when the user only requests the CarPlay window.
        if let window=mainWindow,window.isVisible,!window.isMiniaturized {
            window.orderBack(nil)
        }
    }
    @objc private func toggleReceiver() {
        guard let model else {return}
        if model.receivingOrWaiting {model.stop()} else {model.start()}
    }
    @objc private func quit() {NSApp.terminate(nil)}

    func windowShouldClose(_ sender:NSWindow) -> Bool {
        guard sender === mainWindow,!terminating else {return true}
        if model?.settings.backgroundEnabled == true {
            sender.orderOut(nil)
        } else {NSApp.terminate(nil)}
        return false
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool) -> Bool {
        // A Dock menu selection may also generate a reopen event. Preserve its target.
        guard Date() > explicitWindowRequestUntil else {return false}
        model?.showMainWindow();return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool {false}
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        terminating=true
        model?.stop(restoreMain:false)
        return .terminateNow
    }
}
