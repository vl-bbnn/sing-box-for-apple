import Foundation
#if os(iOS)
  import Darwin
#endif

public enum PacketTunnelDiagnostics {
  private static let fileName = "packet-tunnel-diagnostics.log"
  private static let incidentFileName = "packet-tunnel-incidents.log"
  private static let startupMilestoneFileName = "wlt-startup-milestones.log"
  private static let maxBytes = 2 * 1024 * 1024
  private static let maxIncidentBytes = 512 * 1024
  private static let queue = DispatchQueue(label: "PacketTunnelDiagnostics")

  public static var fileURL: URL {
    FilePath.cacheDirectory.appendingPathComponent(fileName)
  }

  public static var incidentFileURL: URL {
    FilePath.cacheDirectory.appendingPathComponent(incidentFileName)
  }

  public static var startupMilestoneFileURL: URL {
    FilePath.cacheDirectory.appendingPathComponent(startupMilestoneFileName)
  }

  private static let allowedStartupMilestones: Set<String> = [
    "profile_loaded",
    "start_options_ready",
    "extension_start_requested",
    "extension_started",
    "start_options_received",
    "libbox_ready",
    "wlt_snapshot_file_present",
    "wlt_snapshot_file_missing",
    "core_starting",
    "core_started",
    "wlt_service_starting",
    "carrier_config_loading",
    "carrier_config_ready",
    "carrier_snapshot_current",
    "carrier_snapshot_previous",
    "carrier_snapshot_inline",
    "carrier_connect_started",
    "carrier_connect_pending",
    "carrier_reauthorization_required",
    "carrier_provider_recovery",
    "carrier_recovery_succeeded",
    "carrier_recovery_failed_timeout",
    "carrier_recovery_failed_challenge",
    "carrier_recovery_failed_reauthorization",
    "carrier_recovery_reauth_messages_identity",
    "carrier_recovery_reauth_anonymous_identity",
    "carrier_recovery_anonymous_challenge_setup",
    "carrier_recovery_challenge_stage_content",
    "carrier_recovery_challenge_stage_input",
    "carrier_recovery_challenge_stage_frames",
    "carrier_recovery_challenge_stage_candidate",
    "carrier_recovery_challenge_stage_other",
    "carrier_recovery_anonymous_challenge_rejected",
    "carrier_recovery_checkbox_retry_required",
    "carrier_recovery_checkbox_rejected",
    "carrier_recovery_slider_rejected",
    "carrier_recovery_challenge_check_rejected",
    "carrier_recovery_anonymous_challenge_rate_limited",
    "carrier_recovery_anonymous_challenge_interaction",
    "carrier_recovery_anonymous_challenge_other",
    "carrier_recovery_anonymous_authentication_required",
    "carrier_recovery_anonymous_access_denied",
    "carrier_recovery_anonymous_identity_rejected",
    "carrier_recovery_anonymous_invalid_response",
    "carrier_recovery_anonymous_other",
    "carrier_recovery_reauth_renewed_join",
    "carrier_recovery_reauth_unknown",
    "carrier_recovery_failed_other",
    "carrier_previous_unavailable",
    "carrier_previous_started",
    "carrier_previous_succeeded",
    "carrier_previous_failed",
    "carrier_inline_started",
    "carrier_inline_succeeded",
    "carrier_inline_failed",
    "carrier_start_failed_auth_snapshot",
    "carrier_start_failed_bootstrap",
    "carrier_start_failed_connect",
    "snapshot_checked",
    "provider_refresh_started",
    "provider_refresh_ready_cached",
    "provider_refresh_ready_not_needed",
    "provider_ready",
    "turn_ready_cached",
    "turn_ready_refreshed",
    "peer_ready",
    "carrier_ready",
    "sing_box_ready",
    "first_packet",
    "traffic_ready",
    "direct_fallback",
  ]

  #if os(iOS) && SFI_DEV
    private static let stopStages = Set(WLTStopStage.allCases.map(\.rawValue))
    private static let stopReceiptMaxBytes = 1024 * 1024

