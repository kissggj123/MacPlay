import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Darwin

struct ReleaseVersion: Comparable, Equatable {
    let parts: [Int]
    init?(_ text: String) {
        guard let range = text.range(of: #"(?<![0-9])\d+\.\d+\.\d+(?![0-9.])"#, options: .regularExpression) else { return nil }
        parts = text[range].split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
    var description: String { parts.map(String.init).joined(separator: ".") }
}

struct GitHubRelease: Decodable {
    struct Asset: Decodable { let name: String; let browser_download_url: String }
    let tag_name: String
    let html_url: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    var version: ReleaseVersion? { ReleaseVersion(tag_name) }
    func installer(arm64: Bool) -> URL? {
        let architecture = arm64 ? ["arm64", "aarch64", "apple-silicon"] : ["x86_64", "x64", "intel", "amd64"]
        let images = assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        let asset = images.first { item in architecture.contains { item.name.lowercased().contains($0) } }
            ?? images.first { $0.name.lowercased().contains("universal") }
        guard let asset, let url = URL(string: asset.browser_download_url), url.scheme == "https",
              url.host == "github.com", url.path.hasPrefix("/kissggj123/NIOPlay/releases/download/") else { return nil }
        return url
    }
}

@MainActor final class MacPlayUpdates: ObservableObject {
    @Published var checking = false
    @Published var status = "尚未检查更新"
    @Published var detail = ""
    @Published var release: GitHubRelease?
    @Published var showPrompt = false
    @Published var exportStatus = ""
    @Published var exportDetail = ""
    @Published var automatic = UserDefaults.standard.object(forKey: "MacPlay.automaticUpdates") as? Bool ?? false // Fork: no background update checks by default (saves power/network; upstream repo isn't ours).
    private var automaticTimer:Timer?
    private var didStartupCheck=false
    func startAutomaticChecks() {
        guard !didStartupCheck else {return};didStartupCheck=true
        if automatic {check(automatic:true);scheduleChecks()}
    }
    private func scheduleChecks() {
        automaticTimer?.invalidate()
        automaticTimer=Timer.scheduledTimer(withTimeInterval:7200,repeats:true){[weak self] _ in
            MainActor.assumeIsolated {self?.check(automatic:true,silent:true)}
        }
    }
    private let defaults = UserDefaults.standard
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.1" }
    var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }
    var architecture: String {
        #if arch(arm64)
        return "Apple Silicon"
        #else
        return "Intel"
        #endif
    }
    var nativeArm64: Bool {
        #if arch(arm64)
        return true
        #else
        var value: Int32 = 0; var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
        #endif
    }
    var installer: URL? { release?.installer(arm64: nativeArm64) }
    func setAutomatic(_ enabled: Bool) {
        automatic = enabled; defaults.set(enabled, forKey: "MacPlay.automaticUpdates")
        if enabled { check(automatic: true);scheduleChecks() } else {automaticTimer?.invalidate();automaticTimer=nil;showPrompt=false}
    }
    func check(automatic isAutomatic: Bool = false,silent:Bool=false) {
        guard !checking, !isAutomatic || automatic else { return }
        let now = Date().timeIntervalSince1970
        if isAutomatic { defaults.set(now, forKey: "MacPlay.lastUpdateCheck") }
        checking = true; status = "正在检查更新…"; detail = ""
        Task {
            defer { checking = false }
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/kissggj123/NIOPlay/releases?per_page=100")!)
                request.timeoutInterval = 15
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("MacPlay/\(currentVersion)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                guard http.statusCode == 200 else {
                    status = "检查更新失败"; detail = "GitHub HTTP \(http.statusCode)"; return
                }
                let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
                    .filter { !$0.draft && !$0.prerelease && $0.version != nil }
                guard let newest = releases.max(by: { $0.version! < $1.version! }), let latest = newest.version,
                      let current = ReleaseVersion(currentVersion) else { status = "未找到正式发行版"; return }
                defaults.set(now, forKey: "MacPlay.lastUpdateCheck")
                guard latest > current else { release = nil; status = "当前已是最新版本"; return }
                let arm = nativeArm64
                release = releases.first { $0.version == latest && $0.installer(arm64: arm) != nil } ?? newest
                status = "发现新版本"; detail = latest.description
                if !silent && (!isAutomatic || automatic && defaults.string(forKey: "MacPlay.notifiedVersion") != latest.description) { showPrompt = true }
            } catch {
                status = "检查更新失败"; detail = error.localizedDescription
            }
        }
    }
    func dismissPrompt() {
        showPrompt = false
        if let version = release?.version { defaults.set(version.description, forKey: "MacPlay.notifiedVersion") }
    }
    func openDownload() {
        if let url = installer { NSWorkspace.shared.open(url) }
        else { openRelease() }
        dismissPrompt()
    }
    func openRelease() {
        if let url = URL(string: release?.html_url ?? "https://github.com/kissggj123/NIOPlay/releases"), url.scheme == "https", url.host == "github.com" { NSWorkspace.shared.open(url) }
    }
    func exportLogs(_ model: PlayModel) {
        exportDetail = ""
        let raw = (try? String(contentsOf: model.logURL, encoding: .utf8)) ?? model.logs
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { exportStatus = "暂无日志可导出"; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "MacPlay-\(currentVersion)-\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none).replacingOccurrences(of: "/", with: "-"))-logs.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let safe = Self.redactedLog(raw)
            try "MacPlay \(currentVersion) (\(build)) · \(architecture)\n\(Date().ISO8601Format())\n\n\(safe)".write(to: url, atomically: true, encoding: .utf8)
            exportStatus = "日志已导出"
        } catch { exportStatus = "日志导出失败"; exportDetail = error.localizedDescription }
    }
    static func redactedLog(_ raw: String) -> String {
        raw.replacingOccurrences(of: NSHomeDirectory(), with: "~").components(separatedBy: .newlines).filter {
            $0.range(of: #"(?i)password|passphrase|private.?key|certificate|pair.?record|ssid|payload=|hex=|token|identity\.pk8"#, options: .regularExpression) == nil
        }.map {
            $0.replacingOccurrences(of: #"(?i)\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b|\b(?:\d{1,3}\.){3}\d{1,3}\b|\b[0-9a-f]{8}-[0-9a-f-]{20,}\b|\b[0-9a-f]{24,}\b"#, with: "[redacted]", options: .regularExpression)
        }.joined(separator: "\n")
    }
}

// About tab hero: app icon + rainbow version pill on a light gradient card.
struct AboutHeroCard: View {
    @ObservedObject var updates: MacPlayUpdates
    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text("NIO Play").font(.system(size: 20, weight: .bold))
                HStack(spacing: 8) {
                    Text("v\(updates.currentVersion).\(updates.build)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(LinearGradient.rainbow))
                    Text(updates.architecture).font(.caption).foregroundStyle(.secondary)
                }
                Text(L("将 Mac 变成 CarPlay 接收器，串流到车机浏览器显示和操作"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(LinearGradient.rainbowSoft))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
    }
}

// Bundled-component self check: verifies every packaged runtime piece exists
// and that the GStreamer plugin registry actually loads the critical elements.
struct ComponentCheck: Identifiable {
    let id: String
    let nameKey: String
    var ok: Bool
    var detail: String
}

@MainActor final class MacPlayDiagnostics: ObservableObject {
    @Published var checks: [ComponentCheck] = []
    @Published var running = false

    private var res: URL { Bundle.main.resourceURL ?? Bundle.main.bundleURL }

    private func exists(_ relativePath: String, executable: Bool = false) -> Bool {
        let url = res.appendingPathComponent(relativePath)
        let fm = FileManager.default
        return executable ? fm.isExecutableFile(atPath: url.path) : fm.fileExists(atPath: url.path)
    }

    private func firstNode(of module: String) -> String? {
        let dir = res.appendingPathComponent("engine/node_modules/\(module)/build/Release")
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .first { $0.hasSuffix(".node") }
    }

    func run() {
        guard !running else { return }
        running = true
        Task {
            var results: [ComponentCheck] = []
            @MainActor func add(_ id: String, _ nameKey: String, _ ok: Bool, _ detail: String = "") {
                results.append(ComponentCheck(id: id, nameKey: nameKey, ok: ok, detail: detail))
                checks = results
            }
            add("receiver", "接收端 Node", exists("runtime/MacPlayReceiver.app/Contents/MacOS/MacPlayReceiver", executable: true))
            add("engine", "引擎脚本", exists("engine/main.js"))
            let crypto = firstNode(of: "livi-crypto")
            add("crypto", "加密模块", crypto != nil, crypto ?? "")
            let video = firstNode(of: "livi-gst-video")
            add("video", "视频引擎", video != nil, video ?? "")
            add("helperd", "辅助进程", exists("driver/livi-helperd", executable: true))
            add("bluetooth", "蓝牙驱动", exists("driver/macplay-bluetooth", executable: true))
            add("auth", "认证文件", exists("authentication/identity.pk8") && exists("authentication/certificate.p7b"))
            let gstVersion = ((try? String(contentsOf: res.appendingPathComponent("gstreamer/macos-arm64/version.txt"), encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            add("gst", "GStreamer 运行时", exists("gstreamer/macos-arm64/lib/libgstreamer-1.0.0.dylib"), gstVersion)
            // Dynamic: the bundled plugin registry must actually load these.
            add("hwdec", "硬件解码（VideoToolbox）", await inspect("vtdec"))
            add("avdec", "libav 兜底解码", await inspect("avdec_h264"))
            add("webrtc", "WebRTC 直通", await inspect("webrtcbin"))
            running = false
        }
    }

    // Runs the bundled gst-inspect against one element with the same env the
    // engine uses; exit 0 means the plugin registry resolved it end to end.
    private func inspect(_ element: String) async -> Bool {
        let root = res.appendingPathComponent("gstreamer/macos-arm64")
        let bin = root.appendingPathComponent("bin/gst-inspect-1.0")
        guard FileManager.default.isExecutableFile(atPath: bin.path) else { return false }
        let process = Process()
        process.executableURL = bin
        process.arguments = [element]
        process.environment = [
            "DYLD_LIBRARY_PATH": root.appendingPathComponent("lib").path,
            "GST_PLUGIN_PATH": root.appendingPathComponent("lib/gstreamer-1.0").path,
            "GST_PLUGIN_SCANNER": root.appendingPathComponent("libexec/gstreamer-1.0/gst-plugin-scanner").path,
            "HOME": NSHomeDirectory(),
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        if process.isRunning { process.terminate(); return false }
        return process.terminationStatus == 0
    }
}

struct MacPlayAboutView: View {
    @ObservedObject var model: PlayModel
    @ObservedObject var updates: MacPlayUpdates
    @StateObject private var diagnostics = MacPlayDiagnostics()
    var body: some View {
        Section {
            AboutHeroCard(updates: updates)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top:4,leading:16,bottom:4,trailing:16))
        }
        Section(L("外观")) {
            Picker(L("外观"),selection:Binding(get:{model.settings.appearance ?? "system"},set:{
                model.settings.appearance=$0=="system" ? nil : $0;model.persistPreferences()
            })) {
                Text(L("跟随系统")).tag("system")
                Text(L("浅色")).tag("light")
                Text(L("深色")).tag("dark")
            }.pickerStyle(.segmented)
        }
        Section(L("信息")) {
            LabeledContent(L("设备 ID"), value: model.settings.bluetoothMAC.isEmpty ? "—" : model.settings.bluetoothMAC)
            LabeledContent(L("开源许可"), value: "GPL-3.0-or-later")
            Link(L("项目主页"), destination: URL(string: "https://github.com/kissggj123/NIOPlay")!)
        }
        Section(L("组件自检")) {
            HStack {
                Button(L(diagnostics.running ? "正在自检…" : "执行自检")) { diagnostics.run() }
                    .disabled(diagnostics.running)
                Spacer()
                if !diagnostics.checks.isEmpty {
                    let broken = diagnostics.checks.filter { !$0.ok }.count
                    Text(broken == 0 ? L("全部组件正常") : L("部分组件缺失"))
                        .font(.callout)
                        .foregroundStyle(broken == 0 ? Color.green : Color.orange)
                }
            }
            ForEach(diagnostics.checks) { check in
                HStack(spacing: 8) {
                    Image(systemName: check.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(check.ok ? Color.green : Color.red)
                    Text(L(check.nameKey))
                    Spacer()
                    if !check.detail.isEmpty {
                        Text(check.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
        Section(L("车机浏览器功能")) {
            Text(L("• 无头模式：画面仅通过浏览器串流")).font(.callout)
            Text(L("• 零转码模式：M1 零 CPU 占用，H.264 直通")).font(.callout)
            Text(L("• WebCodecs 硬解 / MJPEG 自动回退")).font(.callout)
            Text(L("• 分流音频混音器 / 浏览器麦克风回传")).font(.callout)
            Text(L("• Focus 模式 / 显示设置 / 安全边距")).font(.callout)
            Text(L("在车机浏览器打开 http://<Mac-IP>:8080（HTTPS: https://<Mac-IP>:8443）")).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
        Section(L("致谢")) {
            Text(L("基于 Roylyl/MacPlay，移植 youcci/playport 功能，借鉴 fython/wheelplay 设计")).font(.callout).foregroundStyle(.secondary)
        }
        Section(L("软件更新")) {
            Toggle(L("自动检查更新"), isOn: Binding(get: { updates.automatic }, set: { updates.setAutomatic($0) }))
            HStack { Button(L(updates.checking ? "正在检查更新…" : "检查更新")) { updates.check() }.disabled(updates.checking); Button(L("查看发行说明")) { updates.openRelease() } }
            Text(L(updates.status)).foregroundStyle(.secondary)
            if !updates.detail.isEmpty { Text(updates.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            if updates.release != nil {
                if updates.installer != nil { Button(L("下载更新")) { updates.openDownload() } }
                if updates.installer == nil { Text(L("最新发行版暂无适合当前芯片的安装包，请查看发行说明。")).font(.callout).foregroundStyle(.secondary) }
            }
        }
        Section(L("日志")) {
            HStack {
                Button(L("打开日志")) { NSWorkspace.shared.open(model.logURL) }.disabled(!FileManager.default.fileExists(atPath: model.logURL.path))
                Button(L("导出日志")) { updates.exportLogs(model) }
            }
            DisclosureGroup(L("最近日志")) {
                ScrollView {
                    Text(model.logs.isEmpty ? L("暂无日志") : model.logs)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 180)
            }
            if !updates.exportStatus.isEmpty { Text(L(updates.exportStatus)).foregroundStyle(.secondary) }
            if !updates.exportDetail.isEmpty { Text(updates.exportDetail).font(.callout).foregroundStyle(.secondary) }
        }
        Section {
            DisclosureGroup(L("认证文件")) {
                LabeledContent(L("状态"), value: L(model.credentialsReady ? "文件已就绪，等待iPhone验证" : "缺少文件"))
                HStack {
                    Button(L("导入认证文件")) { model.importCredentials() }
                    Button(L("打开认证目录")) { NSWorkspace.shared.open(model.authDirectory) }
                    Button(L("刷新状态")) { model.inspectCredentials() }
                }
            }
        }
    }
}
