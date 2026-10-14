import AppKit
import Darwin
import SwiftUI

struct LiveSample { let t: Date; let cpu: Double; let memKB: Int }

final class LiveSampler {
    private var prev: [pid_t: (cpuTicks: UInt64, at: Date)] = [:]
    private let nsPerTick: Double

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        nsPerTick = Double(tb.numer) / Double(tb.denom)
    }

    /// root path → processes whose cwd is inside it, plus all their descendants.
    /// cpu = instantaneous % since the previous sample (100 = one full core); rss_kb = phys footprint.
    func sample(roots: [String], enrich: [Int: Proc]) -> [String: [Proc]] {
        let now = Date()
        let sortedRoots = roots.sorted { $0.count > $1.count }
        var bsd: [pid_t: proc_bsdinfo] = [:]
        var children: [pid_t: [pid_t]] = [:]
        var rootOf: [pid_t: String] = [:]
        for pid in Self.allPids() {
            guard let b = Self.bsdInfo(pid) else { continue }
            bsd[pid] = b
            children[pid_t(b.pbi_ppid), default: []].append(pid)
            if let cwd = Self.cwd(pid), let root = sortedRoots.first(where: { cwd == $0 || cwd.hasPrefix($0 + "/") }) {
                rootOf[pid] = root
            }
        }
        var isChild: [pid_t: Bool] = rootOf.mapValues { _ in false }
        var stack = Array(rootOf.keys)
        while let parent = stack.popLast() {
            for c in children[parent] ?? [] where rootOf[c] == nil {
                rootOf[c] = rootOf[parent]
                isChild[c] = true
                stack.append(c)
            }
        }

        var next: [pid_t: (UInt64, Date)] = [:]
        var out: [String: [Proc]] = [:]
        for (pid, root) in rootOf {
            guard let (ticks, footprint) = Self.usage(pid), let b = bsd[pid] else { continue }
            next[pid] = (ticks, now)
            var cpu = enrich[Int(pid)]?.cpu ?? 0
            if let p = prev[pid], ticks >= p.cpuTicks {
                let wall = now.timeIntervalSince(p.at)
                if wall > 0.2 { cpu = Double(ticks - p.cpuTicks) * nsPerTick / 1e9 / wall * 100 }
            }
            let name = Self.string(b.pbi_name).isEmpty ? Self.string(b.pbi_comm) : Self.string(b.pbi_name)
            let extra = enrich[Int(pid)]
            out[root, default: []].append(Proc(
                pid: Int(pid), name: name, cmd: extra?.cmd ?? name, ports: extra?.ports ?? [],
                etime: Self.elapsed(Int(now.timeIntervalSince1970) - Int(b.pbi_start_tvsec)),
                rss_kb: Int(footprint / 1024), cpu: cpu, child: isChild[pid] ?? false))
        }
        prev = next
        return out.mapValues { $0.sorted { ($0.rss_kb ?? 0) > ($1.rss_kb ?? 0) } }
    }

    static func allPids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        return buf.prefix(Int(max(got, 0))).filter { $0 > 0 }
    }

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return string(info.pvi_cdir.vip_path)
    }

    static func usage(_ pid: pid_t) -> (UInt64, UInt64)? {
        var ru = rusage_info_v2()
        let r = withUnsafeMutablePointer(to: &ru) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return r == 0 ? (ru.ri_user_time + ru.ri_system_time, ru.ri_phys_footprint) : nil
    }

    static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static func elapsed(_ s: Int) -> String {
        let d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60, sec = s % 60
        if d > 0 { return String(format: "%d-%02d:%02d:%02d", d, h, m, sec) }
        if h > 0 { return String(format: "%02d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }
}