    // Separate process-owned files avoid cross-process append/rotation races.
    // No core logger, platform callback, or service lock is used in this path.
    // This is deliberately a bounded receipt vocabulary: it must never retain
    // exception descriptions, configurations, endpoints, or request payloads.
    private static func stopReceiptDisposition(_ stage: String) -> (String, String, Bool, String, String) {
      if stage == "app_prepare_error" {
        return ("failed", "app", true, "invalid_state", "prepare_failed")
      }
      if stage == "app_rpc_return_error" {
        return ("failed", "app", true, "service_unavailable", "close_rpc_failed")
      }
      if stage == "provider_core_absent" {
        return ("failed", "provider", true, "service_unavailable", "command_server_absent")
      }
      if stage == "provider_close_already_error" || stage == "provider_journal_failure_recorded" {
        return ("failed", "provider", true, "core_close_failed", "prior_close_failed")
      }
      if stage == "provider_close_wait_timeout" {
        return ("failed", "provider", true, "timeout", "close_wait_timeout")
      }
      if stage.hasSuffix("_error") {
        let journal = stage.contains("journal")
        return ("failed", "provider", true,
                journal ? "journal_finalize_failed" : "core_close_failed",
                journal ? "journal_finalize_failed" : "core_close_failed")
      }
      if stage == "provider_close_busy" {
        return ("waiting", "provider", false, "none", "none")
      }
      if stage.hasSuffix("_enter") || stage == "app_prepare_enter" {
        return ("started", stage.hasPrefix("app_") ? "app" : "provider", false, "none", "none")
      }
      return ("succeeded", stage.hasPrefix("app_") ? "app" : "provider", false, "none", "none")
    }

    // Each retained segment starts on a JSON record and carries its sequence
    // origin. Whole-segment archives preserve evidence and allow recovery after
    // a process exits between rename and creation of the next active file.
    private static func stopReceiptPosition(_ url: URL) throws -> (next: Int, origin: Int, count: Int) {
      let text = try String(contentsOf: url, encoding: .utf8)
      guard text.isEmpty || text.hasSuffix("\n") else { throw NSError(domain: "WLTStopReceipt", code: 1) }
      let records = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
      var origin: Int?, expected: Int?
      for line in records {
        guard let data = line.data(using: .utf8),
          let row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sequence = row["sequence"] as? Int, sequence > 0, sequence < Int.max,
          let id = row["operation_id"] as? String, UUID(uuidString: id) != nil else {
          throw NSError(domain: "WLTStopReceipt", code: 1)
        }
        if origin == nil {
          origin = row["sequence_origin"] as? Int ?? 1
          expected = origin
        }
        guard sequence == expected, (row["sequence_origin"] as? Int ?? 1) == origin else {
          throw NSError(domain: "WLTStopReceipt", code: 1)
        }
        expected = sequence + 1
      }
      return (expected ?? 1, origin ?? 1, records.count)
    }

    private static func stopReceiptNextSegment(_ url: URL) throws -> Int {
      let prefix = url.deletingPathExtension().lastPathComponent + ".archive."
      let files = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "jsonl" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
      var next = 1
      for file in files {
        let position = try stopReceiptPosition(file)
        let suffix = String(file.lastPathComponent.dropFirst(prefix.count))
        let parts = suffix.split(separator: ".")
        guard parts.count == 3, parts[0].count == 20,
          let lastSequence = Int(parts[0]), UUID(uuidString: String(parts[1])) != nil,
          parts[2] == "jsonl", position.count > 0,
          position.origin == next, position.next - 1 == lastSequence else {
          throw NSError(domain: "WLTStopReceipt", code: 1)
        }
        next = position.next
      }
      return next
    }

