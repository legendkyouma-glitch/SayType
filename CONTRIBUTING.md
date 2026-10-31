# 参与开发

SayType 使用 Swift、SwiftUI、AppKit、Speech 和 AVFoundation。可下载的本机模型通过原生 MLX Swift 运行，不依赖 Python。依赖版本由 `Package.swift` 和 `Package.resolved` 固定，许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。产品功能与使用方式见 [README](README.md)。

## 提交改动

请从自己的分支或 Fork 发起 Pull Request（PR），说明解决了什么问题、如何验证。涉及界面的改动请附截图；较大的功能建议先开 Issue 讨论。

`main` 的改动通过 PR 合并，由维护者 `@legendkyouma-glitch` review。PR 更新代码后需要重新批准，合并前请解决 review 中的讨论。提交前运行与改动相关的检查，并在 PR 中写明结果；纯文档改动不需要编译应用。

## 构建与签名

普通用户可直接使用 [已打包的 App](https://github.com/legendkyouma-glitch/SayType/releases)，下面的步骤仅供源码开发使用。

Apple Silicon Mac、macOS 26+，以及包含 Swift 6.4 或更新版本的 Xcode。还需在 Xcode → Settings → Components 安装 Metal Toolchain；这些只是开发环境要求，用户运行打包后的 App 不需要安装它们。

```bash
git clone https://github.com/legendkyouma-glitch/SayType.git
cd SayType
./scripts/build.sh
open outputs/SayType.app
```

默认使用 ad-hoc 临时签名。重建后可能需要重新授权辅助功能；脚本不会自动选择本机的个人证书。想用自己的固定身份签名，可以显式指定证书名称或 SHA-1：

```bash
SIGN_IDENTITY='你的代码签名证书名称或 SHA-1' ./scripts/build.sh
```

构建同时生成 `outputs/SayType.zip`，并在临时目录解压检查签名。同步盘可能给 `.app` 重新附加 Finder 元数据，需要传递构建结果时使用这个 ZIP；`package.sh` 会直接复用它。

构建脚本不会完成 Apple 公证，也不会修改系统权限。对外发布时使用下方的正式签名与公证流程。

## 离线回归测试

```bash
./scripts/test.sh
```

测试直接编译相关生产代码，隔离系统设置、钥匙串和用户数据，验证错误响应脱敏、截断结果处理、真实模型归属、迟到结果的历史更新、模型文件校验及配置文件路径。它不调用云端模型、不使用麦克风，也不代替桌面交互或真实模型推理测试。

改动录音、快捷键或插入逻辑后，请手动检查：

- 文本编辑中按住/松开、锁定、切换录音和 Esc 取消。
- 逐段/一次填入、焦点切换，以及目标应用中的手动粘贴回退。
- 没有 Key、本机模式、云端失败和迟到结果替换。
- 关闭历史保存、清空历史、重新启动和权限恢复。
- 模型下载、取消、失败重试、删除，以及口述期间切换模型后下一句才生效。
- 云端失败仍显示本机模型；迟到结果只有真正替换成功后才显示“已用 XX 模型优化”。

不要使用私人文本做日志示例，也不要把个人 Key 或签名证书提交到仓库。

## 音频诊断

已有音频文件时，可以跳过麦克风和辅助功能，诊断识别链路：

```bash
outputs/SayType.app/Contents/MacOS/SayType --selftest /absolute/path/sample.wav
```

这个命令使用本机识别和规则整理，缺少语言资源时可能下载。它会打印完整识别结果及文件路径，也可能创建运行日志。

可选云端诊断：

```bash
outputs/SayType.app/Contents/MacOS/SayType --selftest /absolute/path/sample.wav --cloud
outputs/SayType.app/Contents/MacOS/SayType --selftest --text '嗯，明天下午三点开会'
```

`--cloud` 会向服务商发送音频；`--text` 即使没有 `--cloud` 也会直接请求云端整理，并可用 `SAYTYPE_LLM` 临时指定整理模型。两者都读取应用的 Key 配置。

**自检目前成功和失败都返回退出码 0**，输出是面向人的文本，没有稳定 JSON 协议。请检查实际输出。没有 `--help`、`doctor` 或 `transcribe` 命令；未知参数会进入默认 GUI 流程。

## 代码结构

| 文件 | 负责什么 |
| --- | --- |
| `app/Sources/AppDelegate.swift` | 录音会话、分段流水线、回退、菜单与窗口 |
| `app/Sources/Audio.swift` | 音频采集、本机识别和语音分段 |
| `app/Sources/Cloud.swift` | 云端请求、规则整理和云端失败回退 |
| `app/Sources/LocalModels.swift`、`LocalModelStorage.swift` | 模型目录、下载校验、生命周期与本机 MLX 推理 |
| `app/Sources/ModelPresentation.swift`、`TranscriptionResults.swift` | 实际模型名称、结果归属与超时等待 |
| `app/Sources/Inserter.swift` | 辅助功能写入、粘贴和迟到结果替换 |
| `app/Sources/Hotkey.swift` | 全局快捷键、锁定、取消 |
| `app/Sources/Settings.swift` | 配置与 Key 存储 |
| `app/Sources/History.swift` | 本机历史与音频自检 |
| `app/Sources/Onboarding.swift`、`SettingsView.swift`、`LocalModelSettingsView.swift`、`HUD.swift` | 引导、设置、模型下载、历史和状态条 |
| `app/Sources/main.swift` | 启动入口、数据路径和日志 |

## 打包

```bash
./scripts/package.sh
```

它会重新构建，输出 `outputs/releases/SayType-<版本>-macOS-arm64.zip` 和 `SHA256SUMS`。压缩包只包含 App，不包含本地配置、用户历史或日志。所有生成文件都被 Git 忽略。

## 正式签名与 Apple 公证

发布者需要有效的 Developer ID Application 证书及其私钥。先把公证凭证存入本机钥匙串；交互提示中输入 Apple 提供的 App 专用密码，不要把密码写进命令、脚本或仓库：

```bash
xcrun notarytool store-credentials saytype-notary \
  --apple-id '你的 Apple 账号' --team-id '你的 Team ID'
```

正式构建会启用 Hardened Runtime、可信时间戳和麦克风权限。证书由发布者显式指定，普通开发构建仍使用临时签名。

```bash
RELEASE_SIGNING=1 SIGN_IDENTITY='你的 Developer ID Application 证书名称或 SHA-1' \
  ./scripts/package.sh

# 解压到本机缓存目录，避免同步文件夹重新附加 Finder 元数据。
mkdir -p "$HOME/Library/Caches/SayType"
notary_stage="$(mktemp -d "$HOME/Library/Caches/SayType/notarize.XXXXXX")"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' app/Info.plist)"
archive="SayType-$version-macOS-arm64.zip"
ditto -x -k "outputs/releases/$archive" "$notary_stage"
codesign --verify --strict --verbose=2 "$notary_stage/SayType.app"

xcrun notarytool submit "outputs/releases/$archive" \
  --keychain-profile saytype-notary --wait
```

必须等返回 `Accepted`，并用返回的提交 ID 下载、查看公证日志。如果等待超时，使用同一 ID 查询状态，不需要重新提交。通过后，将公证票据附到同一个 App，再重新压缩：

```bash
xcrun notarytool log '提交 ID' --keychain-profile saytype-notary \
  outputs/notarization-log.json
xcrun stapler staple "$notary_stage/SayType.app"
xcrun stapler validate "$notary_stage/SayType.app"
codesign --verify --strict --verbose=2 "$notary_stage/SayType.app"
spctl --assess --type execute --verbose=4 "$notary_stage/SayType.app"

ditto -c -k --keepParent --norsrc --noextattr "$notary_stage/SayType.app" \
  "outputs/releases/$archive"
(cd outputs/releases && shasum -a 256 "$archive" > SHA256SUMS)
```

此时不要再次运行 `build.sh` 或 `package.sh`，它们会重新构建并替换已公证的 App。发布前再解压最终 ZIP，对解压出来的 App 重复签名、公证票据和 Gatekeeper 检查，确认结果为 `Notarized Developer ID`。

参考：[Apple 公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。

## 后续改进

当前比较需要补足的是跨应用插入测试、云端迟到替换的可靠性、长段文字整理和诊断退出码。欢迎以可复现问题为起点提交 Issue 或 PR。
