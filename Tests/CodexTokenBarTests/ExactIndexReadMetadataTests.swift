import Foundation
import XCTest
@testable import CodexTokenBar

final class ExactIndexReadMetadataTests: XCTestCase {
    func testCombinedInspectionPreservesProvenanceEnrichmentAndCoverageBeforeAndAfterPublish() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("exact-metadata-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: root.appendingPathComponent("index.sqlite"))
        func verify() throws {
            let metadata = try index.readMetadata()
            XCTAssertEqual(metadata.attribution, try index.attributionState())
            XCTAssertEqual(metadata.enrichmentComplete, try index.eventEnrichmentIsComplete())
            XCTAssertEqual(metadata.certificate, try index.coverageCertificate())
            if let certificate = metadata.certificate {
                XCTAssertEqual(certificate.generation, metadata.attribution.generation)
                XCTAssertEqual(certificate.provenanceEpoch, metadata.attribution.provenanceEpoch)
            }
        }
        try verify()
        _ = try index.synchronize(files: [], sessionID: { $0.lastPathComponent }) { _, _, _, _, _ in
            XCTFail("No files may be parsed by metadata inspection")
            throw NSError(domain: "UnexpectedParser", code: 1)
        }
        try verify()
        let reopened = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: root.appendingPathComponent("index.sqlite"))
        XCTAssertEqual(try reopened.readMetadata().attribution, try index.readMetadata().attribution)
    }
}
