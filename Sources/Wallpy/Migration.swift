import Foundation

/// The app used to be called MyWallpaper. Carry its library and settings over once.
enum Migration {
    static func fromMyWallpaper() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldFolder = support.appendingPathComponent("MyWallpaper", isDirectory: true)
        let newFolder = support.appendingPathComponent("Wallpy", isDirectory: true)
        if fm.fileExists(atPath: oldFolder.path), !fm.fileExists(atPath: newFolder.path) {
            try? fm.moveItem(at: oldFolder, to: newFolder)
        }

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromMyWallpaper") else { return }
        if let old = defaults.persistentDomain(forName: "com.egluu.mywallpaper") {
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: "migratedFromMyWallpaper")
    }
}
