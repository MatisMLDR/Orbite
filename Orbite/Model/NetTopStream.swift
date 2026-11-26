import Darwin
import Foundation
import os

nonisolated private let log = Logger(subsystem: "app.matis.Orbite", category: "nettop")

/// Runs `nettop` in logging mode and hands out one sample per second.
///
/// nettop only flushes its output line by line on a terminal, and it needs a quiet terminal on
/// stdin too: with /dev/null (always readable) it spins at more than 100 % CPU on keyboard input.
/// `script` gives it both: a pseudo-terminal that is its controlling terminal, so when Orbite dies
/// (even killed), script gets SIGPIPE, the terminal hangs up and nettop goes with it.
/// Its stdin is a pipe Orbite keeps open and never writes to. `-t external` leaves loopback out.
nonisolated final class NetTopStream: @unchecked Sendable {
    static let arguments = ["-t", "external", "-L", "0", "-s", "1", "-n", "-x", "-J", "interface,state,bytes_in,bytes_out,re-tx,rtt_avg"]
    /// How `ps` shows our nettop (it cuts its own -J argument at the first comma).
    private static let commandSignature = "-L 0 -s 1 -n -x -J interface"

    private let queue = DispatchQueue(label: "app.matis.Orbite.nettop", qos: .utility)
    private let onSample: @Sendable (NetTopSample) -> Void
    private let onStatus: @Sendable (String?) -> Void
    private var process: Process?
    /// Write end kept open so script never sees end of file on its input.
    private var input: Pipe?
    private var generation = 0
    private var parser = NetTopParser()
    private var pending = Data()
    private var flushWork: DispatchWorkItem?
    private var stopped = false

    init(onSample: @escaping @Sendable (NetTopSample) -> Void, onStatus: @escaping @Sendable (String?) -> Void) {
        self.onSample = onSample
        self.onStatus = onStatus
    }

    func start() {
        queue.async {
            self.stopped = false
            Self.killOrphans()
            self.launch()
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            flushWork?.cancel()
            flushWork = nil
            if let process, process.isRunning { process.terminate() }
            process = nil
            input = nil
        }
    }

    private func launch() {
        guard !stopped, process == nil else { return }
        let output = Pipe()
        let input = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        task.arguments = ["-q", "/dev/null", "/usr/bin/nettop"] + Self.arguments
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        task.standardInput = input
        task.environment = ["LC_ALL": "C", "TERM": "dumb"]
        task.terminationHandler = { [weak self] finished in
            guard let self else { return }
            self.queue.async {
                guard self.process === finished else { return }
                log.notice("nettop exited (\(finished.terminationStatus))")
                self.process = nil
                self.input = nil
                self.retry()
            }
        }
        do {
            try task.run()
        } catch {
            onStatus(String(localized: "nettop could not start: \(error.localizedDescription)"))
            retry()
            return
        }

        process = task
        self.input = input
        generation += 1
        let current = generation
        parser = NetTopParser()
        pending.removeAll(keepingCapacity: true)
        onStatus(nil)

        let descriptor = output.fileHandleForReading.fileDescriptor
        let reader = Thread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    let chunk = Data(buffer[0..<count])
                    self?.queue.async { self?.received(chunk, generation: current) }
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break // script exited
                }
            }
            try? output.fileHandleForReading.close()
        }
        reader.name = "nettop-reader"
        reader.qualityOfService = .utility
        reader.start()
    }

    private func retry() {
        guard !stopped else { return }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.launch() }
    }

    private func received(_ chunk: Data, generation current: Int) {
        guard current == generation, !stopped else { return }
        pending.append(chunk)
        processLines()
        // A sample arrives as one burst; a short pause means it is complete.
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let sample = self.parser.flush() else { return }
            self.onSample(sample)
        }
        flushWork = work
        queue.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func processLines() {
        guard let lastNewline = pending.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = pending[pending.startIndex...lastNewline]
        let text = String(decoding: complete, as: UTF8.self)
        pending.removeSubrange(pending.startIndex...lastNewline)
        for line in text.split(whereSeparator: \.isNewline) {
            if let sample = parser.consume(line) { onSample(sample) }
        }
    }

    /// A previous Orbite that crashed leaves its nettop to launchd: end it.
    private static func killOrphans() {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axww", "-o", "pid=,ppid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        for line in output.split(separator: "\n") where line.contains("/usr/bin/nettop") && line.contains(commandSignature) {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = pid_t(fields[0]), fields[1] == "1" else { continue }
            log.notice("ending orphan nettop \(pid)")
            kill(pid, SIGTERM)
        }
    }
}
