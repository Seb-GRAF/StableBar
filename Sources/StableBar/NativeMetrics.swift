import AppKit
import Darwin
import EventKit
import Foundation

struct NetworkCounters: Sendable {
    let received: UInt64
    let sent: UInt64

    func rates(since previous: NetworkCounters, elapsed: Double) -> (download: Double, upload: Double) {
        let received = received >= previous.received ? received - previous.received : 0
        let sent = sent >= previous.sent ? sent - previous.sent : 0
        return (Double(received) / elapsed, Double(sent) / elapsed)
    }
}

struct CPUTicks: Sendable {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32

    /// The fractions of time spent running programs, including niced ones, and in the kernel.
    func usage(since previous: CPUTicks) -> (user: Double, system: Double) {
        let user = UInt64(user &- previous.user) + UInt64(nice &- previous.nice)
        let system = UInt64(system &- previous.system)
        let total = user + system + UInt64(idle &- previous.idle)
        return total == 0 ? (0, 0) : (Double(user) / Double(total), Double(system) / Double(total))
    }
}

/// A process's program, its memory footprint in bytes and the CPU time it has used in nanoseconds.
struct ProcessSample: Sendable {
    let pid: pid_t
    let path: String
    let memory: UInt64
    let cpuTime: UInt64
}

/// The `count` rows using the most memory and the most CPU. A process whose program lies inside the
/// bundle of a running app in `apps`, keyed by bundle path, adds to that app's row, which has the
/// app's PID; other processes have rows of their own. `cpu` holds each PID's share of one core.
func processLists(_ samples: [ProcessSample], cpu: [pid_t: Double], apps: [String: (pid: pid_t, name: String)],
                  count: Int) -> [String: [[String: String]]] {
    struct Row {
        let name: String
        let pid: pid_t
        let path: String
        var memory: UInt64 = 0
        var cpu = 0.0
    }
    var rows: [String: Row] = [:]
    for sample in samples {
        let bundle = sample.path.range(of: ".app/").map { String(sample.path[..<$0.lowerBound]) + ".app" }
        let key: String
        var row: Row
        if let bundle, let app = apps[bundle] {
            key = bundle
            row = rows[key] ?? Row(name: app.name, pid: app.pid, path: bundle)
        } else {
            key = String(sample.pid)
            row = Row(name: (sample.path as NSString).lastPathComponent, pid: sample.pid, path: sample.path)
        }
        row.memory += sample.memory
        row.cpu += cpu[sample.pid] ?? 0
        rows[key] = row
    }
    let fields = { (row: Row) in
        ["name": row.name, "pid": String(row.pid), "path": row.path, "cpu": String(Int(row.cpu * 100)),
         "memory": ByteCountFormatter.string(fromByteCount: Int64(row.memory), countStyle: .memory)]
    }
    return ["memory": rows.values.sorted { $0.memory != $1.memory ? $0.memory > $1.memory : $0.name < $1.name }.prefix(count).map(fields),
            "cpu": rows.values.sorted { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.name < $1.name }.prefix(count).map(fields)]
}

/// Samples your own processes off the main thread, where reading each one takes too long.
actor ProcessMetrics {
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
    private var times: [pid_t: UInt64] = [:]
    private var time: ContinuousClock.Instant?

    func lists(count: Int) -> [String: [[String: String]]] {
        var size = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size + 64)
        size = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        var samples: [ProcessSample] = []
        for pid in pids.prefix(Int(size) / MemoryLayout<pid_t>.size) {
            var usage = rusage_info_v0()
            let status = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V0, $0) }
            }
            guard status == 0, proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            samples.append(ProcessSample(pid: pid, path: path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }, memory: usage.ri_phys_footprint,
                                         cpuTime: (usage.ri_user_time + usage.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)))
        }
        let now = ContinuousClock.now
        var cpu: [pid_t: Double] = [:]
        if let time {
            let elapsed = time.duration(to: now) / .nanoseconds(1)
            for sample in samples {
                if let previous = times[sample.pid], sample.cpuTime >= previous { cpu[sample.pid] = Double(sample.cpuTime - previous) / elapsed }
            }
        }
        times = Dictionary(uniqueKeysWithValues: samples.map { ($0.pid, $0.cpuTime) })
        time = now
        let apps = Dictionary(NSWorkspace.shared.runningApplications.compactMap { app in
            app.bundleURL.map { ($0.resolvingSymlinksInPath().path, (pid: app.processIdentifier, name: app.localizedName ?? $0.deletingPathExtension().lastPathComponent)) }
        }) { first, _ in first }
        return processLists(samples, cpu: cpu, apps: apps, count: count)
    }
}

