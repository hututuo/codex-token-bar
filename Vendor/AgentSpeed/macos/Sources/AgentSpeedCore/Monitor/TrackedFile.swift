import Foundation

/// One transcript file being followed: its reader, its parser and the last observed stat.
final class TrackedFile {
    let path: String
    let family: TranscriptFamily
    /// The root the file was discovered under (omp derives sub-agents from it).
    let root: String
    let fileID: FileID
    var reader: TranscriptReader
    var parser: TranscriptParser
    /// For an Antigravity database, the `.db` with its `-wal` folded in (`FileStat.databaseStat`).
    var lastStat: FileStat
    /// A whole-file read of this file runs off the session queue (METRICS 5.3).
    var wholeReadInFlight = false
    /// The file changed again while that read ran; read once more when it completes.
    var wholeReadAgain = false
    /// Uptime of the last database read; a database is read at most once per `TranscriptSession.databaseReadIntervalNs`.
    var lastReadNs: UInt64 = 0
    /// The database changed while a read was throttled; read it once the interval has passed.
    var isDirty = false

    init(
        path: String,
        family: TranscriptFamily,
        root: String,
        fileID: FileID,
        stat: FileStat,
        start: FileTailer.Start,
        maxLineBytes: Int = FileTailer.defaultMaxLineBytes
    ) {
        self.path = path
        self.family = family
        self.root = root
        self.fileID = fileID
        lastStat = stat
        reader = TranscriptReader(path: path, start: start, maxLineBytes: maxLineBytes, readsHeaderFirst: family == .omp)
        parser = TranscriptParser(family: family, agentId: path, fileID: fileID, root: root)
    }

    /// Parser state restarts after truncation or replacement; the global dedupe set is kept.
    func resetParser() {
        parser = TranscriptParser(family: family, agentId: path, fileID: fileID, root: root)
    }

    func hasChanged(comparedTo stat: FileStat) -> Bool {
        stat.size != lastStat.size || stat.modifiedNs != lastStat.modifiedNs || stat.identity != lastStat.identity
    }
}
