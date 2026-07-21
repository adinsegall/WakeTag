import Foundation
#if canImport(CoreNFC)
import CoreNFC
#endif

enum NFCScanError: LocalizedError {
    case unavailable
    case userCanceled
    case timeout
    case system(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "NFC isn't available on this device."
        case .userCanceled: "Scan canceled."
        case .timeout: "The scan timed out. Try again."
        case .system(let message): message
        }
    }
}

/// One-shot NFC tag reader. Create an instance, await a scan, let it go.
///
/// `scanTag` returns the factory UID of whatever supported tag is presented
/// (used at registration). `scanForMatch` keeps the session polling until the
/// tag with the expected UID is presented, the user cancels, or the ~60 s
/// system window ends (used to silence a ringing alarm).
final class NFCService: NSObject {

    static var isAvailable: Bool {
        #if canImport(CoreNFC)
        return NFCTagReaderSession.readingAvailable
        #else
        return false
        #endif
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var expectedUID: String?
    #if canImport(CoreNFC)
    private var session: NFCTagReaderSession?
    #endif

    /// Scan any supported tag and return its UID as uppercase hex.
    func scanTag(prompt: String = "Hold your iPhone near the tag.") async throws -> String {
        try await beginSession(prompt: prompt, expectedUID: nil)
    }

    /// Scan until the tag matching `expectedUID` is presented.
    func scanForMatch(expectedUID: String, prompt: String) async throws {
        _ = try await beginSession(prompt: prompt, expectedUID: expectedUID)
    }

    private func beginSession(prompt: String, expectedUID: String?) async throws -> String {
        #if targetEnvironment(simulator)
        // No NFC hardware in the simulator: simulate a successful scan so the
        // full alarm flow stays testable end-to-end.
        try? await Task.sleep(for: .seconds(1.2))
        return expectedUID ?? "04A2246AB37381"
        #else
        #if canImport(CoreNFC)
        guard Self.isAvailable else { throw NFCScanError.unavailable }
        self.expectedUID = expectedUID?.uppercased()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            guard let session = NFCTagReaderSession(pollingOption: [.iso14443, .iso15693],
                                                    delegate: self, queue: nil) else {
                finish(.failure(NFCScanError.unavailable))
                return
            }
            session.alertMessage = prompt
            self.session = session
            session.begin()
        }
        #else
        throw NFCScanError.unavailable
        #endif
        #endif
    }

    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

#if canImport(CoreNFC) && !targetEnvironment(simulator)
extension NFCService: NFCTagReaderSessionDelegate {

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let tag = tags.first else {
            session.restartPolling()
            return
        }

        let uidData: Data
        switch tag {
        case .miFare(let mifare): uidData = mifare.identifier
        case .iso15693(let iso15693): uidData = iso15693.identifier
        default:
            // ISO7816/FeliCa tags require extra Info.plist keys to even be
            // delivered by CoreNFC; WakeTag supports NTAG/MIFARE + ISO15693.
            session.invalidate(errorMessage: "Unsupported tag type — use an NTAG213/215/216 tag.")
            return
        }

        let uid = uidData.map { String(format: "%02X", $0) }.joined()

        if let expected = expectedUID, uid != expected {
            session.alertMessage = "Wrong tag — scan the tag you registered."
            session.restartPolling()
            return
        }

        // Confirm the tag is still in the field before accepting the read.
        session.connect(to: tag) { [weak self] error in
            if error != nil {
                session.restartPolling()
                return
            }
            session.alertMessage = "Tag verified."
            session.invalidate()
            self?.finish(.success(uid))
        }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        self.session = nil
        let mapped: NFCScanError
        if let readerError = error as? NFCReaderError {
            switch readerError.code {
            case .readerSessionInvalidationErrorUserCanceled: mapped = .userCanceled
            case .readerSessionInvalidationErrorSessionTimeout: mapped = .timeout
            default: mapped = .system(readerError.localizedDescription)
            }
        } else {
            mapped = .system(error.localizedDescription)
        }
        finish(.failure(mapped))
    }
}
#endif
