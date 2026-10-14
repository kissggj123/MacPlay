<p align="center"><img src="assets/icons/mac/macplay.iconset/icon_128x128.png" width="104" alt="MacPlay应用图标"></p>

<h1 align="center">MacPlay</h1>

<p align="center">在Mac上显示和操作iPhone的CarPlay界面，支持USB直连与共用Wi-Fi无线连接。</p>

<p align="center">
  <a href="scripts/package-native.sh"><img src="https://img.shields.io/badge/version-1.2.2-2563eb?style=flat-square" alt="版本1.2.2"></a>
  <a href="#使用条件"><img src="https://img.shields.io/badge/platform-macOS%2014%2B-555555?style=flat-square" alt="运行平台"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--or--later-2563eb?style=flat-square" alt="项目许可"></a>
</p>

<p align="center">
  <a href="https://github.com/Roylyl/MacPlay/releases"><img src="https://img.shields.io/github/downloads/Roylyl/MacPlay/total?style=flat-square&amp;label=downloads&amp;color=2563eb" alt="发行附件累计下载量"></a>
  <a href="https://github.com/Roylyl/MacPlay/stargazers"><img src="https://img.shields.io/github/stars/Roylyl/MacPlay?style=flat-square&amp;label=stars&amp;color=2563eb" alt="GitHub Star数"></a>
  <a href="https://github.com/Roylyl/MacPlay/forks"><img src="https://img.shields.io/github/forks/Roylyl/MacPlay?style=flat-square&amp;label=forks&amp;color=555555" alt="GitHub Fork数"></a>
  <a href="https://github.com/Roylyl/MacPlay/issues"><img src="https://img.shields.io/github/issues/Roylyl/MacPlay?style=flat-square&amp;label=issues&amp;color=555555" alt="开放Issue数"></a>
  <a href="https://github.com/Roylyl/MacPlay/pulls"><img src="https://img.shields.io/github/issues-pr/Roylyl/MacPlay?style=flat-square&amp;label=pull%20requests&amp;color=555555" alt="开放Pull Request数"></a>
  <a href="https://github.com/Roylyl/MacPlay/commits"><img src="https://img.shields.io/github/last-commit/Roylyl/MacPlay?style=flat-square&amp;label=last%20commit&amp;color=555555" alt="最近提交时间"></a>
</p>

<p align="center"><a href="#快速入门">快速入门</a> · <a href="#主要功能">主要功能</a> · <a href="#其他平台">其他平台</a> · <a href="#从源码构建">源码构建</a> · <a href="#来源与许可">来源与许可</a></p>

<p align="center">其他设备：<a href="https://github.com/Roylyl/AndroidPlay">AndroidPlay</a> · <a href="https://github.com/Roylyl/WinPlay">WinPlay</a></p>

## 快速入门

### 使用条件

- macOS 14 及以上，Apple Silicon（M 系列）处理器。**目前仅提供 ARM64 构建，Intel 机型需自行从源码编译。**
- 支持CarPlay的iPhone；有线需要USB数据线，无线需要蓝牙与允许设备互访的共用Wi-Fi。
- 安装包内置Node.js与GStreamer运行组件，无需额外安装开发工具。

### 安装

