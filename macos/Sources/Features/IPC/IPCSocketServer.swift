import Foundation
import OSLog
import GhosttyKit

/// Unix socket server for IPC communication.
///
/// This provides remote control capabilities matching the protocol in `src/apprt/socket.zig`.
/// Clients can send JSON requests to create windows, tabs, etc.
class IPCSocketServer {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "IPCSocketServer"
    )

    /// The socket file descriptor
    private var socketFD: Int32 = -1

    /// The path to the socket file
    private var socketPath: String = ""

    /// Whether the server is running
    private(set) var isRunning = false

    /// The dispatch source for accepting connections
    private var acceptSource: DispatchSourceRead?

    /// Reference to the app delegate for accessing ghostty
    private weak var appDelegate: AppDelegate?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    deinit {
        stop()
    }

    /// Start the socket server.
    func start() {
        guard !isRunning else { return }

        do {
            socketPath = try getSocketPath()
            try createSocketDirectory()
            try createSocket()
            isRunning = true
            logger.info("IPC socket server started at \(self.socketPath)")
        } catch {
            logger.error("Failed to start IPC socket server: \(error.localizedDescription)")
        }
    }

    /// Stop the socket server.
    func stop() {
        acceptSource?.cancel()
        acceptSource = nil

        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }

        if !socketPath.isEmpty {
            unlink(socketPath)
            socketPath = ""
        }

        isRunning = false
    }

    // MARK: - Socket Path

    /// Get the socket path matching the Zig implementation.
    private func getSocketPath() throws -> String {
        let uid = getuid()

        // Try TMPDIR first (macOS sets this per-user)
        if let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"] {
            let dir = (tmpdir as NSString).appendingPathComponent("ghostty-\(uid)")
            return (dir as NSString).appendingPathComponent("ghostty.sock")
        }

        // Fallback to /tmp/ghostty-$UID
        let dir = "/tmp/ghostty-\(uid)"
        return (dir as NSString).appendingPathComponent("ghostty.sock")
    }

    /// Create the socket directory if it doesn't exist.
    private func createSocketDirectory() throws {
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    // MARK: - Socket Creation

    private func createSocket() throws {
        // Remove existing socket file if present
        unlink(socketPath)

        // Create the socket
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw IPCError.socketCreationFailed(errno)
        }

        setNoSigPipe(socketFD)

        // Bind to the path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        guard socketPath.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw IPCError.pathTooLong
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cstr in
                _ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            throw IPCError.bindFailed(errno)
        }

        // Set permissions on socket file
        chmod(socketPath, 0o600)

        // Listen for connections
        guard listen(socketFD, 5) == 0 else {
            throw IPCError.listenFailed(errno)
        }

        // Set non-blocking
        let flags = fcntl(socketFD, F_GETFL)
        _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)

        // Create dispatch source for accepting connections
        acceptSource = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: .main)
        acceptSource?.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        acceptSource?.setCancelHandler { [weak self] in
            if let fd = self?.socketFD, fd >= 0 {
                close(fd)
                self?.socketFD = -1
            }
        }
        acceptSource?.resume()
    }

    // MARK: - Connection Handling

    private func acceptConnection() {
        var clientAddr = sockaddr_un()
        var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                accept(socketFD, sockaddrPtr, &addrLen)
            }
        }

        guard clientFD >= 0 else {
            if errno != EWOULDBLOCK && errno != EAGAIN {
                logger.error("Failed to accept connection: \(errno)")
            }
            return
        }

        // Handle the connection in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.handleClient(clientFD)
        }
    }

    private func handleClient(_ clientFD: Int32) {
        defer { close(clientFD) }

        setNoSigPipe(clientFD)
        guard validatePeerIsSameUser(clientFD) else { return }

        do {
            // Read length prefix (4 bytes, little-endian u32)
            let lengthBytes = try readExact(clientFD, count: 4)
            let messageLength = UInt32(lengthBytes[0]) |
                (UInt32(lengthBytes[1]) << 8) |
                (UInt32(lengthBytes[2]) << 16) |
                (UInt32(lengthBytes[3]) << 24)

            guard messageLength <= 1024 * 1024 else {
                try sendResponseOrThrow(clientFD, response: IPCResponse(ok: false, error: "Request too large"))
                return
            }

            // Read the JSON message
            let messageData = Data(try readExact(clientFD, count: Int(messageLength)))

            // Parse and handle the request
            let response = try handleRequest(data: messageData)
            try sendResponseOrThrow(clientFD, response: response)
        } catch {
            logger.error("IPC socket request failed: \(error.localizedDescription)")
            sendErrorResponse(clientFD, message: "IPC error: \(error.localizedDescription)")
        }
    }

    private func handleRequest(data: Data) throws -> IPCResponse {
        do {
            let request = try JSONDecoder().decode(IPCRequest.self, from: data)

            guard request.version == 1 else {
                return IPCResponse(ok: false, error: "Unsupported protocol version")
            }

            switch request.action {
            case .new_window(let payload):
                return handleNewWindow(payload: payload)
            case .new_tab(let payload):
                return handleNewTab(payload: payload)
            }
        } catch {
            logger.error("Failed to parse IPC request: \(error.localizedDescription)")
            return IPCResponse(ok: false, error: "Invalid request: \(error.localizedDescription)")
        }
    }

    // MARK: - Action Handlers

    private func handleNewWindow(payload: IPCRequest.NewWindowPayload?) -> IPCResponse {
        let result: Result<Void, IPCError> = performOnMain { [weak self] in
            guard let self = self,
                  let appDelegate = self.appDelegate else {
                throw IPCError.appUnavailable
            }

            var config = Ghostty.SurfaceConfiguration()
            if let args = payload?.arguments {
                guard !args.isEmpty else { throw IPCError.invalidArguments }
                config.initialInput = "exec \(shellQuoteArguments(args))\n"
            }

            _ = TerminalController.newWindow(appDelegate.ghostty, withBaseConfig: config)
        }

        switch result {
        case .success:
            return IPCResponse(ok: true)
        case .failure(let err):
            return IPCResponse(ok: false, error: err.localizedDescription)
        }
    }

    private func handleNewTab(payload: IPCRequest.NewTabPayload?) -> IPCResponse {
        let result: Result<Void, IPCError> = performOnMain { [weak self] in
            guard let self = self,
                  let appDelegate = self.appDelegate else {
                throw IPCError.appUnavailable
            }

            var config = Ghostty.SurfaceConfiguration()
            if let args = payload?.arguments {
                guard !args.isEmpty else { throw IPCError.invalidArguments }
                config.initialInput = "exec \(shellQuoteArguments(args))\n"
            }

            // Get the preferred parent window for the new tab
            let parentWindow = TerminalController.preferredParent?.window

            _ = TerminalController.newTab(
                appDelegate.ghostty,
                from: parentWindow,
                withBaseConfig: config
            )
        }

        switch result {
        case .success:
            return IPCResponse(ok: true)
        case .failure(let err):
            return IPCResponse(ok: false, error: err.localizedDescription)
        }
    }

    // MARK: - Response Sending

    private func sendSuccessResponse(_ clientFD: Int32) {
        sendResponse(clientFD, response: IPCResponse(ok: true))
    }

    private func sendErrorResponse(_ clientFD: Int32, message: String) {
        sendResponse(clientFD, response: IPCResponse(ok: false, error: message))
    }

    private func sendResponse(_ clientFD: Int32, response: IPCResponse) {
        do {
            try sendResponseOrThrow(clientFD, response: response)
        } catch {
            logger.error("Failed to send response: \(error.localizedDescription)")
        }
    }

    private func sendResponseOrThrow(_ clientFD: Int32, response: IPCResponse) throws {
        let data = try JSONEncoder().encode(response)

        // Send length prefix (u32, little-endian)
        var length = UInt32(data.count).littleEndian
        try writeAll(clientFD, bytes: &length, count: MemoryLayout<UInt32>.size)

        // Send response data
        var sendError: Error? = nil
        data.withUnsafeBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            do {
                try writeAll(clientFD, bytes: baseAddress, count: data.count)
            } catch {
                sendError = error
            }
        }
        if let sendError { throw sendError }
    }

    // MARK: - Low-Level Socket Helpers

    private func setNoSigPipe(_ fd: Int32) {
        var yes: Int32 = 1
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &yes,
            socklen_t(MemoryLayout.size(ofValue: yes))
        )
    }

    private func validatePeerIsSameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        if getpeereid(fd, &uid, &gid) != 0 {
            logger.error("getpeereid failed: \(errno)")
            return false
        }

        if uid != getuid() {
            logger.error("IPC rejected connection from uid=\(uid)")
            return false
        }

        return true
    }

    private func readExact(_ fd: Int32, count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var totalRead = 0

        var readError: IPCError? = nil
        buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                readError = .readFailed(0)
                return
            }

            while totalRead < count {
                let n = recv(fd, base.advanced(by: totalRead), count - totalRead, 0)
                if n == 0 {
                    readError = .connectionClosed
                    return
                }
                if n < 0 {
                    if errno == EINTR { continue }
                    readError = .readFailed(errno)
                    return
                }
                totalRead += n
            }
        }
        if let readError { throw readError }

        return buffer
    }

    private func writeAll(_ fd: Int32, bytes: UnsafeRawPointer, count: Int) throws {
        var totalSent = 0
        while totalSent < count {
            let n = send(fd, bytes.advanced(by: totalSent), count - totalSent, 0)
            if n == 0 { throw IPCError.connectionClosed }
            if n < 0 {
                if errno == EINTR { continue }
                throw IPCError.sendFailed(errno)
            }
            totalSent += n
        }
    }

    private func performOnMain<T>(_ body: () throws -> T) -> Result<T, IPCError> {
        if Thread.isMainThread {
            return Result { try body() }.mapError { IPCError.from($0) }
        }

        var result: Result<T, IPCError>!
        DispatchQueue.main.sync {
            result = Result { try body() }.mapError { IPCError.from($0) }
        }
        return result
    }

    private func shellQuoteArguments(_ arguments: [String]) -> String {
        return arguments.map(shellQuote).joined(separator: " ")
    }

    private func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

