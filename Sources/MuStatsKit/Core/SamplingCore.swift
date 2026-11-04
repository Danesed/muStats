import Foundation
import IOKit.ps
import notify

/// Per-source scheduling state. Generic so each concrete collector keeps its
/// strong type all the way to the snapshot — no `Any` boxing on the hot path.
final class SourceSlot<Source: MetricSource> {
    let source: Source
    private(set) var state: MetricState<Source.Output> = .pending
    private var lastSampled: ContinuousClock.Instant?
    private var isStarted = false
    /// Set when the source reports `.unsupported`. We never call it again this
    /// session — that is the whole point of distinguishing unsupported from failed.
    private(set) var isRetired = false
    private var consecutiveFailures = 0
    private var retryNotBefore: ContinuousClock.Instant?

    init(_ source: Source) { self.source = source }

    var identifier: CollectorID { source.identifier }

    /// Runs the source if it is enabled and due. Returns true when `state` changed.
    @discardableResult
    func tick(now: ContinuousClock.Instant,
              activity: SamplingActivity,
              isEnabled: Bool,
              baseInterval: TimeInterval,
              didWakeFromSleep: Bool,
              force: Bool = false,
              thermalCadenceMultiplier: Double = 1) -> Bool {
        guard isEnabled, !isRetired, activity.isSampling else {
            if !isEnabled && isStarted { suspend() ; return false }
            return false
        }

        if !isStarted {
            source.start()
            isStarted = true
        }

        if !force, let retryNotBefore, now < retryNotBefore { return false }

        let interval = max(source.preferredInterval, baseInterval)
            * activity.cadenceMultiplier * thermalCadenceMultiplier
        let elapsed: TimeInterval
        if let lastSampled {
            elapsed = Monotonic.seconds(since: lastSampled)
            // Sample slightly early rather than slightly late so a coalesced timer
            // does not systematically stretch the effective interval.
            guard force || elapsed >= interval * 0.9 else { return false }
        } else {
            elapsed = 0
        }

        let context = SampleContext(elapsed: elapsed,
                                    isFirstSample: lastSampled == nil,
                                    activity: activity,
                                    didWakeFromSleep: didWakeFromSleep)
        let newState = source.collect(context: context)
        lastSampled = now

        switch newState {
        case .value:
            consecutiveFailures = 0
            retryNotBefore = nil
        case .failure(let failure):
            if failure.isPermanent {
                isRetired = true
                source.stop()
                isStarted = false
            } else if failure == .pending {
                // A collector establishing its first baseline has not failed; the
                // reading it promised for the next tick must not be pushed out.
                retryNotBefore = nil
            } else {
                consecutiveFailures += 1
                let delay = consecutiveFailures >= 6
                    ? 60.0
                    : pow(2.0, Double(consecutiveFailures))
                retryNotBefore = now.advanced(by: .seconds(delay))
            }
        }

        let changed = newState != state
        state = newState
        return changed
    }

    func nextDelay(now: ContinuousClock.Instant, activity: SamplingActivity,
                   baseInterval: TimeInterval, multiplier: Double) -> TimeInterval? {
        guard !isRetired, activity.isSampling else { return nil }
        let interval = max(source.preferredInterval, baseInterval)
            * activity.cadenceMultiplier * multiplier
        let due = lastSampled.map { $0.advanced(by: .seconds(interval)) } ?? now
        let next = retryNotBefore.map { max(due, $0) } ?? due
        let delay = next - now
        return max(0, Double(delay.components.seconds) + Double(delay.components.attoseconds) * 1e-18)
    }

    /// Release resources but stay eligible to run again later.
    func suspend() {
        guard isStarted else { return }
        source.stop()
        isStarted = false
        state = .pending
        lastSampled = nil
        retryNotBefore = nil
        consecutiveFailures = 0
    }

    /// Force the next tick to treat its counters as a fresh baseline.
    func invalidateBaseline() { lastSampled = nil }

