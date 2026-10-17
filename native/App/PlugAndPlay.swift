import Foundation
import AppKit
import CoreWLAN
import Security

// Fork: one-shot admin credential. The FIRST privileged operation shows our
// own password dialog, verifies the password via `sudo -S -k /usr/bin/true`,
// and stores it in the login keychain (kSecClassGenericPassword, service
// "NIO Play Admin", ThisDeviceOnly). Every later operation — plug-and-play
// activate/revert, firewall allow — runs scripts through
// `sudo -S -k /bin/sh -c <script>` with the stored password piped to stdin:
// no more password dialogs. If the password stops verifying (changed / user
// demoted from admin) the stored copy is dropped and we re-prompt; standard
// (non-admin) accounts fall back to the old osascript system prompt, which
// accepts any admin's credentials.
enum AdminAuth {
    static let service = "NIO Play Admin"
    private static let account = "admin"

    static func storedPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8),
              !password.isEmpty else { return nil }
        return password
    }

    static func storePassword(_ password: String) {
        guard !password.isEmpty else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(password.utf8)
        var status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func removePassword() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Run argv as root: `sudo -S -k <argv>` with the password on stdin.
    /// Returns the command's exit status, or nil when the process couldn't run.
    /// `-k` forces fresh authentication every call — we always supply the
    /// password, so a cached sudo timestamp can never mask a stale one.
    nonisolated static func runSudo(_ arguments: [String], password: String) -> Int32? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-S", "-k"] + arguments
        let input = Pipe()
        task.standardInput = input
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        try? input.fileHandleForWriting.write(contentsOf: Data((password + "\n").utf8))
        try? input.fileHandleForWriting.close()
        task.waitUntilExit()
        return task.terminationStatus
    }

    nonisolated static func verifyPassword(_ password: String) -> Bool {
        runSudo(["/usr/bin/true"], password: password) == 0
    }

    /// Run a shell script as root with the stored password (nil when none is
    /// stored or it no longer verifies). Exit status semantics preserved.
    nonisolated static func runScript(_ script: String) -> Int32? {
        guard let password = storedPassword(), verifyPassword(password) else { return nil }
        return runSudo(["/bin/sh", "-c", script], password: password)
    }

    /// Run argv as root and capture stdout, e.g. `security find-generic-password`
    /// for the AirPort item. Returns (exit status, stdout) — status nil-safe
    /// only when the process failed to launch (-1, nil).
    nonisolated static func runSudoOutput(_ arguments: [String], password: String) -> (Int32, String?) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-S", "-k"] + arguments
        let input = Pipe()
        let output = Pipe()
        task.standardInput = input
        task.standardOutput = output
        task.standardError = Pipe()
        do { try task.run() } catch { return (-1, nil) }
        try? input.fileHandleForWriting.write(contentsOf: Data((password + "\n").utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(data: data, encoding: .utf8))
    }

    /// Modal password prompt styled after the reference dialog: title states
    /// what is stored, body explains scope and how to revoke. Returns nil when
    /// the user cancels.
    @MainActor static func promptPassword(retry: Bool) -> String? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = retry ? L("管理员密码不正确，请重试") : L("钥匙串管理员密码授权")
        alert.informativeText = L("您的密码将采用系统级加密存入 macOS 钥匙串，仅用于本机静默执行即插即用、防火墙放行与读取网络密码等特权操作；之后的自动执行不再重复询问，可随时在「设置 → 连接 → 授权管理」中移除。")
        let field = NSSecureTextField()
        field.placeholderString = L("请输入当前 Mac 登录密码")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L("授权并储存"))
        alert.addButton(withTitle: L("取消"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              !field.stringValue.isEmpty else { return nil }
        return field.stringValue
    }
}

// 即插即用（CarPlay 盒子模式）：插入 iPhone 后 Mac 自动变成车机的网络——
// 断开当前 Wi-Fi → 打开 macOS「互联网共享」（NAT：iPhone USB → 预配置的
// Wi-Fi 热点，热点名/密码由系统设置里配好，本功能只负责打开）→ 开启合盖
// 不休眠（pmset disablesleep，合盖熄屏但系统继续运行）。拔出 iPhone、关闭
// 开关或退出应用时按快照精确还原。系统级修改每次方向需要一次管理员授权
// （osascript，与防火墙一键放行同一套路）；授权被取消时不做半途状态。

