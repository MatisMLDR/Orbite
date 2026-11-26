import Darwin
import Foundation

/// libproc and sysctl reads. Paths of other users' processes (root daemons) stay readable;
/// most other details do not.
nonisolated enum LibProc {
    static func path(of pid: pid_t) -> String {
        guard pid > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t

    /// `responsibility_get_pid_responsible_for_pid` (libquarantine): the app a helper process works for,
    /// e.g. Safari for its WebKit networking process.
    private static let responsibleFunction: ResponsibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    static func responsiblePID(of pid: pid_t) -> pid_t? {
        guard let function = responsibleFunction else { return nil }
        let responsible = function(pid)
        return responsible > 0 ? responsible : nil
    }

    /// Owner of any process (works for root daemons too).
    static func uid(of pid: pid_t) -> uid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ucred.cr_uid
    }

    static func userName(of uid: uid_t) -> String {
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else { return "\(uid)" }
        return String(cString: name)
    }
}
