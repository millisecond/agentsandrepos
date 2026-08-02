import Darwin
import Foundation

/// Kernel process-table lookups: controlling tty and parent-pid walking.
/// Used to trace a Claude agent's pid up to the terminal app hosting it.
public enum ProcessTree {

    /// Controlling terminal device name, e.g. "ttys015", or nil for
    /// daemons/background processes with no tty.
    public static func ttyName(of pid: pid_t) -> String? {
        guard pid > 0, let info = kinfoProc(pid) else { return nil }
        let dev = info.kp_eproc.e_tdev
        // NODEV is (dev_t)-1; 0 would be /dev/console's major 0 minor 0 but
        // never a user terminal.
        guard dev != ~0, dev != 0 else { return nil }
        guard let name = devname(dev, S_IFCHR) else { return nil }
        return String(cString: name)
    }

    /// Immediate parent pid, or nil if the process is gone or has no parent.
    public static func parent(of pid: pid_t) -> pid_t? {
        guard pid > 0, let info = kinfoProc(pid) else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    /// Ancestor pids from nearest to farthest, stopping before launchd (1).
    /// Bounded to guard against pathological ppid cycles.
    public static func ancestors(of pid: pid_t, limit: Int = 32) -> [pid_t] {
        var out: [pid_t] = []
        var current = pid
        while out.count < limit, let ppid = parent(of: current), ppid > 1,
            !out.contains(ppid)
        {
            out.append(ppid)
            current = ppid
        }
        return out
    }

    private static func kinfoProc(_ pid: pid_t) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard rc == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return info
    }
}
