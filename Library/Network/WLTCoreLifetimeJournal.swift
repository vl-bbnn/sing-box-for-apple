import CryptoKit
import CoreFoundation
import Foundation

/// A fail-closed, file-backed journal for the complete lifetime of a core WLT service.
///
/// The caller prepares a distinct file before every libbox start/reload, injects the
/// returned runtime configuration, and reports the synchronous libbox result. A file
/// is hashed only after libbox has synchronously closed the generation that wrote it.
public final class WLTCoreLifetimeJournal {
  public struct PreparedGeneration {
    public let number: Int
    public let logFile: URL
    public let configContent: String

    fileprivate let identifier: UUID
  }

  public enum JournalError: Error, LocalizedError {
    case invalidSessionIdentifier
    case finalized
    case generationAlreadyPrepared
    case noPreparedGeneration
    case wrongPreparedGeneration
    case invalidConfig
    case invalidLogObject
    case loggingDisabled
    case createFileFailed(String)
    case journalQuotaExceeded
    case generationLimitExceeded

    public var errorDescription: String? {
      switch self {
      case .invalidSessionIdentifier:
        return "invalid journal session identifier"
      case .finalized:
        return "journal session is already finalized"
      case .generationAlreadyPrepared:
        return "a journal generation is already prepared"
      case .noPreparedGeneration:
        return "no journal generation is prepared"
      case .wrongPreparedGeneration:
        return "prepared journal generation does not match current state"
      case .invalidConfig:
        return "runtime configuration is not a JSON object"
      case .invalidLogObject:
        return "runtime configuration log field is not a JSON object"
      case .loggingDisabled:
        return "runtime configuration explicitly disables logging"
      case .createFileFailed(let path):
        return "could not create journal file: \(path)"
      case .journalQuotaExceeded:
        return "WLT lifetime journal byte quota is exhausted"
      case .generationLimitExceeded:
        return "WLT lifetime journal generation limit is exhausted"
      }
    }
  }

  public static let defaultMaximumGenerationBytes: UInt64 = 64 * 1024 * 1024
  public static let defaultMaximumJournalBytes: UInt64 = 384 * 1024 * 1024
  public static let maximumGenerationsPerSession = 1_024
  private static let metadataHeadroomBytes: UInt64 = 8 * 1024 * 1024
  private static let outputOverflowMarker = "[WLT-JOURNAL] log_output_overflow schema=1"
  private static let terminalOverflowMarker = "[WLT-JOURNAL] terminal_reserve_overflow schema=1"

  public let rootDirectory: URL
  public let sessionDirectory: URL
  public let sessionIdentifier: String
  public let maximumGenerationBytes: UInt64
  public let maximumJournalBytes: UInt64

  private final class Generation {
    let identifier: UUID
    let number: Int
    let logFile: URL
    let receiptFile: URL
    let preparedUTC: String

    init(
      identifier: UUID,
      number: Int,
      logFile: URL,
      receiptFile: URL,
      preparedUTC: String
    ) {
      self.identifier = identifier
      self.number = number
      self.logFile = logFile
      self.receiptFile = receiptFile
      self.preparedUTC = preparedUTC
    }
  }

  private let fileManager: FileManager
  private let now: () -> Date
  private let lock = NSLock()
  private let startedUTC: String
  private var finishedUTC: String?
  private var nextGeneration = 1
  private var generations: [Generation] = []
  private var pending: Generation?
  private var active: Generation?
  private var sessionHasIncompleteGeneration = false
  private var finalized = false
  private var serviceState = "idle"

