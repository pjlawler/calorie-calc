import Foundation
import SwiftData
#if canImport(HealthKit)
import HealthKit
#endif

nonisolated struct HealthKitWorkout: Sendable, Hashable, Identifiable {
    let id: UUID
    let displayName: String
    let startDate: Date
    let endDate: Date
    let activeEnergyBurned: Double
    let duration: TimeInterval
}

nonisolated enum HealthKitAuthorizationStatus: Sendable, Hashable {
    case notDetermined
    case authorized
    case denied
    case unavailable
}

/// Backs every HealthKit read with a local SwiftData cache so callers render instantly and never
/// block on HK. The cache is populated three ways:
///   1. **Initial backfill** — `startBackgroundSync` runs an anchored / statistics query over the
///      last `Self.backfillWindowDays` days the first time it's called per process.
///   2. **HK background delivery** — `HKObserverQuery` instances wake the app when new samples
///      land in HealthKit (foreground OR background, system-decided cadence). The system caps
///      observer wake-ups: workouts are `.immediate`, step count is throttled to `.hourly`.
///   3. **60s foreground timer** — while the app is active, the timer re-runs the anchored fetch
///      so the user sees up-to-the-minute data when looking at the app. Stops automatically when
///      the app backgrounds (run loop pauses).
///
/// HK is the source of truth — the local cache is disposable and re-derivable. The cache lives in
/// the local-only `Cache` SwiftData store, not in iCloud.
@Observable
@MainActor
final class HealthKitService {

    var authorizationStatus: HealthKitAuthorizationStatus = .notDetermined

    /// How far back to maintain the cache. 90 days covers the dashboard's longest default range
    /// without being so wide that observer-query refreshes get expensive.
    private static let backfillWindowDays = 90

    private let modelContainer: ModelContainer

    #if canImport(HealthKit) && os(iOS)
    private let store = HKHealthStore()
    #endif

    private var didEnsureAuthorization = false
    private var authorizationTask: Task<Void, Never>?

    private var didStartBackgroundSync = false
    private var foregroundTimer: Timer?

    #if canImport(HealthKit) && os(iOS)
    private var workoutAnchor: HKQueryAnchor?
    private var observerQueries: [HKObserverQuery] = []
    #endif

