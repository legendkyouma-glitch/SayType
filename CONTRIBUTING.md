# 参与开发

SayType 使用 Swift、SwiftUI、AppKit、Speech 和 AVFoundation，没有第三方运行时依赖。产品功能与使用方式见 [README](README.md)。

## 构建与签名

普通用户可直接使用 [已打包的 App](https://github.com/legendkyouma-glitch/SayType/releases)，下面的步骤仅供源码开发使用。

Apple Silicon Mac、macOS 26+、Xcode 26+：

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

构建脚本不会完成 Apple 公证，也不会修改系统权限。

## 离线回归测试

```bash
./scripts/test.sh
```

测试直接编译相关生产代码，隔离系统设置、钥匙串和用户数据，验证错误响应脱敏、截断结果处理、历史清理及配置文件路径。它不调用云端模型、不使用麦克风，也不代替桌面交互测试。

改动录音、快捷键或插入逻辑后，请手动检查：

- 文本编辑中按住/松开、锁定、切换录音和 Esc 取消。
- 逐段/一次填入、焦点切换，以及目标应用中的手动粘贴回退。
- 没有 Key、本机模式、云端失败和迟到结果替换。
- 关闭历史保存、清空历史、重新启动和权限恢复。

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
| `app/Sources/Inserter.swift` | 辅助功能写入、粘贴和迟到结果替换 |
| `app/Sources/Hotkey.swift` | 全局快捷键、锁定、取消 |
| `app/Sources/Settings.swift` | 配置与 Key 存储 |
| `app/Sources/History.swift` | 本机历史与音频自检 |
| `app/Sources/Onboarding.swift`、`SettingsView.swift`、`HUD.swift` | 引导、设置、历史和状态条 |
| `app/Sources/main.swift` | 启动入口、数据路径和日志 |

## 打包

```bash
./scripts/package.sh
```

它会重新构建，输出 `outputs/releases/SayType-<版本>-macOS-arm64.zip` 和 `SHA256SUMS`。压缩包只包含 App，不包含本地配置、用户历史或日志。所有生成文件都被 Git 忽略。

## 后续改进

当前比较需要补足的是跨应用插入测试、云端迟到替换的可靠性、长段文字整理、诊断退出码以及发布签名和公证。欢迎以可复现问题为起点提交 Issue 或 PR。
