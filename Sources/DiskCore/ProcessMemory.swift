import Darwin

public enum ProcessMemory {
    /// Lifetime bytes read by this process according to macOS task accounting.
    /// This includes cached reads only when the operating system accounts for them.
    public static func diskReadBytes() -> UInt64? {
        // v2 exposes disk I/O on every supported macOS version; avoid binding
        // runtime support to the newest structure in the build SDK.
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self,
                                     capacity: MemoryLayout<rusage_info_v2>.size / MemoryLayout<rusage_info_t?>.stride) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return nil }
        return usage.ri_diskio_bytesread
    }

    /// Resident bytes for this process at the instant of the call.
    public static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
    }

    /// Lifetime peak resident bytes reported for this process by getrusage.
    public static func peakResidentBytes() -> UInt64? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0, usage.ru_maxrss >= 0 else { return nil }
        return UInt64(usage.ru_maxrss)
    }
}

public enum DiskReadMetric {
    /// A counter reset or unavailable pair has no comparable read total.
    public static func bytesRead(from start: UInt64?, to end: UInt64?) -> UInt64? {
        guard let start, let end, end >= start else { return nil }
        return end - start
    }

    /// Uses decimal megabytes so the user-facing unit is MB/s.
    public static func megabytesPerSecond(bytesRead: UInt64?, elapsed: Double) -> Double? {
        guard let bytesRead, elapsed.isFinite, elapsed > 0 else { return nil }
        return Double(bytesRead) / 1_000_000 / elapsed
    }
}
