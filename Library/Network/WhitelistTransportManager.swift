#if os(macOS)
    import Darwin
    import Foundation
    import os

    public actor WhitelistTransportManager {
        public static let shared = WhitelistTransportManager()

        private let logger = Logger(category: "WhitelistTransport")
        private var process: Process?
        private var stdoutPipe: Pipe?
        private var stderrPipe: Pipe?

        private init() {}

        @discardableResult
        public func startIfNeeded() async throws -> Bool {
            let enabled = await SharedPreferences.whitelistTransportEnabled.get()
            guard enabled else {
                stop()
                return false
            }
            if let process, process.isRunning {
                return false
            }

            let executableURL = try await resolveExecutableURL()
            let telemostLinkFile = await SharedPreferences.whitelistTransportTelemostLinkFile.get()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !telemostLinkFile.isEmpty else {
                throw makeError("Telemost link file is not configured")
            }
            guard FileManager.default.fileExists(atPath: telemostLinkFile) else {
                throw makeError("Telemost link file does not exist")
            }

            let socksSpec = await SharedPreferences.whitelistTransportSOCKSListeners.get()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !socksSpec.isEmpty else {
                throw makeError("SOCKS listener map is not configured")
            }

            let displayName = await SharedPreferences.whitelistTransportDisplayName.get()
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let process = Process()
            process.executableURL = executableURL
            process.arguments = [
                "-transport", "telemost",
                "-tm-link-file", telemostLinkFile,
                "-socks", socksSpec,
                "-tm-display-name", displayName.isEmpty ? "WLT Client" : displayName,
            ]
            process.environment = sanitizedEnvironment()

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            attachLogReader(stdoutPipe, level: .debug)
            attachLogReader(stderrPipe, level: .error)

            process.terminationHandler = { [weak self] terminated in
                Task { await self?.handleTermination(pid: terminated.processIdentifier, status: terminated.terminationStatus) }
            }

            do {
                try process.run()
            } catch {
                closePipes()
                throw makeError("Failed to start whitelist transport: \(error.localizedDescription)")
            }

            self.process = process
            do {
                try await waitForListeners(socksSpec)
            } catch {
                stop()
                throw error
            }
            logger.info("whitelist transport started")
            return true
        }

        public func stop() {
            guard let process else {
                closePipes()
                return
            }
            self.process = nil
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(5)
                while process.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            closePipes()
            logger.info("whitelist transport stopped")
        }

        private func resolveExecutableURL() async throws -> URL {
            let configuredPath = await SharedPreferences.whitelistTransportExecutablePath.get()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !configuredPath.isEmpty {
                let url = URL(fileURLWithPath: configuredPath)
                try validateExecutable(url)
                return url
            }
            if let url = Bundle.main.url(forAuxiliaryExecutable: "wlt-client") {
                try validateExecutable(url)
                return url
            }
            if let url = Bundle.main.url(forResource: "wlt-client", withExtension: nil) {
                try validateExecutable(url)
                return url
            }
            throw makeError("wlt-client executable was not found")
        }

        private func validateExecutable(_ url: URL) throws {
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw makeError("wlt-client is not executable")
            }
        }

        private func sanitizedEnvironment() -> [String: String] {
            let current = ProcessInfo.processInfo.environment
            let allowedKeys = ["PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE"]
            return allowedKeys.reduce(into: [:]) { result, key in
                if let value = current[key] {
                    result[key] = value
                }
            }
        }

        private func waitForListeners(_ socksSpec: String) async throws {
            let endpoints = try parseListenerEndpoints(socksSpec)
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if let process, !process.isRunning {
                    throw makeError("whitelist transport exited before listeners became ready")
                }
                var allReady = true
                for endpoint in endpoints {
                    if !canConnect(endpoint) {
                        allReady = false
                        break
                    }
                }
                if allReady {
                    return
                }
                try await Task.sleep(nanoseconds: 200 * NSEC_PER_MSEC)
            }
            throw makeError("timeout waiting for whitelist transport listeners")
        }

        private func parseListenerEndpoints(_ socksSpec: String) throws -> [String] {
            let endpoints = socksSpec
                .split(separator: ",")
                .map { item in
                    item.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
                }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !endpoints.isEmpty else {
                throw makeError("SOCKS listener map is empty")
            }
            return endpoints
        }

        private func canConnect(_ endpoint: String) -> Bool {
            guard let separator = endpoint.lastIndex(of: ":") else {
                return false
            }
            let host = String(endpoint[..<separator])
            guard let port = UInt16(endpoint[endpoint.index(after: separator)...]) else {
                return false
            }

            let socketFD = socket(AF_INET, SOCK_STREAM, 0)
            guard socketFD >= 0 else {
                return false
            }
            defer {
                Darwin.close(socketFD)
            }

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
                return false
            }

            return withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        }

        private enum LogLevel {
            case debug
            case error
        }

        private func attachLogReader(_ pipe: Pipe, level: LogLevel) {
            pipe.fileHandleForReading.readabilityHandler = { [logger] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                    return
                }
                let sanitized = sanitizeLog(text)
                switch level {
                case .debug:
                    logger.debug("\(sanitized, privacy: .public)")
                case .error:
                    logger.error("\(sanitized, privacy: .public)")
                }
            }
        }

        private func handleTermination(pid: Int32, status: Int32) {
            if process?.processIdentifier == pid {
                process = nil
                closePipes()
            }
            logger.info("whitelist transport exited status=\(status)")
        }

        private func closePipes() {
            stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            stderrPipe?.fileHandleForReading.readabilityHandler = nil
            stdoutPipe = nil
            stderrPipe = nil
        }

        private func makeError(_ message: String) -> NSError {
            NSError(domain: "WhitelistTransport", code: -1, userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
    }

    private func sanitizeLog(_ text: String) -> String {
        var output = text
        output = output.replacingOccurrences(
            of: #"https://telemost\.yandex\.ru/j/[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+"#,
            with: "https://telemost.yandex.ru/j/[redacted]",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#,
            with: "[uuid]",
            options: .regularExpression
        )
        return output
    }
#endif
