import Foundation

/// URLSession download with progress.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Failure: Error { case notFound }

    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var finished = false

    private init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    /// Downloads `url` to a temporary file the caller owns (and deletes). HTTP 404 throws `Failure.notFound`.
    static func fetch(_ url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let delegate = Downloader(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 404 {
            resume(.failure(Failure.notFound))
            return
        }
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            resume(.failure(URLError(.badServerResponse)))
            return
        }
        // The file is deleted when this method returns: move it first.
        let suffix = downloadTask.originalRequest?.url?.pathExtension ?? ""
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + (suffix.isEmpty ? "" : ".\(suffix)"))
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            resume(.success(kept))
        } catch {
            resume(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { resume(.failure(error)) }
    }

    private func resume(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        continuation?.resume(with: result)
    }
}
