import SwiftUI
import AppKit
import CoreWLAN
import CoreLocation
import IOKit
import IOBluetooth
import Combine
import Security
import CoreAudio
import MediaPlayer
import ServiceManagement
import Darwin

struct DisplayChoice: Identifiable {
    let id: UInt32
    let name: String
    let width: Int
    let height: Int
    let builtIn: Bool
    let refresh: Double
    let size: CGSize
    var label: String { "\(name)（\(width)×\(height)）" }
    var details: String { "\(builtIn ? "内建显示器" : "外接显示器") · \(width)×\(height)像素 · \(Int(refresh))Hz · \(Int(size.width))×\(Int(size.height))mm" }
}
struct AudioChoice: Identifiable { let id: String; let name: String }


struct PhoneChoice: Codable, Identifiable {
    var id: String
    var name: String
    var bluetooth: String? = nil
    var usb: String? = nil
}

// Fork: LAN addresses for the car browser + firewall helpers.
// Returns (label, address, network, iphoneUSB). Junk interfaces are filtered
// (VPN tunnels, AirDrop); each entry carries its subnet key so the UI can warn
// when two interfaces share a network — iPhone's USB tether interface and its
// Wi-Fi hotspot BOTH use 172.20.10.0/28, and the USB address is unreachable
// from hotspot clients, which is why car browsers "can't open the page" there.
func lanIPv4Addresses() -> [(name: String, address: String, network: String, iphoneUSB: Bool)] {
    var result: [(String, String, String, Bool)] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
    defer { freeifaddrs(ifaddr) }
    var ptr: UnsafeMutablePointer<ifaddrs>? = first
    while let p = ptr {
        defer { ptr = p.pointee.ifa_next }
        guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: p.pointee.ifa_name)
        if name == "lo0" || name.hasPrefix("utun") || name == "awdl0" || name == "llw0" { continue }
        var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
        let ip = String(cString: buf)
        var network = ip
        if let maskPtr = p.pointee.ifa_netmask {
            var m = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var mbuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &m.sin_addr, &mbuf, socklen_t(INET_ADDRSTRLEN)) != nil {
                let ipParts = ip.split(separator: ".").compactMap { UInt32($0) }
                let mParts = String(cString: mbuf).split(separator: ".").compactMap { UInt32($0) }
                if ipParts.count == 4 && mParts.count == 4 {
                    let addr=(ipParts[0]<<24)|(ipParts[1]<<16)|(ipParts[2]<<8)|ipParts[3]
                    let mk=(mParts[0]<<24)|(mParts[1]<<16)|(mParts[2]<<8)|mParts[3]
                    let net=addr&mk
                    network="\((net>>24)&255).\((net>>16)&255).\((net>>8)&255).\((net)&255)"
                }
            }
        }
        let iphoneUSB = ip.hasPrefix("172.20.10.") && name != "en0"
        if !result.contains(where: { $0.1 == ip }) { result.append((name, ip, network, iphoneUSB)) }
    }
    // Wi-Fi (en0) first — that's the car-hotspot interface in practice.
    result.sort {
        if $0.0 == "en0" && $1.0 != "en0" { return true }
        if $1.0 == "en0" && $0.0 != "en0" { return false }
        return $0.0 < $1.0
    }
    return result
}

func firewallEnabled() -> Bool? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/libexec/ApplicationFirewall/socketfilterfw")
    task.arguments = ["--getglobalstate"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    guard (try? task.run()) != nil else { return nil }
    task.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if out.localizedCaseInsensitiveContains("enabled") { return true }
    if out.localizedCaseInsensitiveContains("disabled") { return false }
    return nil
}

func firewallAllows(binaryPath: String) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/libexec/ApplicationFirewall/socketfilterfw")
    task.arguments = ["--listapps"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    guard (try? task.run()) != nil else { return false }
    task.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let name = (binaryPath as NSString).lastPathComponent
    return out.contains(binaryPath) || out.components(separatedBy: .newlines).contains { $0.contains(name) && $0.localizedCaseInsensitiveContains("allow") }
}

func receiverBinaryPath() -> String? {
    guard let resources = Bundle.main.resourceURL else { return nil }
    let url = resources.appendingPathComponent("runtime/MacPlayReceiver.app/Contents/MacOS/MacPlayReceiver")
    return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
}

struct PlaySettings: Codable {
    var language: String? = nil
    // Fork: manual appearance override — "light"/"dark", nil = follow system.
    var appearance: String? = nil
    var autoReconnect: Bool? = nil
    var autoStartUSB: Bool? = nil
    var backgroundEnabled: Bool? = nil
    var launchAtLogin: Bool? = nil
    var preventSleepWhenConnected: Bool? = nil
    // Fork: 即插即用（CarPlay-box mode）— on iPhone plug-in: disconnect Wi-Fi,
    // enable macOS Internet Sharing (iPhone-USB → pre-configured Wi-Fi hotspot)
    // and disable lid-close sleep; reverts on unplug/toggle-off/quit.
    var plugAndPlay: Bool? = nil
    var mjpegFallback: Bool? = nil
    var headless: Bool? = nil
    var zeroTranscode: Bool? = nil
    var screenCapture: Bool? = nil
    var displayID: UInt32? = nil
    var inputDevice: String? = nil
    var outputDevice: String? = nil
    var callVolume: Double? = nil
    var strictPixels: Bool? = nil
    var resolution = "native"
    // Fork: advertised physical width in mm. iOS brackets its CarPlay layout
    // by physical size; the wrong bracket renders an in-stream bezel. nil=auto
    // (derive from the Mac panel like upstream).
    var widthMmOverride: Int? = nil
    var width = 1280
    var height = 720
    var screenPixelWidth: Int? = nil
    var screenPixelHeight: Int? = nil
    var screenWidthMm: Double? = nil
    var screenHeightMm: Double? = nil
    var fps = 60
    var selectedPhone: String? = nil
    var lastPhone: String? = nil
    var phones: [PhoneChoice]? = nil
    var targetBluetooth: String? = nil
    var targetUSB: String? = nil
    var wireless = false
    var ssid = ""
    var password = ""
    var wifiProfiles: [String: String] = [:]
    var channel = 36
    var wifiInterface = "en0"
    var wifiMAC = ""
    var accessPointMAC: String? = nil
    var bluetoothMAC = ""
    var audioEnabled = false
    // Fork: send the Play media key when a browser client attaches. Turn off
    // to respect a manual pause — opening a browser only restores the audio
    // route; the user resumes playback themselves.
    var autoResumeOnBrowser: Bool? = nil
    var volume = 1.0
}

