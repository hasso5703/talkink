import Foundation
import Metal

/// Pre-flight verdict before loading a model into unified memory.
public enum MemoryVerdict: Equatable, Sendable {
    case ok
    /// Loadable, but the system is under pressure — warn, then proceed.
    case tight(message: String)
    /// Loading would exceed what this Mac can hold — refuse with guidance.
    case insufficient(message: String)
}

public enum PreflightError: LocalizedError, Equatable {
    case notEnoughDisk(neededGB: Double, freeGB: Double)
    case notEnoughMemory(String)

    public var errorDescription: String? {
        switch self {
        case .notEnoughDisk(let needed, let free):
            return String(format: "Not enough disk space: needs ~%.1f GB more, %.1f GB free.", needed, free)
        case .notEnoughMemory(let message):
            return message
        }
    }
}

/// What this Mac can actually hold. MLX runs on unified memory, so the real
/// ceilings are the Metal working-set limit (per-process GPU-visible memory)
/// and whatever RAM the rest of the system isn't using.
public enum SystemResources {

    public static var physicalMemoryBytes: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    /// Free + inactive + purgeable + speculative pages — the "could be ours"
    /// pool, close to Activity Monitor's available memory. Conservative by
    /// nature: compressed memory could also be reclaimed under pressure.
    public static func availableMemoryBytes() -> UInt64? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pageSize = UInt64(vm_kernel_page_size)
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count)
            + UInt64(stats.purgeable_count) + UInt64(stats.speculative_count)
        return pages * pageSize
    }

    /// Metal's recommended per-process working set (≈ 70–75% of RAM on Apple
    /// Silicon). Weights beyond this won't fit on the GPU.
    public static func metalWorkingSetBytes() -> UInt64? {
        MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize
    }

    public static func freeDiskBytes(for url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Disk verdict

    /// Default headroom kept free on top of the download. `freeDiskBytes` uses
    /// `volumeAvailableCapacityForImportantUsage`, which counts purgeable space
    /// and so runs ~1 GB optimistic (measured on a real volume); this margin
    /// absorbs that so a "there's room" verdict is honest, not borrowed from
    /// caches the OS may or may not reclaim in time.
    public static let diskMarginBytes: Int64 = 1_000_000_000

    /// Pure disk pre-flight, injectable for tests. Returns the error to surface
    /// (and throw), or nil when the download fits with margin to spare.
    /// `neededBytes` is what's left to fetch (total size minus partial bytes).
    public static func diskPreflight(
        neededBytes: Int64,
        freeBytes: Int64,
        marginBytes: Int64 = diskMarginBytes
    ) -> PreflightError? {
        guard freeBytes < neededBytes + marginBytes else { return nil }
        return .notEnoughDisk(neededGB: Double(neededBytes) / 1_000_000_000,
                              freeGB: Double(freeBytes) / 1_000_000_000)
    }

    // MARK: Memory verdict

    /// Runtime need beyond the raw weights: activations, tokenizer, the app
    /// itself. Calibrated against `--memtest` (1.7B-8bit ≈ weights + ~0.4 GB
    /// in MLX, plus the app's own footprint).
    public static func estimatedRuntimeBytes(forWeightsGB sizeGB: Double) -> UInt64 {
        UInt64((sizeGB * 1.2 + 0.6) * 1_073_741_824)
    }

    /// Pure decision, injectable for tests. `available == nil` skips the
    /// pressure check (host_statistics can fail; never block on missing info).
    public static func memoryVerdict(
        neededBytes: UInt64,
        physicalBytes: UInt64,
        availableBytes: UInt64?,
        metalLimitBytes: UInt64?
    ) -> MemoryVerdict {
        let neededGB = Double(neededBytes) / 1_073_741_824
        let physicalGB = Double(physicalBytes) / 1_073_741_824
        if let metal = metalLimitBytes, neededBytes > metal {
            return .insufficient(message: String(
                format: "This model needs ~%.1f GB of memory: more than this Mac (%.0f GB) can give one app. Pick a smaller model.",
                neededGB, physicalGB))
        }
        if neededBytes > physicalBytes {
            return .insufficient(message: String(
                format: "This model needs ~%.1f GB of memory but this Mac has %.0f GB. Pick a smaller model.",
                neededGB, physicalGB))
        }
        if let available = availableBytes, neededBytes > available {
            let availableGB = Double(available) / 1_073_741_824
            return .tight(message: String(
                format: "Memory is tight: ~%.1f GB needed, ~%.1f GB free right now. Closing other apps will help.",
                neededGB, availableGB))
        }
        return .ok
    }

    /// Convenience using the live machine values.
    public static func memoryVerdict(forWeightsGB sizeGB: Double) -> MemoryVerdict {
        memoryVerdict(
            neededBytes: estimatedRuntimeBytes(forWeightsGB: sizeGB),
            physicalBytes: physicalMemoryBytes,
            availableBytes: availableMemoryBytes(),
            metalLimitBytes: metalWorkingSetBytes()
        )
    }
}