  public init(
    rootDirectory: URL,
    maximumGenerationBytes: UInt64 = WLTCoreLifetimeJournal.defaultMaximumGenerationBytes,
    maximumJournalBytes: UInt64 = WLTCoreLifetimeJournal.defaultMaximumJournalBytes,
    sessionIdentifier: String = UUID().uuidString.lowercased(),
    fileManager: FileManager = .default,
    now: @escaping () -> Date = Date.init
  ) throws {
    guard Self.isSafePathComponent(sessionIdentifier), maximumGenerationBytes >= 4_096,
      maximumGenerationBytes <= UInt64(Int64.max),
      maximumJournalBytes >= maximumGenerationBytes + Self.metadataHeadroomBytes
    else {
      throw JournalError.invalidSessionIdentifier
    }
    self.rootDirectory = rootDirectory
    self.sessionIdentifier = sessionIdentifier
    self.sessionDirectory = rootDirectory.appendingPathComponent(sessionIdentifier, isDirectory: true)
    self.maximumGenerationBytes = maximumGenerationBytes
    self.maximumJournalBytes = maximumJournalBytes
    self.fileManager = fileManager
    self.now = now
    self.startedUTC = Self.timestamp(now())

    try Self.createPrivateDirectory(rootDirectory, fileManager: fileManager)
    let existingBytes = try Self.directoryByteCount(rootDirectory, fileManager: fileManager)
    guard existingBytes <= maximumJournalBytes - maximumGenerationBytes - Self.metadataHeadroomBytes else {
      throw JournalError.journalQuotaExceeded
    }
    guard !fileManager.fileExists(atPath: sessionDirectory.path) else {
      throw JournalError.createFileFailed(sessionDirectory.path)
    }
    try fileManager.createDirectory(
      at: sessionDirectory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    try Self.setPermissions(0o700, at: sessionDirectory, fileManager: fileManager)
    try writeSessionManifest()
  }

  /// Creates a private empty file and returns an in-memory-only configuration copy.
  /// Persisted profile/start-option bytes are never accepted by or written from this type.
  public func prepareGeneration(configContent: String) throws -> PreparedGeneration {
    try locked {
      guard !finalized else {
        throw JournalError.finalized
      }
      guard pending == nil else {
        throw JournalError.generationAlreadyPrepared
      }
      guard generations.count < Self.maximumGenerationsPerSession else {
        throw JournalError.generationLimitExceeded
      }
      try requireJournalCapacityForNewGeneration()

      let number = nextGeneration
      let stem = String(format: "generation-%04d", number)
      let logFile = sessionDirectory.appendingPathComponent("\(stem).log", isDirectory: false)
      let receiptFile = sessionDirectory.appendingPathComponent("\(stem).json", isDirectory: false)
      let injected = try Self.injectingJournalOutput(
        into: configContent,
        outputFile: logFile,
        maximumBytes: maximumGenerationBytes
      )

      guard fileManager.createFile(
        atPath: logFile.path,
        contents: Data(),
        attributes: [.posixPermissions: NSNumber(value: 0o600)]
      ) else {
        throw JournalError.createFileFailed(logFile.path)
      }
      do {
        try Self.setPermissions(0o600, at: logFile, fileManager: fileManager)
        let generation = Generation(
          identifier: UUID(),
          number: number,
          logFile: logFile,
          receiptFile: receiptFile,
          preparedUTC: Self.timestamp(now())
        )
        try writeReceipt(
          generation,
          state: "prepared",
          sealed: false,
          complete: false,
          overflow: false
        )
        generations.append(generation)
        pending = generation
        nextGeneration += 1
        serviceState = active == nil ? "starting" : "reloading"
        try writeSessionManifest()
        return PreparedGeneration(
          number: number,
          logFile: logFile,
          configContent: injected,
          identifier: generation.identifier
        )
      } catch {
        try? fileManager.removeItem(at: receiptFile)
        try? fileManager.removeItem(at: logFile)
        throw error
      }
    }
  }

  /// Call only after the r2+ daemon returns successfully. Its reload contract
  /// propagates the prior Instance.Close result before constructing a replacement.
  public func didStartGeneration(
    _ prepared: PreparedGeneration,
    previousGenerationCloseConfirmed: Bool = true
  ) throws {
    try locked {
      let generation = try requirePending(prepared)
      if let previous = active {
        if previousGenerationCloseConfirmed {
          do {
            let complete = try seal(previous, closeReason: "reload_succeeded")
            sessionHasIncompleteGeneration = sessionHasIncompleteGeneration || !complete
          } catch {
            sessionHasIncompleteGeneration = true
            try? writeReceipt(
              previous,
              state: "seal_failed",
              sealed: false,
              complete: false,
              overflow: false,
              closeReason: "reload_succeeded",
              error: error.localizedDescription
            )
          }
        } else {
          sessionHasIncompleteGeneration = true
          try writeReceipt(
            previous,
            state: "reload_close_unconfirmed",
            sealed: false,
            complete: false,
            overflow: false,
            closeReason: "reload_succeeded",
            error: "daemon discarded the prior Instance.Close result"
          )
        }
      }
      active = generation
      pending = nil
      serviceState = "active"
      try writeReceipt(
        generation,
        state: "active",
        sealed: false,
        complete: false,
        overflow: false
      )
      try writeSessionManifest()
    }
  }

  /// Call when startOrReloadService throws. No file is assumed closed or stable.
  public func didFailToStartGeneration(
    _ prepared: PreparedGeneration,
    errorDescription: String
  ) throws {
    try locked {
      let generation = try requirePending(prepared)
      sessionHasIncompleteGeneration = true
      if let previous = active {
        try? writeReceipt(
          previous,
          state: "reload_failed_ambiguous",
          sealed: false,
          complete: false,
          overflow: false,
          closeReason: "reload_failed",
          error: errorDescription
        )
      }
      try writeReceipt(
        generation,
        state: "start_failed_ambiguous",
        sealed: false,
        complete: false,
        overflow: false,
        closeReason: "start_failed",
        error: errorDescription
      )
      active = nil
      pending = nil
      serviceState = "failed"
      try writeSessionManifest()
    }
  }

  /// Call only after the r2+ closeService returns successfully. Its relay handler
  /// joins tracked terminal observers before the log factory closes.
  public func didCloseService(
    reason: String,
    finalizeSession: Bool,
    terminalObserversConfirmed: Bool = true
  ) throws {
    try locked {
      if let generation = active {
        let complete = try seal(
          generation,
          closeReason: reason,
          forcedIncompleteReason: terminalObserversConfirmed
            ? nil : "terminal diagnostic observers can outlive the core log factory"
        )
        sessionHasIncompleteGeneration = sessionHasIncompleteGeneration || !complete
        active = nil
      }
      serviceState = "idle"
      if finalizeSession {
        finalized = true
        finishedUTC = Self.timestamp(now())
      }
      try writeSessionManifest()
    }
  }

  /// Call when closeService throws. The active file may still be open, so it is not hashed.
  public func didFailToCloseService(
    reason: String,
    errorDescription: String,
    finalizeSession: Bool
  ) throws {
    try locked {
      sessionHasIncompleteGeneration = true
      if let generation = active {
        try? writeReceipt(
          generation,
          state: "close_failed_ambiguous",
          sealed: false,
          complete: false,
          overflow: false,
          closeReason: reason,
          error: errorDescription
        )
        active = nil
      }
      serviceState = "failed"
      if finalizeSession {
        finalized = true
        finishedUTC = Self.timestamp(now())
      }
      try writeSessionManifest()
    }
  }

  /// Finalizes a tunnel that has no live service (for example after a failed reload).
  public func finalizeIncompleteSession(reason: String) throws {
    try locked {
      guard !finalized else {
        return
      }
      sessionHasIncompleteGeneration = true
      if let generation = active ?? pending {
        try? writeReceipt(
          generation,
          state: "tunnel_ended_unsealed",
          sealed: false,
          complete: false,
          overflow: false,
          closeReason: reason
        )
      }
      active = nil
      pending = nil
      serviceState = "failed"
      finalized = true
      finishedUTC = Self.timestamp(now())
      try writeSessionManifest()
    }
  }

  public static func injectingJournalOutput(
    into configContent: String,
    outputFile: URL,
    maximumBytes: UInt64 = WLTCoreLifetimeJournal.defaultMaximumGenerationBytes
  ) throws -> String {
    guard let data = configContent.data(using: .utf8),
      var dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw JournalError.invalidConfig
    }
    var log: [String: Any]
    if let rawLog = dictionary["log"] {
      guard let object = rawLog as? [String: Any] else {
        throw JournalError.invalidLogObject
      }
      log = object
    } else {
      log = [:]
    }
    if (log["disabled"] as? Bool) == true {
      throw JournalError.loggingDisabled
    }
    log["output"] = outputFile.path
    log["output_max_bytes"] = NSNumber(value: maximumBytes)
    log["timestamp"] = true
    dictionary["log"] = log
    guard JSONSerialization.isValidJSONObject(dictionary) else {
      throw JournalError.invalidConfig
    }
    let encoded = try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
    guard let injected = String(data: encoded, encoding: .utf8) else {
      throw JournalError.invalidConfig
    }
    return injected
  }