// MARK: - Protocol Types

/// IPC request matching the Zig protocol.
struct IPCRequest: Decodable {
    let version: Int
    let action: Action
    let target: String?

    enum Action: Decodable {
        case new_window(NewWindowPayload?)
        case new_tab(NewTabPayload?)

        enum CodingKeys: String, CodingKey {
            case new_window
            case new_tab
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            if container.contains(.new_window) {
                let payload = try container.decodeIfPresent(NewWindowPayload.self, forKey: .new_window)
                self = .new_window(payload)
            } else if container.contains(.new_tab) {
                let payload = try container.decodeIfPresent(NewTabPayload.self, forKey: .new_tab)
                self = .new_tab(payload)
            } else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Unknown action"
                    )
                )
            }
        }
    }

    struct NewWindowPayload: Decodable {
        let arguments: [String]?
    }

    struct NewTabPayload: Decodable {
        let arguments: [String]?
    }
}

/// IPC response matching the Zig protocol.
struct IPCResponse: Encodable {
    let ok: Bool
    let error: String?
    let data: ResponseData?

    init(ok: Bool, error: String? = nil, data: ResponseData? = nil) {
        self.ok = ok
        self.error = error
        self.data = data
    }

    struct ResponseData: Encodable {
        let id: String?
    }
}

// MARK: - Errors

enum IPCError: Error {
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case pathTooLong
    case appUnavailable
    case invalidArguments
    case readFailed(Int32)
    case sendFailed(Int32)
    case connectionClosed

    static func from(_ error: Error) -> IPCError {
        if let err = error as? IPCError { return err }
        return .appUnavailable
    }

    var localizedDescription: String {
        switch self {
        case .socketCreationFailed(let e):
            return "Socket creation failed (errno=\(e))"
        case .bindFailed(let e):
            return "Socket bind failed (errno=\(e))"
        case .listenFailed(let e):
            return "Socket listen failed (errno=\(e))"
        case .pathTooLong:
            return "Socket path too long"
        case .appUnavailable:
            return "App not available"
        case .invalidArguments:
            return "Invalid arguments"
        case .readFailed(let e):
            return "Socket read failed (errno=\(e))"
        case .sendFailed(let e):
            return "Socket send failed (errno=\(e))"
        case .connectionClosed:
            return "Connection closed"
        }
    }
}
