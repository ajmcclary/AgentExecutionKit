import Foundation
import XCTest
import AgentACPRPC

final class ACPWireContractTests: XCTestCase {
	func testTypedPermissionIdentitiesStayDistinct() {
		XCTAssertNotEqual(ACPRequestID.string("1"), .int(1))
		XCTAssertEqual(ACPRequestID.string("1").storageKey, "s:1")
		XCTAssertEqual(ACPRequestID.int(1).storageKey, "i:1")
		XCTAssertEqual(ACPRequestID.double(1).storageKey, "d:1.0")
	}
	func testCompatibilityAliasesPreserveCanonicalAndSafeIntegerBounds() {
		XCTAssertEqual(ACPRequestID.string("1").compatibleResponseKeys, ["s:1", "i:1", "d:1.0"])
		for spelling in ["+1", "01", "-0", " 1", "1e0", "1.0", "1e300", "9007199254740992"] {
			XCTAssertEqual(ACPRequestID.string(spelling).compatibleResponseKeys, ["s:\(spelling)"])
		}
		for number in [Double.infinity, Double.nan, 1e300, 9_007_199_254_740_992, 1.5] {
			XCTAssertEqual(ACPRequestID.double(number).compatibleResponseKeys.count, 1)
		}
		XCTAssertEqual(ACPRequestID.int(Int.min).compatibleResponseKeys, ["i:\(Int.min)"])
	}
	func testFoundationBooleanAndHostileNumericIDs() throws {
		let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("{\"bool\":true,\"huge\":1e300,\"ordinary\":1}".utf8)) as? [String: Any])
		XCTAssertNil(ACPRequestID.decode(object["bool"]))
		XCTAssertEqual(ACPRequestID.decode(object["ordinary"]), .int(1))
		XCTAssertEqual(ACPRequestID.decode(object["huge"])?.compatibleResponseKeys.count, 1)
		XCTAssertNil(ACPRequestID.decode(NSNull()))
	}
	func testErrorCodeDoesNotWrapUnsignedProviderNumber() throws {
		let error = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("{\"code\":18446744073709519014}".utf8)) as? [String: Any])
		XCTAssertNil(ACPResponseError.code(from: error))
		XCTAssertEqual(ACPResponseError.code(from: ["code": -32602]), -32602)
		XCTAssertNil(ACPResponseError.code(from: ["code": true]))
		XCTAssertNil(ACPResponseError.code(from: ["code": 1e300]))
	}
	func testNestedDetailsFallbackAndBoundedSortedJSONPreview() {
		XCTAssertEqual(ACPResponseError.message(from: [:]), "Unknown ACP error")
		XCTAssertEqual(ACPResponseError.message(from: ["message": " base ", "data": ["error": ["message": " detail "]]]), "base: detail")
		XCTAssertEqual(ACPResponseError.message(from: ["message": "base", "data": "base"]), "base")
		XCTAssertEqual(ACPResponseError.message(from: ["message": "base", "data": ["z": 2, "a": 1]]), "base: {\"a\":1,\"z\":2}")
		let message = ACPResponseError.message(from: ["data": [String(repeating: "x", count: 3000)]])
		XCTAssertEqual(message.count, "Unknown ACP error: ".count + 2001)
		XCTAssertTrue(message.hasSuffix("…"))
	}
}