前往[GitHubReleases](https://github.com/Roylyl/MacPlay/releases)，根据“苹果菜单→关于本机”中的芯片信息选择安装包：

| Mac类型 | 安装包 |
| --- | --- |
| AppleM系列 | `MacPlay-1.2.2-arm64.dmg` |
| Intel | `MacPlay-1.2.2-x86_64.dmg` |

打开DMG，将MacPlay拖入“应用程序”后启动。若macOS拦截，在“系统设置→隐私与安全性”中允许打开。当前包采用本地签名，未经过Apple公证。

首次启动自动准备内置认证文件，默认1280×720、60fps，并优先使用内建显示器。更新安装保留已有设置。完整步骤见[发行版使用教程](docs/发行版使用教程.md)。在“连接→应用”选择跟随系统、简体中文、繁體中文或English，默认跟随Mac系统语言；CarPlay内部语言仍跟随iPhone。

### 有线CarPlay

1. 用USB数据线连接iPhone与Mac，解锁iPhone并完成“信任此电脑”。
2. 在“连接”页选择“有线CarPlay”，多台设备同时接入时选择目标iPhone。
3. 点击“启动接收”，在iPhone上确认CarPlay提示。

有线无需填写Wi-Fi信息。在“连接→应用”开启“USB接入时自动启动CarPlay”，MacPlay运行期间接入iPhone就会启动有线接收。已指定设备时只响应该设备；首次使用仍需解锁并确认信任。修改设置后，点击“应用并重新连接”。

### 无线CarPlay

1. Mac和iPhone加入同一个允许设备互访的Wi-Fi，选择“无线CarPlay”。
2. 点击“读取当前网络”或手动填写SSID；填写Wi-Fi共享密码，也可点击“读取已保存密码”并按钥匙串提示授权。
3. 打开蓝牙设置，在iPhone上选择Mac的系统名称，在两端确认配对码。
4. 在MacPlay选择目标iPhone，点击“启动接收”，在iPhone上允许CarPlay连接。

MacPlay通过蓝牙引导，再通过共用Wi-Fi传输音视频，不创建名为MacPlay的热点。读取Wi-Fi名称需要定位权限，读取密码可能要求钥匙串授权。企业802.1X和网页登录凭据不适用于此握手，建议使用个人Wi-Fi或有线连接。

## 主要功能

- 原生设置界面：SwiftUI主窗口提供连接、显示、音频和关于四页，AppKit独立窗口显示CarPlay。
- 多屏与窗口适配：选择内建或外接显示器，默认适配窗口并可等比例调整大小，也可开启严格物理像素显示。
- 点击与触控板：支持点击、拖动和双指滚动，滚动转换为CarPlay触摸滑动。
- 音频与设备：实时调整媒体和通话音量，分别选择输入/输出设备，默认跟随系统。
- 系统媒体控件：向macOS播放面板同步歌曲、歌手、专辑、封面、进度和播放状态，支持播放控制及播放器允许的进度跳转。
- 设备记忆与断开复位：记住上次连接的iPhone；断开后关闭画面并返回连接主页；可选择在无线连接被动断开后自动重连。
- 语言与后台运行：支持跟随Mac系统、简体中文、繁體中文和English；可选USB接入自动启动及菜单栏常驻。
- 统一窗口入口：主窗口与CarPlay画面共用MacPlay的Dock入口；关闭CarPlay画面先确认断开，点击CarPlay中的MacPlay图标可打开主窗口。

- 关于与更新：查看版本、检查GitHub正式发行版，按芯片选择安装包，支持自动更新提醒和TXT日志导出。

### 无线自动重连

在“连接→共用Wi-Fi”开启“无线连接被动断开时自动重连”。默认关闭，只回连已成功连接后被动断开的iPhone，使用上次应用的配置。首次等待5秒，失败后按10、20、30、60秒延长间隔；主动停止、确认断开、退出或关闭开关会取消重连。首次连接失败不进入自动重连。

切换Wi-Fi后需要读取或填写新网络密码；同一网络读取密码失败时保留已有输入。最终60fps尝试等待视频超过45秒会结束，避免一直停留在等待界面。

## 其他平台

使用Mac时选择MacPlay；如果还想在Windows电脑或Android设备上使用CarPlay，可以按设备选择下面的项目。

| 项目 | 平台 | 适合的使用场景 |
| --- | --- | --- |
| [WinPlay](https://github.com/Roylyl/WinPlay) | Windows10/11x64 | 适合Windows电脑。支持本机移动热点和现有局域网两种无线模式，提供独立画面窗口与系统媒体控件。 |
| [AndroidPlay](https://github.com/Roylyl/AndroidPlay) | Android9及以上 | 适合Android手机、平板和车机。通过系统热点与蓝牙连接iPhone，提供全屏画面、音频和通知栏媒体控制。 |

## 显示与声音

“显示”页提供屏幕原生像素（避开刘海）、1280×720、1920×1080、2560×1440和自定义宽高。默认720p关闭“严格按屏幕物理像素显示”，窗口按画面比例适配所选屏幕，初始尺寸不超过可用区域的80%，可以拖动边框等比例调整大小；请求给iPhone的分辨率不变。开启严格像素显示后，窗口按物理像素固定大小，仍可移动。原生像素模式始终全屏并避开刘海。更改显示选项后点击“应用并重新连接”。

收到首帧解码画面后才打开CarPlay窗口。将鼠标移到画面顶部并停留片刻，可显示悬浮标题栏，用于拖动、最小化或关闭窗口；关闭时会询问是否断开连接。

帧率可选30/60/90/120fps，默认60fps。120的视频启动协商失败后依次尝试90和60，90失败后尝试60；回退只影响本次连接。高帧率是请求上限，实际输出由iPhone、网络和解码能力决定。

CarPlay自身的“设置→显示屏→智能缩放显示”可能改变图标、文字和渲染尺寸。希望按所选像素显示时可关闭该开关，再应用并重新连接；MacPlay不提供缩放倍率，也不远程控制此设置。

媒体/通话音量实时生效，输入/输出设备更换后需应用并重新连接。播放歌曲后可在Mac控制中心查看音乐信息；播放器提供有效时长并允许跳转时，可以拖动系统进度条。封面按歌曲身份关联，标题变化不作为切歌，迟到的旧封面不会覆盖新曲目。本版不提供独立歌词同步。

## 关于、更新与日志

在侧栏最后的“关于”页查看版本号、构建号和运行架构。点击“检查更新”读取GitHub正式发行版，按版本号比较，并为当前Mac选择M系列或Intel安装包；通过Rosetta运行时仍优先选择M系列版。没有对应安装包时可打开发行说明。

“自动检查更新”默认开启，每次启动检查一次，持续运行时每两小时静默检查。后台检查结果显示在“关于→软件更新”，不弹窗；启动发现新版时提示，同一版本确认后不重复提醒。检查失败会显示错误，手动检查可随时执行。点击“下载更新”后通过浏览器下载，退出旧版再替换应用，不自动安装。

在“关于→日志”点击“导出日志”，选择位置保存TXT。导出当前连接日志，过滤网络密码及常见设备标识，不包含设置文件或认证文件。发送给他人前仍可自行查看导出内容。

## 常见问题

| 现象 | 处理方法 |
| --- | --- |
| USB未识别 | 更换数据线，解锁iPhone并确认信任，查看连接阶段 |
| 无线一直等待连接 | 检查配对、目标设备、SSID和密码，确认Wi-Fi允许设备互访 |
| 读取不到Wi-Fi名称或密码 | 查看按钮下方的灰色结果提示；授权定位/钥匙串访问，或手动填写。密码读取失败保留实际系统状态码 |
| 自定义分辨率无法启动 | 关闭严格像素显示以适配窗口，或降低分辨率、选择原生像素模式 |
| 系统进度条不能拖动 | 播放器需提供有效时长和跳转权限；直播通常不支持 |
| 选择另一台iPhone后没有连接 | 确认目标已接入或配对，再应用并重新连接 |

“自动（上次连接的iPhone）”不会在目标缺席时擅自改连其他设备。点击CarPlay窗口的红色关闭按钮，会先询问是否断开；取消后继续保持连接。CarPlay中的MacPlay入口用于打开设置主窗口。

开启“连接→应用→允许后台运行”后，关闭主窗口会保持接收，菜单栏显示简约图标，可打开主窗口、显示画面、启动/停止接收或退出；Dock中的MacPlay也提供两个窗口的入口。未开启后台运行时，关闭主窗口会退出应用。后台运行不等于开机启动。更新前退出旧版，再替换应用。

## 认证与数据

1.2.2内置实验性认证材料，首次启动不覆盖本机已有身份。也可在“关于→认证文件→导入认证文件”选择匹配且获准使用的`identity.pk8`与`certificate.p7b`；普通Apple开发者签名证书不能替代配件认证。材料来源见[认证来源](assets/authentication/SOURCE.txt)。公开下载不等于取得再分发授权，公开分发前应确认材料权利。

设置、Wi-Fi密码、设备记录与配对身份保存在本机应用支持目录，不上传到服务器。定位权限用于读取Wi-Fi信息，蓝牙/本地网络用于连接，麦克风用于通话和语音。分享诊断日志前应遮盖手机名称、地址和网络信息。

## 从源码构建

需要macOS、Xcode命令行工具、Node.js、pnpm、Rust、pkg-config及GStreamer开发SDK。将SDK的`lib/pkgconfig`加入`PKG_CONFIG_PATH`，在仓库根目录执行：

~~~sh
pnpm install
pnpm run build
~~~

默认按本机架构构建；指定架构时选择一条命令：

~~~sh
# AppleM系列
pnpm run build -- --arch=arm64
# Intel
pnpm run build -- --arch=x64
~~~

生成`dist/MacPlay.app`和`dist/MacPlay-1.2.2-<arch>.dmg`，架构为`arm64`或`x86_64`。脚本处理SwiftUI应用、蓝牙桥接、Rust后端、音视频模块和Node.js服务，并进行本地签名与DMG打包。

## 更新日志

1.2.2完善无线认证后的服务发现与有限重试，首帧解码后再显示窗口，新增可选窗口适配，增强音频统计及麦克风会话隔离。包含[Artist-x的PR#6](https://github.com/Roylyl/MacPlay/pull/6)提供的悬浮标题栏和后台窗口恢复改进。完整变更见[CHANGELOG](CHANGELOG.md)。Intel支持由[drewpall的PR#1](https://github.com/Roylyl/MacPlay/pull/1)提供基础实现。

## 来源与许可

网络发现实现参考同系列[WinPlay](https://github.com/Roylyl/WinPlay)，保留来源说明。

MacPlay基于[LIVI](https://github.com/f-io/LIVI)，参考[DiPlay](https://github.com/shihabal3amri/DiPlay)，保留LasseHeitgres及贡献者的版权和许可声明，见[NOTICE](NOTICE)。项目沿用GPL-3.0-or-later，见[LICENSE](LICENSE)；运行库许可位于`assets/licenses`与`assets/gstreamer/LICENSES`。

第三方组件、认证文件和商标分别适用各自权利条件。MacPlay是独立衍生项目，不代表Apple或上游作者，不声称获得MFi认证。分发修改版时应保留声明并提供适用许可证要求的对应源码与构建资料。
