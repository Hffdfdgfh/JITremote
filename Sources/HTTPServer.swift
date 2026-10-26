import Foundation
import Network

/// Tiny GET-only HTTP/1.1 server (enough for Shortcuts / browsers).
final class HTTPServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "jitremote.http")
    var onRequest: ((String) async -> (Int, String))?

    func start(port: UInt16) throws {
        stop()
        guard let p = NWEndpoint.Port(rawValue: port) else { throw RemoteError.message("bad port") }
        let l = try NWListener(using: .tcp, on: p)
        l.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self, let data, error == nil,
                  let text = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            let firstLine = text.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET" else {
                self.reply(conn, 405, "{\"ERROR\":\"GET only\"}")
                return
            }
            let path = String(parts[1])
            Task {
                let (status, body) = await self.onRequest?(path) ?? (500, "{\"ERROR\":\"no handler\"}")
                self.reply(conn, status, body)
            }
        }
    }

    private func reply(_ conn: NWConnection, _ status: Int, _ body: String) {
        let head = "HTTP/1.1 \(status) OK\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in conn.cancel() })
    }
}
