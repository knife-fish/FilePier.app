import Foundation
import Testing
@testable import FilePier

nonisolated private final class DownloadCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}

private final class ReplacementURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.value(forHTTPHeaderField: "X-Replacement-Outcome") == "failure" {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let body = Data("replacement".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

nonisolated private final class DownloadClientBox: @unchecked Sendable {
    let client: any RemoteClient
    init(_ client: any RemoteClient) { self.client = client }
}

@MainActor
struct DownloadReplacementTests {
    @Test(arguments: ["s3", "webdav"], ["failure", "cancelled", "success"])
    func overwritePublishesOnlySuccessfulUncancelledDownloads(backend: String, outcome: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("file.txt")
        try "original".write(to: destination, atomically: true, encoding: .utf8)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReplacementURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Replacement-Outcome": outcome]
        let config = RemoteConnectionConfig(connectionKind: backend == "s3" ? .cloud : .webdav,
            host: "https://replacement.example.com", port: 443, username: "access", authenticationMode: .password,
            privateKeyPath: nil, publicKeyPath: nil, password: "secret", addressPreference: .automatic, s3Region: nil)
        let client: any RemoteClient
        if backend == "s3" {
            client = LibraryBackedS3RemoteClient(config: config,
                transport: S3HTTPSession(config: config, urlSessionConfiguration: configuration))
        } else {
            client = LibraryBackedWebDAVRemoteClient(config: config,
                transport: WebDAVHTTPSession(config: config, urlSessionConfiguration: configuration))
        }
        let cancellation = DownloadCancellationFlag()
        let clientBox = DownloadClientBox(client)
        let failed = await Task.detached {
            do {
                _ = try clientBox.client.downloadItem(named: "file.txt", at: "/bucket/file.txt", toDirectory: root,
                    localFileTransfer: LocalFileTransferService(), conflictPolicy: .overwrite,
                    progress: { progress in
                        if outcome == "cancelled", progress.completedByteCount > 0 { cancellation.cancel() }
                    }, isCancelled: { cancellation.isCancelled })
                return false
            } catch {
                return true
            }
        }.value
        #expect(failed == (outcome != "success"))
        #expect(try String(contentsOf: destination, encoding: .utf8) == (outcome == "success" ? "replacement" : "original"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["file.txt"])
    }

    @Test func cancelledPartialAndDestinationRaceLeaveExistingFilesUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("file.txt")
        try "original".write(to: destination, atomically: true, encoding: .utf8)
        let cancellation = DownloadCancellationFlag()
        #expect(throws: CancellationError.self) {
            try LocalFileTransferService().downloadSafely(to: destination, overwrite: true,
                isCancelled: { cancellation.isCancelled }) { staged in
                try "partial".write(to: staged, atomically: true, encoding: .utf8)
                cancellation.cancel()
            }
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
        #expect(throws: (any Error).self) {
            try LocalFileTransferService().downloadSafely(to: destination, overwrite: false, isCancelled: nil) { staged in
                try "new".write(to: staged, atomically: true, encoding: .utf8)
            }
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["file.txt"])
    }
}
