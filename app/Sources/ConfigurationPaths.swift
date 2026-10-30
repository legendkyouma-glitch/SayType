import Foundation

enum ConfigurationPaths {
    /// 只有明确的源码构建目录才读取仓库配置，普通安装位置只读取应用数据目录。
    static func candidates(bundleURL: URL, supportURL: URL, fileManager: FileManager = .default) -> [URL] {
        let installedConfig = supportURL.appendingPathComponent("local.config.json")
        let bundle = bundleURL.standardizedFileURL
        let parent = bundle.deletingLastPathComponent()
        guard bundle.pathExtension == "app", ["outputs", "build"].contains(parent.lastPathComponent) else {
            return [installedConfig]
        }

        let root = parent.deletingLastPathComponent()
        let markers = ["app/Info.plist", "scripts/build.sh"]
        guard markers.allSatisfy({ marker in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: root.appendingPathComponent(marker).path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }) else { return [installedConfig] }

        return [root.appendingPathComponent("local.config.json"), installedConfig]
    }
}
