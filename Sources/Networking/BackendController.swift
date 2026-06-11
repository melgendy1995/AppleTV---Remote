import Foundation
import SwiftUI
import Darwin

/// Manages the lifecycle of the bundled Python backend that ships inside the
/// macOS .app's Resources. Picks a free port, spawns ``python -m uvicorn``,
/// waits for the FastAPI ``/api/status`` to respond, and terminates the
/// subprocess on app quit.
@MainActor
final class BackendController: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case running(port: Int)
        case failed(message: String)
        case external   // user pointed at an external backend; we don't manage it
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var stderrTail: String = ""

    private var process: Process?
    private var stderrPipe: Pipe?

    private let baseURL: URL? = nil

    /// Embedded backend URL once running; nil otherwise.
    var embeddedURL: URL? {
        if case let .running(port) = state {
            return URL(string: "http://127.0.0.1:\(port)")
        }
        return nil
    }

    var isEmbeddedAvailable: Bool {
        Bundle.main.url(forResource: "python/bin/python3", withExtension: nil, subdirectory: "Vendor") != nil
    }

    /// Start the bundled backend. No-op if Vendor/ isn't present (dev builds).
    func startIfEmbedded() async {
        guard state == .idle else { return }
        guard isEmbeddedAvailable else {
            state = .external
            return
        }
        await start()
    }

    func start() async {
        state = .starting
        guard let pythonURL = Bundle.main.url(forResource: "python/bin/python3", withExtension: nil, subdirectory: "Vendor"),
              let backendDir = Bundle.main.url(forResource: "backend", withExtension: nil, subdirectory: "Vendor") else {
            state = .failed(message: "Bundled Python or backend not found in .app/Contents/Resources/Vendor/")
            return
        }

        let port = pickFreePort() ?? 28473  // fallback
        let p = Process()
        p.executableURL = pythonURL
        p.arguments = [
            "-m", "uvicorn",
            "app.main:app",
            "--host", "127.0.0.1",
            "--port", String(port),
            "--app-dir", backendDir.path,
            "--log-level", "info",
        ]
        // Make sure the bundled Python finds its stdlib + site-packages.
        var env = ProcessInfo.processInfo.environment
        env["PYTHONHOME"] = pythonURL.deletingLastPathComponent().deletingLastPathComponent().path
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env

        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe
        stderrPipe = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let s = String(data: data, encoding: .utf8) {
                Task { @MainActor in
                    // Keep only the last ~4 KB so we don't grow forever.
                    let combined = (self?.stderrTail ?? "") + s
                    self?.stderrTail = String(combined.suffix(4096))
                }
            }
        }

        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                // If we weren't already failed, this is unexpected exit.
                if case .running = self.state {
                    self.state = .failed(message: "Backend exited with code \(proc.terminationStatus)")
                }
            }
        }

        do {
            try p.run()
            process = p
        } catch {
            state = .failed(message: "Failed to launch backend: \(error.localizedDescription)")
            return
        }

        // Probe until /api/status answers (or give up after ~12s).
        let probeURL = URL(string: "http://127.0.0.1:\(port)/api/status")!
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if !(process?.isRunning ?? false) {
                state = .failed(message: "Backend exited before becoming ready.\n\n\(stderrTail)")
                return
            }
            var req = URLRequest(url: probeURL)
            req.timeoutInterval = 1.0
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               !data.isEmpty {
                state = .running(port: port)
                return
            }
        }
        state = .failed(message: "Backend did not become ready in time.\n\n\(stderrTail)")
        stop()
    }

    func stop() {
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let p = process, p.isRunning {
            p.terminate()
            // Best-effort wait without blocking the main actor for long.
            DispatchQueue.global().async {
                let deadline = Date().addingTimeInterval(2)
                while p.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if p.isRunning {
                    kill(p.processIdentifier, SIGKILL)
                }
            }
        }
        process = nil
        if state != .external { state = .idle }
    }

    // MARK: - Port discovery

    private func pickFreePort() -> Int? {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0  // kernel picks
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let _ = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(sock, sa, &len)
            }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
