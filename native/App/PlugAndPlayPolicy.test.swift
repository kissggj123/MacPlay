import Foundation

// PlugAndPlay.swift 的密码弹窗使用主工程的 L() 本地化函数；单测环境无
// Localization.swift，用恒等 stub 让文件可独立编译。
func L(_ text: String) -> String { text }

@main struct PlugAndPlayPolicyTests {
    static func main() {
        // nat.plist 解析：主开关 + AirPort 热点段（真实机器上的字段形态）。
        let sample = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>NAT</key><dict>
        <key>Enabled</key><integer>1</integer>
        <key>AirPort</key><dict><key>Enabled</key><integer>0</integer><key>NetworkName</key><string>paocailaosiji</string></dict>
        <key>SharingDevices</key><array><string>en5</string><string>en0</string></array>
        </dict></dict></plist>
        """
        let config=PlugAndPlayCore.natConfig(from:Data(sample.utf8))
        precondition(config != nil)
        precondition(config!.enabled,"integer 1 应按真值读取")
        precondition(config!.hasAirport)
        precondition(!config!.airportEnabled)
        precondition(config!.networkName=="paocailaosiji")
        precondition(PlugAndPlayCore.natConfig(from:Data("{}".utf8))==nil,"缺 NAT 段应返回 nil")

        // 触发门：开关开、不在忙、未激活才允许激活。
        precondition(PlugAndPlayCore.shouldActivate(enabled:true,busy:false,active:false))
        precondition(!PlugAndPlayCore.shouldActivate(enabled:false,busy:false,active:false))
        precondition(!PlugAndPlayCore.shouldActivate(enabled:true,busy:true,active:false))
        precondition(!PlugAndPlayCore.shouldActivate(enabled:true,busy:false,active:true))

        // 启用脚本：写主开关、写热点段、禁睡、kick 共享服务并验证 bridge100。
        let enable=PlugAndPlayCore.enableScript(airportConfigured:true)
        precondition(enable.contains("Set :NAT:Enabled true"))
        precondition(enable.contains("Set :NAT:AirPort:Enabled true"))
        precondition(enable.contains("pmset -a disablesleep 1"))
        precondition(enable.contains("kickstart -k system/com.apple.NetworkSharing"))
        precondition(enable.contains("ifconfig bridge100"))
        let enableNoAirport=PlugAndPlayCore.enableScript(airportConfigured:false)
        precondition(!enableNoAirport.contains("AirPort"),"未配置热点段时不得改写 AirPort 键")

        // 还原脚本：逐项写回快照，而不是一律关闭。
        let restoreOn=PlugAndPlayCore.restoreScript(natEnabledWas:true,airportEnabledWas:false,airportConfigured:true,sleepDisabledWas:false)
        precondition(restoreOn.contains("Set :NAT:Enabled true"),"用户本来就开着共享时应还原为开")
        precondition(restoreOn.contains("Set :NAT:AirPort:Enabled false"))
        precondition(restoreOn.contains("pmset -a disablesleep 0"))
        let restoreOff=PlugAndPlayCore.restoreScript(natEnabledWas:false,airportEnabledWas:false,airportConfigured:false,sleepDisabledWas:true)
        precondition(restoreOff.contains("Set :NAT:Enabled false"))
        precondition(!restoreOff.contains("AirPort"))
        precondition(!restoreOff.contains("disablesleep"),"快照本来就禁睡时不得改写 pmset")

        // 快照编解码走 JSON，崩溃恢复依赖它。
        var state=PnpState()
        state.natEnabledWas=true;state.airportConfigured=true;state.wifiSSID="Home"
        let round=PnpState.load(from:{let url=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("pnp-test-\(UUID().uuidString).json");state.save(to:url);return url}())
        precondition(round?.natEnabledWas==true && round?.airportConfigured==true && round?.wifiSSID=="Home")

        print("PlugAndPlay: nat parse, activation gate, enable/restore scripts, snapshot round-trip passed")
    }
}
