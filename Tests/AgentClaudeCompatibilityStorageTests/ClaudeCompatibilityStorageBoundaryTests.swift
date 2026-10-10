import Foundation
import XCTest
import AgentClaudeCompatibilityStorage
import ClaudeRuntimeKit
import AIClientStorage

final class ClaudeCompatibilityStorageBoundaryTests: XCTestCase {
    private let sha = ClaudeSHA256(String(repeating: "a", count: 64))!
    private let environment = ClaudeCompatibilityCacheEnvironment(manifestVersion: "2026-07-21.1", appBuild: "build-100", probeSchemaVersion: 1)

    func testLegacyEnvelopeAndRecordDecodeWithoutReencoding() throws {
        let suite = "legacy-cache-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = CacheTestKeys.key(seed: 1)
        // Hand-authored historical schema; no current encoder is used to make the fixture.
        let record = Data("""
        {"sha256":"\(sha.value)","launchProfileKey":"\(key.digest.value)","manifestVersion":"2026-07-21.1","appBuild":"build-100","probeSchemaVersion":1,"classification":"exactCertified","validation":"observedPassed"}
        """.utf8)
        let storageKey = ClaudeCompatibilityCache.storageKey(sha256: sha, launchProfileKey: key)
        let legacy = Data("""
        {"order":["\(storageKey)"],"entries":{"\(storageKey)":"\(record.base64EncodedString())"}}
        """.utf8)
        defaults.set(legacy, forKey: "claude.compatibility.cache.v1")
        let cache = ClaudeCompatibilityCache(preferences: AIDefaultsDataPreferences(defaults: defaults), namespace: "claude.compatibility.cache.v1", environment: environment)
        XCTAssertEqual(cache.lookup(sha256: sha, launchProfileKey: key).record?.classification, .exactCertified)
        XCTAssertEqual(defaults.data(forKey: "claude.compatibility.cache.v1"), legacy, "lookup must not rewrite historical bytes")
    }

    func testUnknownOutcomeAndMalformedEnvelopeAreMisses() throws {
        let suite = "future-cache-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = CacheTestKeys.key(seed: 1)
        let cache = ClaudeCompatibilityCache(preferences: AIDefaultsDataPreferences(defaults: defaults), namespace: "history", environment: environment)
        cache.store(sha256: sha, launchProfileKey: key, classification: .exactCertified, validation: .observedPassed)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: "history"))) as? [String: Any])
        let recordKey = ClaudeCompatibilityCache.storageKey(sha256: sha, launchProfileKey: key)
        var entries = try XCTUnwrap(envelope["entries"] as? [String: String])
        let raw = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(entries[recordKey])))
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        record["classification"] = "futureClassification"
        entries[recordKey] = try JSONSerialization.data(withJSONObject: record).base64EncodedString()
        envelope["entries"] = entries
        defaults.set(try JSONSerialization.data(withJSONObject: envelope), forKey: "history")
        XCTAssertEqual(cache.lookup(sha256: sha, launchProfileKey: key), .miss(.corruptRecord))
        defaults.set(Data("malformed".utf8), forKey: "history")
        XCTAssertEqual(cache.lookup(sha256: sha, launchProfileKey: key), .miss(.noRecord))
        XCTAssertTrue(cache.store(sha256: sha, launchProfileKey: key, classification: .exactLimited, validation: .observedFailed))
        XCTAssertEqual(cache.lookup(sha256: sha, launchProfileKey: key).record?.classification, .exactLimited)
    }

    func testHostsHaveIsolatedNamespacesAndRemoval() throws {
        let suite = "isolated-cache-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = CacheTestKeys.key(seed: 1)
        let first = ClaudeCompatibilityCache(preferences: AIDefaultsDataPreferences(defaults: defaults), namespace: "host.first", environment: environment)
        let second = ClaudeCompatibilityCache(preferences: AIDefaultsDataPreferences(defaults: defaults), namespace: "host.second", environment: environment)
        first.store(sha256: sha, launchProfileKey: key, classification: .exactCertified, validation: .observedPassed)
        XCTAssertEqual(second.lookup(sha256: sha, launchProfileKey: key), .miss(.noRecord))
        second.store(sha256: sha, launchProfileKey: key, classification: .knownBadMatch, validation: .observedFailed)
        first.removeAll()
        XCTAssertEqual(first.lookup(sha256: sha, launchProfileKey: key), .miss(.noRecord))
        XCTAssertEqual(second.lookup(sha256: sha, launchProfileKey: key).record?.classification, .knownBadMatch)
    }

    func testConcurrentCallsOnOneStoreDoNotLoseRecords() throws {
        let suite = "concurrent-cache-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = ClaudeCompatibilityCache(preferences: AIDefaultsDataPreferences(defaults: defaults), namespace: "history", environment: environment)
        let identity = sha
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            cache.store(sha256: identity, launchProfileKey: CacheTestKeys.key(seed: index), classification: .exactCertified, validation: .observedPassed)
        }
        for index in 0..<8 {
            XCTAssertNotNil(cache.lookup(sha256: sha, launchProfileKey: CacheTestKeys.key(seed: index)).record)
        }
    }
}
