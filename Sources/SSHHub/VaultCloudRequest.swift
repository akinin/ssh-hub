import Foundation

struct VaultCloudAuthenticationRequired: LocalizedError {
    var errorDescription: String? { "Вход не выполнен или сеанс истёк. Проверь логин и пароль и войди заново." }
}

// Native HTTPS only, system TLS validation, bounded replies, no redirects,
// cookies, credential storage, caching or raw server diagnostics in errors.
final class VaultCloudRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let mutex = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Data, Error>?
    private var output = Data()
    private var status = 0
    private var cancelled = false
    private var oversized = false
    func cancel() { mutex.lock(); cancelled = true; let task = task; mutex.unlock(); task?.cancel() }
    func run(url: URL, token: String?, data: Data) async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                mutex.lock(); defer { mutex.unlock() }
                guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
                let config = URLSessionConfiguration.ephemeral
                config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
                config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 60
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session; self.continuation = continuation
                var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = data
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
                let task = session.dataTask(with: request); self.task = task; task.resume()
            }
        }, onCancel: { self.cancel() })
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        mutex.lock(); defer { mutex.unlock() }
        guard let response = response as? HTTPURLResponse, response.expectedContentLength <= 6 * 1024 * 1024 else { oversized = true; completionHandler(.cancel); return }
        status = response.statusCode; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        mutex.lock(); defer { mutex.unlock() }
        if output.count + data.count > 6 * 1024 * 1024 { oversized = true; dataTask.cancel() } else { output.append(data) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        mutex.lock(); let continuation = self.continuation; self.continuation = nil; self.task = nil
        let output = output, status = status, stopped = cancelled, oversized = oversized
        self.output = Data(); self.session = nil; mutex.unlock(); session.finishTasksAndInvalidate()
        guard let continuation else { return }
        if stopped { continuation.resume(throwing: CancellationError()) }
        else if oversized { continuation.resume(throwing: VaultError.message("Ответ сервера превышает допустимый размер.")) }
        else if error != nil { continuation.resume(throwing: VaultError.message("Не удалось подключиться по HTTPS. Проверь сеть/VPN, DNS и сертификат сервера.")) }
        else if status == 401 { continuation.resume(throwing: VaultCloudAuthenticationRequired()) }
        else if status == 429 { continuation.resume(throwing: VaultError.message("Слишком много попыток. Повтори вход позже.")) }
        else if !(200...299).contains(status) { continuation.resume(throwing: VaultError.message("Сервер отклонил действие (HTTP \(status)).")) }
        else { continuation.resume(returning: output) }
    }
}
