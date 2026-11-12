import Foundation

/// Per-process CPU, memory, threads and I/O.
///
/// Concurrency: every method runs on `SamplingCore`'s serial queue. See
/// `MetricSource` for the full contract, including the rule that a failed syscall
/// must surface as `.failure`, never as a zeroed value.
public final class ProcessCollector: MetricSource {
    public typealias Output = ProcessSnapshot

    public let identifier: CollectorID = .processes
    public let preferredInterval: TimeInterval = 2.0

    /// How many rows reach the UI. The panel shows a dozen at a time and sorts within
    /// what it is given, so shipping every process would be work nobody looks at.
    private static let rowLimit = 50
    /// Ranked by CPU, the top 50 miss anything idle, and the biggest memory users
    /// usually are idle: an editor left open holds gigabytes at 0%. These extra rows
    /// are the largest footprints outside the CPU cut, so a memory-ranked list has
    /// the right processes to rank.
    private static let memoryRowLimit = 10
    /// How many apps reach the UI on each of the three figures they are ranked by.
    private static let appLimit = 8
    /// Distinct executables remembered before the table is rebuilt. A build can run
    /// thousands of short-lived tools from as many paths over a day.
    private static let appTableLimit = 4_096

    /// Cumulative per-process counters carried between samples, keyed by pid.
    private struct Baseline {
        var cpuTime: UInt64
        var diskRead: UInt64
        var diskWrite: UInt64
        /// Nanojoules the kernel has charged the process since it started.
        var energy: UInt64
        var hasIO: Bool
        var seenAt: UInt64
        /// Index into `apps` of the app this process belongs to. Resolved once, from
        /// its executable path, the first time the pid is seen.
        var app: Int32
    }

    /// Just enough to rank a process without building a String for one we will drop.
    private struct Candidate {
        var pid: pid_t
        var cpuPercent: Double
        /// phys_footprint, the figure Activity Monitor's "Memory" column shows: it
        /// counts compressed and IOKit-mapped pages and excludes shared clean ones,
        /// so it and the resident size disagree by hundreds of megabytes on browsers.
        var memoryBytes: UInt64
        var watts: Double?
        var readRate: Double?
        var writeRate: Double?
    }

    /// One app's processes, summed over a sample.
    private struct AppTotal {
        var processCount = 0
        var cpuPercent = 0.0
        var memoryBytes: UInt64 = 0
        var watts = 0.0
        var hasWatts = false
        var leaderPID: pid_t = 0
        var leaderCPU = -1.0
    }

    private var baselines: [pid_t: Baseline] = [:]
    private var generation: UInt64 = 0
    private var userNames: [uid_t: String] = [:]
    /// Mach absolute time ticks to seconds; fixed for the life of the process.
    private var tickSeconds: Double = 0
    private var pidBuffer: [pid_t] = []
    private var ownPIDBuffer: [pid_t] = []
    private var candidates: [Candidate] = []
    /// Every app or plain executable seen, by the path that identifies it.
    private var apps: [(path: String, name: String)] = []
    private var appIndex: [String: Int32] = [:]
    private var appTotals: [AppTotal] = []
    /// μStats itself. Counted in the totals but never listed: opening the panel is what
    /// makes it sample fast, so it would otherwise top the very list the user opened
    /// the panel to read, every time, for a cost they caused by looking.
    private let selfPID = getpid()
    private var host: host_t = 0
    /// Cleared for good the first time the kernel refuses the zone query.
    private var threadZoneReadable = true
    private var pathBuffer = [CChar]()

    public init() {}

    public func start() {
        var timebase = mach_timebase_info_data_t()
        if mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 {
            tickSeconds = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        }
        if host == 0 { host = mach_host_self() }
        pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        candidates.reserveCapacity(1024)
        baselines.removeAll(keepingCapacity: true)
        apps.removeAll(keepingCapacity: true)
        appIndex.removeAll(keepingCapacity: true)
        generation = 0
        threadZoneReadable = true
    }

    public func stop() {
        if host != 0 {
            mach_port_deallocate(mach_task_self_, host)
            host = 0
        }
        baselines = [:]
        userNames = [:]
        pidBuffer = []
        ownPIDBuffer = []
        candidates = []
        apps = []
        appIndex = [:]
        appTotals = []
        pathBuffer = []
    }