@MainActor final class PlayModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var settings = PlaySettings()
    @Published var displays: [DisplayChoice] = []
    @Published var audioInputs: [AudioChoice] = []
    @Published var audioOutputs: [AudioChoice] = []
    private var nowPlaying: [String:Any] = [:]
    private var playingState=NowPlayingState()
    private var metadataFeed:NowPlayingFeed?
    private var mediaDiagnostic=""
    private var artworkBytes: Data?
    private var pendingSeekID: String?
    private var remoteTargets: [Any] = []
    @Published var status = "尚未启动接收"
    @Published var detail = "连接iPhone后启动接收端。"
    @Published var frameRateFallbackNote = ""
    private var reconnectTimer:Timer?
    private var reconnectBackoff=ReconnectBackoff()
    private var reconnectCycle=false
    private var successfulSettings:PlaySettings?
    private var appliedSettings:PlaySettings?
    private var attemptID=""
    private var attemptStart=Date()
    private var logWrite:DispatchWorkItem?
    private var mediaPublish:DispatchWorkItem?
    private var fallbackQueued=false
    var receivingOrWaiting:Bool {running || reconnectCycle}
    @Published var running = false
    @Published var page:Page? = .connection
    @Published var logs = ""
    @Published var credentialsReady = false
    @Published var readingPassword = false
    @Published var networkStatus = "尚未读取网络"
    @Published var passwordStatus = ""
    @Published var phoneChoices: [PhoneChoice] = []
    @Published var usbDevices: [String] = []
    @Published var usbStage = "接收服务未启动"
    @Published var usbError = ""
    // Fork: car-browser LAN info + firewall.
    @Published var lanAddresses: [(name: String, address: String, network: String, iphoneUSB: Bool)] = []
    // Fork: two interfaces on the same subnet — iPhone USB tether + its Wi-Fi
    // hotspot both use 172.20.10.x, and hotspot clients can't reach the USB one.
    @Published var lanSubnetConflict = false
    @Published var firewallState = ""
    @Published var firewallNeedsAllow = false
    @Published var firewallWorking = false
    // Fork: firewall card shows a green check once nothing needs allowing.
    @Published var firewallAllowed = false
    // Fork: plug-and-play live state for the tray menu + settings UI. Written
    // by PlugAndPlayController; @Published keeps the menu cache in sync.
    @Published var plugAndPlayActive = false
    @Published var plugAndPlayBusy = false
    @Published var plugAndPlayStatus = ""
    var plugAndPlay: PlugAndPlayController!
    // Fork: plug-and-play guided setup — live view of the prerequisite config
    // (hotspot name / Wi-Fi share segment / sharing switch) read from nat.plist,
    // plus the bridge gateway address while sharing is up. Refreshed when the
    // controller activates/reverts (pnpRefreshLanInfo) and by the re-detect
    // button in the guide UI.
    @Published var pnpGuideConfig = PlugAndPlayCore.natConfigNow()
    @Published var pnpGuideBridgeIP = PlugAndPlayCore.sharedBridgeIPv4()
    // Fork: authorization-management section state. adminAuthState: "none" (no
    // stored credential) / "checking" / "ok" (verified — privileged operations
    // run silently via sudo -S) / "invalid" (stored password no longer works).
    @Published var adminAuthState = "none"
    @Published var adminAuthWorking = false
    @Published var keychainWifiCount = 0
    // Fork: connection-tab status card shows session duration.
    @Published var sessionStart: Date?
    private let locationManager = CLLocationManager()
    private var networkRequestPending = false
    private var usbTimer: Timer?
    private var connectedUSBIDs = Set<String>()
    var currentUSBIDs:Set<String> {connectedUSBIDs}
    private var automaticStartReady = false
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var pending = Data()
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacPlay")
    var authDirectory: URL { directory.appendingPathComponent("authentication") }
    var configURL: URL { directory.appendingPathComponent("settings.json") }
    var logURL: URL { directory.appendingPathComponent("MacPlay.log") }
    override init() {
        super.init()
        locationManager.delegate = self
        try? FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? Data(contentsOf: configURL), let decoded = try? JSONDecoder().decode(PlaySettings.self, from:data) { settings = decoded }
        MacPlayLocalization.language=settings.language ?? "system"
        applyAppearance()
        if ![30,60,90,120].contains(settings.fps) { settings.fps=60 }
        if settings.resolution == "1920x720" { settings.resolution="custom" }
        if settings.resolution == "3840x2160" { settings.resolution="native" }
        plugAndPlay=PlugAndPlayController(host:self)
        configureRemoteCommands(); refreshHardware(); installBundledCredentials(); updateResolution(); inspectCredentials(); detectNetwork(); refreshUSB()
        plugAndPlay.restoreIfStaleIfNeeded()
        NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main){[weak self] _ in Task { @MainActor in self?.refreshHardware(); self?.updateResolution() }}
        usbTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshUSB() }
        }
    }
    var selectedScreen: NSScreen? {
        NSScreen.screens.first(where:{($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value==settings.displayID}) ?? NSScreen.screens.first
    }
    func installBundledCredentials() {
        guard let bundled=Bundle.main.resourceURL?.appendingPathComponent("authentication") else {return}
        let names=["identity.pk8","certificate.p7b"]
        guard names.allSatisfy({!FileManager.default.fileExists(atPath:authDirectory.appendingPathComponent($0).path)}) else {return}
        for name in names {
            let target=authDirectory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath:target.path),let data=try? Data(contentsOf:bundled.appendingPathComponent(name)) {
                try? data.write(to:target,options:.atomic)
                try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)
            }
        }
    }
    func refreshHardware() {
        var native: [UInt32:(Int,Int)] = [:]
        let task=Process();task.executableURL=URL(fileURLWithPath:"/usr/sbin/system_profiler");task.arguments=["SPDisplaysDataType","-json"]
        let pipe=Pipe();task.standardOutput=pipe;task.standardError=FileHandle.nullDevice
        if (try? task.run()) != nil {
            let data=pipe.fileHandleForReading.readDataToEndOfFile();task.waitUntilExit()
            if let root=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let gpus=root["SPDisplaysDataType"] as? [[String:Any]] {
                for panel in gpus.flatMap({$0["spdisplays_ndrvs"] as? [[String:Any]] ?? []}) {
                    if let text=panel["_spdisplays_displayID"] as? String,let id=UInt32(text),let pixels=panel["spdisplays_pixelresolution"] as? String {
                        let parts=pixels.replacingOccurrences(of:"spdisplays_",with:"").replacingOccurrences(of:"Retina",with:"").components(separatedBy:"x")
                        if parts.count==2,let w=Int(parts[0].trimmingCharacters(in:.whitespaces)),let h=Int(parts[1].trimmingCharacters(in:.whitespaces)){native[id]=(w,h)}
                    }
                }
            }
        }
        displays=NSScreen.screens.compactMap { screen in
            guard let id=(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {return nil}
            let mode=CGDisplayCopyDisplayMode(id)
            return DisplayChoice(id:id,name:screen.localizedName,width:native[id]?.0 ?? mode?.pixelWidth ?? Int(screen.frame.width*screen.backingScaleFactor),height:native[id]?.1 ?? mode?.pixelHeight ?? Int(screen.frame.height*screen.backingScaleFactor),builtIn:CGDisplayIsBuiltin(id) != 0,refresh:mode?.refreshRate ?? 0,size:CGDisplayScreenSize(id))
        }.sorted { $0.builtIn && !$1.builtIn }
        if !displays.contains(where:{$0.id==settings.displayID}) {settings.displayID=displays.first?.id}
        var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var bytes: UInt32=0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&bytes)==noErr else {return}
        var ids=[AudioDeviceID](repeating:0,count:Int(bytes)/MemoryLayout<AudioDeviceID>.size)
        let result=ids.withUnsafeMutableBytes {AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&bytes,$0.baseAddress!)}
        guard result==noErr else {return}
        func string(_ id:AudioDeviceID,_ selector:AudioObjectPropertySelector)->String? {
            var a=AudioObjectPropertyAddress(mSelector:selector,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
            var value:Unmanaged<CFString>?;var size=UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id,&a,0,nil,&size,&value)==noErr else {return nil}
            return value?.takeUnretainedValue() as String?
        }
        func hasStreams(_ id:AudioDeviceID,_ scope:AudioObjectPropertyScope)->Bool {
            var a=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyStreams,mScope:scope,mElement:kAudioObjectPropertyElementMain);var size:UInt32=0
            return AudioObjectGetPropertyDataSize(id,&a,0,nil,&size)==noErr && size>0
        }
        audioInputs=[];audioOutputs=[]
        for id in ids {
            guard let uid=string(id,kAudioDevicePropertyDeviceUID),let name=string(id,kAudioObjectPropertyName) else {continue}
            let choice=AudioChoice(id:uid,name:name)
            if hasStreams(id,kAudioObjectPropertyScopeInput){audioInputs.append(choice)}
            if hasStreams(id,kAudioObjectPropertyScopeOutput){audioOutputs.append(choice)}
        }
        if let uid=settings.inputDevice,!uid.isEmpty,!audioInputs.contains(where:{$0.id==uid}){settings.inputDevice=nil}
        if let uid=settings.outputDevice,!uid.isEmpty,!audioOutputs.contains(where:{$0.id==uid}){settings.outputDevice=nil}
    }
    // Fork: car-browser LAN info + firewall for the webserver port.
    func refreshLanInfo(refreshFirewall: Bool = true) {
        lanAddresses = lanIPv4Addresses()
        // Fork: mDNS hostname entry. Car browsers that block private-range IP
        // literals (Tesla-style — iPhone hotspots are 172.20.10.x) can still
        // open the page through the Mac's .local name: the browser resolves it
        // on the LAN and the client builds its WebSocket/HTTPS URLs from
        // location.host, so the whole page follows the name automatically.
        let host=ProcessInfo.processInfo.hostName
        if !host.isEmpty && host != "localhost" {
            let mdns=host.hasSuffix(".local") ? host : host+".local"
            if !lanAddresses.contains(where:{$0.address==mdns}) {
                lanAddresses.append((name:"mdns",address:mdns,network:"-",iphoneUSB:false))
            }
        }
        // Two live interfaces on one network = hotspot/USB-tether conflict.
        var seen = Set<String>(); lanSubnetConflict = false
        for item in lanAddresses where seen.contains(item.network) { lanSubnetConflict = true }
        for item in lanAddresses { seen.insert(item.network) }
        guard refreshFirewall else { return }
        guard let bin = receiverBinaryPath() else {
            firewallState = L("找不到接收器程序")
            firewallNeedsAllow = false
            firewallAllowed = false
            return
        }
        switch firewallEnabled() {
        case nil:
            firewallState = L("防火墙状态未知")
            firewallNeedsAllow = false
            firewallAllowed = false
        case false:
            firewallState = L("防火墙已关闭，无需放行")
            firewallNeedsAllow = false
            firewallAllowed = true
        case true:
            if firewallAllows(binaryPath: bin) {
                firewallState = L("防火墙已开启 · MacPlayReceiver 已放行")
                firewallNeedsAllow = false
                firewallAllowed = true
            } else {
                firewallState = L("防火墙已开启 · 未放行（车机可能连不上）")
                firewallNeedsAllow = true
                firewallAllowed = false
            }
        }
    }
    // Fork: PlugAndPlayHost — the controller reads/writes these; lan refresh
    // after activation/revert feeds the tray menu's address items.
    var plugAndPlayEnabled: Bool { settings.plugAndPlay == true }
    var savedWifiPasswords: [String: String] { settings.wifiProfiles }
    func pnpRefreshLanInfo() { refreshLanInfo(refreshFirewall: false); refreshPnpGuide() }
    // Fork: re-read the nat.plist prerequisite state + bridge gateway for the
    // guided-setup card (user just configured sharing in System Settings).
    func refreshPnpGuide() {
        pnpGuideConfig = PlugAndPlayCore.natConfigNow()
        pnpGuideBridgeIP = PlugAndPlayCore.sharedBridgeIPv4()
    }
    // Fork: authorization management (设置 → 连接 → 授权管理). Verify the stored
    // credential in the background so the section shows live validity; also
    // count app-owned WiFi keychain items for the "remembered networks" row.
    func refreshAdminAuthState() {
        refreshKeychainWifiCount()
        guard let password = AdminAuth.storedPassword() else { adminAuthState = "none"; return }
        guard adminAuthState != "checking" else { return }
        adminAuthState = "checking"
        Task {
            let ok = await Task.detached { AdminAuth.verifyPassword(password) }.value
            adminAuthState = ok ? "ok" : "invalid"
        }
    }
    func refreshKeychainWifiCount() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "NIO Play WiFi",
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var items: CFTypeRef?
        keychainWifiCount = (SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess
            ? (items as? [[String: Any]] ?? []).count : 0)
    }
    /// force=true always prompts (重新授权 — replace the stored credential);
    /// force=false repairs: silent no-op when the stored password still works,
    /// otherwise drops it and prompts (修复授权).
    func authorizeAdmin(force: Bool) {
        guard !adminAuthWorking else { return }
        adminAuthWorking = true
        Task { @MainActor in
            defer { adminAuthWorking = false }
            if !force, let stored = AdminAuth.storedPassword() {
                adminAuthState = "checking"
                if await Task.detached { AdminAuth.verifyPassword(stored) }.value {
                    adminAuthState = "ok"
                    return
                }
                AdminAuth.removePassword()
            }
            for attempt in 0..<3 {
                guard let password = AdminAuth.promptPassword(retry: attempt > 0) else { break }
                guard await Task.detached { AdminAuth.verifyPassword(password) }.value else { continue }
                AdminAuth.storePassword(password)
                adminAuthState = "ok"
                // Bonus: with a fresh credential the AirPort read is silent —
                // auto-fill the current network's password if it's still missing.
                if settings.wireless, !settings.ssid.isEmpty, settings.password.isEmpty {
                    readSavedNetworkPassword()
                }
                return
            }
            adminAuthState = AdminAuth.storedPassword() == nil ? "none" : "invalid"
        }
    }
    func removeAdminAuth() {
        AdminAuth.removePassword()
        adminAuthState = "none"
    }
    // Fork: plug-and-play master switch — settings UI and tray menu share it.
    func setPlugAndPlay(_ enabled: Bool) {
        settings.plugAndPlay=enabled;persistPreferences()
        if enabled {plugAndPlay.enableRequested(hasPhone:!connectedUSBIDs.isEmpty)}
        else {plugAndPlay.disableRequested()}
    }
    func revertBeforeQuit(completion: @escaping () -> Void) {
        plugAndPlay.revertBeforeQuit(completion: completion)
    }
    func allowFirewallForReceiver() {
        guard let bin = receiverBinaryPath(), !firewallWorking else { return }
        firewallWorking = true
        firewallState = L("正在请求管理员权限…")
        DispatchQueue.global().async {
            // Fork: keychain-first — when the plug-and-play admin credential is
            // stored, socketfilterfw runs via sudo -S with no password dialog;
            // otherwise fall back to the osascript system prompt.
            let command = "/usr/libexec/ApplicationFirewall/socketfilterfw --add " + bin
            var ok = false
            if let status = AdminAuth.runScript(command) {
                ok = status == 0
            } else {
                let script = "do shell script \"" +
                    command.replacingOccurrences(of: "\"", with: "\\\"") +
                    "\" with administrator privileges"
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                task.arguments = ["-e", script]
                task.standardOutput = Pipe()
                task.standardError = Pipe()
                try? task.run()
                task.waitUntilExit()
                ok = task.terminationStatus == 0
            }
            DispatchQueue.main.async {
                self.firewallWorking = false
                self.refreshLanInfo()
                if !ok { self.firewallState = L("放行失败，请手动在系统设置 → 防火墙中允许") }
            }
        }
    }
    // Volume sliders call this on every tick — only the receiver command, no file write.
    func sendAudioCommand() {
        let message:[String:Any]=["command":"audio","volume":settings.volume,"callVolume":settings.callVolume ?? 1,"enabled":settings.audioEnabled]
        if let data=try? JSONSerialization.data(withJSONObject:message),let line=String(data:data,encoding:.utf8){command(line)}
    }
    func applyLiveAudio() {
        sendAudioCommand()
        persistPreferences()
    }
    // Fork: the appearance override must reach NSApp, not just SwiftUI —
    // custom NSAlerts (admin password prompt), the menu bar and Dock menus
    // all follow NSApp.appearance; without this they stayed at "system"
    // while the SwiftUI window followed the setting.
    func applyAppearance() {
        switch settings.appearance {
        case "light": NSApp?.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp?.appearance = NSAppearance(named: .darkAqua)
        default: NSApp?.appearance = nil
        }
    }
    func showCarPlayWindow() {
        // Headless mode never creates a local window — the engine's show
        // command is a no-op there; don't activate the faceless receiver.
        guard settings.headless != true else {return}
        guard let task=process,task.isRunning else {return}
        MacPlayApplicationDelegate.shared?.prepareCarPlayPresentation()
        if let receiver=NSRunningApplication(processIdentifier:task.processIdentifier) {
            NSApp.yieldActivation(to:receiver)
            receiver.activate(options:.activateIgnoringOtherApps)
        }
        command("show")
    }
    func showMainWindow() {
        if MacPlayApplicationDelegate.shared?.restoreMainWindow() == true {return}
        NSApp.activate()
        for window in NSApp.windows where !(window is NSPanel) && (window.canBecomeMain || window.isMiniaturized) {
            if window.isMiniaturized {window.deminiaturize(nil)}
            window.makeKeyAndOrderFront(nil)
        }
    }
    // Fork: launch-at-login. UI state always reads SMAppService directly —
    // never the settings cache. Settings toggle and menu bar checkbox both
    // route through this single entry point.
    var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }
    func setLaunchAtLogin(_ enable: Bool) {
        let service = SMAppService.mainApp
        do {
            if enable {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
            settings.launchAtLogin = enable
            persistPreferences()
        } catch {
            status = L("登录项注册失败")
            detail = error.localizedDescription
        }
        MacPlayApplicationDelegate.shared?.preferencesChanged()
    }
    func persistPreferences() {
        guard let data=try? JSONEncoder().encode(settings) else {return}
        try? data.write(to:configURL,options:.atomic)
        try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:configURL.path)
    }
    func setLanguage(_ value:String) {
        guard ["system","zh-Hans","zh-Hant","en"].contains(value) else {return}
        MacPlayLocalization.language=value
        settings.language=value
        persistPreferences()
        if let data=try? JSONSerialization.data(withJSONObject:["command":"language","language":MacPlayLocalization.effectiveLanguage]),let line=String(data:data,encoding:.utf8){command(line)}
        MacPlayApplicationDelegate.shared?.preferencesChanged()
    }
    func enableAutomaticUSBStart() {
        guard !automaticStartReady else {return}
        automaticStartReady=true
        startForUSBIfNeeded(connectedUSBIDs)
    }
    func startForUSBIfNeeded(_ devices:Set<String>) {
        guard automaticStartReady,settings.autoStartUSB == true,!running,!reconnectCycle,!devices.isEmpty else {return}
        let selected=settings.selectedPhone ?? settings.lastPhone
        let preferred=phoneChoices.first(where:{$0.id==selected})
        if settings.selectedPhone != nil,preferred?.usb == nil {return}
        if let serial=preferred?.usb {
            guard devices.contains(serial.replacingOccurrences(of:"-",with:"").lowercased()) else {return}
        } else {
            guard devices.count==1,let serial=devices.first,let phone=phoneChoices.first(where:{$0.usb?.replacingOccurrences(of:"-",with:"").lowercased()==serial}) else {return}
            settings.selectedPhone=phone.id
        }
        settings.wireless=false
        start()
    }
    func configureRemoteCommands() {
        let center=MPRemoteCommandCenter.shared()
        center.changePlaybackPositionCommand.isEnabled=false
        remoteTargets.append(center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event=event as? MPChangePlaybackPositionCommandEvent,event.positionTime.isFinite else {return .commandFailed}
            let position=event.positionTime
            Task { @MainActor in self?.requestSeek(position) }
            return .success
        })
        for (command,index) in [(center.playCommand,1),(center.pauseCommand,2),(center.togglePlayPauseCommand,3),(center.nextTrackCommand,4),(center.previousTrackCommand,5)] {
            command.isEnabled=true
            remoteTargets.append(command.addTarget { [weak self] _ in
                Task { @MainActor in self?.command("media \(index)") }
                return .success
            })
        }
    }
    func requestSeek(_ seconds:Double) {
        guard running,playingState.canSeek,playingState.duration>0,seconds.isFinite else {return}
        let id=UUID().uuidString
        var message:[String:Any]=["command":"seek","requestId":id,"positionMs":Int(max(0,min(seconds,playingState.duration))*1000)]
        if let track=playingState.trackID {message["trackId"]=track}
        if let data=try? JSONSerialization.data(withJSONObject:message),let line=String(data:data,encoding:.utf8){pendingSeekID=id;command(line)}
    }
    func clearNowPlaying() {
        mediaPublish?.cancel();mediaPublish=nil
        metadataFeed?.stop();metadataFeed=nil
        mediaDiagnostic=""
        playingState=NowPlayingState();artworkBytes=nil;pendingSeekID=nil;nowPlaying=[:]
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled=false
        MPNowPlayingInfoCenter.default().nowPlayingInfo=nil;MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
    func publishNowPlaying(_ event:[String:Any]) {
        let now=ProcessInfo.processInfo.systemUptime
        if event["type"] as? String == "seekResult" {
            guard event["requestId"] as? String == pendingSeekID else {return}
            pendingSeekID=nil
            if event["sent"] as? Bool == true,let ms=event["positionMs"] as? Double {playingState.acceptSeek(ms/1000,at:now)}
            else {logs += "[媒体] iPhone当前不接受播放位置跳转。\n"}
        } else {
            let oldID=playingState.trackID,oldApp=playingState.appID
            playingState.receive(event,at:now)
            if oldID != playingState.trackID || oldApp != playingState.appID {pendingSeekID=nil}
        }
        guard mediaPublish==nil else {return}
        let work=DispatchWorkItem { [weak self] in self?.mediaPublish=nil;self?.flushNowPlaying() }
        mediaPublish=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.1,execute:work)
    }
    private func flushNowPlaying() {
        guard running else {return}
        playingState.advance(to:ProcessInfo.processInfo.systemUptime)
        nowPlaying[MPMediaItemPropertyTitle]=playingState.title
        nowPlaying[MPMediaItemPropertyArtist]=playingState.artist
        nowPlaying[MPMediaItemPropertyAlbumTitle]=playingState.album
        nowPlaying[MPMediaItemPropertyPlaybackDuration]=playingState.duration
        nowPlaying[MPNowPlayingInfoPropertyElapsedPlaybackTime]=playingState.position
        nowPlaying[MPNowPlayingInfoPropertyPlaybackRate]=playingState.rate
        nowPlaying[MPNowPlayingInfoPropertyDefaultPlaybackRate]=1.0
        nowPlaying[MPNowPlayingInfoPropertyIsLiveStream]=playingState.duration<=0
        if let id=playingState.trackID {nowPlaying[MPNowPlayingInfoPropertyExternalContentIdentifier]=id}
        else {nowPlaying.removeValue(forKey:MPNowPlayingInfoPropertyExternalContentIdentifier)}
        if artworkBytes != playingState.artwork {
            artworkBytes=playingState.artwork
            if let bytes=artworkBytes,let image=NSImage(data:bytes) {nowPlaying[MPMediaItemPropertyArtwork]=MPMediaItemArtwork(boundsSize:image.size){_ in image}}
            else {nowPlaying.removeValue(forKey:MPMediaItemPropertyArtwork)}
        }
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled=running && playingState.canSeek && playingState.duration>0
        MPNowPlayingInfoCenter.default().nowPlayingInfo=nowPlaying
        MPNowPlayingInfoCenter.default().playbackState=playingState.rate>0 ? .playing : .paused
        let diagnostic="总时长\(Int(playingState.duration))秒，封面\(nowPlaying[MPMediaItemPropertyArtwork] == nil ? "未收到" : "已发布")，进度跳转\(playingState.canSeek ? "可用" : "不可用")"
        if diagnostic != mediaDiagnostic {
            mediaDiagnostic=diagnostic;logs += "[媒体] \(diagnostic)\n"
            queueLogWrite()
        }
    }
    func inspectCredentials() { credentialsReady = ["identity.pk8","certificate.p7b"].allSatisfy { FileManager.default.fileExists(atPath: authDirectory.appendingPathComponent($0).path) } }
    func updateResolution() {
            guard let screen=selectedScreen else {return}
            let id=(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let physicalWidth=displays.first(where:{$0.id==id})?.width ?? Int(screen.frame.width*screen.backingScaleFactor)
            let physicalHeight=displays.first(where:{$0.id==id})?.height ?? Int(screen.frame.height*screen.backingScaleFactor)
            settings.screenPixelWidth=physicalWidth
            settings.screenPixelHeight=physicalHeight
            if let display=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let size=CGDisplayScreenSize(CGDirectDisplayID(display.uint32Value))
                settings.screenWidthMm=size.width>0 ? size.width : nil
                settings.screenHeightMm=size.height>0 ? size.height : nil
            }
        if settings.resolution == "native" {
            // Map macOS safe-area points to physical panel pixels, rather than
            // subtracting points from pixels or using the scaled desktop size.
            let insets=screen.safeAreaInsets
            let usableWidth=max(0,screen.frame.width-insets.left-insets.right)
            let usableHeight=max(0,screen.frame.height-insets.top-insets.bottom)
            settings.width=Int(Double(physicalWidth)*usableWidth/screen.frame.width)/2*2
            settings.height=Int(Double(physicalHeight)*usableHeight/screen.frame.height)/2*2
        } else if settings.resolution != "custom" {
            let parts=settings.resolution.split(separator:"x");if parts.count==2,let w=Int(parts[0]),let h=Int(parts[1]){settings.width=w;settings.height=h}
        }
    }
    func detectNetwork(requestPermission: Bool = false) {
        guard let interface=CWWiFiClient.shared().interface(), interface.powerOn() else {
            networkStatus = "Wi-Fi未开启或没有可用接口"; return
        }
        settings.wifiInterface=interface.interfaceName ?? "en0"
        settings.wifiMAC=interface.hardwareAddress() ?? ""
        let addressTask=Process();addressTask.executableURL=URL(fileURLWithPath:"/sbin/ifconfig");addressTask.arguments=[settings.wifiInterface]
        let addressPipe=Pipe();addressTask.standardOutput=addressPipe;addressTask.standardError=FileHandle.nullDevice
        if (try? addressTask.run()) != nil {
            let data=addressPipe.fileHandleForReading.readDataToEndOfFile();addressTask.waitUntilExit()
            if let text=String(data:data,encoding:.utf8),let line=text.split(separator:"\n").first(where:{$0.trimmingCharacters(in:.whitespaces).hasPrefix("ether ")}),let mac=line.split(whereSeparator:{$0.isWhitespace}).last {settings.wifiMAC=String(mac)}
        }
        if let channel=interface.wlanChannel(){settings.channel=Int(channel.channelNumber)}
        if let ssid=interface.ssid(), !ssid.isEmpty {
            if settings.ssid != ssid {
                // Fork: auto-fill password from saved WiFi profiles / the
                // app-owned keychain copy; otherwise attempt the (silent)
                // admin-credential read — see readSavedNetworkPassword(). No
                // path here ever pops the system keychain access dialog.
                if let savedPassword = settings.wifiProfiles[ssid], !savedPassword.isEmpty {
                    settings.password = savedPassword
                    passwordStatus = "已自动填入已保存的网络密码。"
                } else if let keychainPassword = readAppOwnedWifiPassword(ssid) {
                    // App-owned keychain item: no system dialog, no admin password.
                    settings.password = keychainPassword
                    settings.wifiProfiles[ssid] = keychainPassword
                    persistPreferences()
                    passwordStatus = "已从应用钥匙串自动填入网络密码。"
                } else {
                    settings.password = ""
                    passwordStatus = "网络已切换，正在自动读取密码…"
                    readSavedNetworkPassword()
                }
            }
            settings.ssid=ssid
            settings.accessPointMAC=interface.bssid()
            networkStatus="已读取当前Wi-Fi名称和信道"
            networkRequestPending=false
            return
        }
        guard CLLocationManager.locationServicesEnabled() else {
            networkStatus="系统定位服务已关闭。读取Wi-Fi名称需要在系统设置中开启定位服务。";return
        }
        switch locationManager.authorizationStatus {
        case .notDetermined:
            networkStatus="读取Wi-Fi名称需要定位权限；点击“读取当前网络”后按系统提示允许。"
            if requestPermission {
                networkRequestPending=true
                locationManager.requestWhenInUseAuthorization()
                // macOS requests authorization when a location service starts.
                // Only use this one-shot request to trigger authorization; coordinates are discarded.
                locationManager.requestLocation()
            }
        case .denied, .restricted:
            networkStatus="定位权限未允许。请在“隐私与安全性→定位服务”中允许NIO Play后重试。"
        default:
            networkStatus="已获定位权限，但系统未返回Wi-Fi名称。请确认Mac已连接Wi-Fi后重试。"
        }
    }
    var currentNetworkIsEnterprise: Bool {
        guard let interface=CWWiFiClient.shared().interface(withName:settings.wifiInterface),interface.ssid()==settings.ssid else {return false}
        return [7,8,9,10,12].contains(Int(interface.security().rawValue))
    }
    // Fork: app-owned keychain copy of WiFi passwords (generic password items
    // created by the app itself — no ACL challenge as long as the code
    // signature is stable; see scripts/create-signing-cert.sh). settings.json
    // wifiProfiles remains the first line of defence; this covers a wiped or
    // lost settings file without touching the system AirPort item again.
    func writeAppOwnedWifiPassword(ssid: String, password: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "NIO Play WiFi",
            kSecAttrAccount as String: ssid,
        ]
        let payload: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(base as CFDictionary, payload as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(base.merging(payload) { _, new in new } as CFDictionary, nil)
        }
    }
    func readAppOwnedWifiPassword(_ ssid: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "NIO Play WiFi",
            kSecAttrAccount as String: ssid,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8), !password.isEmpty else { return nil }
        return password
    }
    func readSavedNetworkPassword() {
        guard !readingPassword else { return }
        if currentNetworkIsEnterprise {
            passwordStatus="当前网络使用802.1X企业认证（用户名/密码或证书）。NIO Play的无线握手不支持发送这类凭据，请改用个人Wi-Fi、热点或USB连接。"
            return
        }
        let ssid=settings.ssid
        guard !ssid.isEmpty else {passwordStatus="请先读取当前网络名称。";return}
        readingPassword=true
        passwordStatus="正在读取钥匙串…"
        Task {
            // Fork: admin-credential path — read the AirPort item as root via
            // the security tool (argv form; no shell quoting). Root reads the
            // login AND System keychains without any ACL challenge. Query by
            // kind+account ("AirPort Network Password" / SSID), which is how
            // AirPort items are shaped on macOS that still keeps them.
            //
            // The legacy user-context SecKeychainFindGenericPassword search is
            // GONE on purpose: newer macOS no longer stores Wi-Fi passwords in
            // keychains at all, and merely touching the System keychain pops
            // "NIO Play wants to use the System keychain" — a dialog with NO
            // "Always Allow", i.e. a prompt on EVERY read for a password that
            // isn't even there. When the search comes up empty the user fills
            // the password once by hand; it is cached locally + in the
            // app-owned keychain so this never comes up again.
            if !ssid.hasPrefix("-"), let stored = AdminAuth.storedPassword() {
                let verified = await Task.detached { AdminAuth.verifyPassword(stored) }.value
                guard settings.ssid == ssid else { readingPassword=false; passwordStatus="网络已切换，请重新读取密码。"; return }
                if !verified {
                    AdminAuth.removePassword()
                    adminAuthState = "none"
                    readingPassword=false
                    passwordStatus="管理员授权已失效，请到 设置→连接→授权管理 重新授权，或手动填写密码一次（将永久记住）。"
                    return
                }
                let result = await Task.detached { () -> (Int32, String?) in
                    // Confirmed on this machine: AirPort items are stored as
                    // svce="AirPort" + acct=<SSID>, and the CURRENT network's
                    // entry lives in the SYSTEM keychain (old ones also pile
                    // up in the login keychain). Search both as root — the
                    // canonical silent Wi-Fi-password dump.
                    AdminAuth.runSudoOutput(["/usr/bin/security","find-generic-password","-w",
                                             "-s","AirPort","-a",ssid,
                                             NSHomeDirectory() + "/Library/Keychains/login.keychain-db",
                                             "/Library/Keychains/System.keychain"], password: stored)
                }.value
                guard settings.ssid == ssid else { readingPassword=false; passwordStatus="网络已切换，请重新读取密码。"; return }
                readingPassword=false
                if result.0 == 0, let password = result.1?.trimmingCharacters(in: .whitespacesAndNewlines), !password.isEmpty {
                    settings.password=password
                    settings.wifiProfiles[ssid]=password
                    writeAppOwnedWifiPassword(ssid: ssid, password: password)
                    persistPreferences()
                    passwordStatus="已通过管理员授权静默读取并记住密码，之后无需再授权。"
                } else if result.0 == 44 {
                    passwordStatus="钥匙串中没有该网络密码（新版macOS已不把Wi-Fi密码存入钥匙串）。请手动填写一次，NIO Play将永久记住。"
                } else {
                    passwordStatus="未获准读取（状态码\(result.0)），可稍后重试，或手动填写一次（将永久记住）。"
                }
                return
            }
            // No admin credential yet — run the ONE-TIME authorization flow.
            // authorizeAdmin() prompts once, stores the password in the login
            // keychain (device-only), and on success re-invokes
            // readSavedNetworkPassword(), which now takes the silent sudo
            // path above. One password entry ever; every later read (manual
            // button, network switch, app relaunch) is fully silent.
            readingPassword = false
            passwordStatus = "首次读取需一次管理员授权（仅此一次，之后自动静默读取）。"
            authorizeAdmin(force: false)
        }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else {return}
            if self.networkRequestPending { self.detectNetwork() }
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in self?.detectNetwork() }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.detectNetwork() }
    }
    func refreshUSB() {
        var iterator: io_iterator_t=0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOUSBHostDevice"),&iterator)==KERN_SUCCESS else {
            usbError="无法读取系统USB设备列表"; return
        }
        defer {IOObjectRelease(iterator)}
        var phones:[String]=[]
        var serials=Set<String>()
        var choices=settings.phones ?? []
        while case let device=IOIteratorNext(iterator), device != 0 {
            defer {IOObjectRelease(device)}
            guard let value=IORegistryEntryCreateCFProperty(device,"USB Product Name" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? String else {continue}
            if value.localizedCaseInsensitiveContains("iPhone") {
                phones.append(value)
                if let serial=IORegistryEntryCreateCFProperty(device,"USB Serial Number" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? String {
                    serials.insert(serial.replacingOccurrences(of:"-",with:"").lowercased())
                    if !choices.contains(where:{$0.usb?.replacingOccurrences(of:"-",with:"")==serial.replacingOccurrences(of:"-",with:"")}) {choices.append(PhoneChoice(id:"usb:"+serial,name:value,usb:serial))}
                }
            }
        }
        let changed=phones.count != usbDevices.count
        usbDevices=phones
        for device in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []) {
            let address=device.addressString?.replacingOccurrences(of:"-",with:":").lowercased() ?? ""
            guard !address.isEmpty else {continue}
            if device.name?.localizedCaseInsensitiveContains("iPhone") == true || choices.contains(where:{$0.bluetooth==address}) {
                if !choices.contains(where:{$0.bluetooth==address}) {choices.append(PhoneChoice(id:address,name:device.name ?? "iPhone",bluetooth:address))}
            }
        }
        phoneChoices=choices
        let added=serials.subtracting(connectedUSBIDs)
        connectedUSBIDs=serials
        // Fork: plug-and-play trigger — act on plug-in/absence transitions only.
        plugAndPlay.usbPresenceChanged(hasPhone: !serials.isEmpty)
        if changed {usbError="";usbStage=running ? "等待USB握手，请保持iPhone解锁" : "接收服务未启动"}
        startForUSBIfNeeded(added)
    }
    var usbStatus: String {
        guard !usbDevices.isEmpty else {return "未检测到USB连接的iPhone"}
        return "已检测到\(usbDevices.count)台iPhone"
    }
    func readUSBEvent(_ value:[String:String]) {
        if let stage=value["usbStatus"] {usbStage=stage;usbError=""}
        if let error=value["usbError"] {usbError=error}
    }
    func save() throws {
        updateResolution()
        settings.width=max(320,min(7680,settings.width/2*2));settings.height=max(200,min(4320,settings.height/2*2))
        if settings.strictPixels == true,settings.resolution != "native",let screen=selectedScreen,
           let physicalWidth=settings.screenPixelWidth,let physicalHeight=settings.screenPixelHeight {
            let content=NSRect(x:0,y:0,width:Double(settings.width)*screen.frame.width/Double(physicalWidth),height:Double(settings.height)*screen.frame.height/Double(physicalHeight))
            let frame=NSWindow.frameRect(forContentRect:content,styleMask:[.borderless,.closable,.miniaturizable])
            if frame.width>screen.visibleFrame.width || frame.height>screen.visibleFrame.height {
                throw NSError(domain:"MacPlay",code:2,userInfo:[NSLocalizedDescriptionKey:"所选分辨率超过当前屏幕的可见区域，无法按物理像素比例显示。请选择较低分辨率，或使用原生像素全屏模式。"])
            }
        }
        guard let w=settings.screenWidthMm,let h=settings.screenHeightMm,w>0,h>0 else {
            throw NSError(domain:"MacPlay",code:3,userInfo:[NSLocalizedDescriptionKey:"系统未返回显示器真实尺寸，无法上报固定窗口的物理大小。"])
        }
        let selected=settings.selectedPhone ?? settings.lastPhone
        let phone=phoneChoices.first(where:{$0.id==selected})
        settings.targetBluetooth=phone?.bluetooth
        settings.targetUSB=phone?.usb
        if settings.targetUSB==nil && !settings.wireless && phone==nil {
            let usbChoices=phoneChoices.filter{phone in
                guard let serial=phone.usb else {return false}
                return connectedUSBIDs.contains(serial.replacingOccurrences(of:"-",with:"").lowercased())
            }
            if usbChoices.count>1 {throw NSError(domain:"MacPlay",code:5,userInfo:[NSLocalizedDescriptionKey:"检测到多台USB连接的iPhone，请先选择要连接的设备。"])}
            if usbChoices.count==1 {settings.targetUSB=usbChoices.first?.usb}
        }
        if let phone,settings.wireless ? phone.bluetooth==nil : phone.usb==nil {
            throw NSError(domain:"MacPlay",code:4,userInfo:[NSLocalizedDescriptionKey:"所选iPhone缺少当前连接方式的设备记录，请选择已配对或USB接入的设备完成首次连接。"])
        }
        let data=try JSONEncoder().encode(settings);try data.write(to:configURL,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:configURL.path)
    }
    func setAutoReconnect(_ enabled:Bool) {
        settings.autoReconnect=enabled;persistPreferences()
        if !enabled {let waiting=reconnectCycle && !running;cancelReconnect(clearSession:!running);if waiting {status="接收已停止";detail=""}}
    }
    private func cancelReconnect(clearSession:Bool=true) {
        reconnectTimer?.invalidate();reconnectTimer=nil;reconnectBackoff.reset();reconnectCycle=false;if clearSession {successfulSettings=nil}
    }
    private func scheduleReconnect() {
        guard settings.autoReconnect == true,successfulSettings?.wireless == true,reconnectTimer==nil else {return}
        reconnectCycle=true
        let seconds=reconnectBackoff.nextDelay()
        let previousReason=status
        status="等待自动重连";detail=L(previousReason)+"\n"+L("将在\(seconds)秒后重试连接。")
        appendDiagnostic("reconnect-wait seconds=\(seconds) attempt=\(reconnectBackoff.attempts)")
        reconnectTimer=Timer.scheduledTimer(withTimeInterval:Double(seconds),repeats:false){[weak self] _ in
            MainActor.assumeIsolated {
                guard let self else {return};self.reconnectTimer=nil
                guard self.settings.autoReconnect == true,let config=self.successfulSettings else {return}
                self.refreshUSB()
                let draft=self.settings
                self.settings=config;self.settings.autoReconnect=true
                self.start(isAutomatic:true)
                self.settings=draft
                self.persistPreferences()
            }
        }
    }
    private func passiveDisconnect(_ reason:String) {
        let retry=ReconnectBackoff.permitted(enabled:settings.autoReconnect == true,successfulWirelessSession:successfulSettings?.wireless == true)
        stop(preserveReconnect:retry)
        status=reason;detail=""
        appendDiagnostic("disconnected: \(reason)")
        if retry {scheduleReconnect()}
    }
    private func appendDiagnostic(_ value:String) {
        logs += "[\(attemptID)] +\(Int(Date().timeIntervalSince(attemptStart)*1000))ms \(value)\n"
        queueLogWrite()
    }
    private func queueLogWrite() {
        let lines=logs.split(separator:"\n",omittingEmptySubsequences:false)
        if lines.count>1000 {logs=lines.suffix(1000).joined(separator:"\n")}
        guard logWrite==nil else {return}
        let work=DispatchWorkItem { [weak self] in
            guard let self else {return};self.logWrite=nil
            try? MacPlayUpdates.redactedLog(self.logs).write(to:self.logURL,atomically:true,encoding:.utf8)
        }
        logWrite=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.3,execute:work)
    }
    func start(isFallback:Bool=false,isAutomatic:Bool=false) {
        if !isFallback && !isAutomatic {cancelReconnect()}
        defer {if !running && reconnectCycle {scheduleReconnect()}}

        if !isFallback {frameRateFallbackNote=""}
        fallbackQueued=false
        stop(restoreMain:false,preserveReconnect:isFallback || isAutomatic);inspectCredentials()
        settings.bluetoothMAC=IOBluetoothHostController.default()?.addressAsString()?.replacingOccurrences(of:"-",with:":") ?? ""
        guard credentialsReady else {status="缺少认证文件";detail="请在关于页面导入有使用权限的配套认证文件。";return}
        // Fork: auto-detect current WiFi and switch profile on start
        if settings.wireless {
            if let interface = CWWiFiClient.shared().interface(withName: settings.wifiInterface),
               let actualSSID = interface.ssid(), !actualSSID.isEmpty,
               actualSSID != settings.ssid {
                settings.ssid = actualSSID
                settings.accessPointMAC = interface.bssid()
                if let savedPassword = settings.wifiProfiles[actualSSID], !savedPassword.isEmpty {
                    settings.password = savedPassword
                    passwordStatus = "已自动切换到网络 \(actualSSID) 并填入已保存的密码。"
                } else {
                    settings.password = ""
                    passwordStatus = "已自动切换到网络 \(actualSSID)，请填写密码。"
                }
            }
        }
        if settings.wireless && currentNetworkIsEnterprise {
            status="当前Wi-Fi采用企业认证";detail="无线CarPlay握手不支持802.1X用户名/密码或证书，请改用个人Wi-Fi、热点或USB连接。";return
        }
        if settings.wireless && settings.ssid.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            status="无线连接缺少网络信息";detail="请先读取当前Wi-Fi名称。";return
        }
        if settings.wireless,let network=CWWiFiClient.shared().interface(withName:settings.wifiInterface),let actual=network.ssid(),!actual.isEmpty,actual != settings.ssid {
            status="当前Wi-Fi与连接配置不一致";detail="请读取当前网络并填写对应密码。";return
        }
        do {
            let sessionURL=directory.appendingPathComponent("session-settings.json")
            // Fork: the engine persists browser-negotiated display geometry into the
            // session file (MACPLAY_SETTINGS_PATH); the car browser owns resolution
            // and physical width, the Mac only relays. start() rewrites that file
            // from memory, so adopt the negotiated values from the previous
            // session's file BEFORE overwriting — otherwise every restart silently
            // reverts to stale Mac-side values (the "匹配后毫无变化" bug).
            if let data=try? Data(contentsOf:sessionURL),
               let prev=try? JSONDecoder().decode(PlaySettings.self,from:data) {
                if prev.resolution=="custom" {
                    settings.resolution="custom"
                    settings.width=prev.width
                    settings.height=prev.height
                }
                settings.widthMmOverride=prev.widthMmOverride
            }
            try save()
            appliedSettings=settings
            try JSONEncoder().encode(settings).write(to:sessionURL,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:sessionURL.path)
            attemptID=UUID().uuidString.prefix(8).description;attemptStart=Date()
            appendDiagnostic("starting wireless=\(settings.wireless) interface=\(settings.wifiInterface) channel=\(settings.channel) video=\(settings.width)x\(settings.height) fps=\(settings.fps)")
            guard let resources=Bundle.main.resourceURL else {throw NSError(domain:"MacPlay",code:1,userInfo:[NSLocalizedDescriptionKey:"找不到应用资源目录"])}
            let task=Process();task.executableURL=resources.appendingPathComponent("runtime/MacPlayReceiver.app/Contents/MacOS/MacPlayReceiver");task.arguments=[resources.appendingPathComponent("engine/main.js").path]
            var environment=ProcessInfo.processInfo.environment;environment["MACPLAY_RESOURCES"]=resources.path;environment["MACPLAY_DATA"]=directory.path
            environment["MACPLAY_SETTINGS_PATH"]=sessionURL.path
            environment["MACPLAY_ATTEMPT"]=attemptID
            environment["MACPLAY_LANGUAGE"]=MacPlayLocalization.effectiveLanguage
            let gstLibPath: String = {
                #if arch(x86_64)
                let x64Path = resources.appendingPathComponent("gstreamer/macos-x64/lib")
                if FileManager.default.fileExists(atPath: x64Path.path) { return x64Path.path }
                #else
                let arm64Path = resources.appendingPathComponent("gstreamer/macos-arm64/lib")
                if FileManager.default.fileExists(atPath: arm64Path.path) { return arm64Path.path }
                #endif
                let armFallback = resources.appendingPathComponent("gstreamer/macos-arm64/lib")
                if FileManager.default.fileExists(atPath: armFallback.path) { return armFallback.path }
                let uniFallback = resources.appendingPathComponent("gstreamer/macos/lib")
                if FileManager.default.fileExists(atPath: uniFallback.path) { return uniFallback.path }
                return resources.appendingPathComponent("gstreamer/macos-x64/lib").path
            }()
            environment["DYLD_LIBRARY_PATH"]=gstLibPath
            task.environment=environment
            let stdin=Pipe(),stdout=Pipe();task.standardInput=stdin;task.standardOutput=stdout;task.standardError=stdout
            output=stdout;input=stdin;process=task
            stdout.fileHandleForReading.readabilityHandler={ [weak self] handle in
                let data=handle.availableData
                guard !data.isEmpty else {return}
                Task { @MainActor in
                    guard self?.process === task else {return}
                    self?.consume(data)
                }
            }
            task.terminationHandler={ [weak self] task in Task { @MainActor in
                guard self?.process === task else {return};self?.passiveDisconnect("接收进程已退出")
            }}
            try task.run();running=true;sessionStart=Date();usbStage="等待USB握手，请保持iPhone解锁";usbError="";status="正在启动接收服务";detail=settings.wireless ? "准备蓝牙握手与共用Wi-Fi连接。" : "准备USB连接与配件认证。"
        } catch {status="启动失败";detail=error.localizedDescription}
    }
    func stop(restoreMain:Bool=true,preserveReconnect:Bool=false) {
        if !preserveReconnect {cancelReconnect()}
        if let task=process,task.isRunning {
            // Give the receiver time to close its window and USB/Bluetooth helpers
            // before starting another receiver on the same ports.
            try? input?.fileHandleForWriting.write(contentsOf:Data("stop\n".utf8))
            let deadline=Date().addingTimeInterval(2)
            while task.isRunning && Date()<deadline {Thread.sleep(forTimeInterval:0.01)}
            if task.isRunning {kill(task.processIdentifier,SIGKILL)}
            task.waitUntilExit()
        }
        output?.fileHandleForReading.readabilityHandler=nil;process=nil;input=nil;output=nil;running=false;sessionStart=nil;pending.removeAll()
        status="接收已停止";detail="可以调整设置后重新启动。"
        usbStage="接收服务未启动";usbError=""
        clearNowPlaying();if restoreMain {page = .connection;showMainWindow()}
    }
    func consume(_ data:Data) {
        pending.append(data)
        while let newline=pending.firstIndex(of:0x0a) {
            let line=String(decoding:pending[..<newline],as:UTF8.self);pending.removeSubrange(...newline)
            if let eventData=line.data(using:.utf8),let event=(try? JSONSerialization.jsonObject(with:eventData)) as? [String:Any] {
                if let kind=event["type"] as? String,kind=="seekResult" {publishNowPlaying(event);continue}
                if let kind=event["type"] as? String,kind=="nowplaying" || kind=="albumart" {continue}
                if event["showCarPlay"] as? Bool == true {
                    successfulSettings=appliedSettings;reconnectBackoff.reset();reconnectCycle=false
                    reconnectTimer?.invalidate();reconnectTimer=nil
                    showCarPlayWindow();continue
                }
                if event["showMain"] as? Bool == true {showMainWindow();continue}
                if event["disconnected"] as? Bool == true {
                    if event["manual"] as? Bool == true {stop()}
                    else {passiveDisconnect(event["reason"] as? String ?? "连接已断开")}
                    return
                }
            }
            if let data=line.data(using:.utf8),let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:String] {
                if let message=value["status"] {status=message;detail=value["detail"] ?? ""}
                if let nextText=value["fallbackFps"],let next=Int(nextText),running,!fallbackQueued,
                   (appliedSettings?.fps==120 && next==90 || appliedSettings?.fps==90 && next==60) {
                    fallbackQueued=true
                    let failedTask=process
                    let previous=appliedSettings?.fps ?? settings.fps
                    Task { @MainActor [weak self] in
                        guard let self,self.running,self.process === failedTask,self.appliedSettings?.fps==previous else {return}
                        let draft=self.settings
                        self.settings=self.appliedSettings ?? self.settings
                        self.settings.fps=next
                        let note="\(previous)fps协商未启动视频，已改用\(next)fps重连。"
                        self.frameRateFallbackNote += self.frameRateFallbackNote.isEmpty ? note : "\n"+note
                        self.start(isFallback:true)
                        self.settings=draft;self.persistPreferences()
                    }
                }
                if let deviceId=value["connectedPhone"],!deviceId.isEmpty {
                    if metadataFeed==nil {
                        let receiver=process
                        let feed=NowPlayingFeed(phone:deviceId) { [weak self] event in
                            guard let self,self.running,self.process === receiver else {return}
                            self.publishNowPlaying(event)
                        }
                        metadataFeed=feed;feed.start()
                    }
                    var known=settings.phones ?? []
                    let bt=deviceId.replacingOccurrences(of:"-",with:":").lowercased()
                    let udid=value["connectedUSB"].flatMap{$0.isEmpty ? nil : $0} ?? known.first(where:{$0.bluetooth==bt})?.usb
                    let name=value["phoneName"].flatMap{$0.isEmpty ? nil : $0} ?? "iPhone"
                    known.removeAll{$0.id==bt || $0.bluetooth==bt || (udid != nil && $0.usb==udid)}
                    known.append(PhoneChoice(id:bt,name:name,bluetooth:bt,usb:udid))
                    successfulSettings?.phones=known;successfulSettings?.lastPhone=bt
                    successfulSettings?.selectedPhone=bt;successfulSettings?.targetBluetooth=bt;successfulSettings?.targetUSB=udid
                    settings.phones=known;settings.lastPhone=bt
                    if settings.selectedPhone != nil {settings.selectedPhone=bt}
                    refreshUSB()
                    if let encoded=try? JSONEncoder().encode(settings){try? encoded.write(to:configURL,options:.atomic);try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:configURL.path)}
                }
                readUSBEvent(value)
            }
            logs += MacPlayUpdates.redactedLog(line)+"\n"
        }
        queueLogWrite()
    }
    func command(_ command:String){try? input?.fileHandleForWriting.write(contentsOf:Data((command+"\n").utf8))}
    func importCredentials() {
        let panel=NSOpenPanel();panel.canChooseFiles=true;panel.canChooseDirectories=false;panel.allowsMultipleSelection=true;panel.message=L("选择identity.pk8和certificate.p7b")
        guard panel.runModal() == .OK else {return}
        for source in panel.urls where ["identity.pk8","certificate.p7b"].contains(source.lastPathComponent) {
            do {let data=try Data(contentsOf:source);let target=authDirectory.appendingPathComponent(source.lastPathComponent);try data.write(to:target,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)}catch{detail=error.localizedDescription}
        }
        inspectCredentials()
    }
}

