import Darwin
import Foundation

enum SessionClaim {
    final class Token: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32?

        fileprivate init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        fileprivate func release() {
            lock.lock()
            defer { lock.unlock() }
            guard let descriptor else { return }
            self.descriptor = nil
            close(descriptor)
        }

        deinit {
            release()
        }
    }

    static func acquire(at url: URL) -> Token? {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return Token(descriptor: descriptor)
    }

    static func release(_ token: Token) {
        token.release()
    }
}
