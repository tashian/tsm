import Foundation
import Darwin

enum SocketError: Error {
    case createFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
}

extension Notification.Name {
    static let tsmdShutdown = Notification.Name("tsmdShutdown")
}

final class SocketServer: @unchecked Sendable {
    let socketPath: String
    let handler: JSONRPCHandler
    private var serverFd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "tsmd.socket", attributes: .concurrent)
    private let maxMessageSize = 1_048_576 // 1 MB
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(socketPath: String, handler: JSONRPCHandler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    // LOCAL_PEERPID gives the connecting peer's real PID; effective PID
    // (LOCAL_PEEREPID) is not relevant here because setsid affects real and
    // effective sessions equally and we want session-id resolution to follow
    // the peer's actual process, not whatever setuid masquerade is in effect.
    private func peerSessionID(fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        let rc = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len)
        guard rc == 0, pid > 0 else { return nil }
        let sid = getsid(pid)
        return sid > 0 ? sid : nil
    }

    func start() throws {
        unlink(socketPath)

        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )

        serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            throw SocketError.createFailed(errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for i in 0..<min(pathBytes.count, buf.count - 1) {
                buf[i] = UInt8(bitPattern: pathBytes[i])
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(serverFd)
            throw SocketError.bindFailed(errno)
        }

        chmod(socketPath, 0o700)

        guard listen(serverFd, 5) == 0 else {
            close(serverFd)
            throw SocketError.listenFailed(errno)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: serverFd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let clientFd = accept(self.serverFd, nil, nil)
            guard clientFd >= 0 else { return }
            guard let sid = self.peerSessionID(fd: clientFd) else {
                close(clientFd)
                return
            }
            Task { await self.handleConnection(clientFd, sessionID: sid) }
        }
        source.setCancelHandler { [serverFd = self.serverFd] in
            close(serverFd)
        }
        source.resume()
        readSource = source
    }

    func stop() {
        readSource?.cancel()
        readSource = nil
        unlink(socketPath)
    }

    private func handleConnection(_ fd: Int32, sessionID: pid_t) async {
        defer { close(fd) }

        var buffer = Data()
        let chunkSize = 4096
        var chunk = Data(count: chunkSize)

        while true {
            let bytesRead = chunk.withUnsafeMutableBytes { ptr in
                read(fd, ptr.baseAddress!, chunkSize)
            }
            if bytesRead <= 0 { break }
            buffer.append(chunk.prefix(bytesRead))

            if buffer.count > maxMessageSize {
                let errorResp = JSONRPCResponse(
                    error: JSONRPCError(code: RPCErrorCode.parseError, message: "Message too large"),
                    id: .null
                )
                writeResponse(errorResp, to: fd)
                return
            }

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = Data(buffer.prefix(upTo: newlineIndex))
                buffer = Data(buffer.suffix(from: buffer.index(after: newlineIndex)))

                guard let request = try? decoder.decode(JSONRPCRequest.self, from: lineData) else {
                    let errorResp = JSONRPCResponse(
                        error: JSONRPCError(code: RPCErrorCode.parseError, message: "Invalid JSON"),
                        id: .null
                    )
                    writeResponse(errorResp, to: fd)
                    continue
                }

                let response = await handler.handle(request, sessionID: sessionID)
                writeResponse(response, to: fd)

                if request.method == "daemon.shutdown" {
                    NotificationCenter.default.post(name: .tsmdShutdown, object: nil)
                }
            }
        }
    }

    private func writeResponse(_ response: JSONRPCResponse, to fd: Int32) {
        guard var data = try? encoder.encode(response) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { ptr in
            _ = write(fd, ptr.baseAddress!, data.count)
        }
    }
}