    var isAvailable: Bool {
        #if canImport(HealthKit) && os(iOS)
        return HKHealthStore.isHealthDataAvailable()
        #else
        return false
        #endif
    }

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        #if canImport(HealthKit) && os(iOS)
        authorizationStatus = isAvailable ? .notDetermined : .unavailable
        loadPersistedAnchorIfCacheIntact()
        #else
        authorizationStatus = .unavailable
        #endif
    }

    #if canImport(HealthKit) && os(iOS)
    /// Load the workout anchor only if the cache has rows. An empty cache + a persisted anchor
    /// means the cache was wiped between launches (manual reset, OS migration, our own
    /// `CachedFoodStoreMigrator` nuking `Cache.store`). Keeping the old anchor in that state
    /// would cause the next anchored fetch to return only deltas since the wipe (≈ none), and
    /// the user's prior 90 days of workouts would never backfill into the empty cache. Clearing
    /// the anchor forces the next refresh to scope to the backfill window and pull everything.
    private func loadPersistedAnchorIfCacheIntact() {
        let count = (try? modelContainer.mainContext.fetchCount(FetchDescriptor<CachedWorkout>())) ?? 0
        if count == 0 {
            UserDefaults.standard.removeObject(forKey: Self.workoutAnchorKey)
            workoutAnchor = nil
            return
        }
        loadPersistedAnchor()
    }
    #endif

    func requestAuthorization() async throws {
        #if canImport(HealthKit) && os(iOS)
        guard isAvailable else {
            authorizationStatus = .unavailable
            return
        }
        let readTypes: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKObjectType.quantityType(forIdentifier: .stepCount)!,
            HKObjectType.workoutType(),
        ]
        try await store.requestAuthorization(toShare: [], read: readTypes)
        authorizationStatus = .authorized
        didEnsureAuthorization = true
        #else
        authorizationStatus = .unavailable
        #endif
    }

    func ensureAuthorizationAtStartup() async {
        if didEnsureAuthorization { return }
        if let existing = authorizationTask {
            await existing.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.requestAuthorization()
            } catch {
                self.didEnsureAuthorization = true
            }
        }
        authorizationTask = task
        await task.value
    }

    /// Idempotent — call from `RootView`'s startup task. Performs the initial backfill, registers
    /// observer queries, enables background delivery, and starts the 60s foreground timer. Subsequent
    /// calls no-op.
    func startBackgroundSync() async {
        guard !didStartBackgroundSync else { return }
        didStartBackgroundSync = true
        #if canImport(HealthKit) && os(iOS)
        guard isAvailable else { return }
        await ensureAuthorizationAtStartup()
        await refreshAll()
        registerObservers()
        startForegroundTimer()
        #endif
    }

    // MARK: - Background pipeline

    #if canImport(HealthKit) && os(iOS)
    private func startForegroundTimer() {
        foregroundTimer?.invalidate()
        // 60s cadence while the app is foreground. Run loop pauses when backgrounded so the timer
        // naturally stops without us managing it; observer queries cover background updates.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshAll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        foregroundTimer = timer
    }

    private func registerObservers() {
        let workoutType = HKObjectType.workoutType()
        let workoutObserver = HKObserverQuery(sampleType: workoutType, predicate: nil) { [weak self] _, completionHandler, _ in
            // Acknowledge the HK notification synchronously — the actual refresh is dispatched
            // separately on MainActor. Keeping `completionHandler` out of the Task closure side-
            // steps Swift 6's "task-isolated value captured by main-actor closure" error. If the
            // refresh fails, the next sample arrival fires this observer again anyway.
            completionHandler()
            Task { @MainActor [weak self] in
                await self?.refreshWorkouts()
            }
        }
        store.execute(workoutObserver)
        observerQueries.append(workoutObserver)
        store.enableBackgroundDelivery(for: workoutType, frequency: .immediate) { _, _ in }

        let stepType = HKQuantityType(.stepCount)
        let stepObserver = HKObserverQuery(sampleType: stepType, predicate: nil) { [weak self] _, completionHandler, _ in
            completionHandler()
            Task { @MainActor [weak self] in
                await self?.refreshSteps()
            }
        }
        store.execute(stepObserver)
        observerQueries.append(stepObserver)
        // .hourly is iOS's hard floor for cumulative quantity types — we can't go below it.
        store.enableBackgroundDelivery(for: stepType, frequency: .hourly) { _, _ in }
    }

    private func refreshAll() async {
        await refreshWorkouts()
        await refreshSteps()
    }

    private func refreshWorkouts() async {
        guard isAvailable else { return }
        // HK rejects abstract predicates (NSTruePredicate) — anchored queries must be given a
        // concrete one. First run scopes to the backfill window; subsequent runs use distantPast
        // so the predicate is concrete but the anchor still drives incremental dedup.
        let cutoff: Date
        if workoutAnchor == nil {
            cutoff = Calendar.current.date(byAdding: .day, value: -Self.backfillWindowDays, to: Date()) ?? Date()
        } else {
            cutoff = .distantPast
        }
        let predicate = HKQuery.predicateForSamples(withStart: cutoff, end: nil, options: .strictStartDate)
        do {
            let descriptor = HKAnchoredObjectQueryDescriptor(
                predicates: [.workout(predicate)],
                anchor: workoutAnchor
            )
            let result = try await descriptor.result(for: store)
            let added = result.addedSamples
            let deletedUUIDs = result.deletedObjects.map(\.uuid)
            try await applyWorkoutChanges(added: added, deletedUUIDs: deletedUUIDs)
            workoutAnchor = result.newAnchor
            persistAnchor()
        } catch {
            // Silent — HK errors are common (auth not yet granted, query interrupted) and the cache
            // remains valid until the next refresh tick.
        }
    }

    private func applyWorkoutChanges(added: [HKWorkout], deletedUUIDs: [UUID]) async throws {
        let context = modelContainer.mainContext
        if !deletedUUIDs.isEmpty {
            let deletedSet = Set(deletedUUIDs)
            let descriptor = FetchDescriptor<CachedWorkout>(
                predicate: #Predicate<CachedWorkout> { deletedSet.contains($0.healthKitUUID) }
            )
            for cached in (try? context.fetch(descriptor)) ?? [] {
                context.delete(cached)
            }
        }
        for workout in added {
            let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
                .sumQuantity()?
                .doubleValue(for: .kilocalorie()) ?? 0
            let uuid = workout.uuid
            let existing = try? context.fetch(
                FetchDescriptor<CachedWorkout>(
                    predicate: #Predicate<CachedWorkout> { $0.healthKitUUID == uuid }
                )
            ).first
            if let existing {
                existing.startDate = workout.startDate
                existing.endDate = workout.endDate
                existing.activeEnergyBurned = energy
                existing.displayName = workout.workoutActivityType.displayName
                existing.activityTypeRaw = Int(workout.workoutActivityType.rawValue)
                existing.duration = workout.duration
            } else {
                context.insert(CachedWorkout(
                    healthKitUUID: uuid,
                    startDate: workout.startDate,
                    endDate: workout.endDate,
                    activeEnergyBurned: energy,
                    displayName: workout.workoutActivityType.displayName,
                    activityTypeRaw: Int(workout.workoutActivityType.rawValue),
                    duration: workout.duration
                ))
            }
        }
        try context.save()
    }

    private func refreshSteps() async {
        guard isAvailable else { return }
        let calendar = Calendar.current
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
        guard let start = calendar.date(byAdding: .day, value: -Self.backfillWindowDays, to: calendar.startOfDay(for: Date())) else { return }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: endOfToday, options: .strictStartDate)
        var components = DateComponents()
        components.day = 1
        let stepType = HKQuantityType(.stepCount)
        let query = HKStatisticsCollectionQuery(
            quantityType: stepType,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum,
            anchorDate: calendar.startOfDay(for: start),
            intervalComponents: components
        )
        let buckets: [(Date, Double)] = await withCheckedContinuation { continuation in
            query.initialResultsHandler = { _, results, _ in
                var out: [(Date, Double)] = []
                results?.enumerateStatistics(from: start, to: endOfToday) { stats, _ in
                    let value = stats.sumQuantity()?.doubleValue(for: .count()) ?? 0
                    out.append((calendar.startOfDay(for: stats.startDate), value))
                }
                continuation.resume(returning: out)
            }
            store.execute(query)
        }
        try? await applyStepChanges(buckets)
    }

    private func applyStepChanges(_ buckets: [(Date, Double)]) async throws {
        let context = modelContainer.mainContext
        let now = Date()
        for (day, value) in buckets {
            let key = CachedDailySteps.dayKey(for: day)
            let existing = try? context.fetch(
                FetchDescriptor<CachedDailySteps>(
                    predicate: #Predicate<CachedDailySteps> { $0.dayKey == key }
                )
            ).first
            if let existing {
                existing.stepCount = value
                existing.updatedAt = now
            } else {
                context.insert(CachedDailySteps(dayKey: key, stepCount: value, updatedAt: now))
            }
        }
        try context.save()
    }

    // MARK: - Anchor persistence

    private static let workoutAnchorKey = "HealthKitService.workoutAnchor.v1"

    private func loadPersistedAnchor() {
        guard let data = UserDefaults.standard.data(forKey: Self.workoutAnchorKey) else { return }
        workoutAnchor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func persistAnchor() {
        guard let anchor = workoutAnchor else { return }
        let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
        UserDefaults.standard.set(data, forKey: Self.workoutAnchorKey)
    }
    #endif

    // MARK: - Public read API (cache-backed)
    //
    // These keep their original signatures so call sites (Dashboard, History, WeekCalendar,
    // DayDetail) don't need to change. Reads now hit SwiftData instead of HK directly — instant,
    // never blocks on auth / query latency. Background sync keeps the cache fresh.

    func workoutsEnergyBurned(on date: Date, calendar: Calendar = .current) async throws -> Double {
        let list = try await workouts(on: date, calendar: calendar)
        return list.reduce(0) { $0 + $1.activeEnergyBurned }
    }

    func dailyWorkoutBurn(
        from startDate: Date,
        through endDate: Date,
        calendar: Calendar = .current
    ) async throws -> [Date: Double] {
        let rangeStart = calendar.startOfDay(for: startDate)
        guard let rangeEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) else { return [:] }
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<CachedWorkout>(
            predicate: #Predicate<CachedWorkout> {
                $0.startDate >= rangeStart && $0.startDate < rangeEnd
            }
        )
        let workouts = (try? context.fetch(descriptor)) ?? []
        var buckets: [Date: Double] = [:]
        for workout in workouts {
            let day = calendar.startOfDay(for: workout.startDate)
            buckets[day, default: 0] += workout.activeEnergyBurned
        }
        return buckets
    }

    func dailySteps(on date: Date, calendar: Calendar = .current) async throws -> Double {
        let key = CachedDailySteps.dayKey(for: date, calendar: calendar)
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<CachedDailySteps>(
            predicate: #Predicate<CachedDailySteps> { $0.dayKey == key }
        )
        return (try? context.fetch(descriptor))?.first?.stepCount ?? 0
    }

    func dailyStepsByDay(
        from startDate: Date,
        through endDate: Date,
        calendar: Calendar = .current
    ) async throws -> [Date: Double] {
        let startKey = CachedDailySteps.dayKey(for: startDate, calendar: calendar)
        let endKey = CachedDailySteps.dayKey(for: endDate, calendar: calendar)
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<CachedDailySteps>(
            predicate: #Predicate<CachedDailySteps> {
                $0.dayKey >= startKey && $0.dayKey <= endKey
            }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        var buckets: [Date: Double] = [:]
        for row in rows {
            // Rebuild the day's start-of-day Date in the current calendar so consumers keyed by
            // Date still line up with the week grid's dates.
            guard let day = CachedDailySteps.date(forDayKey: row.dayKey, calendar: calendar) else { continue }
            buckets[day] = row.stepCount
        }
        return buckets
    }

    func workouts(on date: Date, calendar: Calendar = .current) async throws -> [HealthKitWorkout] {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<CachedWorkout>(
            predicate: #Predicate<CachedWorkout> {
                $0.startDate >= start && $0.startDate < end
            },
            sortBy: [SortDescriptor(\.startDate, order: .forward)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.map { cached in
            HealthKitWorkout(
                id: cached.healthKitUUID,
                displayName: cached.displayName,
                startDate: cached.startDate,
                endDate: cached.endDate,
                activeEnergyBurned: cached.activeEnergyBurned,
                duration: cached.duration
            )
        }
    }
}

#if canImport(HealthKit) && os(iOS)
private extension HKWorkoutActivityType {
    var displayName: String {
        switch self {
        case .running: "Running"
        case .walking: "Walking"
        case .cycling: "Cycling"
        case .swimming: "Swimming"
        case .hiking: "Hiking"
        case .yoga: "Yoga"
        case .functionalStrengthTraining, .traditionalStrengthTraining: "Strength"
        case .highIntensityIntervalTraining: "HIIT"
        case .rowing: "Rowing"
        case .elliptical: "Elliptical"
        case .dance: "Dance"
        case .mixedCardio, .crossTraining: "Cross Training"
        default: "Workout"
        }
    }
}
#endif
