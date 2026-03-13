import Foundation

/// Handles {"cmd": "memory"} — process memory stats.
///
/// Commands:
///   {"cmd":"memory"}
///   {"cmd":"memory","params":{"action":"snapshot"}}
///     → Memory footprint, resident/virtual size
///
///   {"cmd":"memory","params":{"action":"vm"}}
///     → Detailed VM info (internal, compressed, purgeable)
struct MemoryHandler: PepperHandler {
    let commandName = "memory"

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "snapshot"

        switch action {
        case "snapshot":
            return handleSnapshot(command)
        case "vm":
            return handleVM(command)
        default:
            return .error(id: command.id, message: "Unknown action '\(action)'. Available: snapshot, vm")
        }
    }

    // MARK: - Snapshot (primary — used by builder panel polling)

    private func handleSnapshot(_ command: PepperCommand) -> PepperResponse {
        var basicInfo = mach_task_basic_info()
        var basicCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let basicResult = withUnsafeMutablePointer(to: &basicInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &basicCount)
            }
        }

        guard basicResult == KERN_SUCCESS else {
            return .error(id: command.id, message: "task_info failed: \(basicResult)")
        }

        let footprint = getPhysFootprint()

        var data: [String: AnyCodable] = [
            "resident_mb": AnyCodable(mbRound(basicInfo.resident_size)),
            "virtual_mb": AnyCodable(mbRound(basicInfo.virtual_size)),
            "timestamp_ms": AnyCodable(Int(Date().timeIntervalSince1970 * 1000)),
        ]

        if let fp = footprint {
            data["footprint_mb"] = AnyCodable(mbRound(fp))
        }

        return .ok(id: command.id, data: data)
    }

    // MARK: - VM detail

    private func handleVM(_ command: PepperCommand) -> PepperResponse {
        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let vmResult = withUnsafeMutablePointer(to: &vmInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &vmCount)
            }
        }

        guard vmResult == KERN_SUCCESS else {
            return .error(id: command.id, message: "task_vm_info failed: \(vmResult)")
        }

        return .ok(id: command.id, data: [
            "phys_footprint_mb": AnyCodable(mbRound(vmInfo.phys_footprint)),
            "internal_mb": AnyCodable(mbRound(vmInfo.internal)),
            "compressed_mb": AnyCodable(mbRound(vmInfo.compressed)),
            "purgeable_mb": AnyCodable(mbRound(vmInfo.purgeable_volatile_resident)),
            "timestamp_ms": AnyCodable(Int(Date().timeIntervalSince1970 * 1000)),
        ])
    }

    // MARK: - Helpers

    private func getPhysFootprint() -> UInt64? {
        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &vmInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &vmCount)
            }
        }
        return result == KERN_SUCCESS ? vmInfo.phys_footprint : nil
    }

    private func mbRound<T: BinaryInteger>(_ bytes: T) -> Double {
        round(Double(bytes) / 1_048_576 * 100) / 100
    }
}