  /// Removes only old sessions whose complete receipts and immutable log bytes validate.
  /// Every deletion leaves a root-level tombstone. Incomplete sessions are never selected.
  @discardableResult
  public static func enforceRetention(
    in rootDirectory: URL,
    keepingLatestSealedSessions keepCount: Int,
    fileManager: FileManager = .default,
    now: () -> Date = Date.init
  ) throws -> [URL] {
    guard keepCount >= 0 else {
      return []
    }
    try createPrivateDirectory(rootDirectory, fileManager: fileManager)
    let children = try fileManager.contentsOfDirectory(
      at: rootDirectory,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    var candidates: [(url: URL, sessionID: String, startedUTC: String)] = []
    for child in children {
      let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true,
        values.isSymbolicLink != true,
        let manifest = try? jsonObject(at: child.appendingPathComponent("session.json")),
        manifest["state"] as? String == "sealed",
        let sessionID = manifest["session_id"] as? String,
        let startedUTC = manifest["started_utc"] as? String,
        try fullyValidSealedSession(at: child, manifest: manifest, fileManager: fileManager)
      else {
        continue
      }
      candidates.append((child, sessionID, startedUTC))
    }
    candidates.sort {
      ($0.startedUTC, $0.sessionID) < ($1.startedUTC, $1.sessionID)
    }
    let removeCount = max(0, candidates.count - keepCount)
    var tombstones: [URL] = []
    for candidate in candidates.prefix(removeCount) {
      let manifestFile = candidate.url.appendingPathComponent("session.json")
      let manifestDigest = try sha256(of: manifestFile)
      let retainedBytes = try directoryByteCount(candidate.url, fileManager: fileManager)
      let retiring = rootDirectory.appendingPathComponent(
        ".retiring-\(candidate.sessionID)-\(UUID().uuidString.lowercased())",
        isDirectory: true
      )
      let tombstone = rootDirectory.appendingPathComponent(
        "retention-\(candidate.sessionID).json",
        isDirectory: false
      )
      try fileManager.moveItem(at: candidate.url, to: retiring)
      let base: [String: Any] = [
        "schema": 1,
        "kind": "wlt_core_lifetime_journal_retention",
        "session_id": candidate.sessionID,
        "session_manifest_sha256": manifestDigest,
        "retained_bytes": retainedBytes,
        "retained_utc": timestamp(now()),
      ]
      do {
        var staged = base
        staged["state"] = "staged"
        try writeJSON(staged, to: tombstone, fileManager: fileManager)
        try fileManager.removeItem(at: retiring)
        var deleted = base
        deleted["state"] = "deleted"
        try writeJSON(deleted, to: tombstone, fileManager: fileManager)
        tombstones.append(tombstone)
      } catch {
        throw error
      }
    }
    return tombstones
  }

  private func requirePending(_ prepared: PreparedGeneration) throws -> Generation {
    guard let pending else {
      throw JournalError.noPreparedGeneration
    }
    guard pending.identifier == prepared.identifier,
      pending.number == prepared.number,
      pending.logFile == prepared.logFile
    else {
      throw JournalError.wrongPreparedGeneration
    }
    return pending
  }

  private func requireJournalCapacityForNewGeneration() throws {
    let actualBytes = try Self.directoryByteCount(rootDirectory, fileManager: fileManager)
    var activeRemaining: UInt64 = 0
    if let active {
      let attributes = try fileManager.attributesOfItem(atPath: active.logFile.path)
      let activeBytes = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
      if activeBytes < maximumGenerationBytes {
        activeRemaining = maximumGenerationBytes - activeBytes
      }
    }
    let (withActive, activeOverflow) = actualBytes.addingReportingOverflow(activeRemaining)
    let (withGeneration, generationOverflow) = withActive.addingReportingOverflow(maximumGenerationBytes)
    let (projected, metadataOverflow) = withGeneration.addingReportingOverflow(Self.metadataHeadroomBytes)
    guard !activeOverflow, !generationOverflow, !metadataOverflow,
      projected <= maximumJournalBytes
    else {
      throw JournalError.journalQuotaExceeded
    }
  }

  @discardableResult
  private func seal(
    _ generation: Generation,
    closeReason: String,
    forcedIncompleteReason: String? = nil
  ) throws -> Bool {
    let attributes = try fileManager.attributesOfItem(atPath: generation.logFile.path)
    let byteCount = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    let digest = try Self.sha256(of: generation.logFile)
    let markerOverflow = try Self.containsAnyMarker(
      in: generation.logFile,
      markers: [Self.outputOverflowMarker, Self.terminalOverflowMarker]
    )
    let overflow = byteCount > maximumGenerationBytes || markerOverflow
    let correctMode = (mode & 0o777) == 0o600
    let complete = !overflow && correctMode && forcedIncompleteReason == nil
    let state: String
    let error: String?
    if overflow {
      state = "overflow"
      error = markerOverflow
        ? "core log writer reported output overflow"
        : "generation exceeds maximum_generation_bytes"
    } else if !correctMode {
      state = "invalid_file_mode"
      error = "generation file mode is not 0600"
    } else if let forcedIncompleteReason {
      state = "terminal_observers_unconfirmed"
      error = forcedIncompleteReason
    } else {
      state = "sealed"
      error = nil
    }
    try writeReceipt(
      generation,
      state: state,
      sealed: true,
      complete: complete,
      overflow: overflow,
      closeReason: closeReason,
      sealedUTC: Self.timestamp(now()),
      byteCount: byteCount,
      sha256: digest,
      fileMode: String(format: "%04o", mode & 0o777),
      error: error
    )
    return complete
  }

  private func writeReceipt(
    _ generation: Generation,
    state: String,
    sealed: Bool,
    complete: Bool,
    overflow: Bool,
    closeReason: String? = nil,
    sealedUTC: String? = nil,
    byteCount: UInt64? = nil,
    sha256: String? = nil,
    fileMode: String? = nil,
    error: String? = nil
  ) throws {
    var receipt: [String: Any] = [
      "schema": 1,
      "kind": "wlt_core_lifetime_journal_generation",
      "session_id": sessionIdentifier,
      "generation": generation.number,
      "log_file": generation.logFile.lastPathComponent,
      "state": state,
      "prepared_utc": generation.preparedUTC,
      "sealed": sealed,
      "complete": complete,
      "overflow": overflow,
      "maximum_generation_bytes": maximumGenerationBytes,
      "maximum_journal_bytes": maximumJournalBytes,
    ]
    if let closeReason { receipt["close_reason"] = closeReason }
    if let sealedUTC { receipt["sealed_utc"] = sealedUTC }
    if let byteCount { receipt["byte_count"] = byteCount }
    if let sha256 { receipt["sha256"] = sha256 }
    if let fileMode { receipt["file_mode"] = fileMode }
    if let error { receipt["error"] = error }
    try Self.writeJSON(receipt, to: generation.receiptFile, fileManager: fileManager)
  }

  private func writeSessionManifest() throws {
    let state: String
    if finalized {
      state = sessionHasIncompleteGeneration ? "incomplete" : "sealed"
    } else if sessionHasIncompleteGeneration {
      state = "open_incomplete"
    } else {
      state = "open"
    }
    let index: [[String: Any]] = generations.map {
      [
        "generation": $0.number,
        "log_file": $0.logFile.lastPathComponent,
        "receipt_file": $0.receiptFile.lastPathComponent,
      ]
    }
    var manifest: [String: Any] = [
      "schema": 1,
      "kind": "wlt_core_lifetime_journal_session",
      "session_id": sessionIdentifier,
      "state": state,
      "service_state": serviceState,
      "started_utc": startedUTC,
      "maximum_generation_bytes": maximumGenerationBytes,
      "maximum_journal_bytes": maximumJournalBytes,
      "generations": index,
    ]
    if let finishedUTC { manifest["finished_utc"] = finishedUTC }
    try Self.writeJSON(
      manifest,
      to: sessionDirectory.appendingPathComponent("session.json"),
      fileManager: fileManager
    )
  }

  private func locked<T>(_ operation: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try operation()
  }

  private static func createPrivateDirectory(_ url: URL, fileManager: FileManager) throws {
    try fileManager.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    try setPermissions(0o700, at: url, fileManager: fileManager)
  }

  private static func setPermissions(
    _ mode: Int,
    at url: URL,
    fileManager: FileManager
  ) throws {
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: mode)],
      ofItemAtPath: url.path
    )
  }

  private static func writeJSON(
    _ object: [String: Any],
    to url: URL,
    fileManager: FileManager
  ) throws {
    let data = try JSONSerialization.data(
      withJSONObject: object,
      options: [.prettyPrinted, .sortedKeys]
    )
    try data.write(to: url, options: .atomic)
    try setPermissions(0o600, at: url, fileManager: fileManager)
  }

  private static func jsonObject(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw JournalError.invalidConfig
    }
    return object
  }

  private static func fullyValidSealedSession(
    at directory: URL,
    manifest: [String: Any],
    fileManager: FileManager
  ) throws -> Bool {
    let sessionKeys: Set<String> = [
      "schema", "kind", "session_id", "state", "service_state", "started_utc",
      "finished_utc", "maximum_generation_bytes", "maximum_journal_bytes", "generations",
    ]
    let generationKeys: Set<String> = [
      "schema", "kind", "session_id", "generation", "log_file", "state", "prepared_utc",
      "sealed", "complete", "overflow", "maximum_generation_bytes", "maximum_journal_bytes",
      "close_reason", "sealed_utc", "byte_count", "sha256", "file_mode",
    ]
    let manifestFile = directory.appendingPathComponent("session.json")
    let directoryAttributes = try? fileManager.attributesOfItem(atPath: directory.path)
    let manifestAttributes = try? fileManager.attributesOfItem(atPath: manifestFile.path)
    let manifestValues = try manifestFile.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )
    guard Set(manifest.keys) == sessionKeys,
      exactUInt64(manifest["schema"]) == 1,
      manifest["kind"] as? String == "wlt_core_lifetime_journal_session",
      manifest["state"] as? String == "sealed",
      manifest["service_state"] as? String == "idle",
      let sessionID = manifest["session_id"] as? String,
      isSafePathComponent(sessionID),
      directory.lastPathComponent == sessionID,
      let startedUTC = manifest["started_utc"] as? String,
      let startedDate = exactTimestamp(startedUTC),
      let finishedDate = exactTimestamp(manifest["finished_utc"]),
      finishedDate >= startedDate,
      let maximumGenerationBytes = exactUInt64(manifest["maximum_generation_bytes"]),
      maximumGenerationBytes >= 4_096,
      maximumGenerationBytes <= UInt64(Int64.max),
      let maximumJournalBytes = exactUInt64(manifest["maximum_journal_bytes"]),
      maximumGenerationBytes <= UInt64.max - metadataHeadroomBytes,
      maximumJournalBytes >= maximumGenerationBytes + metadataHeadroomBytes,
      let entries = manifest["generations"] as? [[String: Any]], !entries.isEmpty,
      entries.count <= maximumGenerationsPerSession,
      ((directoryAttributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777 == 0o700,
      manifestValues.isRegularFile == true,
      manifestValues.isSymbolicLink != true,
      ((manifestAttributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777 == 0o600
    else {
      return false
    }
    var expectedNames: Set<String> = ["session.json"]
    var expectedGeneration = 1
    var previousSealedDate = startedDate
    for entry in entries {
      let stem = String(format: "generation-%04d", expectedGeneration)
      guard Set(entry.keys) == ["generation", "log_file", "receipt_file"],
        exactUInt64(entry["generation"]) == UInt64(expectedGeneration),
        let logName = entry["log_file"] as? String,
        let receiptName = entry["receipt_file"] as? String,
        isSafePathComponent(logName),
        isSafePathComponent(receiptName),
        logName == "\(stem).log",
        receiptName == "\(stem).json"
      else {
        return false
      }
      let logFile = directory.appendingPathComponent(logName)
      let receiptFile = directory.appendingPathComponent(receiptName)
      let receipt = try jsonObject(at: receiptFile)
      let logValues = try logFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      let receiptValues = try receiptFile.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
      )
      let logAttributes = try? fileManager.attributesOfItem(atPath: logFile.path)
      let receiptAttributes = try? fileManager.attributesOfItem(atPath: receiptFile.path)
      guard Set(receipt.keys) == generationKeys,
        exactUInt64(receipt["schema"]) == 1,
        receipt["kind"] as? String == "wlt_core_lifetime_journal_generation",
        receipt["state"] as? String == "sealed",
        exactUInt64(receipt["generation"]) == UInt64(expectedGeneration),
        receipt["session_id"] as? String == sessionID,
        receipt["log_file"] as? String == logName,
        exactBool(receipt["sealed"]) == true,
        exactBool(receipt["complete"]) == true,
        exactBool(receipt["overflow"]) == false,
        exactUInt64(receipt["maximum_generation_bytes"]) == maximumGenerationBytes,
        exactUInt64(receipt["maximum_journal_bytes"]) == maximumJournalBytes,
        let preparedDate = exactTimestamp(receipt["prepared_utc"]),
        let sealedDate = exactTimestamp(receipt["sealed_utc"]),
        preparedDate >= previousSealedDate,
        sealedDate >= preparedDate,
        sealedDate <= finishedDate,
        let closeReason = receipt["close_reason"] as? String, !closeReason.isEmpty,
        receipt["file_mode"] as? String == "0600",
        let expectedBytes = exactUInt64(receipt["byte_count"]),
        expectedBytes <= maximumGenerationBytes,
        let expectedDigest = receipt["sha256"] as? String, isSHA256(expectedDigest),
        logValues.isRegularFile == true,
        logValues.isSymbolicLink != true,
        receiptValues.isRegularFile == true,
        receiptValues.isSymbolicLink != true,
        (logAttributes?[.size] as? NSNumber)?.uint64Value == expectedBytes,
        ((logAttributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777 == 0o600,
        ((receiptAttributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777 == 0o600,
        try sha256(of: logFile) == expectedDigest
      else {
        return false
      }
      expectedNames.insert(logName)
      expectedNames.insert(receiptName)
      previousSealedDate = sealedDate
      expectedGeneration += 1
    }
    let actualNames = try Set(fileManager.contentsOfDirectory(atPath: directory.path))
    let actualBytes = try directoryByteCount(directory, fileManager: fileManager)
    return actualNames == expectedNames && actualBytes <= maximumJournalBytes
  }

  private static func directoryByteCount(_ directory: URL, fileManager: FileManager) throws -> UInt64 {
    var traversalError: Error?
    guard let enumerator = fileManager.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
      options: [],
      errorHandler: { _, error in
        traversalError = error
        return false
      }
    ) else {
      throw JournalError.journalQuotaExceeded
    }
    var total: UInt64 = 0
    for case let file as URL in enumerator {
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      if values.isRegularFile == true {
        guard let fileSize = values.fileSize, fileSize >= 0 else {
          throw JournalError.journalQuotaExceeded
        }
        let (next, overflow) = total.addingReportingOverflow(UInt64(fileSize))
        guard !overflow else {
          throw JournalError.journalQuotaExceeded
        }
        total = next
      }
    }
    if let traversalError {
      throw traversalError
    }
    return total
  }

  private static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func containsAnyMarker(in url: URL, markers: [String]) throws -> Bool {
    let markerData = markers.map { Data($0.utf8) }
    let overlapCount = max(0, (markerData.map(\.count).max() ?? 1) - 1)
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var overlap = Data()
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
      var window = overlap
      window.append(data)
      if markerData.contains(where: { window.range(of: $0) != nil }) {
        return true
      }
      overlap = Data(window.suffix(overlapCount))
    }
    return false
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private static func isSafePathComponent(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".."
      && !value.contains("/") && !value.contains("\\")
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.utf8.allSatisfy {
      ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
    }
  }

  private static func exactUInt64(_ value: Any?) -> UInt64? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      let parsed = UInt64(number.stringValue)
    else {
      return nil
    }
    return parsed
  }

  private static func exactBool(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) == CFBooleanGetTypeID()
    else {
      return nil
    }
    return number.boolValue
  }

  private static func exactTimestamp(_ value: Any?) -> Date? {
    guard let value = value as? String else {
      return nil
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let parsed = formatter.date(from: value), timestamp(parsed) == value else {
      return nil
    }
    return parsed
  }
}