    /// Whether the last collection happened at `instant`.
    func sampled(at instant: ContinuousClock.Instant) -> Bool { lastSampled == instant }

    func resetRetry() {
        consecutiveFailures = 0
        retryNotBefore = nil
    }

    func shutdown() {
        suspend()
        state = .pending
    }
}

/// Owns every collector and the sampling timer.
///
/// ## Threading
/// All state on this class is confined to `queue`, a single serial queue at
/// `.utility` QoS. Nothing here touches the main thread except the `onSnapshot`
/// callback, which is dispatched to the main actor. The class is `@unchecked
/// Sendable` because that confinement is enforced by construction, not by types.
public final class SamplingCore: @unchecked Sendable {

    // MARK: Sources

    private let cpuSlot: SourceSlot<CPUCollector>
    private let memorySlot: SourceSlot<MemoryCollector>
    private let gpuSlot: SourceSlot<GPUCollector>
    private let networkSlot: SourceSlot<NetworkCollector>
    private let diskSlot: SourceSlot<DiskCollector>
    private let powerSlot: SourceSlot<PowerCollector>
    private let thermalSlot: SourceSlot<ThermalCollector>
    private let processSlot: SourceSlot<ProcessCollector>
    private let systemSlot: SourceSlot<SystemInfoCollector>

    // MARK: Scheduling

