import Foundation

/// How much memory this process is actually using, and how close it is to being
/// killed for it.
///
/// A keyboard extension's ceiling is not published and has moved between releases,
/// so the only trustworthy figure is the one measured on the device in question.
public enum MemoryProbe {
    /// Bytes this process has resident. `phys_footprint` is what the system judges,
    /// not `resident_size`, which undercounts.
    public static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }

        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// What the system will let this process have before killing it.
    public static func limit() -> UInt64 {
        UInt64(ProcessInfo.processInfo.physicalMemory)
    }

    public static func describe(_ stage: String) -> String {
        let megabytes = Double(footprint()) / 1_048_576
        return String(format: "%@: %.1f MB", stage, megabytes)
    }
}
