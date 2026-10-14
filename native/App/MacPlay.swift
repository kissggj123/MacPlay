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
func lanIPv4Addresses() -> [(name: String, address: String)] {
    var result: [(String, String)] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
    defer { freeifaddrs(ifaddr) }
    var ptr: UnsafeMutablePointer<ifaddrs>? = first
    while let p = ptr {
        defer { ptr = p.pointee.ifa_next }
        guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: p.pointee.ifa_name)
        if name == "lo0" { continue }
        var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
        let ip = String(cString: buf)
        if !result.contains(where: { $0.1 == ip }) { result.append((name, ip)) }
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
    var autoReconnect: Bool? = nil
    var autoStartUSB: Bool? = nil
    var backgroundEnabled: Bool? = nil
    var preventSleepWhenConnected: Bool? = nil
    var headless: Bool? = nil
    var zeroTranscode: Bool? = nil
    var displayID: UInt32? = nil
    var inputDevice: String? = nil
    var outputDevice: String? = nil
    var callVolume: Double? = nil
    var strictPixels: Bool? = nil
    var resolution = "1280x720"
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
    var channel = 36
    var wifiInterface = "en0"
    var wifiMAC = ""
    var accessPointMAC: String? = nil
    var bluetoothMAC = ""
    var audioEnabled = true
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
    @Published var lanAddresses: [(name: String, address: String)] = []
    @Published var firewallState = ""
    @Published var firewallNeedsAllow = false
    @Published var firewallWorking = false
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
        if ![30,60,90,120].contains(settings.fps) { settings.fps=60 }
        if settings.resolution == "1920x720" { settings.resolution="custom" }
        if settings.resolution == "3840x2160" { settings.resolution="native" }
        configureRemoteCommands(); refreshHardware(); installBundledCredentials(); updateResolution(); inspectCredentials(); detectNetwork(); refreshUSB()
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
    func refreshLanInfo() {
        lanAddresses = lanIPv4Addresses()
        guard let bin = receiverBinaryPath() else {
            firewallState = L("找不到接收器程序")
            firewallNeedsAllow = false
            return
        }
        switch firewallEnabled() {
        case nil:
            firewallState = L("防火墙状态未知")
            firewallNeedsAllow = false
        case false:
            firewallState = L("防火墙已关闭，无需放行")
            firewallNeedsAllow = false
        case true:
            if firewallAllows(binaryPath: bin) {
                firewallState = L("防火墙已开启 · MacPlayReceiver 已放行")
                firewallNeedsAllow = false
            } else {
                firewallState = L("防火墙已开启 · 未放行（车机可能连不上）")
                firewallNeedsAllow = true
            }
        }
    }
    func allowFirewallForReceiver() {
        guard let bin = receiverBinaryPath(), !firewallWorking else { return }
        firewallWorking = true
        firewallState = L("正在请求管理员权限…")
        DispatchQueue.global().async {
            // socketfilterfw needs admin; osascript shows the system password dialog.
            let script = "do shell script \"/usr/libexec/ApplicationFirewall/socketfilterfw --add " +
                bin.replacingOccurrences(of: "\"", with: "\\\"") +
                "\" with administrator privileges"
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            try? task.run()
            task.waitUntilExit()
            let ok = task.terminationStatus == 0
            DispatchQueue.main.async {
                self.firewallWorking = false
                self.refreshLanInfo()
                if !ok { self.firewallState = L("放行失败，请手动在系统设置 → 防火墙中允许") }
            }
        }
    }
    func applyLiveAudio() {
        let message:[String:Any]=["command":"audio","volume":settings.volume,"callVolume":settings.callVolume ?? 1,"enabled":settings.audioEnabled]
        if let data=try? JSONSerialization.data(withJSONObject:message),let line=String(data:data,encoding:.utf8){command(line)}
        if let data=try? JSONEncoder().encode(settings){try? data.write(to:configURL,options:.atomic);try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:configURL.path)}
    }
    func showCarPlayWindow() {
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
            if settings.ssid != ssid {settings.password="";passwordStatus="网络已切换，请读取或填写当前网络密码。"}
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
            networkStatus="定位权限未允许。请在“隐私与安全性→定位服务”中允许MacPlay后重试。"
        default:
            networkStatus="已获定位权限，但系统未返回Wi-Fi名称。请确认Mac已连接Wi-Fi后重试。"
        }
    }
    var currentNetworkIsEnterprise: Bool {
        guard let interface=CWWiFiClient.shared().interface(withName:settings.wifiInterface),interface.ssid()==settings.ssid else {return false}
        return [7,8,9,10,12].contains(Int(interface.security().rawValue))
    }
    func readSavedNetworkPassword() {
        guard !readingPassword else { return }
        if currentNetworkIsEnterprise {
            passwordStatus="当前网络使用802.1X企业认证（用户名/密码或证书）。MacPlay的无线握手不支持发送这类凭据，请改用个人Wi-Fi、热点或USB连接。"
            return
        }
        let ssid=settings.ssid
        guard !ssid.isEmpty else {passwordStatus="请先读取当前网络名称。";return}
        readingPassword=true
        passwordStatus="正在读取钥匙串；如有系统提示，请授权MacPlay访问该网络密码。"
        Task {
            let result=await Task.detached { () -> (OSStatus, String?) in
                var length: UInt32=0
                var bytes: UnsafeMutableRawPointer?
                let service="AirPort"
                let status=service.withCString { servicePtr in
                    ssid.withCString { accountPtr in
                        SecKeychainFindGenericPassword(nil,UInt32(service.utf8.count),servicePtr,UInt32(ssid.utf8.count),accountPtr,&length,&bytes,nil)
                    }
                }
                defer { if let bytes {SecKeychainItemFreeContent(nil,bytes)} }
                let password=bytes.flatMap {String(data:Data(bytes:$0,count:Int(length)),encoding:.utf8)}
                return (status,password)
            }.value
            readingPassword=false
            guard settings.ssid==ssid else {passwordStatus="网络已切换，请重新读取密码。";return}
            if result.0==errSecSuccess,let password=result.1,!password.isEmpty {
                settings.password=password
                passwordStatus="已读取保存的密码，点击“应用并重新连接”使用网络凭据。"
            } else if result.0==errSecSuccess {
                passwordStatus="钥匙串未返回可用密码，请手动填写。"
            } else if result.0==errSecItemNotFound {
                passwordStatus="钥匙串未找到该网络的可读取密码，请手动填写。"
            } else if result.0==errSecUserCanceled || result.0==errSecAuthFailed || result.0==errSecInteractionNotAllowed {
                passwordStatus="未获准读取网络密码（系统状态码\(result.0)），请重新授权或手动填写。"
            } else {
                let explanation=SecCopyErrorMessageString(result.0,nil) as String? ?? ""
                passwordStatus="无法读取网络密码（系统状态码\(result.0)），请手动填写。"+(explanation.isEmpty ? "" : "\n"+explanation)
            }
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
            try save()
            appliedSettings=settings
            let sessionURL=directory.appendingPathComponent("session-settings.json")
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
            try task.run();running=true;usbStage="等待USB握手，请保持iPhone解锁";usbError="";status="正在启动接收服务";detail=settings.wireless ? "准备蓝牙握手与共用Wi-Fi连接。" : "准备USB连接与配件认证。"
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
        output?.fileHandleForReading.readabilityHandler=nil;process=nil;input=nil;output=nil;running=false;pending.removeAll()
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

enum Page: String,CaseIterable,Identifiable {
    case connection="连接",display="显示",audio="音频",about="关于"
    var id:String{rawValue}
    var icon:String {switch self{case .connection:return "iphone.radiowaves.left.and.right";case .display:return "display";case .audio:return "speaker.wave.2";case .about:return "info.circle"}}
}

struct SettingsView: View {
    @ObservedObject var model:PlayModel
    @StateObject private var updates=MacPlayUpdates()
    var body:some View {
        NavigationSplitView {
            List(Page.allCases,selection:$model.page){ item in Label(L(item.rawValue),systemImage:item.icon).tag(item) }
                .navigationTitle("MacPlay").navigationSplitViewColumnWidth(min:150,ideal:165,max:200)
        } detail: {
            VStack(spacing:0) {
                Form {
                    switch model.page ?? .connection {
                    case .connection:
                        Section(L("接收端")) {
                            LabeledContent(L("状态"),value:L(model.status))
                            Text(L(model.detail)).foregroundStyle(.secondary).font(.callout).textSelection(.enabled)
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
                            Toggle(L("CarPlay连接时防止系统休眠"),isOn:Binding(get:{model.settings.preventSleepWhenConnected ?? false},set:{model.settings.preventSleepWhenConnected=$0;model.persistPreferences()}))
                            Text(L("连接期间阻止系统休眠（含合盖，需连接电源），显示器仍可正常熄屏。")).font(.callout).foregroundStyle(.secondary)
                            Toggle(L("无头模式（不在Mac上显示CarPlay画面）"),isOn:Binding(get:{model.settings.headless ?? false},set:{model.settings.headless=$0;model.persistPreferences()}))
                            Text(L("画面仅通过浏览器串流，适合车机使用。切换后重新连接生效。")).font(.callout).foregroundStyle(.secondary)
                            Toggle(L("零转码模式（M1 最佳性能，需 WebCodecs 浏览器）"),isOn:Binding(get:{model.settings.zeroTranscode ?? false},set:{model.settings.zeroTranscode=$0;model.persistPreferences()}))
                            Text(L("跳过 Mac 端视频解码，H.264 直接转发给浏览器硬解。需配合无头模式 + Chrome/Edge 类浏览器（HTTPS）。不支持 WebCodecs 时无画面。切换后重新连接生效。")).font(.callout).foregroundStyle(.secondary)
                            Text(L("关闭主窗口后继续接收，可从菜单栏图标打开窗口或退出。自动启动需要MacPlay保持运行，并在iPhone上解锁和完成信任。")).font(.callout).foregroundStyle(.secondary)
                        }
                        Section(L("车机浏览器")) {
                            Text(L("在车机浏览器打开以下地址（Mac 与车机需在同一局域网）：")).font(.callout).foregroundStyle(.secondary)
                            if model.lanAddresses.isEmpty {
                                Text(L("未检测到局域网地址，请确认 Mac 已连接 Wi-Fi。")).foregroundStyle(.secondary)
                            } else {
                                ForEach(model.lanAddresses, id: \.address) { item in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("http://\(item.address):8080").textSelection(.enabled)
                                            Text(item.name).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button(L("复制")) {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString("http://\(item.address):8080", forType: .string)
                                        }
                                    }
                                }
                            }
                            HStack {
                                Text(L("防火墙"))
                                Spacer()
                                Text(model.firewallState).foregroundStyle(.secondary)
                            }
                            if model.firewallNeedsAllow {
                                Button(model.firewallWorking ? L("正在放行…") : L("一键放行 MacPlayReceiver")) {
                                    model.allowFirewallForReceiver()
                                }.disabled(model.firewallWorking)
                                Text(L("需要管理员密码。放行后车机浏览器才能访问 8080 端口。")).font(.callout).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button(L("刷新地址")) { model.refreshLanInfo() }
                                Button(L("打开防火墙设置")) {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Firewall")!)
                                }
                            }
                            Text(L("局域网需放行：TCP 8080（浏览器画面/触控/音频）。iPhone 直连 CarPlay 使用系统 usbmuxd/蓝牙/Wi-Fi，走 MacPlay 自身通道。")).font(.callout).foregroundStyle(.secondary)
                        }.onAppear { model.refreshLanInfo() }
                        if !model.settings.wireless {Section(L("USB直连")) {
                            LabeledContent(L("设备"),value:L(model.usbStatus))
                            if !model.usbDevices.isEmpty {LabeledContent(L("连接阶段"),value:L(model.usbError.isEmpty ? model.usbStage : model.usbError))}
                            Button(L("刷新USB设备")){model.refreshUSB()}
                            Text(L("连接数据线后点击“启动接收”，并在iPhone上解锁、确认信任。USB设备检测会自动刷新。")).foregroundStyle(.secondary)
                        }}
                        if model.settings.wireless {
                            Section(L("共用Wi-Fi")) {
                                Toggle(L("无线连接被动断开时自动重连"),isOn:Binding(get:{model.settings.autoReconnect ?? false},set:{model.setAutoReconnect($0)}))
                                TextField(L("网络名称（SSID）"),text:Binding(get:{model.settings.ssid},set:{if model.settings.ssid != $0 {model.settings.password=""};model.settings.ssid=$0}))
                                SecureField(L("网络密码"),text:$model.settings.password)
                                TextField(L("网络接口"),text:$model.settings.wifiInterface)
                                Stepper(L("信道：\(model.settings.channel)"),value:$model.settings.channel,in:1...196)
                                HStack {
                                    Button(L("读取当前网络")){model.detectNetwork(requestPermission:true)}
                                    Button(L(model.readingPassword ? "正在读取密码…" : "读取已保存密码")){model.readSavedNetworkPassword()}.disabled(model.readingPassword || model.settings.ssid.isEmpty)
                                    Button(L("打开定位设置")){NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)}
                                    Button(L("打开蓝牙设置")){NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.BluetoothSettings")!)}
                                }
                                Text(L(model.networkStatus)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                if !model.passwordStatus.isEmpty {Text(L(model.passwordStatus)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)}
                                Text(L("Mac与iPhone需加入同一Wi-Fi，并在两端确认蓝牙配对码。不会创建名为MacPlay的Wi-Fi。填写SSID与共享密码，或授权读取已保存的密码。802.1X企业Wi-Fi的用户名、个人密码或证书不能作为共享密码发送。")).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    case .display:
                        Section(L("显示器")) {
                            Picker(L("显示位置"),selection:Binding(get:{model.settings.displayID ?? model.displays.first?.id ?? 0},set:{model.settings.displayID=$0;model.updateResolution()})) {
                                ForEach(model.displays){Text($0.label).tag($0.id)}
                            }
                            if let panel=model.displays.first(where:{$0.id==model.settings.displayID}) {Text(L(panel.details)).font(.callout).foregroundStyle(.secondary)}
                            Text(L("默认内建显示器；切换显示器后应用并重新连接。")).font(.callout).foregroundStyle(.secondary)
                        }
                        Section(L("视频分辨率")) {
                            Picker(L("分辨率"),selection:$model.settings.resolution) {
                                Text(L("屏幕原生像素（避开刘海）")).tag("native")
                                ForEach(["1280x720","1920x1080","2560x1440"],id:\.self){Text($0.replacingOccurrences(of:"x",with:"×")).tag($0)}
                                Text(L("自定义")).tag("custom")
                            }.onChange(of:model.settings.resolution){_,_ in model.updateResolution()}
                            if model.settings.resolution == "custom" {
                                TextField(L("宽度（像素）"),value:$model.settings.width,format:.number)
                                TextField(L("高度（像素）"),value:$model.settings.height,format:.number)
                            }
                            Toggle(L("严格按屏幕物理像素显示"),isOn:Binding(get:{model.settings.strictPixels ?? false},set:{model.settings.strictPixels=$0})).disabled(model.settings.resolution == "native")
                            LabeledContent(L("请求像素"),value:"\(model.settings.width)×\(model.settings.height)")
                            Text(L("原生像素模式全屏显示。关闭严格像素显示后，窗口适配屏幕并可等比例调整大小，不改变请求分辨率。")).font(.callout).foregroundStyle(.secondary)
                        }
                        Section(L("流畅度")) {
                            Picker(L("最高帧率"),selection:$model.settings.fps){ForEach([30,60,90,120],id:\.self){Text(L("\($0)fps")).tag($0)}}
                            Text(L("高帧率为实验请求：120fps协商失败后改用90fps，90fps仍失败则改用60fps。发起CarPlay连接后20秒未启动视频视为失败。")).font(.callout).foregroundStyle(.secondary)
                            if !model.frameRateFallbackNote.isEmpty {Text(L(model.frameRateFallbackNote)).font(.callout).foregroundStyle(.secondary)}
                            Text(L("上报所选分辨率与固定窗口对应的真实物理尺寸，不提供倍率调节。请关闭CarPlay自身的“智能缩放显示”以避免自动缩放。帧率为请求上限。")).font(.callout).foregroundStyle(.secondary)
                        }
                    case .audio:
                        Section(L("CarPlay声音")) {
                            Toggle(L("播放iPhone音频"),isOn:$model.settings.audioEnabled).onChange(of:model.settings.audioEnabled){_,_ in model.applyLiveAudio()}
                            LabeledContent(L("媒体音量")){Slider(value:$model.settings.volume,in:0...1).onChange(of:model.settings.volume){_,_ in model.applyLiveAudio()};Text(L("\(Int(model.settings.volume*100))%")).monospacedDigit().frame(width:42)}
                            LabeledContent(L("通话音量")){Slider(value:Binding(get:{model.settings.callVolume ?? 1},set:{model.settings.callVolume=$0;model.applyLiveAudio()}),in:0...1);Text(L("\(Int((model.settings.callVolume ?? 1)*100))%")).monospacedDigit().frame(width:42)}
                            Picker(L("输出设备"),selection:Binding(get:{model.settings.outputDevice ?? ""},set:{model.settings.outputDevice=$0})) {Text(L("系统默认设备")).tag("");ForEach(model.audioOutputs){Text($0.name).tag($0.id)}}
                            Picker(L("输入设备"),selection:Binding(get:{model.settings.inputDevice ?? ""},set:{model.settings.inputDevice=$0})) {Text(L("系统默认设备")).tag("");ForEach(model.audioInputs){Text($0.name).tag($0.id)}}
                            Button(L("刷新设备")){model.refreshHardware()}
                            Text(L("媒体与通话音量实时生效；设备切换后应用并重新连接。默认跟随系统设备，麦克风使用需要系统授权。")).font(.callout).foregroundStyle(.secondary)
                        }
                    case .about:
                        MacPlayAboutView(model:model,updates:updates)
                    }
                }.formStyle(.grouped)
                if model.page != .about {
                Divider()
                HStack {
                    if model.receivingOrWaiting {Button(L("停止接收")){model.stop()}}
                    if model.running {Button(L("显示画面")){model.showCarPlayWindow()}}
                    Spacer()
                    Button(L(model.running ? "应用并重新连接" : "启动接收")){model.start()}.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }.padding(16)
                }
            }.navigationTitle(L((model.page ?? .connection).rawValue))
        }.frame(minWidth:900,minHeight:560)
        .environment(\.locale,Locale(identifier:MacPlayLocalization.effectiveLanguage))
        .onChange(of:model.settings.ssid){_,_ in model.passwordStatus=""}
        .onAppear{updates.startAutomaticChecks()}
        .alert(L("发现新版本"),isPresented:$updates.showPrompt){
            Button(L(updates.installer == nil ? "查看发行说明" : "下载更新")){updates.openDownload()}
            Button(L("稍后"),role:.cancel){updates.dismissPrompt()}
        } message:{Text("MacPlay \(updates.release?.version?.description ?? "")")}
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)){_ in model.detectNetwork();model.refreshUSB();model.refreshHardware();if model.settings.language == nil || model.settings.language == "system" {model.setLanguage("system")}}
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
        Window("MacPlay",id:"main") {MainWindowContent(model:model,delegate:delegate)}
            .defaultSize(width:820,height:650)
            .commands {CommandGroup(replacing:.newItem){};CommandGroup(after:.appInfo){Button(L("启动接收")){model.start()};Button(L("停止接收")){model.stop()}}}
    }
}