enum PlugAndPlayAdminResult { case success, canceled, failed }

struct PnpNatConfig {
    var enabled = false
    var hasAirport = false
    var airportEnabled = false
    var networkName = ""
}

// 启用前的系统状态快照：恢复时逐项写回，而不是想当然地全部关闭——
// 用户可能本来就让共享保持开启（此时还原为开）。
struct PnpState: Codable {
    var natEnabledWas = false
    var airportEnabledWas = false
    var airportConfigured = false
    var sleepDisabledWas = false
    var wifiInterface: String?
    var wifiSSID: String?

    static func load(from url: URL) -> PnpState? {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(PnpState.self, from: data) else { return nil }
        return state
    }
    func save(to url: URL) {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }
}

// 纯逻辑部分（plist 解析、脚本拼装、触发判定）不含 AppKit/CoreWLAN 依赖，
// 由 PlugAndPlayPolicy.test.swift 覆盖。
enum PlugAndPlayCore {
    static let natPath = "/Library/Preferences/SystemConfiguration/com.apple.nat.plist"
    static let sharingService = "system/com.apple.NetworkSharing"
    static let sharingPlist = "/System/Library/LaunchDaemons/com.apple.NetworkSharing.plist"

    static func natConfig(from data: Data) -> PnpNatConfig? {
        guard let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let nat = root["NAT"] as? [String: Any] else { return nil }
        var config = PnpNatConfig()
        config.enabled = (nat["Enabled"] as? Bool) ?? ((nat["Enabled"] as? String) == "1")
        if let airport = nat["AirPort"] as? [String: Any] {
            config.hasAirport = true
            config.airportEnabled = (airport["Enabled"] as? Bool) ?? ((airport["Enabled"] as? String) == "1")
            config.networkName = airport["NetworkName"] as? String ?? ""
        }
        return config
    }

    static func natConfigNow() -> PnpNatConfig {
        (try? Data(contentsOf: URL(fileURLWithPath: natPath))).flatMap(natConfig) ?? PnpNatConfig()
    }

    // pmset -g 首段的 SleepDisabled 即 disablesleep 的当前值。
    static func sleepDisabledNow() -> Bool {
        let output = runCommand("/usr/bin/pmset", ["-g"])
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            if parts.first == "SleepDisabled" { return parts.last == "1" }
        }
        return false
    }

    // 互联网共享激活后 bridge100 会拿到固定的 192.168.2.1（Mac 侧网关地址），
    // 它就是车机浏览器应打开的地址。
    static func sharedBridgeIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: p.pointee.ifa_name)
            guard name.hasPrefix("bridge") else { continue }
            var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            return String(cString: buf)
        }
        return nil
    }

    static func shouldActivate(enabled: Bool, busy: Bool, active: Bool) -> Bool { enabled && !busy && !active }

    private static func plistSetBool(_ key: String, _ value: Bool) -> String {
        let target = value ? "true" : "false"
        return "/usr/libexec/PlistBuddy -c \"Set \(key) \(target)\" $P 2>/dev/null||/usr/libexec/PlistBuddy -c \"Add \(key) bool \(target)\" $P"
    }

    // kickstart 后轮询 bridge100：共享守护进程是按需启动的 MachService，
    // 改完 nat.plist 必须 kick 让它重读配置；AP 接管前 Wi-Fi 若被自动重连
    // 抢占，多次 kick 也会重试接管。
    private static func kickAndVerifyBridge() -> String {
        "ok=1;for i in 1 2 3 4;do /bin/launchctl kickstart -k \(sharingService) 2>/dev/null||/bin/launchctl bootstrap system \(sharingPlist) 2>/dev/null;/bin/sleep 3;if /sbin/ifconfig bridge100 >/dev/null 2>&1;then ok=0;break;fi;done;exit $ok"
    }

    static func enableScript(airportConfigured: Bool) -> String {
        var parts = ["P=\(natPath)", plistSetBool(":NAT:Enabled", true)]
        if airportConfigured { parts.append(plistSetBool(":NAT:AirPort:Enabled", true)) }
        parts.append("/usr/bin/pmset -a disablesleep 1")
        parts.append(kickAndVerifyBridge())
        return parts.joined(separator: ";")
    }

    static func restoreScript(natEnabledWas: Bool, airportEnabledWas: Bool, airportConfigured: Bool, sleepDisabledWas: Bool) -> String {
        var parts = ["P=\(natPath)", plistSetBool(":NAT:Enabled", natEnabledWas)]
        if airportConfigured { parts.append(plistSetBool(":NAT:AirPort:Enabled", airportEnabledWas)) }
        // 上来就没被禁睡的机器不重复写 0（保持无副作用）。
        if !sleepDisabledWas { parts.append("/usr/bin/pmset -a disablesleep 0") }
        parts.append("/bin/launchctl kickstart -k \(sharingService) 2>/dev/null||/bin/launchctl bootstrap system \(sharingPlist) 2>/dev/null;/bin/sleep 2;/bin/launchctl kickstart -k \(sharingService) 2>/dev/null||true;exit 0")
        return parts.joined(separator: ";")
    }

    static func restoreScript(for state: PnpState) -> String {
        restoreScript(natEnabledWas: state.natEnabledWas, airportEnabledWas: state.airportEnabledWas,
                      airportConfigured: state.airportConfigured, sleepDisabledWas: state.sleepDisabledWas)
    }

    private static func runCommand(_ path: String, _ arguments: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return "" }
        task.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