    private let queue = DispatchQueue(label: "com.danesed.mustats.sampling", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var baseInterval: TimeInterval = 2
    /// The wall-clock minute the process list was last read for a peak, and whether
    /// the read that names the process is still owed. See `wantsPeakWitness`.
    private var witnessedMinute: Int?
    private var witnessFollowUpDue = false
    /// Machine-wide CPU, as a fraction of every core, above which a minute gets a
    /// look at the process list. A tenth is one runaway core on a twelve core Mac,
    /// which is the case a day chart most often has to explain.
    static let cpuWitnessThreshold = 0.10
    /// Memory pressure above which the minute gets the same look.
    static let memoryWitnessThreshold = 0.6
    /// Most of one core, as the share of the machine a single busy process makes.
    static let oneCoreShare = 0.8
    /// Set from outside to read the process list on the next two ticks whatever the
    /// load: unplugging asks, so the alert can say what is drawing the battery.
    private var witnessRequested = false
    private var activity: SamplingActivity = .menuBar
    private var enabledSources: Set<CollectorID> = Set(CollectorID.allCases)
    private var publicIPLookupEnabled = false
    private var panelDetails: Set<CollectorID> = []
    private var panelProcessCount = false
    private var diskIOEnabled = false
    private var pendingWakeFlag = false
    private var isRunning = false
    private var thermalCadenceMultiplier = 1.0
    /// Registration for powerd's "a power source changed" notification. Plugging in,
    /// unplugging, a charge hold starting and the percentage ticking over all post it,
    /// so the battery does not have to be polled to notice any of them.
    private var powerNotifyToken = NOTIFY_TOKEN_INVALID
    /// Set by the power notification so its next sampling cycle ignores cadence.
    private var powerEventPending = false
    /// With events covering every change a user can see in the menu bar, the battery's
    /// own cadence only has to keep watts and time remaining fresh, which nothing reads
    /// until the panel or the widget is open. Until then it is polled this many times
    /// more slowly: five seconds becomes thirty.
    static let powerIdleCadenceMultiplier = 6.0
    /// True while only the menu bar is on screen and the machine is idle. See
    /// `updateQuietLocked`.
    private var isQuiet = false
    /// Whole-machine CPU below which a menu-bar-only session counts as quiet, and above
    /// which it stops. Two thresholds so a load sitting near one does not flip the
    /// cadence on every tick. A quarter of the machine because that is ordinary desk
    /// work on a many-core Mac: measured at 15 to 20% on twelve cores with an editor
    /// and a browser open, so a tenth was a quiet mode that never engaged.
    static let quietEnterBusy = 0.25
    static let quietExitBusy = 0.40
    /// How much more slowly a quiet session ticks. Every tick that changes the bar is
    /// a redraw paid once per menu bar AppKit mirrors the item into, and an idle
    /// machine's numbers are the ones least worth repainting every two seconds.
    static let quietCadenceMultiplier = 2.0
    /// Quiet and also still: the CPU has moved less than `steadyBand` between this many
    /// samples in a row. Nothing on the bar is changing, so it ticks slower again, and
    /// the first sample that moves past the band brings the quiet rate straight back.
    static let steadySamples = 5
    static let steadyBand = 0.03
    static let steadyCadenceMultiplier = 3.0
    /// Temperatures move over tens of seconds, and the sensor read is the most
    /// expensive one the menu bar pays for, so with only the bar on screen it is read
    /// at a third of the rate. The panel and the widget get every sample.
    static let thermalMenuBarMultiplier = 3.0
    /// Live: once a second while the panel is open. Everything else, the menu bar on
    /// its own included, keeps the user's interval and the quiet and steady slowdowns.
    private var livePanel = true
    static let liveInterval: TimeInterval = 1
    private var effectiveBaseInterval: TimeInterval {
        activity == .panel && livePanel ? min(baseInterval, Self.liveInterval) : baseInterval
    }
    private var isSteady = false
    private var steadyRun = 0
    private var lastBusy: Double?

    /// A single settings transaction keeps interval, source selection and network
    /// lookup changes on one queue hop. This matters while a settings control emits
    /// several revisions during a drag.
    public struct Configuration: Sendable, Equatable {
        public let baseInterval: TimeInterval
        public let enabledSources: Set<CollectorID>
        public let publicIPLookupEnabled: Bool
        public let diskIOEnabled: Bool
        /// Sample once a second while the panel is open, whatever the base interval.
        public let livePanel: Bool

        public init(baseInterval: TimeInterval,
                    enabledSources: Set<CollectorID>,
                    publicIPLookupEnabled: Bool,
                    livePanel: Bool = true,
                    diskIOEnabled: Bool = false) {
            self.baseInterval = baseInterval
            self.enabledSources = enabledSources
            self.publicIPLookupEnabled = publicIPLookupEnabled
            self.diskIOEnabled = diskIOEnabled
            self.livePanel = livePanel
        }
    }

    /// Delivered on the main actor after every cycle that produced a change.
    private let onSnapshot: @Sendable @MainActor (SystemSnapshot) -> Void

    public init(onSnapshot: @escaping @Sendable @MainActor (SystemSnapshot) -> Void) {
        self.onSnapshot = onSnapshot
        self.cpuSlot = SourceSlot(CPUCollector())
        self.memorySlot = SourceSlot(MemoryCollector())
        self.gpuSlot = SourceSlot(GPUCollector())
        self.networkSlot = SourceSlot(NetworkCollector())
        self.diskSlot = SourceSlot(DiskCollector())
        self.powerSlot = SourceSlot(PowerCollector())
        self.thermalSlot = SourceSlot(ThermalCollector())
        self.processSlot = SourceSlot(ProcessCollector())
        self.systemSlot = SourceSlot(SystemInfoCollector())
        self.cpuSlot.source.setCountRequests(processes: false, threads: false)
        self.networkSlot.source.setWiFiDetailsEnabled(false)
        self.diskSlot.source.setIOEnabled(false)
    }

    // MARK: Control

    public func start() {
        queue.async { [self] in
            guard !isRunning else { return }
            isRunning = true
            registerPowerNotificationLocked()
            rescheduleTimerLocked()
            sampleLocked()
        }
    }

    public func stop() {
        queue.async { [self] in
            isRunning = false
            timer?.cancel()
            timer = nil
            if powerNotifyToken != NOTIFY_TOKEN_INVALID {
                notify_cancel(powerNotifyToken)
                powerNotifyToken = NOTIFY_TOKEN_INVALID
            }
            forEachSlot { $0.shutdown() }
        }
    }

    public func apply(_ configuration: Configuration) {
        queue.async { [self] in
            applyLocked(configuration)
        }
    }

    public func setActivity(_ newActivity: SamplingActivity) {
        queue.async { [self] in
            guard newActivity != activity else { return }
            let wasSuspended = !activity.isSampling
            activity = newActivity
            // The panel and the widget always get the full rate; quiet is re-earned
            // from the next sample once only the menu bar is left.
            if newActivity != .menuBar { isQuiet = false; isSteady = false; steadyRun = 0 }
            rescheduleTimerLocked()
            // Coming back from suspension, sample immediately so the user never
            // sees a stale menu bar after unlocking the screen.
            if wasSuspended && newActivity.isSampling {
                forEachSlot {
                    $0.invalidateBaseline()
                    $0.resetRetry()
                }
                pendingWakeFlag = true
                sampleLocked(force: true)
            } else if newActivity > .menuBar {
                // The panel or widget just opened: this is the one immediate sample
                // for that surface, so it ignores cadence. Only one: two back-to-back
                // passes give the counter collectors a near-zero interval to divide by.
                sampleLocked(force: true)
            }
        }
    }

    /// The set of collectors anything on screen actually needs. Sources outside
    /// this set are never sampled and release their resources.
    public func setEnabledSources(_ sources: Set<CollectorID>) {
        queue.async { [self] in
            guard sources != enabledSources else { return }
            let removed = enabledSources.subtracting(sources)
            enabledSources = sources
            suspendRemovedSources(removed)
            if isRunning { sampleLocked(publish: !removed.isEmpty) }
        }
    }

    public func setPanelDetails(_ sources: Set<CollectorID>, processCount: Bool) {
        queue.async { [self] in
            guard sources != panelDetails || processCount != panelProcessCount else { return }
            let hadProcesses = panelDetails.contains(.processes)
            let hadDiskIO = diskIOEnabled || panelDetails.contains(.disk)
            panelDetails = sources
            panelProcessCount = processCount
            cpuSlot.source.setCountRequests(processes: processCount,
                                            threads: sources.contains(.cpu))
            networkSlot.source.setWiFiDetailsEnabled(sources.contains(.network))
            let wantsDiskIO = diskIOEnabled || sources.contains(.disk)
            diskSlot.source.setIOEnabled(wantsDiskIO)
            if hadDiskIO && !wantsDiskIO { diskSlot.invalidateIO() }
            if hadProcesses != sources.contains(.processes) && !witnessFollowUpDue {
                processSlot.suspend()
            }
            if isRunning {
                sampleLocked(publish: (hadProcesses && !sources.contains(.processes))
                             || (hadDiskIO && !wantsDiskIO))
            }
        }
    }

    /// Turns the public IP lookup on or off. The one collector behaviour the user has
    /// to opt into, so it is pushed down here rather than read from settings by the
    /// collector: this queue is the only place a collector's state may be touched.
    public func setPublicIPLookupEnabled(_ enabled: Bool) {
        queue.async { [self] in
            publicIPLookupEnabled = enabled
            networkSlot.source.setPublicIPLookupEnabled(enabled)
        }
    }

    /// The latency probe exists for the panel's network module, so it follows panel
    /// visibility rather than a setting: opening the panel starts it, closing it
    /// stops the traffic entirely.
    public func setLatencyProbeEnabled(_ enabled: Bool) {
        queue.async { [self] in
            networkSlot.source.setLatencyProbeEnabled(enabled)
        }
    }

    public func triggerNetworkProbe() {
        queue.async { [self] in
            networkSlot.source.triggerNetworkProbe()
        }
    }

    /// Called on wake from sleep: cumulative counters may have reset and every
    /// rate is meaningless until re-baselined.
    public func noteWakeFromSleep() {
        queue.async { [self] in
            pendingWakeFlag = true
            forEachSlot {
                $0.invalidateBaseline()
                $0.resetRetry()
            }
        }
    }

    /// Thermal pressure slows expensive optional reads while retaining every selected
    /// source. Recovery samples immediately so the UI does not stay stale after the
    /// system returns to a nominal state.
    public func setThermalPressure(_ pressure: ThermalPressure) {
        queue.async { [self] in
            let multiplier: Double
            switch pressure {
            case .nominal, .fair: multiplier = 1
            case .serious: multiplier = 3
            case .critical: multiplier = 5
            }
            guard multiplier != thermalCadenceMultiplier else { return }
            let wasConstrained = thermalCadenceMultiplier > 1
            thermalCadenceMultiplier = multiplier
            if wasConstrained, multiplier == 1, isRunning, activity.isSampling {
                sampleLocked(force: true)
            }
        }
    }

    // MARK: Internals

    private func registerPowerNotificationLocked() {
        guard powerNotifyToken == NOTIFY_TOKEN_INVALID else { return }
        var token = NOTIFY_TOKEN_INVALID
        let status = notify_register_dispatch(kIOPSNotifyPowerSource, &token, queue) { [weak self] _ in
            guard let self, enabledSources.contains(.power), activity.isSampling else { return }
            powerEventPending = true
            if isRunning { sampleLocked() }
        }
        // A failed registration leaves the battery on its old five-second poll, which
        // is the behaviour it had before there were events at all.
        if status == NOTIFY_STATUS_OK { powerNotifyToken = token }
    }

    private func forEachSlot(_ body: (any SlotErasing) -> Void) {
        body(cpuSlot); body(memorySlot); body(gpuSlot); body(networkSlot)
        body(diskSlot); body(powerSlot); body(thermalSlot); body(processSlot)
        body(systemSlot)
    }

    private func suspendRemovedSources(_ removed: Set<CollectorID>) {
        forEachSlot { slot in
            if removed.contains(slot.identifier) { slot.suspend() }
        }
        if removed.contains(.processes) {
            witnessFollowUpDue = false
            witnessRequested = false
            witnessedMinute = nil
        }
    }

    private func rescheduleTimerLocked() {
        guard isRunning, activity.isSampling else {
            timer?.cancel()
            timer = nil
            return
        }

        let now = Monotonic.now
        let quietMultiplier = isSteady ? Self.steadyCadenceMultiplier
            : (isQuiet ? Self.quietCadenceMultiplier : 1)
        var next: TimeInterval?
        forEachSlot { slot in
            guard enabledSources.contains(slot.identifier) else { return }
            if slot.identifier == .processes,
               !Self.panelWantsProcesses(activity: activity, details: panelDetails),
               !witnessFollowUpDue, !witnessRequested { return }
            guard let delay = slot.nextDelay(now: now, activity: activity,
                                             baseInterval: effectiveBaseInterval,
                                             multiplier: cadenceMultiplier(for: slot.identifier) * quietMultiplier)
            else { return }
            next = min(next ?? delay, delay)
        }
        guard let interval = next else {
            timer?.cancel()
            timer = nil
            return
        }

        if timer == nil {
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.setEventHandler { [weak self] in self?.sampleLocked() }
            source.resume()
            timer = source
        }
        let leeway = max(0.1, interval * 0.25)
        timer?.schedule(deadline: .now() + interval, leeway: .milliseconds(Int(leeway * 1000)))
    }

    private func cadenceMultiplier(for identifier: CollectorID) -> Double {
        var multiplier = thermalMultiplier(for: identifier)
        if identifier == .thermal, activity < .panel {
            multiplier *= Self.thermalMenuBarMultiplier
        }
        if identifier == .processes, activity >= .panel,
           let busy = cpuSlot.state.value?.total.busy, busy < 0.06 {
            multiplier *= 2
        }
        if identifier == .power, powerNotifyToken != NOTIFY_TOKEN_INVALID, activity < .panel {
            multiplier *= Self.powerIdleCadenceMultiplier
        }
        return multiplier
    }

    private func applyLocked(_ configuration: Configuration) {
        let clamped = min(max(configuration.baseInterval, 0.5), 60)
        let removed = enabledSources.subtracting(configuration.enabledSources)
        let sourcesChanged = configuration.enabledSources != enabledSources
        let intervalChanged = clamped != baseInterval
        let publicIPChanged = configuration.publicIPLookupEnabled != publicIPLookupEnabled
        let diskIOChanged = configuration.diskIOEnabled != diskIOEnabled
        let disabledDiskIO = diskIOEnabled && !configuration.diskIOEnabled && !panelDetails.contains(.disk)

        let liveChanged = configuration.livePanel != livePanel
        livePanel = configuration.livePanel
        baseInterval = clamped
        enabledSources = configuration.enabledSources
        publicIPLookupEnabled = configuration.publicIPLookupEnabled
        diskIOEnabled = configuration.diskIOEnabled
        if diskIOChanged { diskSlot.source.setIOEnabled(diskIOEnabled || panelDetails.contains(.disk)) }
        if disabledDiskIO { diskSlot.invalidateIO() }
        suspendRemovedSources(removed)
        if publicIPChanged {
            networkSlot.source.setPublicIPLookupEnabled(configuration.publicIPLookupEnabled)
        }
        if intervalChanged || liveChanged { rescheduleTimerLocked() }
        if isRunning && (sourcesChanged || intervalChanged || publicIPChanged || diskIOChanged) {
            sampleLocked(publish: !removed.isEmpty || disabledDiskIO)
        }
    }

    private func sampleLocked(force: Bool = false, publish: Bool = false) {
        guard isRunning, activity.isSampling else { return }
        defer { rescheduleTimerLocked() }
        let now = Monotonic.now
        let didWake = pendingWakeFlag
        pendingWakeFlag = false

        var changed = false
        func run<S: MetricSource>(_ slot: SourceSlot<S>) {
            let multiplier = cadenceMultiplier(for: slot.identifier)
            let forced = force || (slot.identifier == .power && powerEventPending)
            if slot.tick(now: now,
                         activity: activity,
                         isEnabled: enabledSources.contains(slot.identifier),
                         baseInterval: effectiveBaseInterval,
                         didWakeFromSleep: didWake,
                         force: forced,
                         thermalCadenceMultiplier: multiplier) {
                changed = true
            }
        }

        run(systemSlot)
        run(cpuSlot)
        run(memorySlot)
        run(gpuSlot)
        run(networkSlot)
        run(diskSlot)
        run(powerSlot)
        powerEventPending = false
        updateQuietLocked()
        run(thermalSlot)
        // Processes are by far the most expensive source; only ever sampled when
        // the panel that displays them is actually on screen, or twice in a minute
        // the day chart will have to explain.
        if Self.panelWantsProcesses(activity: activity, details: panelDetails) {
            run(processSlot)
            if processSlot.sampled(at: now) { witnessRequested = false; witnessFollowUpDue = false }
        } else {
            let wasFollowUp = witnessFollowUpDue
            if Self.enabledWitness(enabledSources, wants: { wantsPeakWitness() }) {
                run(processSlot)
                if wasFollowUp && processSlot.sampled(at: now) {
                    witnessFollowUpDue = false
                }
            }
        }

        guard changed || publish else { return }

        let snapshot = SystemSnapshot(
            cpu: cpuSlot.state,
            memory: memorySlot.state,
            gpu: gpuSlot.state,
            network: networkSlot.state,
            disk: diskSlot.state,
            power: powerSlot.state,
            thermal: thermalSlot.state,
            processes: processSlot.state,
            processesSampled: processSlot.sampled(at: now),
            system: systemSlot.state,
            capturedAt: Date(),
            capturedInstant: now
        )

        let callback = onSnapshot
        DispatchQueue.main.async { MainActor.assumeIsolated { callback(snapshot) } }
    }

    /// Enters or leaves the quiet cadence from the CPU sample just taken. Only the
    /// menu-bar-only activity can be quiet: the panel and the widget are being looked
    /// at, and an occluded bar is already slowed further. Without a CPU reading the
    /// session is never quiet, since there is nothing to say it is idle.
    private func updateQuietLocked() {
        let busy = cpuSlot.state.value?.total.busy
        let quiet = Self.isQuiet(activity: activity, busy: busy, wasQuiet: isQuiet)
        if let busy, let last = lastBusy, quiet, abs(busy - last) < Self.steadyBand {
            steadyRun += 1
        } else {
            steadyRun = 0
        }
        lastBusy = busy
        let steady = quiet && steadyRun >= Self.steadySamples
        guard quiet != isQuiet || steady != isSteady else { return }
        isQuiet = quiet
        isSteady = steady
        rescheduleTimerLocked()
    }

    static func enabledWitness(_ sources: Set<CollectorID>, wants: () -> Bool) -> Bool {
        sources.contains(.processes) && wants()
    }

    static func panelWantsProcesses(activity: SamplingActivity, details: Set<CollectorID>) -> Bool {
        activity >= .panel && details.contains(.processes)
    }

    static func isQuiet(activity: SamplingActivity, busy: Double?, wasQuiet: Bool) -> Bool {
        guard activity == .menuBar, let busy else { return false }
        return busy < (wasQuiet ? quietExitBusy : quietEnterBusy)
    }

    /// Whether this tick should read the process list to name what is behind a
    /// peak. A minute whose CPU or memory pressure clears the threshold gets two
    /// reads: the first rebaselines the per-process counters and reports nothing,
    /// the second, a tick later, carries real percentages over that tick. One pair
    /// per minute at most, so a sustained load costs two reads a minute and an idle
    /// machine costs none.
    private func wantsPeakWitness() -> Bool {
        if witnessFollowUpDue { return true }
        if witnessRequested {
            witnessRequested = false
            processSlot.invalidateBaseline()
            witnessFollowUpDue = true
            return true
        }
        let busy = cpuSlot.state.value?.total.busy ?? 0
        let pressure = memorySlot.state.value?.pressureFraction ?? 0
        // One core flat out is a tenth of a twelve-core Mac but less than that of a
        // larger one, and a single runaway core is exactly what the runaway alert
        // looks for, so the bar is the lower of the two.
        let cores = Double(max(cpuSlot.state.value?.perCore.count ?? 1, 1))
        let cpuBar = min(Self.cpuWitnessThreshold, Self.oneCoreShare / cores)
        guard busy >= cpuBar || pressure >= Self.memoryWitnessThreshold else {
            return false
        }
        let minute = Int(Date().timeIntervalSince1970 / 60)
        guard minute != witnessedMinute else { return false }
        witnessedMinute = minute
        // Counters last read minutes or hours ago would rank processes by their
        // average since then, not by what they are doing now.
        processSlot.invalidateBaseline()
        witnessFollowUpDue = true
        return true
    }

    /// Reads the process list on the next two ticks, whatever the load.
    func requestProcessWitness() {
        queue.async { [weak self] in
            guard let self else { return }
            witnessRequested = true
            if isRunning && activity.isSampling { sampleLocked() }
        }
    }

    private func thermalMultiplier(for identifier: CollectorID) -> Double {

        switch identifier {
        case .gpu, .disk, .processes: return thermalCadenceMultiplier
        default: return 1
        }
    }
}

/// Type-erased slot operations that do not depend on the source's `Output`.
protocol SlotErasing: AnyObject {
    var identifier: CollectorID { get }
    func nextDelay(now: ContinuousClock.Instant, activity: SamplingActivity,
                   baseInterval: TimeInterval, multiplier: Double) -> TimeInterval?
    func suspend()
    func invalidateBaseline()
    func resetRetry()
    func shutdown()
}

extension SourceSlot: SlotErasing {}

extension SourceSlot where Source == DiskCollector {
    func invalidateIO() {
        guard case .value(var disk) = state else { return }
        disk.ioAvailable = false
        state = .value(disk)
    }
}