func networkCounters(_ data: Data) -> [UInt16: NetworkCounters] {
    var counters: [UInt16: NetworkCounters] = [:]
    data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let length = bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
            let type = bytes.load(fromByteOffset: offset + 3, as: UInt8.self)
            if type == RTM_IFINFO2 {
                let interface = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                if interface.ifm_flags & IFF_UP != 0 {
                    counters[interface.ifm_index] = NetworkCounters(received: interface.ifm_data.ifi_ibytes,
                                                                  sent: interface.ifm_data.ifi_obytes)
                }
            }
            offset += Int(length)
        }
    }
    return counters
}

func meetingCountdown(start: Date, end: Date, at date: Date, soon: Int, now: Int)
    -> (phase: String, minutes: Int, remaining: Double, target: Double, delay: Double) {
    let live = start <= date
    let left = (live ? end : start).timeIntervalSince(date)
    let span = live ? end.timeIntervalSince(start) : Double(soon * 60)
    let phase = live ? "live" : (left <= Double(now * 60) ? "now" : (left <= Double(soon * 60) ? "soon" : "later"))
    let second = left.truncatingRemainder(dividingBy: 60)
    return (phase, Int((left / 60).rounded(.up)), min(1, left / span), min(1, max(0, left - 60) / span), second == 0 ? 60 : second)
}

func meetingLink(_ texts: [String]) -> String? {
    texts.joined(separator: "\n")
        .firstMatch(of: #/https://(?:meet\.google\.com|(?:[a-z0-9-]+\.)*zoom\.us|teams\.microsoft\.com|teams\.live\.com)/[A-Za-z0-9._~%/?=&+#:@-]+/#)
        .map { String($0.output) }
}

actor CalendarMetrics {
    private lazy var eventStore: EKEventStore = {
        let store = EKEventStore()
        store.requestFullAccessToEvents { _, _ in }
        return store
    }()

    func read(_ provider: ProviderConfiguration) -> ScriptOutput {
        let store = eventStore
        let access = EKEventStore.authorizationStatus(for: .event)
        guard access == .fullAccess else {
            return ScriptOutput(text: "No calendar access", icon: "calendar", fields: ["access": access == .notDetermined ? "notDetermined" : "denied"])
        }
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let horizon = now.addingTimeInterval(provider.lookahead * 3600)
        let events = store.events(matching: store.predicateForEvents(withStart: today, end: max(tomorrow, horizon), calendars: nil))
            .filter { !$0.isAllDay && (provider.calendars.isEmpty || provider.calendars.contains($0.calendar.title)) }
            .sorted { $0.startDate < $1.startDate }
        let agenda = events.filter { $0.startDate < tomorrow }.map(meetingFields)
        guard let next = events.first(where: { $0.endDate > now && $0.startDate < horizon }) else {
            return ScriptOutput(text: "No meetings", icon: "calendar", fields: ["access": "granted", "phase": "none"], lists: ["today": agenda],
                                interval: 60 - now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60))
        }
        let countdown = meetingCountdown(start: next.startDate, end: next.endDate, at: now, soon: provider.soon, now: provider.now)
        var fields = meetingFields(next)
        fields["access"] = "granted"
        fields["phase"] = countdown.phase
        fields["minutes"] = String(countdown.minutes)
        return ScriptOutput(text: next.title, icon: "calendar", fields: fields, lists: ["today": agenda],
                            values: ["remaining": countdown.remaining], targets: ["remaining": countdown.target], interval: countdown.delay)
    }

    private func meetingFields(_ event: EKEvent) -> [String: String] {
        var fields: [String: String] = ["title": event.title, "start": event.startDate.formatted(date: .omitted, time: .shortened),
                                        "end": event.endDate.formatted(date: .omitted, time: .shortened)]
        if let link = meetingLink([event.url?.absoluteString, event.location, event.notes].compactMap { $0 }) {
            fields["link"] = link
            fields["joinCommand"] = "open '\(link)'"
        }
        return fields
    }
}

@MainActor
final class NativeMetrics {
    private var cpu: CPUTicks?
    private var network: [String: NetworkCounters] = [:]
    private var networkTime: ContinuousClock.Instant?

