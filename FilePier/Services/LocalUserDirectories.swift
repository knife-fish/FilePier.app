import Foundation

enum LocalUserDirectories {
    static func home(fileManager: FileManager = .default) -> URL {
        if let passwordEntry = getpwuid(getuid()), let homePath = passwordEntry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: homePath), isDirectory: true).standardizedFileURL
        }

        if let homeDirectory = fileManager.homeDirectory(forUser: NSUserName())?.standardizedFileURL {
            return homeDirectory
        }

        return fileManager.homeDirectoryForCurrentUser.standardizedFileURL
    }

    static func desktop(fileManager: FileManager = .default) -> URL {
        home(fileManager: fileManager).appendingPathComponent("Desktop", isDirectory: true).standardizedFileURL
    }

    static func documents(fileManager: FileManager = .default) -> URL {
        home(fileManager: fileManager).appendingPathComponent("Documents", isDirectory: true).standardizedFileURL
    }

    static func downloads(fileManager: FileManager = .default) -> URL {
        home(fileManager: fileManager).appendingPathComponent("Downloads", isDirectory: true).standardizedFileURL
    }
}
