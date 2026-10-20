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

    func usage(since previous: CPUTicks) -> Double {
        let busy = UInt64(user &- previous.user) + UInt64(system &- previous.system) + UInt64(nice &- previous.nice)
        let total = busy + UInt64(idle &- previous.idle)
        return total == 0 ? 0 : Double(busy) / Double(total)
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
        let usage = cpu.map { ticks.usage(since: $0) } ?? 0
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
        return ScriptOutput(text: "\(Int(usage * 100))%", icon: "cpu", value: usage,
                            fields: ["cpu": String(Int(usage * 100)), "memory": String(Int(used / total * 100))],
                            values: ["cpu": usage, "memory": used / total, "memoryUsed": used, "memoryTotal": total])
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