    func system() throws -> ScriptOutput {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var load = host_cpu_load_info()
        var loadCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let cpuStatus = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(loadCount)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &loadCount)
            }
        }
        guard cpuStatus == KERN_SUCCESS else { throw CommandFailure(message: "Could not read CPU statistics (\(cpuStatus)).") }
        let ticks = CPUTicks(user: load.cpu_ticks.0, system: load.cpu_ticks.1, idle: load.cpu_ticks.2, nice: load.cpu_ticks.3)
        let split = cpu.map { ticks.usage(since: $0) } ?? (user: 0, system: 0)
        let usage = split.user + split.system
        cpu = ticks
        var memory = vm_statistics64()
        var memoryCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let memoryStatus = withUnsafeMutablePointer(to: &memory) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(memoryCount)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &memoryCount)
            }
        }
        guard memoryStatus == KERN_SUCCESS else { throw CommandFailure(message: "Could not read memory statistics (\(memoryStatus)).") }
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        let used = (Double(memory.internal_page_count) + Double(memory.wire_count)
                    + Double(memory.compressor_page_count) - Double(memory.purgeable_count))
            * Double(getpagesize())
        let compressed = Double(memory.compressor_page_count) * Double(getpagesize())
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        var pressure: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0)
        var boot = timeval()
        var bootSize = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &boot, &bootSize, nil, 0)
        var averages = [Double](repeating: 0, count: 3)
        getloadavg(&averages, 3)
        let thermal = switch ProcessInfo.processInfo.thermalState {
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        default: "nominal"
        }
        let percent = { (fraction: Double) in String(Int(fraction * 100)) }
        let bytes = { (count: Double) in ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .memory) }
        let uptime = Duration.seconds(Date.now.timeIntervalSince1970 - Double(boot.tv_sec))
        return ScriptOutput(text: "\(Int(usage * 100))%", icon: "cpu", value: usage,
                            fields: ["cpu": percent(usage), "cpuUser": percent(split.user), "cpuSystem": percent(split.system),
                                     "memory": percent(used / total), "memoryUsed": bytes(used), "memoryCompressed": bytes(compressed),
                                     "swap": bytes(Double(swap.xsu_used)), "pressure": pressure == 4 ? "critical" : pressure == 2 ? "warning" : "normal",
                                     "load": averages.map { String(format: "%.2f", $0) }.joined(separator: " "), "thermal": thermal,
                                     "uptime": uptime.formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2))],
                            values: ["cpu": usage, "cpuUser": split.user, "cpuSystem": split.system, "memory": used / total,
                                     "memoryUsed": used, "memoryTotal": total])
    }

    func networkRates() throws -> ScriptOutput {
        var query: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&query, UInt32(query.count), nil, &size, nil, 0) == 0 else {
            throw CommandFailure(message: "Could not read network interfaces: \(String(cString: strerror(errno))).")
        }
        var data = Data(count: size)
        let status = data.withUnsafeMutableBytes { sysctl(&query, UInt32(query.count), $0.baseAddress, &size, nil, 0) }
        guard status == 0 else { throw CommandFailure(message: "Could not read network counters: \(String(cString: strerror(errno))).") }
        var current: [String: NetworkCounters] = [:]
        for (index, counters) in networkCounters(data.prefix(size)) {
            var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            if if_indextoname(UInt32(index), &name) != nil {
                let name = name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                if name.hasPrefix("en") { current[name] = counters }
            }
        }
        let now = ContinuousClock.now
        let elapsed = networkTime.map { Double($0.duration(to: now).components.seconds) + Double($0.duration(to: now).components.attoseconds) / 1e18 }
        var download = 0.0
        var upload = 0.0
        var interfaces: [[String: String]] = []
        for name in current.keys.sorted() {
            var rates = (download: 0.0, upload: 0.0)
            if let previous = network[name], let elapsed, elapsed > 0 {
                rates = current[name]!.rates(since: previous, elapsed: elapsed)
            }
            download += rates.download
            upload += rates.upload
            interfaces.append(["name": name, "download": String(Int(rates.download)), "upload": String(Int(rates.upload))])
        }
        network = current
        networkTime = now
        return ScriptOutput(text: "↓\(Int(download / 1024)) ↑\(Int(upload / 1024)) KiB/s", icon: "network",
                            fields: ["interface": current.keys.sorted().joined(separator: ", ")], lists: ["interfaces": interfaces],
                            values: ["download": download, "upload": upload])
    }
}
