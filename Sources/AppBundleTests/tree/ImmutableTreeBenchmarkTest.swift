#if IMMUTABLE_TREE_BENCHMARK

@testable import AppBundle
import Common
import Foundation
import XCTest

@MainActor
final class ImmutableTreeBenchmarkTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testRefreshFromMutableTreeScaling() {
        for windowCount in benchmarkWindowCounts {
            setUpWorkspacesForTests()
            buildWorkspace(windowCount: windowCount)

            for _ in 0..<warmupIterations {
                TreeStore.shared.refreshFromMutableTree()
            }

            var samples: [Double] = []
            samples.reserveCapacity(measurementIterations)
            for _ in 0..<measurementIterations {
                let start = DispatchTime.now().uptimeNanoseconds
                TreeStore.shared.refreshFromMutableTree()
                let end = DispatchTime.now().uptimeNanoseconds
                samples.append(Double(end - start) / 1_000)
            }

            let summary = BenchmarkSummary(samples: samples)
            let nodeCount = TreeStore.shared.current.nodes.count
            print(
                "IMMUTABLE_TREE_BENCHMARK " +
                    "operation=refreshFromMutableTree " +
                    "windows=\(windowCount) " +
                    "nodes=\(nodeCount) " +
                    "iterations=\(measurementIterations) " +
                    "mean_us=\(format(summary.mean)) " +
                    "p50_us=\(format(summary.p50)) " +
                    "p95_us=\(format(summary.p95)) " +
                    "p99_us=\(format(summary.p99))",
            )
        }
    }

    private var benchmarkWindowCounts: [Int] {
        guard let rawValue = ProcessInfo.processInfo.environment["IMMUTABLE_TREE_BENCHMARK_WINDOWS"] else {
            return [10, 100, 500, 1_000]
        }
        let parsed = rawValue.split(separator: ",").compactMap { part -> Int? in
            let trimmed = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(trimmed)
        }
        return parsed.isEmpty ? [10, 100, 500, 1_000] : parsed
    }

    private var warmupIterations: Int {
        Int(ProcessInfo.processInfo.environment["IMMUTABLE_TREE_BENCHMARK_WARMUPS"] ?? "") ?? 20
    }

    private var measurementIterations: Int {
        Int(ProcessInfo.processInfo.environment["IMMUTABLE_TREE_BENCHMARK_ITERATIONS"] ?? "") ?? 200
    }

    private func buildWorkspace(windowCount: Int) {
        let workspace = Workspace.get(byName: name)
        var nextWindowId: UInt32 = 1

        func addWindows(to parent: NonLeafTreeNodeObject, count: Int) {
            for _ in 0..<count {
                TestWindow.new(id: nextWindowId, parent: parent)
                nextWindowId += 1
            }
        }

        func buildSubtree(parent: NonLeafTreeNodeObject, count: Int, depth: Int) {
            if count <= 8 {
                addWindows(to: parent, count: count)
                return
            }

            let branchCount = min(8, count)
            let baseChunkSize = count / branchCount
            var remainder = count % branchCount
            for branchIndex in 0..<branchCount {
                let chunkSize = baseChunkSize + (remainder > 0 ? 1 : 0)
                remainder -= remainder > 0 ? 1 : 0

                let container = (depth + branchIndex).isMultiple(of: 2)
                    ? TilingContainer.newHTiles(parent: parent, adaptiveWeight: 1)
                    : TilingContainer.newVTiles(parent: parent, adaptiveWeight: 1)
                buildSubtree(parent: container, count: chunkSize, depth: depth + 1)
            }
        }

        buildSubtree(parent: workspace.rootTilingContainer, count: windowCount, depth: 0)
        check(TestApp.shared.windows.last?.focusWindow() == true)
    }

    private func format(_ value: Double) -> String {
        let scaled = Int((value * 100).rounded())
        let whole = scaled / 100
        let fraction = abs(scaled % 100)
        return "\(whole).\(fraction < 10 ? "0" : "")\(fraction)"
    }
}

private struct BenchmarkSummary {
    let mean: Double
    let p50: Double
    let p95: Double
    let p99: Double

    init(samples: [Double]) {
        check(!samples.isEmpty)
        let sorted = samples.sorted()
        mean = samples.reduce(0, +) / Double(samples.count)
        p50 = Self.percentile(sorted, 0.50)
        p95 = Self.percentile(sorted, 0.95)
        p99 = Self.percentile(sorted, 0.99)
    }

    private static func percentile(_ sorted: [Double], _ percentile: Double) -> Double {
        let index = Int((Double(sorted.count - 1) * percentile).rounded(.up))
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}

#endif
