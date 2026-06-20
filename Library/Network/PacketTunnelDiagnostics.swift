import Foundation
#if os(iOS)
  import Darwin
#endif

public enum PacketTunnelDiagnostics {
  private static let fileName = "packet-tunnel-diagnostics.log"
  private static let incidentFileName = "packet-tunnel-incidents.log"
  private static let maxBytes = 2 * 1024 * 1024
  private static let maxIncidentBytes = 512 * 1024
  private static let queue = DispatchQueue(label: "PacketTunnelDiagnostics")

  public static var fileURL: URL {
    FilePath.cacheDirectory.appendingPathComponent(fileName)
  }

  public static var incidentFileURL: URL {
    FilePath.cacheDirectory.appendingPathComponent(incidentFileName)
  }

  public static func append(_ message: String) {
    append(message, to: fileURL, maxBytes: maxBytes)
  }

  public static func appendIncident(_ message: String) {
    append(message, to: incidentFileURL, maxBytes: maxIncidentBytes)
  }

  private static func append(_ message: String, to url: URL, maxBytes: Int) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(timestamp) \(sanitize(message))\n"
    guard let data = line.data(using: .utf8) else {
      return
    }
    queue.sync {
      do {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path) {
          let handle = try FileHandle(forWritingTo: url)
          defer {
            try? handle.close()
          }
          try handle.seekToEnd()
          try handle.write(contentsOf: data)
        } else {
          try data.write(to: url, options: .atomic)
        }
        trimIfNeeded(url, maxBytes: maxBytes)
      } catch {
        // Diagnostics must never interfere with tunnel startup or shutdown.
      }
    }
  }

  public static func readText() -> String {
    queue.sync {
      let diagnostics = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
      let incidents = (try? String(contentsOf: incidentFileURL, encoding: .utf8)) ?? ""
      if incidents.isEmpty {
        return diagnostics
      }
      if diagnostics.isEmpty {
        return "=== packet-tunnel incidents ===\n\(incidents)"
      }
      return "\(diagnostics)\n=== packet-tunnel incidents ===\n\(incidents)"
    }
  }

  public static func clear() {
    queue.sync {
      try? FileManager.default.removeItem(at: fileURL)
      try? FileManager.default.removeItem(at: incidentFileURL)
    }
  }

  public static func residentMemoryBytes() -> UInt64? {
    #if os(iOS)
      var info = task_vm_info_data_t()
      var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
      let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
          task_info(
            mach_task_self_,
            task_flavor_t(TASK_VM_INFO),
            reboundPointer,
            &count
          )
        }
      }
      guard result == KERN_SUCCESS else {
        return nil
      }
      return UInt64(info.phys_footprint)
    #else
      return nil
    #endif
  }

  public static func residentMemoryDescription() -> String {
    guard let bytes = residentMemoryBytes() else {
      return "unknown"
    }
    return formatBytes(bytes)
  }

  public static func formatBytes(_ bytes: UInt64) -> String {
    let mib = Double(bytes) / 1_048_576
    return String(format: "%.1fMiB", mib)
  }

  private static func trimIfNeeded(_ url: URL, maxBytes: Int) {
    guard
      let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
      size.intValue > maxBytes * 2,
      let data = try? Data(contentsOf: url)
    else {
      return
    }
    let suffix = data.suffix(maxBytes)
    try? Data(suffix).write(to: url, options: .atomic)
  }

  private static func sanitize(_ message: String) -> String {
    var output = message
    output = output.replacingOccurrences(
      of: #"https?://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+"#,
      with: "https://[redacted]",
      options: .regularExpression
    )
    output = output.replacingOccurrences(
      of: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#,
      with: "[ip]",
      options: .regularExpression
    )
    output = output.replacingOccurrences(
      of: #"\b[0-9a-fA-F]{0,4}(?::[0-9a-fA-F]{0,4}){2,}\b"#,
      with: "[ipv6]",
      options: .regularExpression
    )
    return output
  }
}