@MainActor protocol PlugAndPlayHost: AnyObject {
    var plugAndPlayEnabled: Bool { get }
    var plugAndPlayActive: Bool { get set }
    var plugAndPlayBusy: Bool { get set }
    var plugAndPlayStatus: String { get set }
    var savedWifiPasswords: [String: String] { get }
    func pnpRefreshLanInfo()
}

@MainActor final class PlugAndPlayController {
    private weak var host: PlugAndPlayHost?
    private var lastHasPhone = false
    private var revertGraceTimer: Timer?
    private var state: PnpState?
    var stateURL: URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacPlay")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("pnp-state.json")
    }

    init(host: PlugAndPlayHost) { self.host = host }

    // refreshUSB 每 3 秒驱动一次：仅在插入状态翻转时动作，拔出走 6 秒宽限
    // （与引擎的 USB 重枚举宽限一致，避免切蜂窝/低电量模式误还原）。
    func usbPresenceChanged(hasPhone: Bool, force: Bool = false) {
        let changed = hasPhone != lastHasPhone
        lastHasPhone = hasPhone
        guard let host else { return }
        if hasPhone {
            if revertGraceTimer != nil {
                revertGraceTimer?.invalidate(); revertGraceTimer = nil
                refreshActiveStatus()
            }
            if PlugAndPlayCore.shouldActivate(enabled: host.plugAndPlayEnabled, busy: host.plugAndPlayBusy, active: host.plugAndPlayActive), changed || force {
                Task { await activate() }
            }
        } else if changed {
            scheduleRevertOnUnplug()
        }
    }

    func enableRequested(hasPhone: Bool) {
        guard let host else { return }
        if PlugAndPlayCore.shouldActivate(enabled: host.plugAndPlayEnabled, busy: host.plugAndPlayBusy, active: host.plugAndPlayActive), hasPhone {
            Task { await activate() }
        } else if !hasPhone {
            host.plugAndPlayStatus = "即插即用：待iPhone插入"
        }
    }

    func disableRequested() {
        revertGraceTimer?.invalidate(); revertGraceTimer = nil
        guard let host else { return }
        guard host.plugAndPlayActive || state != nil || PnpState.load(from: stateURL) != nil else {
            host.plugAndPlayStatus = ""
            return
        }
        Task { [weak self] in
            guard let self else { return }
            // 激活流程还在跑：等它收尾（末尾会写 active）再还原，
            // 否则 revert 撞上 busy 会被静默跳过，留下“开关关了但共享还开着”。
            while let host = self.host, host.plugAndPlayBusy {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            await self.revert()
        }
    }

    // 上次会话崩溃/强退遗留的快照：无论偏好开关如何都还原（disablesleep
    // 残留会让合盖永不睡眠）。延迟片刻让窗口先完成绘制。
    func restoreIfStaleIfNeeded() {
        guard host != nil, state == nil, PnpState.load(from: stateURL) != nil else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, let host = self.host, !self.isActiveOrBusy(host) else { return }
            host.plugAndPlayStatus = "检测到上次未完成的即插即用状态，正在恢复系统设置…"
            await self.revert()
        }
    }

    func revertBeforeQuit(completion: @escaping () -> Void) {
        guard let host, host.plugAndPlayActive else { completion(); return }
        Task { [weak self] in
            await self?.revert()
            completion()
        }
    }

    private func isActiveOrBusy(_ host: PlugAndPlayHost) -> Bool { host.plugAndPlayActive || host.plugAndPlayBusy }

    private func scheduleRevertOnUnplug() {
        guard let host, host.plugAndPlayEnabled, host.plugAndPlayActive else { return }
        host.plugAndPlayStatus = "即插即用：iPhone 已拔出，6 秒后恢复系统设置…"
        revertGraceTimer?.invalidate()
        revertGraceTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let host = self.host, host.plugAndPlayActive else { return }
                await self.revert()
            }
        }
    }

    private func activate() async {
        guard let host, PlugAndPlayCore.shouldActivate(enabled: host.plugAndPlayEnabled, busy: host.plugAndPlayBusy, active: host.plugAndPlayActive) else { return }
        host.plugAndPlayBusy = true
        defer { host.plugAndPlayBusy = false }

        // 先拍快照再动系统：恢复时逐项写回。
        let config = PlugAndPlayCore.natConfigNow()
        var snapshot = PnpState()
        snapshot.natEnabledWas = config.enabled
        snapshot.airportConfigured = config.hasAirport
        snapshot.airportEnabledWas = config.airportEnabled
        snapshot.sleepDisabledWas = PlugAndPlayCore.sleepDisabledNow()
        let iface = CWWiFiClient.shared().interface()
        snapshot.wifiInterface = iface?.interfaceName
        snapshot.wifiSSID = iface?.ssid()
        state = snapshot
        snapshot.save(to: stateURL)

        host.plugAndPlayStatus = "即插即用：正在断开 Wi-Fi…"
        iface?.disassociate()
        host.plugAndPlayStatus = "即插即用：正在开启网络共享（需要管理员授权）…"
        let result = await Self.runAdminFlow(PlugAndPlayCore.enableScript(airportConfigured: config.hasAirport))
        guard result != .canceled else {
            state = nil
            try? FileManager.default.removeItem(at: stateURL)
            host.plugAndPlayStatus = "即插即用：未获管理员授权，已取消并尝试恢复 Wi-Fi。"
            rejoinWiFi(snapshot)
            return
        }
        var bridgeIP: String?
        for _ in 0..<16 {
            if let ip = PlugAndPlayCore.sharedBridgeIPv4() { bridgeIP = ip; break }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        host.plugAndPlayActive = true
        host.pnpRefreshLanInfo()
        let name = PlugAndPlayCore.natConfigNow().networkName
        if bridgeIP != nil {
            host.plugAndPlayStatus = name.isEmpty
                ? "即插即用已开启，合盖不休眠已开启。"
                : "即插即用已开启：热点「\(name)」，合盖不休眠已开启"
        } else {
            host.plugAndPlayStatus = "即插即用：命令已执行，但暂未检测到热点地址，可稍后查看菜单栏或系统设置。"
        }
    }

    private func revert() async {
        guard let host, !host.plugAndPlayBusy else { return }
        guard host.plugAndPlayActive || state != nil else { return }
        let snapshot = state ?? PnpState.load(from: stateURL) ?? PnpState()
        host.plugAndPlayBusy = true
        defer { host.plugAndPlayBusy = false }
        revertGraceTimer?.invalidate(); revertGraceTimer = nil
        host.plugAndPlayStatus = "即插即用：正在恢复（需要管理员授权）…"
        let result = await Self.runAdminFlow(PlugAndPlayCore.restoreScript(for: snapshot))
        state = nil
        host.plugAndPlayActive = false
        host.pnpRefreshLanInfo()
        switch result {
        case .success:
            // 快照只在彻底还原成功后删除；授权被取消/脚本失败时保留，
            // 下次启动仍会尝试自动恢复。
            try? FileManager.default.removeItem(at: stateURL)
            host.plugAndPlayStatus = "即插即用已恢复：互联网共享与合盖不休眠已还原。"
            rejoinWiFi(snapshot)
        case .canceled:
            host.plugAndPlayStatus = "即插即用：已取消恢复授权；请手动关闭互联网共享，并执行 pmset -a disablesleep 0。"
        case .failed:
            host.plugAndPlayStatus = "即插即用：恢复命令执行失败，请检查互联网共享与 pmset disablesleep 状态。"
            rejoinWiFi(snapshot)
        }
    }

    // 互联网共享关闭后 macOS 通常会自动重连原网络；这里用扫描+关联再抢一次，
    // 失败就交给系统自动重连（定位权限缺失时扫描会失败，静默放弃即可）。
    private func rejoinWiFi(_ snapshot: PnpState) {
        guard let interfaceName = snapshot.wifiInterface, let ssid = snapshot.wifiSSID, !ssid.isEmpty,
              let iface = CWWiFiClient.shared().interface(withName: interfaceName),
              iface.ssid() != ssid else { return }
        if let networks = try? iface.scanForNetworks(withName: ssid), let target = networks.first {
            try? iface.associate(to: target, password: host?.savedWifiPasswords[ssid])
        }
    }

    private func refreshActiveStatus() {
        guard let host, host.plugAndPlayActive, !host.plugAndPlayBusy else { return }
        let name = PlugAndPlayCore.natConfigNow().networkName
        host.plugAndPlayStatus = name.isEmpty
            ? "即插即用已开启，合盖不休眠已开启。"
            : "即插即用已开启：热点「\(name)」，合盖不休眠已开启"
    }

    // Fork: privileged execution, keychain-first. Fast path: stored password
    // verifies → sudo -S runs the script silently (no dialog at all). Stored
    // password stale → drop it and re-prompt (up to 3 tries), store on first
    // success. Standard (non-admin) accounts whose password can never verify
    // with sudo fall back to the osascript system prompt, which accepts any
    // admin's credentials.
    @MainActor private static func runAdminFlow(_ script: String) async -> PlugAndPlayAdminResult {
        if let password = AdminAuth.storedPassword() {
            let verified = await Task.detached { AdminAuth.verifyPassword(password) }.value
            if verified {
                let status = await Task.detached { AdminAuth.runSudo(["/bin/sh", "-c", script], password: password) }.value
                return status == 0 ? .success : .failed
            }
            AdminAuth.removePassword()
        }
        for attempt in 0..<3 {
            guard let password = AdminAuth.promptPassword(retry: attempt > 0) else { return .canceled }
            let verified = await Task.detached { AdminAuth.verifyPassword(password) }.value
            guard verified else { continue }
            AdminAuth.storePassword(password)
            let status = await Task.detached { AdminAuth.runSudo(["/bin/sh", "-c", script], password: password) }.value
            return status == 0 ? .success : .failed
        }
        return await Task.detached { Self.runAdminViaOsaScript(script) }.value
    }

    // osascript 提权执行（兜底路径）；在后台线程等待，避免主线程被密码弹窗卡住。
    private nonisolated static func runAdminViaOsaScript(_ script: String) -> PlugAndPlayAdminResult {
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        let errorPipe = Pipe()
        task.standardOutput = Pipe()
        task.standardError = errorPipe
        guard (try? task.run()) != nil else { return .failed }
        task.waitUntilExit()
        if task.terminationStatus == 0 { return .success }
        let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // 用户点掉密码框时 osascript 报 -128（各语言文案都带错误码）。
        return message.contains("-128") ? .canceled : .failed
    }
}