extension PlayModel: PlugAndPlayHost {}

struct LogConsoleView: View {
    @ObservedObject var model: PlayModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("实时日志")).font(.headline)
                Spacer()
                Button(L("清空")) { model.logs = "" }
                Button(L("导出")) { NSWorkspace.shared.open(model.logURL) }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.logs.isEmpty ? L("暂无日志") : model.logs)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("logBottom")
                }
                .frame(height: 200)
                .background(Color.black.opacity(0.05))
                .cornerRadius(8)
                .onChange(of: model.logs) { _, _ in
                    withAnimation { proxy.scrollTo("logBottom", anchor: .bottom) }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

enum Page: String,CaseIterable,Identifiable {
    case connection="连接",display="显示",audio="音频",about="关于"
    var id:String{rawValue}
}

struct SettingsView: View {
    @ObservedObject var model:PlayModel
    @StateObject private var updates=MacPlayUpdates()
    @State private var showLogConsole = false
    // Manual appearance override from the About tab (nil = follow system).
    private var appearanceScheme: ColorScheme? {
        switch model.settings.appearance { case "light": return .light; case "dark": return .dark; default: return nil }
    }
    var body:some View {
        VStack(spacing:0) {
            SettingsTabStrip(selection:$model.page)
            Divider()
                Form {
                    switch model.page ?? .connection {
                    case .connection:
                        Section {
                            SessionStatusCard(model:model)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top:4,leading:16,bottom:4,trailing:16))
                        }
                        Section(L("车机浏览器地址")) {
                            Text(L("在车机浏览器打开以下地址（Mac 与车机需在同一局域网）：")).font(.callout).foregroundStyle(.secondary)
                            if model.lanAddresses.isEmpty {
                                Text(L("等待网络…")).foregroundStyle(.secondary)
                            } else {
                                ForEach(model.lanAddresses, id: \.address) { item in
                                    AddressRow(item: item)
                                }
                            }
                            // Fork: iPhone USB tether + Wi-Fi hotspot share
                            // 172.20.10.0/28 — the classic "car can't open the
                            // page on the hotspot" trap.
                            if model.lanSubnetConflict {
                                Text(L("⚠️ 检测到多个网卡在同一网段（iPhone 的 USB 共享网络与 Wi-Fi 热点都是 172.20.10.x）。请使用上面「Wi-Fi」的地址；若仍无法访问，拔掉数据线或关闭 iPhone 的「USB 网络共享」后重试。")).font(.callout).foregroundStyle(.orange)
                            }
                            if model.lanAddresses.contains(where: { !$0.iphoneUSB && $0.name != "mdns" && $0.address.hasPrefix("172.") }) {
                                Text(L("⚠️ 当前处于 172.x 私网段（iPhone 热点就是这种网段）。部分车机浏览器会拒绝直接访问私网 IP 地址：优先尝试上方「.local 主机名」地址；车机不支持 mDNS 时，只能改用车机自身热点或家庭 Wi-Fi 组网（网关在 iPhone，Mac 侧无法绕过）。")).font(.callout).foregroundStyle(.orange)
                            }
                            HStack {
                                Button(L("刷新地址")) { model.refreshLanInfo() }
                            }
                            Text(L(".local 主机名通过 mDNS 在局域网内解析；车机浏览器拦截私网 IP 字面量时可用它打开页面，页面内的触控/音频/HTTPS 会自动跟随主机名。车机需支持 mDNS 解析。")).font(.caption).foregroundStyle(.secondary)
                        }
                        .onAppear { model.refreshLanInfo() }
                        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
                            // Addresses move when the hotspot (re)assigns DHCP;
                            // skip the firewall scan, that stays manual/first-load.
                            model.refreshLanInfo(refreshFirewall: false)
                        }
                        Section(L("防火墙")) {
                            HStack {
                                Text(L(model.firewallState)).foregroundStyle(.secondary)
                                Spacer()
                                if model.firewallNeedsAllow {
                                    Button(model.firewallWorking ? L("正在放行…") : L("一键放行 MacPlayReceiver")) {
                                        model.allowFirewallForReceiver()
                                    }
                                    .buttonStyle(RainbowButtonStyle())
                                    .disabled(model.firewallWorking)
                                } else if model.firewallAllowed {
                                    Text("✓").font(.system(size: 15, weight: .bold)).foregroundStyle(.green)
                                }
                            }
                            if model.firewallNeedsAllow {
                                Text(L("需要管理员密码。放行后车机浏览器才能访问 8080 端口。")).font(.callout).foregroundStyle(.secondary)
                            }
                            Button(L("打开防火墙设置")) {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Firewall")!)
                            }
                            Text(L("局域网需放行：TCP 8080（浏览器画面/触控/音频）。iPhone 直连 CarPlay 使用系统 usbmuxd/蓝牙/Wi-Fi，走 NIO Play 自身通道。")).font(.callout).foregroundStyle(.secondary)
                        }
                        // Fork: authorization management — live credential status,
                        // re-authorize / repair / remove, and remembered-network
                        // counts. One stored credential silences every password
                        // dialog (plug-and-play, firewall allow, WiFi read).
                        Section(L("授权管理")) {
                            LabeledContent(L("管理员授权")) {
                                switch model.adminAuthState {
                                case "ok": Text("✓ " + L("已授权")).foregroundStyle(.green)
                                case "invalid": Text(L("密码已失效")).foregroundStyle(.orange)
                                case "checking": Text(L("正在验证…")).foregroundStyle(.secondary)
                                default: Text(L("未授权")).foregroundStyle(.secondary)
                                }
                            }
                            HStack {
                                Button(model.adminAuthWorking ? L("正在验证…") : (model.adminAuthState == "ok" ? L("重新授权") : L("立即授权"))) {
                                    model.authorizeAdmin(force: true)
                                }
                                .disabled(model.adminAuthWorking)
                                Button(L("修复授权")) { model.authorizeAdmin(force: false) }
                                    .disabled(model.adminAuthWorking || model.adminAuthState == "none")
                                Button(L("移除授权")) { model.removeAdminAuth() }
                                    .buttonStyle(.link).foregroundStyle(.red)
                                    .disabled(model.adminAuthWorking || model.adminAuthState == "none")
                            }
                            LabeledContent(L("网络密码记忆")) {
                                Text(L("已记住 \(model.settings.wifiProfiles.count) 个网络（钥匙串 \(model.keychainWifiCount) 个）"))
                            }
                            Text(L("管理员密码经系统级加密存入本机钥匙串，用于静默执行即插即用、防火墙放行与读取网络密码等特权操作；密码失效时自动重新询问。网络密码首次读取后自动缓存，之后无需再次授权。")).font(.callout).foregroundStyle(.secondary)
                        }
                        .onAppear { model.refreshAdminAuthState() }
                        Section(L("无线网络密码")) {
                            if model.settings.wifiProfiles.isEmpty {
                                Text(L("尚未保存网络密码")).foregroundStyle(.secondary)
                            } else {
                                DisclosureGroup(L("已保存的网络") + " (\(model.settings.wifiProfiles.count))") {
                                    ForEach(Array(model.settings.wifiProfiles.keys.sorted()), id: \.self) { ssid in
                                        HStack {
                                            Text(ssid).font(.callout)
                                            Spacer()
                                            if ssid == model.settings.ssid {
                                                Text(L("当前")).font(.caption).foregroundStyle(.green)
                                            }
                                            Button(L("删除")) {
                                                model.settings.wifiProfiles.removeValue(forKey: ssid)
                                            }.buttonStyle(.link).foregroundStyle(.red)
                                        }
                                    }
                                }
                            }
                        }
                        Section(L("接收端")) {
                            Picker(L("iPhone"),selection:Binding(get:{model.settings.selectedPhone ?? "auto"},set:{model.settings.selectedPhone=$0=="auto" ? nil : $0})) {
                                Text(L("自动（上次连接的iPhone）")).tag("auto")
                                ForEach(model.phoneChoices){phone in Text(phone.name+"（"+String(phone.id.suffix(5))+"）").tag(phone.id)}
                            }
                            Button(L("刷新iPhone列表")){model.refreshUSB()}
                            Text(L("自动模式优先连接上次成功显示画面的iPhone。切换设备后点击“应用并重新连接”。")).font(.callout).foregroundStyle(.secondary)
                            Picker(L("连接方式"),selection:$model.settings.wireless) {
                                Text(L("有线CarPlay")).tag(false)
                                Text(L("无线CarPlay")).tag(true)
                            }.pickerStyle(.segmented)
                            Text(L(model.settings.wireless ? "通过蓝牙配对后使用共用Wi-Fi连接。" : "通过USB数据线连接，无需填写Wi-Fi信息。")).foregroundStyle(.secondary)
                        }
                        Section(L("应用")) {
                            Picker(L("语言"),selection:Binding(get:{model.settings.language ?? "system"},set:{model.setLanguage($0)})) {
                                Text(L("跟随系统")).tag("system")
                                Text(L("简体中文")).tag("zh-Hans")
                                Text(L("繁體中文")).tag("zh-Hant")
                                Text(L("English")).tag("en")
                            }
                            Toggle(L("USB接入时自动启动CarPlay"),isOn:Binding(get:{model.settings.autoStartUSB ?? false},set:{model.settings.autoStartUSB=$0;model.persistPreferences();if $0 {model.startForUSBIfNeeded(model.currentUSBIDs)}}))
                            Toggle(L("允许后台运行"),isOn:Binding(get:{model.settings.backgroundEnabled ?? false},set:{model.settings.backgroundEnabled=$0;MacPlayApplicationDelegate.shared?.preferencesChanged()}))
                            Toggle(L("登录时启动"),isOn:Binding(get:{model.launchAtLoginEnabled},set:{model.setLaunchAtLogin($0)}))
                            Toggle(L("CarPlay连接时防止系统休眠"),isOn:Binding(get:{model.settings.preventSleepWhenConnected ?? false},set:{model.settings.preventSleepWhenConnected=$0;model.persistPreferences()}))
                            Toggle(L("MJPEG兼容流"),isOn:Binding(get:{model.settings.mjpegFallback ?? true},set:{model.settings.mjpegFallback=$0;model.persistPreferences()}))
                            Text(L("连接期间阻止系统休眠（含合盖，需连接电源），显示器仍可正常熄屏。")).font(.callout).foregroundStyle(.secondary)
                            Text(L("为不支持硬解直通的老旧车机浏览器保留8080端口的兼容画面。关闭后该通道无视频，可降低接收端CPU占用。")).font(.callout).foregroundStyle(.secondary)
                            Text(L("关闭主窗口后继续接收，可从菜单栏图标打开窗口或退出。自动启动需要NIO Play保持运行，并在iPhone上解锁和完成信任。")).font(.callout).foregroundStyle(.secondary)
                        }
                        Section(L("即插即用")) {
                            Toggle(L("插入iPhone后自动共享网络并阻止合盖睡眠"),isOn:Binding(get:{model.settings.plugAndPlay ?? false},set:{model.setPlugAndPlay($0)}))
                            if !model.plugAndPlayStatus.isEmpty {
                                Text(L(model.plugAndPlayStatus)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            // Fork: guided setup — checklist of the one-time
                            // prerequisites read from nat.plist + one-click jumps
                            // into the right System Settings pane for manual
                            // configuration.
                            DisclosureGroup(L("引导设置")) {
                                VStack(alignment:.leading,spacing:6) {
                                    LabeledContent(L("热点名称")) {
                                        Text(L(model.pnpGuideConfig.networkName.isEmpty ? "未配置" : model.pnpGuideConfig.networkName))
                                            .foregroundStyle(model.pnpGuideConfig.networkName.isEmpty ? Color.orange : Color.green)
                                    }
                                    LabeledContent(L("共享给 Wi-Fi")) {
                                        Text(L(model.pnpGuideConfig.hasAirport ? "已配置" : "未检测到"))
                                            .foregroundStyle(model.pnpGuideConfig.hasAirport ? Color.green : Color.orange)
                                    }
                                    LabeledContent(L("互联网共享")) {
                                        Text(L(model.pnpGuideConfig.enabled ? "当前：开" : "当前：关"))
                                    }
                                    if let bridge = model.pnpGuideBridgeIP {
                                        LabeledContent(L("车机访问地址")) {
                                            Text("https://\(bridge):8443").textSelection(.enabled)
                                        }
                                    }
                                    HStack {
                                        Button(L("打开系统设置 → 互联网共享")) {
                                            NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preferences.sharing?internetSharing")!)
                                        }
                                        Button(L("重新检测")) { model.refreshPnpGuide() }
                                    }
                                    Text(L("第 1 步：点按「打开系统设置 → 互联网共享」，在共享设置中将共享来源选为「iPhone USB」、共享给选为「Wi-Fi」，并设置热点名称与密码（只需配置一次）。第 2 步：回到此处打开上方开关，插入 iPhone 即自动生效。改完点「重新检测」确认状态。")).font(.callout).foregroundStyle(.secondary)
                                }
                                .padding(.vertical,2)
                            }
                            Text(L("使用前提：在系统设置 → 通用 → 共享 → 互联网共享中，将「iPhone USB」共享给 Wi-Fi 并配置好热点名称与密码（只需配置一次）。开启后插入 iPhone 自动执行：断开当前 Wi-Fi → 开启互联网共享 → 开启合盖不休眠（熄屏但系统继续运行）；拔出 iPhone 或退出应用时自动还原。开启与还原各需一次管理员授权。")).font(.callout).foregroundStyle(.secondary)
                            Text(L("合盖不休眠期间请保持电源连接；还原后合盖恢复正常睡眠。")).font(.callout).foregroundStyle(.secondary)
                        }
                        if !model.settings.wireless {Section(L("USB直连")) {
                            LabeledContent(L("设备"),value:L(model.usbStatus))
                            if !model.usbDevices.isEmpty {LabeledContent(L("连接阶段"),value:L(model.usbError.isEmpty ? model.usbStage : model.usbError))}
                            Button(L("刷新USB设备")){model.refreshUSB()}
                            Text(L("连接数据线后点击“启动接收”，并在iPhone上解锁、确认信任。USB设备检测会自动刷新。")).foregroundStyle(.secondary)
                        }}
                        if model.settings.wireless {
                            Section(L("共用Wi-Fi")) {
                                Toggle(L("无线连接被动断开时自动重连"),isOn:Binding(get:{model.settings.autoReconnect ?? false},set:{model.setAutoReconnect($0)}))
                                TextField(L("网络名称（SSID）"),text:Binding(get:{model.settings.ssid},set:{
                                    if model.settings.ssid != $0 {
                                        // Fork: auto-fill from saved profiles when SSID changes
                                        if let saved = model.settings.wifiProfiles[$0], !saved.isEmpty {
                                            model.settings.password = saved
                                        } else {
                                            model.settings.password = ""
                                        }
                                    }
                                    model.settings.ssid=$0
                                }))
                                SecureField(L("网络密码"),text:Binding(get:{model.settings.password},set:{
                                    model.settings.password=$0
                                    // Fork: save password to profile when entered
                                    if !model.settings.ssid.isEmpty && !$0.isEmpty {
                                        model.settings.wifiProfiles[model.settings.ssid]=$0
                                    }
                                }))
                                TextField(L("网络接口"),text:$model.settings.wifiInterface)
                                Stepper(L("信道：\(model.settings.channel)"),value:$model.settings.channel,in:1...196)
                                HStack {
                                    Button(L("读取当前网络")){model.detectNetwork(requestPermission:true)}
                                    Button(L(model.readingPassword ? "正在读取密码…" : "读取已保存密码")){model.readSavedNetworkPassword()}.disabled(model.readingPassword || model.settings.ssid.isEmpty)
                                    Button(L("打开定位设置")){NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)}
                                    Button(L("打开蓝牙设置")){NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.BluetoothSettings")!)}
                                }
                                Text(L(model.networkStatus)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                if !model.passwordStatus.isEmpty {Text(L(model.passwordStatus)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                Text(L("Mac与iPhone需加入同一Wi-Fi，并在两端确认蓝牙配对码。不会创建名为NIO Play的Wi-Fi。填写SSID与共享密码，或授权读取已保存的密码。802.1X企业Wi-Fi的用户名、个人密码或证书不能作为共享密码发送。")).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    case .display:
                        Section(L("分辨率")) {
                            // Fork: the car browser IS the display — resolution is negotiated
                            // and remembered by the head unit's web client (webclient.html
                            // 显示 tab), the Mac only relays. Read-only here.
                            LabeledContent(L("请求像素"),value:"\(model.settings.width)×\(model.settings.height)")
                            LabeledContent(L("来源"),value: model.settings.resolution == "custom" ? L("车机浏览器上报") : L("默认（车机连接后自动跟随）"))
                            Text(L("分辨率由车机浏览器「显示」设置决定并按设备记忆，Mac 仅作中继。车机连接后自动按其窗口像素协商，如需修改请在车机网页操作。")).font(.callout).foregroundStyle(.secondary)
                        }
                        Section(L("最高帧率")) {
                            Picker(L("最高帧率"),selection:Binding(get:{model.settings.fps},set:{model.settings.fps=$0;model.persistPreferences()})) {
                                Text("30 fps").tag(30)
                                Text("60 fps").tag(60)
                                Text("90 fps").tag(90)
                                Text("120 fps").tag(120)
                            }.pickerStyle(.segmented)
                        }
                        Section(L("编码")) {
                            Toggle(L("无头模式（不在Mac上显示CarPlay画面）"),isOn:Binding(get:{model.settings.headless ?? false},set:{model.settings.headless=$0;model.persistPreferences()}))
                            Text(L("画面仅通过浏览器串流，适合车机使用。切换后重新连接生效。")).font(.callout).foregroundStyle(.secondary)
                            Toggle(L("零转码模式（M1 最佳性能，需 WebCodecs 浏览器）"),isOn:Binding(get:{model.settings.zeroTranscode ?? false},set:{model.settings.zeroTranscode=$0;model.persistPreferences()}))
                            Text(L("跳过 Mac 端视频解码，H.264 直接转发给浏览器硬解。需配合无头模式 + Chrome/Edge 类浏览器（HTTPS）。不支持 WebCodecs 时无画面。切换后重新连接生效。")).font(.callout).foregroundStyle(.secondary)
                            Toggle(L("截屏模式（兼容性最好，延迟较高）"),isOn:Binding(get:{model.settings.screenCapture ?? false},set:{model.settings.screenCapture=$0;model.persistPreferences()}))
                            Text(L("截取 Mac 上的 CarPlay 窗口，以 MJPEG 发到浏览器。兼容所有浏览器，延迟约 200-500ms，帧率约 10fps。不能与无头模式/零转码同时用（需要 Mac 显示窗口）。切换后重新连接生效。")).font(.callout).foregroundStyle(.secondary)
                        }
                        Section {
                            Text(L("UI 缩放与安全边距在车机浏览器设置面板（⚙️ → 显示）中调整。")).font(.callout).foregroundStyle(.secondary)
                        }
                    case .audio:
                        Section(L("CarPlay声音")) {
                            VStack(alignment:.leading,spacing:4) {
                                Text(L("媒体音量")).font(.callout)
                                Slider(value:Binding(get:{model.settings.volume},set:{
                                    model.settings.volume=$0;model.sendAudioCommand()
                                }),in:0...1) { editing in
                                    if !editing {model.persistPreferences()}
                                }
                                Text("\(Int((model.settings.volume).rounded()*100))%").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            VStack(alignment:.leading,spacing:4) {
                                Text(L("通话音量")).font(.callout)
                                Slider(value:Binding(get:{model.settings.callVolume ?? 1},set:{
                                    model.settings.callVolume=$0;model.sendAudioCommand()
                                }),in:0...1) { editing in
                                    if !editing {model.persistPreferences()}
                                }
                                Text("\(Int(((model.settings.callVolume ?? 1)).rounded()*100))%").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Toggle(L("打开浏览器时自动恢复播放"),isOn:Binding(get:{model.settings.autoResumeOnBrowser ?? true},set:{model.settings.autoResumeOnBrowser=$0;model.persistPreferences()}))
                            Text(L("开启：任一设备打开浏览器页面即自动继续播放，关闭页面自动暂停（同蓝牙耳机断开）。关闭：打开浏览器仅接通声音通道，是否播放、暂停由你在画面里手动控制（尊重手动暂停）。")).font(.callout).foregroundStyle(.secondary)
                        }
                        Section(L("设备")) {
                            Picker(L("输出设备"),selection:Binding(get:{model.settings.outputDevice ?? ""},set:{model.settings.outputDevice=$0.isEmpty ? nil : $0;model.persistPreferences()})) {
                                Text(L("系统默认设备")).tag("")
                                ForEach(model.audioOutputs){device in Text(device.name).tag(device.id)}
                            }
                            Picker(L("输入设备"),selection:Binding(get:{model.settings.inputDevice ?? ""},set:{model.settings.inputDevice=$0.isEmpty ? nil : $0;model.persistPreferences()})) {
                                Text(L("系统默认设备")).tag("")
                                ForEach(model.audioInputs){device in Text(device.name).tag(device.id)}
                            }
                            Button(L("刷新设备")){model.refreshHardware()}
                            Text(L("媒体与通话音量实时生效；设备切换后应用并重新连接。默认跟随系统设备，麦克风使用需要系统授权。")).font(.callout).foregroundStyle(.secondary)
                        }
                    case .about:
                        MacPlayAboutView(model:model,updates:updates)
                    }
                }.formStyle(.grouped)
                if model.page != .about {
                if showLogConsole { LogConsoleView(model: model) }
                Divider()
                HStack {
                    if model.receivingOrWaiting {Button(L("停止接收")){model.stop()}}
                    if model.running {Button(L(showLogConsole ? "隐藏日志" : "日志控制台")){showLogConsole.toggle()}}
                    // Dock icon is hidden (LSUIElement): Cmd+Q has no menu, so
                    // the window needs an explicit quit affordance.
                    Button(L("退出")){NSApp.terminate(nil)}
                        .help(L("退出 NIO Play"))
                    Spacer()
                    Button(L(model.running ? "应用并重新连接" : "启动接收")){model.start()}.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }.padding(16)
                }
        }
        .frame(minWidth:520,minHeight:480)
        .preferredColorScheme(appearanceScheme)
        .environment(\.locale,Locale(identifier:MacPlayLocalization.effectiveLanguage))
        .onChange(of:model.settings.ssid){_,_ in model.passwordStatus=""}
        .onAppear{updates.startAutomaticChecks()}
        .alert(L("发现新版本"),isPresented:$updates.showPrompt){
            Button(L(updates.installer == nil ? "查看发行说明" : "下载更新")){updates.openDownload()}
            Button(L("稍后"),role:.cancel){updates.dismissPrompt()}
        } message:{Text("NIO Play \(updates.release?.version?.description ?? "")")}
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)){_ in model.detectNetwork();model.refreshUSB();model.refreshHardware();if model.settings.language == nil || model.settings.language == "system" {model.setLanguage("system")}}
    }
}

// Rainbow accent, used sparingly: tab underline, primary buttons, status card.
extension LinearGradient {
    static let rainbowColors: [Color] = [
        Color(red: 1.0, green: 0.373, blue: 0.427),
        Color(red: 1.0, green: 0.698, blue: 0.420),
        Color(red: 1.0, green: 0.902, blue: 0.420),
        Color(red: 0.420, green: 0.831, blue: 0.498),
        Color(red: 0.310, green: 0.765, blue: 0.969),
        Color(red: 0.690, green: 0.420, blue: 0.961),
    ]
    static var rainbow: LinearGradient {
        LinearGradient(colors: rainbowColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var rainbowHorizontal: LinearGradient {
        LinearGradient(colors: rainbowColors, startPoint: .leading, endPoint: .trailing)
    }
    static var rainbowSoft: LinearGradient {
        LinearGradient(colors: rainbowColors.map { $0.opacity(0.14) }, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct RainbowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(LinearGradient.rainbow))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct SettingsTabStrip: View {
    @Binding var selection: Page?
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Page.allCases) { page in
                tabButton(page)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }
    private func tabButton(_ page: Page) -> some View {
        let active = (selection ?? .connection) == page
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { selection = page }
        } label: {
            VStack(spacing: 5) {
                Text(L(page.rawValue))
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Color.primary : Color.secondary)
                Capsule()
                    .fill(active ? AnyShapeStyle(LinearGradient.rainbowHorizontal) : AnyShapeStyle(Color.clear))
                    .frame(height: 3)
            }
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// Connection tab: light rainbow gradient card with dot + device + duration + res/fps.
struct SessionStatusCard: View {
    @ObservedObject var model: PlayModel
    private var dotColor: Color {
        if model.running { return Color(red: 0.20, green: 0.78, blue: 0.35) }
        if model.receivingOrWaiting { return .orange }
        return Color(nsColor: .systemGray)
    }
    private var deviceName: String {
        let id = model.settings.selectedPhone ?? model.settings.lastPhone
        if let phone = model.phoneChoices.first(where: { $0.id == id }) { return phone.name }
        return model.running || model.receivingOrWaiting ? "iPhone" : L("未连接")
    }
    private var metaLine: String {
        var parts = [L(model.settings.wireless ? "无线CarPlay" : "有线CarPlay")]
        if model.running, let start = model.sessionStart {
            let minutes = max(1, Int(Date().timeIntervalSince(start) / 60))
            parts.append(L("会话 \(minutes) 分钟"))
        }
        parts.append("\(model.settings.width)×\(model.settings.height) · \(model.settings.fps)fps")
        return parts.joined(separator: " · ")
    }
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(dotColor).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(deviceName).font(.system(size: 14, weight: .semibold))
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(metaLine).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if !model.detail.isEmpty {
                    Text(L(model.detail)).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
            Text(L(model.status)).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(LinearGradient.rainbowSoft))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
    }
}

// Connection tab: one interface row — HTTPS main + HTTP secondary, with copy feedback.
struct AddressRow: View {
    let item: (name: String, address: String, network: String, iphoneUSB: Bool)
    @State private var copied: String?

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copied == text { copied = nil } }
    }
    private var interfaceLabel: String {
        item.iphoneUSB ? L("iPhone USB 网络（与热点同网段，车机无法访问，勿用）")
            : (item.name == "mdns" ? L("mDNS 主机名（车机需支持 .local 解析，可绕过私网 IP 拦截）")
            : (item.name == "en0" ? L("Wi-Fi") : item.name))
    }
    private var interfaceColor: Color {
        item.iphoneUSB ? .orange
            : (item.name == "mdns" ? Color(red: 0.15, green: 0.45, blue: 0.85)
            : (item.name == "en0" ? Color(red: 0.20, green: 0.70, blue: 0.35) : .secondary))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("https://\(item.address):8443")
                    .font(.system(.body, design: .monospaced)).bold().textSelection(.enabled)
                Spacer()
                Button { copy("https://\(item.address):8443") } label: {
                    Text(copied == "https://\(item.address):8443" ? L("已复制") : L("复制 HTTPS"))
                }
                .buttonStyle(RainbowButtonStyle())
            }
            HStack {
                Text("http://\(item.address):8080")
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Button { copy("http://\(item.address):8080") } label: {
                    Text(copied == "http://\(item.address):8080" ? L("已复制") : L("复制 HTTP"))
                }.buttonStyle(.bordered)
            }
            Text(interfaceLabel).font(.caption2).foregroundStyle(interfaceColor)
        }
        .padding(.vertical, 2)
    }
}

private struct MainWindowContent: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: PlayModel
    let delegate: MacPlayApplicationDelegate

    var body: some View {
        SettingsView(model:model).onAppear {
            let openScene=openWindow
            delegate.install(model,openMainWindow:{openScene(id:"main")})
        }
    }
}

@main struct MacPlayApp: App {
    @NSApplicationDelegateAdaptor(MacPlayApplicationDelegate.self) private var delegate
    @StateObject private var model=PlayModel()
    var body:some Scene {
        Window("NIO Play",id:"main") {MainWindowContent(model:model,delegate:delegate)}
            .defaultSize(width:560,height:540)
            .commands {CommandGroup(replacing:.newItem){};CommandGroup(after:.appInfo){Button(L("启动接收")){model.start()};Button(L("停止接收")){model.stop()}}}
    }
}