    @discardableResult
    public static func appendStopStage(_ stage: String, operationID: String,
      requestID: String? = nil, canonicalOperationID: String? = nil, lifecycle: UInt64? = nil) -> Bool {
      let requestID = requestID ?? operationID
      guard stopStages.contains(stage), UUID(uuidString: operationID) != nil,
        UUID(uuidString: requestID) != nil,
        (canonicalOperationID == nil) == (lifecycle == nil),
        canonicalOperationID.map({ UUID(uuidString: $0) != nil }) ?? true else { return false }
      let owner = stage.hasPrefix("app_") ? "app" : "provider"
      guard owner == "app" || (requestID == operationID && canonicalOperationID == operationID && lifecycle != nil),
        owner != "app" || requestID == operationID,
        !["app_owner_bound", "app_rpc_return_ok"].contains(stage) || canonicalOperationID != nil else { return false }
      let url = FilePath.cacheDirectory.appendingPathComponent("wlt-stop-\(owner).jsonl")
      return queue.sync {
        do {
          let disposition = stopReceiptDisposition(stage)
          try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
          let archiveNext = try stopReceiptNextSegment(url)
          var position: (next: Int, origin: Int, count: Int)
          if FileManager.default.fileExists(atPath: url.path) {
            position = try stopReceiptPosition(url)
            if position.count == 0 {
              // A process may exit after creating the new active file, before
              // its first append. Empty active state inherits the archive tail.
              position = (archiveNext, archiveNext, 0)
            }
            guard position.origin == archiveNext else { throw NSError(domain: "WLTStopReceipt", code: 1) }
            let bytes = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            if (bytes?.intValue ?? 0) >= stopReceiptMaxBytes {
              let name = url.deletingPathExtension().lastPathComponent + ".archive."
                + String(format: "%020lld", Int64(position.next - 1)) + "." + UUID().uuidString.lowercased() + ".jsonl"
              try FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent(name))
              position.origin = position.next
            }
          } else {
            position = (archiveNext, archiveNext, 0)
          }
          let entry: [String: Any] = [
            "schema": 2, "sequence": position.next, "sequence_origin": position.origin, "stage": stage,
            "request_id": requestID,
            "canonical_operation_id": canonicalOperationID as Any? ?? NSNull(),
            "lifecycle": lifecycle.map { NSNumber(value: $0) } as Any? ?? NSNull(),
            "operation_id": operationID, "ownership": disposition.1, "outcome": disposition.0,
            "cleanup_required": disposition.2,
            "error": ["class": disposition.3, "code": disposition.4, "retryable": false],
            "wall_unix_ms": Int64(Date().timeIntervalSince1970 * 1000),
            "monotonic_ns": DispatchTime.now().uptimeNanoseconds,
          ]
          var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
          data.append(10)
          if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
          }
          let handle = try FileHandle(forWritingTo: url)
          do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
          } catch {
            try? handle.close()
            throw error
          }
          return true
        } catch {
          // A failed write is explicit incomplete terminal evidence. Callers that
          // need a close verdict must convert this false result into failure.
          return false
        }
      }
    }
  #endif

  public static func append(_ message: String) {
    append(message, to: fileURL, maxBytes: maxBytes)
  }

  public static func appendIncident(_ message: String) {
    append(message, to: incidentFileURL, maxBytes: maxIncidentBytes)
  }

  public static func resetStartupMilestones() {
    queue.sync {
      try? FileManager.default.removeItem(at: startupMilestoneFileURL)
    }
  }

  public static func appendStartupMilestone(_ milestone: String) {
    guard allowedStartupMilestones.contains(milestone) else {
      return
    }
    guard let data = "\(milestone)\n".data(using: .utf8) else {
      return
    }
    queue.sync {
      do {
        try FileManager.default.createDirectory(
          at: startupMilestoneFileURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: startupMilestoneFileURL.path) {
          let handle = try FileHandle(forWritingTo: startupMilestoneFileURL)
          defer { try? handle.close() }
          try handle.seekToEnd()
          try handle.write(contentsOf: data)
        } else {
          try data.write(to: startupMilestoneFileURL, options: .atomic)
        }
      } catch {
        // Milestones are diagnostics and must not affect tunnel startup.
      }
    }
  }

  public static func observeStartupLog(_ message: String) {
    let milestone: String?
    if message.contains("wlt service starting") {
      milestone = "wlt_service_starting"
    } else if message.contains("WLT carrier start phase=load_config") {
      milestone = "carrier_config_loading"
    } else if message.contains("WLT carrier start phase=config_ready") {
      milestone = "carrier_config_ready"
    } else if message.contains("WLT carrier auth event=snapshot_loaded source=current") {
      milestone = "carrier_snapshot_current"
    } else if message.contains("WLT carrier auth event=snapshot_loaded source=previous") {
      milestone = "carrier_snapshot_previous"
    } else if message.contains("WLT carrier auth event=snapshot_loaded source=inline") {
      milestone = "carrier_snapshot_inline"
    } else if message.contains("WLT carrier connect attempt started") {
      milestone = "carrier_connect_started"
    } else if message.contains("WLT carrier connect attempt still pending") {
      milestone = "carrier_connect_pending"
    } else if message.contains("WLT carrier auth event=reauthorization_required") {
      milestone = "carrier_reauthorization_required"
    } else if message.contains("WLT carrier start phase=turn_auth_recovered") {
      milestone = "carrier_recovery_succeeded"
    } else if message.contains("WLT carrier start phase=turn_auth_recovery_unavailable") {
      if message.contains("context deadline exceeded") || message.contains("deadline exceeded") {
        milestone = "carrier_recovery_failed_timeout"
      } else if message.contains("automatic provider challenge outcome=")
        || message.contains("automatic challenge attempt=")
        || message.contains("human challenge")
        || message.localizedCaseInsensitiveContains("captcha")
      {
        milestone = "carrier_recovery_failed_challenge"
      } else if message.contains("auth snapshot reauthorization required") {
        if message.contains("provider reauthorization stage=messages_identity") {
          milestone = "carrier_recovery_reauth_messages_identity"
        } else if message.contains("provider reauthorization stage=anonymous_identity") {
          if message.contains("category=challenge_required") {
            if message.contains("recovery=stage_")
              || message.contains("recovery=setup_unavailable")
            {
              if message.contains("recovery=stage_content") {
                milestone = "carrier_recovery_challenge_stage_content"
              } else if message.contains("recovery=stage_input_") {
                milestone = "carrier_recovery_challenge_stage_input"
              } else if message.contains("recovery=stage_frames") {
                milestone = "carrier_recovery_challenge_stage_frames"
              } else if message.contains("recovery=stage_automatic_slider_") {
                milestone = "carrier_recovery_challenge_stage_candidate"
              } else if message.contains("recovery=stage_") {
                milestone = "carrier_recovery_challenge_stage_other"
              } else {
                milestone = "carrier_recovery_anonymous_challenge_setup"
              }
            } else if message.contains("rate_limited") {
              milestone = "carrier_recovery_anonymous_challenge_rate_limited"
            } else if message.contains("interaction_invalid")
              || message.contains("type_changed")
            {
              milestone = "carrier_recovery_anonymous_challenge_interaction"
            } else if message.contains("rejected")
              || message.contains("checkbox_")
              || message.contains("check_")
            {
              if message.contains("recovery=checkbox_checkbox_retry_required_") {
                milestone = "carrier_recovery_checkbox_retry_required"
              } else if message.contains("recovery=checkbox_checkbox_rejected_") {
                milestone = "carrier_recovery_checkbox_rejected"
              } else if message.contains("recovery=slider_") {
                milestone = "carrier_recovery_slider_rejected"
              } else if message.contains("_check_") {
                milestone = "carrier_recovery_challenge_check_rejected"
              } else {
                milestone = "carrier_recovery_anonymous_challenge_rejected"
              }
            } else {
              milestone = "carrier_recovery_anonymous_challenge_other"
            }
          } else if message.contains("category=authentication_required") {
            milestone = "carrier_recovery_anonymous_authentication_required"
          } else if message.contains("category=access_denied") {
            milestone = "carrier_recovery_anonymous_access_denied"
          } else if message.contains("category=anonymous_identity_rejected") {
            milestone = "carrier_recovery_anonymous_identity_rejected"
          } else if message.contains("category=invalid_response") {
            milestone = "carrier_recovery_anonymous_invalid_response"
          } else if message.contains("category=") {
            milestone = "carrier_recovery_anonymous_other"
          } else {
            milestone = "carrier_recovery_reauth_anonymous_identity"
          }
        } else if message.contains("provider reauthorization stage=renewed_join") {
          milestone = "carrier_recovery_reauth_renewed_join"
        } else if message.contains("provider reauthorization stage=") {
          milestone = "carrier_recovery_reauth_unknown"
        } else {
          milestone = "carrier_recovery_failed_reauthorization"
        }
      } else {
        milestone = "carrier_recovery_failed_other"
      }
    } else if message.contains("WLT carrier auth event=previous_unavailable") {
      milestone = "carrier_previous_unavailable"
    } else if message.contains("WLT carrier auth event=fallback_started source=previous") {
      milestone = "carrier_previous_started"
    } else if message.contains("WLT carrier auth event=fallback_succeeded source=previous") {
      milestone = "carrier_previous_succeeded"
    } else if message.contains("WLT carrier auth event=fallback_failed source=previous") {
      milestone = "carrier_previous_failed"
    } else if message.contains("WLT carrier auth event=fallback_started source=inline") {
      milestone = "carrier_inline_started"
    } else if message.contains("WLT carrier auth event=fallback_succeeded source=inline") {
      milestone = "carrier_inline_succeeded"
    } else if message.contains("WLT carrier auth event=fallback_failed source=inline") {
      milestone = "carrier_inline_failed"
    } else if message.contains("phase=turn_auth_recovery") {
      milestone = "carrier_provider_recovery"
    } else if message.contains("WLT carrier start failed phase=auth_snapshot") {
      milestone = "carrier_start_failed_auth_snapshot"
    } else if message.contains("WLT carrier start failed phase=bootstrap") {
      milestone = "carrier_start_failed_bootstrap"
    } else if message.contains("WLT carrier start failed phase=connect") {
      milestone = "carrier_start_failed_connect"
    } else if message.contains("WLT startup phase=snapshot_checked") {
      milestone = "snapshot_checked"
    } else if message.contains("WLT startup phase=provider_refresh_started") {
      milestone = "provider_refresh_started"
    } else if message.contains("WLT startup phase=provider_refresh_ready") {
      milestone = message.contains("outcome=cached")
        ? "provider_refresh_ready_cached" : "provider_refresh_ready_not_needed"
    } else if message.contains("WLT startup phase=provider_ready") {
      milestone = "provider_ready"
    } else if message.contains("WLT startup phase=turn_ready") {
      milestone = message.contains("outcome=refreshed")
        ? "turn_ready_refreshed" : "turn_ready_cached"
    } else if message.contains("WLT startup phase=peer_ready") {
      milestone = "peer_ready"
    } else if message.contains("WLT startup phase=carrier_ready") {
      milestone = "carrier_ready"
    } else if message.contains("WLT startup phase=sing_box_ready") {
      milestone = "sing_box_ready"
    } else if message.contains("WLT startup phase=first_packet") {
      milestone = "first_packet"
    } else if message.contains("WLT startup phase=traffic_ready") {
      milestone = "traffic_ready"
    } else if message.contains("using encrypted upstream direct fallback") {
      milestone = "direct_fallback"
    } else {
      milestone = nil
    }
    if let milestone {
      appendStartupMilestone(milestone)
    }
  }

  public static func startupMilestones() -> [String] {
    queue.sync {
      guard let text = try? String(contentsOf: startupMilestoneFileURL, encoding: .utf8) else {
        return []
      }
      var seen = Set<String>()
      return text.split(whereSeparator: { $0.isNewline }).compactMap { value in
        let milestone = String(value)
        guard allowedStartupMilestones.contains(milestone), seen.insert(milestone).inserted else {
          return nil
        }
        return milestone
      }
    }
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
      try? FileManager.default.removeItem(at: startupMilestoneFileURL)
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
