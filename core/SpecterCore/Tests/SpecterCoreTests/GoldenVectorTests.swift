import XCTest
import Foundation
@testable import SpecterCore

final class GoldenVectorTests: XCTestCase {
    struct GoldenVector: Decodable {
        struct Expected: Decodable {
            let direct_bin: Int
            let target_bin: Int
            let range_m: Double
            let bpm: Double
            let conf: Double
            let disp_ptp_mm: Double
        }
        let name: String
        let fs: Double
        let n: Int
        let f0: Double
        let f1: Double
        let samples_b64: String
        let num_samples: Int
        let expected: Expected
    }

    func testGoldenVectorsMatchPython() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let goldenDir = testsDir
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("lab/golden")

        let files = try FileManager.default.contentsOfDirectory(at: goldenDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertFalse(files.isEmpty, "No golden vector JSON files found in \(goldenDir.path)")

        let pipeline = SpecterPipeline()
        for file in files {
            let data = try Data(contentsOf: file)
            let gv = try JSONDecoder().decode(GoldenVector.self, from: data)
            let rawData = Data(base64Encoded: gv.samples_b64)!
            let floatSamples: [Float] = rawData.withUnsafeBytes { ptr in
                Array(ptr.bindMemory(to: Float.self))
            }
            let samples = floatSamples.map { Double($0) }
            let result = pipeline.analyze(samples: samples)

            XCTAssertEqual(result.directBin, gv.expected.direct_bin, "Direct bin mismatch in \(gv.name)")
            XCTAssertEqual(result.targetBin, gv.expected.target_bin, "Target bin mismatch in \(gv.name)")
            XCTAssertEqual(result.rangeMeters, gv.expected.range_m, accuracy: 0.005, "Range mismatch in \(gv.name)")
            XCTAssertEqual(result.confidence, gv.expected.conf, accuracy: 0.02, "Confidence mismatch in \(gv.name)")
            XCTAssertEqual(result.bpm, gv.expected.bpm, accuracy: 0.2, "BPM mismatch in \(gv.name)")
            let ptp = (result.displacementMm.max() ?? 0) - (result.displacementMm.min() ?? 0)
            XCTAssertEqual(ptp, gv.expected.disp_ptp_mm, accuracy: max(0.05, gv.expected.disp_ptp_mm * 0.03), "Displacement mismatch in \(gv.name)")
        }
    }
}