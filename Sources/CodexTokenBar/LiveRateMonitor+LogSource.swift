import Foundation
import Darwin

extension LiveRateMonitor {
    @discardableResult
    func setDataSource(_ source: CodexDataSource?) -> Bool {
        compositionDataSourceBound = true
        return transitionDataSource(to: source)
    }

    @discardableResult
    func adoptResolvedDataSource(_ source: CodexDataSource) -> Bool {
        transitionDataSource(to: source)
    }

    private func transitionDataSource(to source: CodexDataSource?) -> Bool {
        let previousSource = dataSource
        let previousIdentity = dataSource?.stableIdentityKey
        let nextIdentity = source?.stableIdentityKey
        let previousPath = dataSource?.codexHome.standardizedFileURL.path
        let nextPath = source?.codexHome.standardizedFileURL.path
        dataSource = source
        guard previousIdentity != nextIdentity || previousPath != nextPath else {
            return false
        }

        sourceBindingGeneration += 1
        if previousIdentity == nextIdentity {
            rebindSourcePaths(from: previousSource, to: source)
            return true
        }

        sourceGeneration += 1
        if let source {
            let homePath = source.codexHome.path as NSString
            cachedLogsDatabasePath = homePath.appendingPathComponent("logs_2.sqlite")
            cachedLogsDirectoryPath = (cachedLogsDatabasePath as NSString).deletingLastPathComponent
        } else {
            cachedLogsDatabasePath = ""
            cachedLogsDirectoryPath = ""
        }
        resetSourceLocalState(for: source)
        return true
    }

    func configureLogWatcher(logsDirectory directory: String) {
        guard !directory.isEmpty, watchedLogsDirectory != directory else { return }

        logsDirectorySource?.cancel()
        logsDirectorySource = nil
        watchedLogsDirectory = directory

        let descriptor = open(directory, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let eventSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: .main
        )
        eventSource.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.logChangePending = true
                self.extendFastPolling(from: Date().timeIntervalSince1970)
                self.scheduleNextPoll(after: 0.02)
            }
        }
        eventSource.setCancelHandler {
            close(descriptor)
        }
        logsDirectorySource = eventSource
        eventSource.resume()
    }

    func logReader(for logsDB: String) -> LiveRateLogReading {
        if let logReader, logReader.path == logsDB {
            return logReader
        }
        let reader = logReaderFactory.makeLiveRateLogReader(path: logsDB)
        logReader = reader
        return reader
    }

    func hasActiveRollingWindow(now: TimeInterval) -> Bool {
        selectedRate.hasRecentActivity(now: now, windowSeconds: windowSeconds)
            || totalRate.hasRecentActivity(now: now, windowSeconds: windowSeconds)
    }

    func extendFastPolling(from now: TimeInterval) {
        fastPollUntil = max(fastPollUntil, now + activeFastPollHoldSeconds)
    }

    func clearStreamState() {
        turnThreadIDs.removeAll()
        itemTurnIDs.removeAll()
        itemThreadIDs.removeAll()
        itemToolNames.removeAll()
        itemCallIDs.removeAll()
        countedStreamFingerprints.removeAll()
        countedRolloutFingerprints.removeAll()
        countedStreamVisibleFingerprints.removeAll()
        countedRolloutVisibleFingerprints.removeAll()
        visibleStreamAssemblies.removeAll()
        consumedVisibleAssemblyMatches.removeAll()
        clearPendingRolloutCompletions()
    }
}
