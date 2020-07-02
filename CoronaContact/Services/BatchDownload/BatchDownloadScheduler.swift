//
//  BatchDownloadScheduler.swift
//  CoronaContact
//

import BackgroundTasks
import Foundation
import Resolver

final class BatchDownloadScheduler {
    struct Timing {
        private let startDate: Date
        private let endDate: Date
        private let dateInterval: DateInterval
        private let datesToSchedule: [Date]

        var nextDateToSchedule: Date? {
            datesToSchedule.first { $0 > Date() }
        }

        init() {
            startDate = Calendar.current.date(
                bySettingHour: BatchDownloadConfiguration.Scheduler.startTime.hour,
                minute: BatchDownloadConfiguration.Scheduler.startTime.minute,
                second: 0,
                of: Date()
            )!
            endDate = Calendar.current.date(
                bySettingHour: BatchDownloadConfiguration.Scheduler.endTime.hour,
                minute: BatchDownloadConfiguration.Scheduler.endTime.minute,
                second: 0,
                of: Date()
            )!
            dateInterval = DateInterval(start: startDate, end: endDate)
            datesToSchedule = dateInterval.divide(
                by: .hour,
                value: BatchDownloadConfiguration.Scheduler.intervalInHours
            )
        }
    }

    @Injected private var localStorage: LocalStorage
    @Injected private var healthRepository: HealthRepository
    @Injected private var batchDownloadService: BatchDownloadService
    @Injected private var riskCalculationController: RiskCalculationController

    weak var exposureManager: ExposureManager?

    private let log = ContextLogger(context: .batchDownload)
    private let backgroundTaskIdentifier = Bundle.main.bundleIdentifier! + ".exposure-notification"
    private let backgroundTaskScheduler = BGTaskScheduler.shared
    private let timing = Timing()

    func registerBackgroundTask() {
        backgroundTaskScheduler.register(forTaskWithIdentifier: backgroundTaskIdentifier, using: .main) { task in
            let minutes55: TimeInterval = 3300

            self.log.debug("Starting background batch download task.")

            if let lastTime = self.timeSinceLastBatchProcessing(), lastTime < minutes55 {
                self.log.debug("Cancelling batch processing background task, because it already happened \(Int(lastTime / 60)) minutes ago.")
                self.localStorage.batchDownloadSchedulerResult = "\(Date()): Cancelled because done \(Int(lastTime / 60)) minutes ago."
                task.setTaskCompleted(success: true)
                self.scheduleBackgroundTaskIfNeeded()
                return
            }

            let downloadRequirement = self.determineDownloadRequirement()

            let progress = self.batchDownloadService.startBatchDownload(downloadRequirement) { [weak self] result in
                guard let self = self else {
                    return
                }

                switch result {
                case let .success(batches):
                    self.riskCalculationController.processBatches(batches, completionHandler: self.handleRiskCalculationResult)
                    self.log.debug("Successfully completed the background batch download task.")
                    task.setTaskCompleted(success: true)
                    self.localStorage.batchDownloadSchedulerResult = BatchDownloadSchedulerResult(task: task, error: nil).description
                case let .failure(error):
                    task.setTaskCompleted(success: false)
                    self.log.error("Failed to complete the background batch download task due to an error: \(error).")
                    self.localStorage.batchDownloadSchedulerResult = BatchDownloadSchedulerResult(task: task, error: .download(error)).description
                }
            }

            // Handle running out of time
            task.expirationHandler = {
                progress.cancel()
                self.log.error("Failed to complete the background batch download task, because the task ran out of time.")
                self.localStorage.batchDownloadSchedulerResult = BatchDownloadSchedulerResult(task: task, error: .backgroundTimeout).description
            }

            // Schedule the next background task
            self.scheduleBackgroundTaskIfNeeded()
        }

        scheduleBackgroundTaskIfNeeded()
    }

    private func timeSinceLastBatchProcessing() -> TimeInterval? {
        guard let performedBatchProcessingAt = localStorage.performedBatchProcessingAt else {
            return nil
        }

        return Date().timeIntervalSince1970 - performedBatchProcessingAt.timeIntervalSince1970
    }

    private func determineDownloadRequirement() -> BatchDownloadService.DownloadRequirement {
        switch healthRepository.userHealthStatus {
        case .isHealthy:
            return .sevenDaysBatchAndDailyBatches
        case .hasAttestedSickness, .isProbablySick, .isUnderSelfMonitoring:
            return .onlyFourteenDaysBatch
        }
    }

    private func handleRiskCalculationResult(_ result: Result<RiskCalculationResult, RiskCalculationError>) {
        if case let .success(riskResult) = result {
            log.debug("Passing the risk calculation result to the quarantine time controller.")
            localStorage.performedBatchProcessingAt = Date()
            QuarantineTimeController.quarantineTimeCalculation(riskResult: riskResult)
        }

        batchDownloadService.removeBatches()
    }

    func scheduleBackgroundTaskIfNeeded() {
        guard exposureManager?.authorizationStatus == .authorized else {
            return
        }

        if let nextScheduledDate = timing.nextDateToSchedule {
            scheduleBackgroundTask(at: nextScheduledDate)
        }
        #if LOGGING
            backgroundTaskScheduler.getPendingTaskRequests { pendingRequests in
                self.log.debug("Pending Taskrequests: \(pendingRequests)")
            }
        #endif
    }

    private func scheduleBackgroundTask(at date: Date) {
        let taskRequest = BGProcessingTaskRequest(identifier: backgroundTaskIdentifier)
        taskRequest.earliestBeginDate = date
        taskRequest.requiresNetworkConnectivity = true

        do {
            try backgroundTaskScheduler.submit(taskRequest)
            log.debug("Successfully scheduled background batch download task at date \(date): \(backgroundTaskIdentifier)")
        } catch {
            log.error("Failed to schedule background batch download task: \(error)")
        }
    }

    #if DEBUG
        func scheduleBackgroundTaskForDebuggingPurposes() {
            backgroundTaskScheduler.cancelAllTaskRequests()
            let oneMinuteFromNow = Date(timeIntervalSinceNow: 60)
            scheduleBackgroundTask(at: oneMinuteFromNow)
        }
    #endif
}

private extension DateInterval {
    func divide(by component: Calendar.Component, value divisor: Int) -> [Date] {
        var dates: [Date] = [start]

        var previousDate = start
        while let nextDate = Calendar.current.date(byAdding: component, value: divisor, to: previousDate),
            contains(nextDate) {
            dates.append(nextDate)
            previousDate = nextDate
        }

        return dates
    }
}
