import AppKit
import Darwin
import SwiftUI

struct SystemSample { let t: Date; let cpu: Double; let memGB: Double; let rxBps: Double; let txBps: Double }

final class SystemSampler {
    let totalMemGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    private var prevTicks: (busy: UInt64, total: UInt64)?
    private var prevNet: [String: (rx: UInt32, tx: UInt32)] = [:]
    private var prevNetAt: Date?

    func sample() -> SystemSample {
        let now = Date()
        let net = network(now, commit: true)
        return SystemSample(t: now, cpu: cpu(), memGB: memory(), rxBps: net.0, txBps: net.1)
    }

    /// % of the whole machine (100 = every core busy), from HOST_CPU_LOAD_INFO tick deltas.
    private func cpu() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let t = info.cpu_ticks
        let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)
        let total = busy + UInt64(t.2)
        defer { prevTicks = (busy, total) }
        guard let p = prevTicks, total > p.total else { return 0 }
        return Double(busy - p.busy) / Double(total - p.total) * 100
    }

    /// "Memory Used" as in Activity Monitor: app memory + wired + compressed.
    private func memory() -> Double {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        var page: vm_size_t = 0
        host_page_size(mach_host_self(), &page)
        let pages = UInt64(vm.internal_page_count) - UInt64(vm.purgeable_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)
        return Double(pages * UInt64(page)) / 1_073_741_824
    }

    private var lastRates: (Double, Double) = (0, 0)

    /// Bytes/s in and out over every non-loopback interface (32-bit if_data counters, wrap-safe).
    private func network(_ now: Date, commit: Bool = false) -> (Double, Double) {
        guard commit else { return lastRates }
        var ptr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ptr) == 0, let first = ptr else { return lastRates }
        defer { freeifaddrs(ptr) }
        var cur: [String: (rx: UInt32, tx: UInt32)] = [:]
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.pointee.ifa_data else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            if name.hasPrefix("lo") { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            cur[name] = (d.ifi_ibytes, d.ifi_obytes)
        }
        defer { prevNet = cur; prevNetAt = now }
        guard let at = prevNetAt else { return (0, 0) }
        let dt = now.timeIntervalSince(at)
        guard dt > 0.2 else { return lastRates }
        var rx: UInt64 = 0, tx: UInt64 = 0
        for (k, v) in cur {
            if let p = prevNet[k] { rx += UInt64(v.rx &- p.rx); tx += UInt64(v.tx &- p.tx) }
        }
        lastRates = (Double(rx) / dt, Double(tx) / dt)
        return lastRates
    }
}
