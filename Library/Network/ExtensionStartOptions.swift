import Foundation

enum ExtensionStartOptions {
    static let snapshotFileName = "start_options.plist"

    static var snapshotURL: URL {
        #if os(macOS)
            if Variant.useSystemExtension {
                return FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(snapshotFileName)
            }
        #endif
        return FilePath.sharedDirectory.appendingPathComponent(snapshotFileName)
    }

    static func encode(_ options: [String: NSObject]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: options, format: .binary, options: 0)
    }

    static func persist(_ options: [String: NSObject]) throws {
        try encode(options).write(to: snapshotURL, options: .atomic)
    }

    static func decode(_ data: Data) throws -> [String: NSObject] {
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let options = plist as? [String: NSObject] else {
            throw NSError(domain: "ExtensionStartOptions", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid start options payload",
            ])
        }
        return options
    }
}
