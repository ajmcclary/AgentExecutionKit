import Foundation
import XCTest
import AgentACPSession

final class ACPMetadataTests: XCTestCase {
	func testConfigOptionsPrecedeLegacyModelsAndDeduplicateStably() {
		let snapshot = ACPModelMetadata.decode(from: [
			"models": ["currentModelId": "legacy", "availableModels": [["modelId": " M ", "name": "legacy label"], ["id": "other"]]],
			"configOptions": [["id": " MODEL ", "currentValue": " M ", "options": [["value": "m", "name": "config label", "description": " detail ", "isDefault": true]]]]
		])
		XCTAssertEqual(snapshot?.currentModelRaw, "M")
		XCTAssertEqual(snapshot?.options.map(\.rawValue), ["m", "other"])
		XCTAssertEqual(snapshot?.options.first?.displayName, "config label")
		XCTAssertEqual(snapshot?.options.first?.description, "detail")
		XCTAssertEqual(snapshot?.options.first?.isProviderDefault, true)
	}
	func testUnknownCurrentModelIsInsertedWithoutChangingRawSpelling() {
		let snapshot = ACPModelMetadata.decode(from: ["models": ["currentModelId": " Current ", "availableModels": [["id": "other"]]]])
		XCTAssertEqual(snapshot?.options.map(\.rawValue), ["Current", "other"])
		XCTAssertEqual(snapshot?.options.first?.isProviderDefault, false)
	}
	func testModelAndConfigAliasesMissingLabelsAndBlankEntries() {
		let snapshot = ACPModelMetadata.decode(from: [
			"configOptions": [["category": "model", "options": [["modelId": " one ", "displayName": " One "], ["id": "two"], ["value": " "]]]]
		])
		XCTAssertEqual(snapshot?.options.map(\.rawValue), ["one", "two"])
		XCTAssertEqual(snapshot?.options.map(\.displayName), ["One", "two"])
	}
	func testUnusableMetadataEmitsDiagnosticOnlyWhenMetadataWasPresent() {
		var diagnostics = 0
		XCTAssertNil(ACPModelMetadata.decode(from: [:]) { diagnostics += 1 })
		XCTAssertEqual(diagnostics, 0)
		XCTAssertNil(ACPModelMetadata.decode(from: ["models": NSNull(), "configOptions": []]) { diagnostics += 1 })
		XCTAssertEqual(diagnostics, 1)
	}
	func testSessionValidatorUTF8ByteBoundAndUnicodeControlRules() {
		XCTAssertEqual(ACPSessionIdentity.validated(" raw é "), " raw é ")
		for id in ["", "  ", "x\n", "x\u{85}", "x\u{2028}", "x\u{2029}", "x\u{200d}", "x\u{2066}"] { XCTAssertNil(ACPSessionIdentity.validated(id)) }
		XCTAssertNotNil(ACPSessionIdentity.validated(String(repeating: "é", count: 2048)))
		XCTAssertNil(ACPSessionIdentity.validated(String(repeating: "é", count: 2049)))
	}
}