    public func collect(context: SampleContext) -> MetricState<ProcessSnapshot> {
        if tickSeconds == 0 { start() }

        guard let pidCount = listPIDs(&pidBuffer, filter: UInt32(PROC_ALL_PIDS), argument: 0) else {
            return .failure(.failed("proc_listpids failed: \(String(cString: strerror(errno)))"))
        }

        // Only same-uid processes are inspectable, and PROC_UID_ONLY reproduces
        // proc_pidinfo's permission check exactly, so filtering here drops ~230 calls
        // per sample that could only return EPERM. Elevated, everything is ours.
        let euid = geteuid()
        var ownCount = pidCount
        if euid != 0 {
            guard let own = listPIDs(&ownPIDBuffer, filter: UInt32(PROC_UID_ONLY), argument: euid) else {
                return .failure(.failed("proc_listpids failed: \(String(cString: strerror(errno)))"))
            }
            ownCount = own
        }

        // Cumulative CPU time is meaningless without a previous reading: dividing a
        // process's whole lifetime of CPU by one interval would rank long-running
        // daemons at thousands of percent.
        let rebaselining = context.isFirstSample || context.didWakeFromSleep || context.elapsed <= 0.001
        if context.didWakeFromSleep { baselines.removeAll(keepingCapacity: true) }

        generation &+= 1
        candidates.removeAll(keepingCapacity: true)
        if apps.count > Self.appTableLimit { forgetApps() }
        appTotals.removeAll(keepingCapacity: true)

        var taskInfo = proc_taskinfo()
        let taskInfoSize = Int32(MemoryLayout<proc_taskinfo>.size)
        var totalThreads = 0
        var inspected = 0

        for index in 0..<ownCount {
            let pid = euid == 0 ? pidBuffer[index] : ownPIDBuffer[index]
            guard pid > 0 else { continue }
            let read = withUnsafeMutablePointer(to: &taskInfo) {
                proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, taskInfoSize)
            }
            // Still possible to fail: the process may have exited since the pid list was
            // taken. Skip it rather than fail a sample over one dead pid.
            guard read == taskInfoSize else { continue }
            inspected += 1
            totalThreads += Int(taskInfo.pti_threadnum)
            guard pid != selfPID else { continue }

            // Mach absolute time units, despite the "time" naming — measured against a
            // process pinned to one core, treating them as nanoseconds understates CPU
            // by the timebase ratio (24x on Apple Silicon).
            let cpuTime = taskInfo.pti_total_user &+ taskInfo.pti_total_system
            let previous = baselines[pid]
            // A pid first seen this cycle has no delta to report. Zero is what Activity
            // Monitor shows for the same reason, and it corrects on the next sample.
            var percent = 0.0
            if let previous, !rebaselining, cpuTime >= previous.cpuTime {
                percent = Double(cpuTime - previous.cpuTime) * tickSeconds / context.elapsed * 100
            }

            // rusage for every process, not only the rows shown: an app is the sum of
            // its processes, and forty idle browser helpers never reach a top-fifty
            // list. Measured at 1.3 ms for 900 processes, against 0.4 ms for the task
            // info above; paid only while something is reading the process list.
            var memoryBytes = taskInfo.pti_resident_size
            var watts: Double?
            var readRate: Double?
            var writeRate: Double?
            var diskRead = previous?.diskRead ?? 0
            var diskWrite = previous?.diskWrite ?? 0
            var energy = previous?.energy ?? 0
            var hasIO = previous?.hasIO ?? false
            var usage = rusage_info_v6()
            // V6 rather than V4 for `ri_energy_nj`: the same call and the same copy,
            // with the energy the kernel's power model has charged the process.
            let usageOK = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            } == 0
            if usageOK {
                memoryBytes = usage.ri_phys_footprint
                if hasIO, !rebaselining {
                    if usage.ri_diskio_bytesread >= diskRead {
                        readRate = Double(usage.ri_diskio_bytesread - diskRead) / context.elapsed
                    }
                    if usage.ri_diskio_byteswritten >= diskWrite {
                        writeRate = Double(usage.ri_diskio_byteswritten - diskWrite) / context.elapsed
                    }
                    // Nanojoules over seconds is nanowatts. Average power over the
                    // interval, which is what "using significant energy" means; the
                    // instantaneous figure would rank whoever woke up last.
                    if usage.ri_energy_nj >= energy {
                        watts = Double(usage.ri_energy_nj - energy) / context.elapsed / 1_000_000_000
                    }
                }
                diskRead = usage.ri_diskio_bytesread
                diskWrite = usage.ri_diskio_byteswritten
                energy = usage.ri_energy_nj
                hasIO = true
            }
            let app = previous.flatMap { $0.app >= 0 ? $0.app : nil } ?? resolveApp(pid)
            baselines[pid] = Baseline(cpuTime: cpuTime, diskRead: diskRead, diskWrite: diskWrite,
                                      energy: energy, hasIO: hasIO, seenAt: generation, app: app)
            candidates.append(Candidate(pid: pid, cpuPercent: percent, memoryBytes: memoryBytes,
                                        watts: watts, readRate: readRate, writeRate: writeRate))
            total(app: app, pid: pid, cpuPercent: percent, memoryBytes: memoryBytes, watts: watts)
        }

        // Without this the dictionary would accumulate an entry for every process the
        // machine has ever run, which over days of uptime is tens of thousands.
        if baselines.count > inspected {
            let current = generation
            baselines = baselines.filter { $0.value.seenAt == current }
        }

        // See `CPUCollector`: a first sample with nothing to difference against is
        // pending, not failed.
        guard !rebaselining else {
            return .pending
        }

        candidates.sort { $0.cpuPercent > $1.cpuPercent }

        var rows: [ProcessRow] = []
        rows.reserveCapacity(Self.rowLimit + Self.memoryRowLimit)
        for candidate in candidates.prefix(Self.rowLimit) {
            if let row = buildRow(candidate) { rows.append(row) }
        }

        // Rows stay in CPU order end to end: the memory picks all sit below the CPU
        // cut by construction, and are re-sorted among themselves so the tail of the
        // list is ordered the same way as its head.
        if candidates.count > Self.rowLimit {
            candidates[Self.rowLimit...].sort { $0.memoryBytes > $1.memoryBytes }
            let tailEnd = min(candidates.count, Self.rowLimit + Self.memoryRowLimit)
            var tail = candidates[Self.rowLimit..<tailEnd].compactMap { buildRow($0) }
            tail.sort { $0.cpuPercent > $1.cpuPercent }
            rows.append(contentsOf: tail)
        }

        // `totalThreads` only covers processes this uid may inspect, which is ~60% of
        // them. The kernel's `threads` zone counts every live thread on the machine and
        // is what CPUSnapshot.threadCount reports — the two are shown side by side in
        // the UI, so they must not disagree by 40%. See CPUCollector for the caveats
        // on mach_zone_info; the summed figure is the fallback.
        return .value(ProcessSnapshot(processes: rows,
                                      apps: leadingApps(),
                                      totalProcessCount: pidCount,
                                      totalThreadCount: liveThreadCount() ?? totalThreads))
    }

    private func liveThreadCount() -> Int? {
        guard threadZoneReadable else { return nil }
        var names: mach_zone_name_array_t?
        var nameCount: mach_msg_type_number_t = 0
        var info: mach_zone_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard mach_zone_info(host, &names, &nameCount, &info, &infoCount) == KERN_SUCCESS,
              let names, let info else {
            threadZoneReadable = false
            return nil
        }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: names)),
                          vm_size_t(Int(nameCount) * MemoryLayout<mach_zone_name_t>.size))
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<mach_zone_info_t>.size))
        }
        for index in 0..<min(Int(nameCount), Int(infoCount)) {
            let isThreads = withUnsafeBytes(of: names[index].mzn_name) {
                $0.prefix { $0 != 0 }.elementsEqual("threads".utf8)
            }
            if isThreads { return Int(info[index].mzi_count) }
        }
        threadZoneReadable = false
        return nil
    }

    // MARK: Apps

    /// The app `pid` belongs to, as an index into `apps`, adding it when it is new.
    ///
    /// Everything under one `.app` is that app: Chrome's renderers, Xcode's compilers.
    /// A plain executable stands for itself, and every instance of it is one entry,
    /// so nine `swift-frontend` are one line and not nine.
    private func resolveApp(_ pid: pid_t) -> Int32 {
        let length = pathBuffer.withUnsafeMutableBufferPointer {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        let path: String
        let name: String
        if length > 0 {
            let executable = pathBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            (path, name) = AppUsage.identity(forExecutable: executable)
        } else {
            // No path to group by: the process is its own entry under its short name.
            name = ProcessName.of(pid) ?? "pid \(pid)"
            path = name
        }
        if let known = appIndex[path] { return known }
        let index = Int32(apps.count)
        apps.append((path, name))
        appIndex[path] = index
        return index
    }

    private func total(app: Int32, pid: pid_t, cpuPercent: Double, memoryBytes: UInt64, watts: Double?) {
        let index = Int(app)
        if appTotals.count <= index {
            appTotals.append(contentsOf: repeatElement(AppTotal(), count: index + 1 - appTotals.count))
        }
        appTotals[index].processCount += 1
        appTotals[index].cpuPercent += cpuPercent
        appTotals[index].memoryBytes += memoryBytes
        if let watts {
            appTotals[index].watts += watts
            appTotals[index].hasWatts = true
        }
        if cpuPercent > appTotals[index].leaderCPU {
            appTotals[index].leaderCPU = cpuPercent
            appTotals[index].leaderPID = pid
        }
    }

    /// The apps leading on CPU, memory or energy, in CPU order. An app that tops any
    /// one of the three is in the list, so whichever figure the reader sorts by has
    /// its leaders.
    private func leadingApps() -> [AppUsage] {
        let live = appTotals.indices.filter { appTotals[$0].processCount > 0 }
        var picked = Set<Int>()
        func take(_ areInOrder: (AppTotal, AppTotal) -> Bool) {
            picked.formUnion(live.sorted { areInOrder(appTotals[$0], appTotals[$1]) }.prefix(Self.appLimit))
        }
        take { $0.cpuPercent > $1.cpuPercent }
        take { $0.memoryBytes > $1.memoryBytes }
        take { $0.watts > $1.watts }
        return picked.map { index in
            let total = appTotals[index]
            return AppUsage(path: apps[index].path, name: apps[index].name,
                            processCount: total.processCount, cpuPercent: total.cpuPercent,
                            memoryBytes: total.memoryBytes,
                            watts: total.hasWatts ? total.watts : nil,
                            leaderPID: total.leaderPID)
        }.sorted { ($0.cpuPercent, $0.memoryBytes) > ($1.cpuPercent, $1.memoryBytes) }
    }

    /// Start the app table again. Every live pid re-resolves on the next sample.
    private func forgetApps() {
        apps.removeAll(keepingCapacity: true)
        appIndex.removeAll(keepingCapacity: true)
        for pid in baselines.keys { baselines[pid]?.app = -1 }
    }

    /// Second pass, run only for the rows that will actually be displayed: names and
    /// paths cost roughly as much again as ranking every process did.
    private func buildRow(_ candidate: Candidate) -> ProcessRow? {
        var all = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        let read = withUnsafeMutablePointer(to: &all) {
            proc_pidinfo(candidate.pid, PROC_PIDTASKALLINFO, 0, $0, size)
        }
        // The process exited between the two passes; drop it rather than invent a row.
        guard read == size else { return nil }

        let name = cString(all.pbsd.pbi_name).isEmpty
            ? cString(all.pbsd.pbi_comm)
            : cString(all.pbsd.pbi_name)

        let pathLength = pathBuffer.withUnsafeMutableBufferPointer {
            proc_pidpath(candidate.pid, $0.baseAddress, UInt32($0.count))
        }
        let path: String? = pathLength > 0
            ? pathBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            : nil

        let start = all.pbsd.pbi_start_tvsec > 0
            ? Date(timeIntervalSince1970: Double(all.pbsd.pbi_start_tvsec)
                   + Double(all.pbsd.pbi_start_tvusec) / 1_000_000)
            : nil

        return ProcessRow(pid: candidate.pid,
                          parentPID: pid_t(bitPattern: all.pbsd.pbi_ppid),
                          name: name,
                          executablePath: path,
                          cpuPercent: candidate.cpuPercent,
                          memoryBytes: candidate.memoryBytes,
                          threadCount: Int(all.ptinfo.pti_threadnum),
                          userName: userName(for: all.pbsd.pbi_uid),
                          startTime: start,
                          energyImpact: candidate.watts,
                          diskReadBytesPerSecond: candidate.readRate,
                          diskWriteBytesPerSecond: candidate.writeRate,
                          isAppleSignedSystem: path.map(Self.isSystemPath) ?? false)
    }

    /// Approximated from the executable's location rather than its signature: verifying
    /// a real code signature costs milliseconds per process, which is far beyond the
    /// budget for something sampled every two seconds. SIP owns these prefixes, so a
    /// binary living under one is Apple's.
    private static func isSystemPath(_ path: String) -> Bool {
        path.hasPrefix("/System/") || path.hasPrefix("/usr/lib") || path.hasPrefix("/usr/libexec/")
            || path.hasPrefix("/usr/sbin/") || path.hasPrefix("/usr/bin/")
            || path.hasPrefix("/sbin/") || path.hasPrefix("/bin/")
            || path.hasPrefix("/Library/Apple/")
    }

    private func userName(for uid: uid_t) -> String? {
        if let cached = userNames[uid] { return cached }
        // getpwuid hits Open Directory, so it is cached: a cold lookup can take
        // milliseconds and the uid of a running process never changes.
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else { return nil }
        let resolved = String(cString: name)
        userNames[uid] = resolved
        return resolved
    }

    private func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

}

/// Fills `buffer`, growing it as needed, and returns how many entries are valid.
private func listPIDs(_ buffer: inout [pid_t], filter: UInt32, argument: UInt32) -> Int? {
    if buffer.isEmpty { buffer = [pid_t](repeating: 0, count: 1024) }
    let pidSize = MemoryLayout<pid_t>.size
    while true {
        let bytes = buffer.withUnsafeMutableBufferPointer {
            proc_listpids(filter, argument, $0.baseAddress, Int32($0.count * pidSize))
        }
        guard bytes > 0 else { return nil }
        let count = Int(bytes) / pidSize
        // proc_listpids truncates silently, so an exactly-full buffer means the tail
        // of the process list was dropped.
        guard count == buffer.count else { return count }
        buffer = [pid_t](repeating: 0, count: buffer.count * 2)
    }
}
