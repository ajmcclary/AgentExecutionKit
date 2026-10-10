import Foundation

public struct ACPDiscoveredModel: Sendable, Equatable {
	public let rawValue: String
	public let displayName: String
	public let description: String?
	public let isProviderDefault: Bool
	public init(rawValue: String, displayName: String, description: String?, isProviderDefault: Bool) {
		self.rawValue = rawValue; self.displayName = displayName; self.description = description; self.isProviderDefault = isProviderDefault
	}
}
public struct ACPDiscoveredModels: Sendable, Equatable {
	public let options: [ACPDiscoveredModel]
	public let currentModelRaw: String?
	public init(options: [ACPDiscoveredModel], currentModelRaw: String?) { self.options = options; self.currentModelRaw = currentModelRaw }
}

/// Wire metadata only. Preference lookup, registry persistence and provider alias policy
/// remain host-owned. Config options precede legacy models, with stable case-folded dedup.
public enum ACPModelMetadata {
	public static func decode(from response: [String: Any], onUnusableMetadata: () -> Void = {}) -> ACPDiscoveredModels? {
		let modelSnapshot = parseModelsSnapshot(from: response["models"] as? [String: Any])
		let configSnapshot = parseConfigOptionsModelSnapshot(from: response["configOptions"] as? [[String: Any]])

		let currentModelRaw = configSnapshot.currentModelRaw ?? modelSnapshot.currentModelRaw
		var options = mergeModelOptions(configSnapshot.options + modelSnapshot.options)
		if let currentModelRaw,
			!options.contains(where: { $0.rawValue.caseInsensitiveCompare(currentModelRaw) == .orderedSame }) {
			options.insert(
				ACPDiscoveredModel(
					rawValue: currentModelRaw,
					displayName: currentModelRaw,
					description: nil,
					isProviderDefault: false
				),
				at: 0
			)
		}

		guard !options.isEmpty || currentModelRaw != nil else {
			if response["models"] != nil || response["configOptions"] != nil {
				onUnusableMetadata()
			}
			return nil
		}

		return ACPDiscoveredModels(
			options: options,
			currentModelRaw: currentModelRaw
		)
	}

	private static func parseModelsSnapshot(from models: [String: Any]?) -> (currentModelRaw: String?, options: [ACPDiscoveredModel]) {
		guard let models else { return (nil, []) }
		let currentModelRaw = normalizedACPModelString(models["currentModelId"] as? String)
		let availableModels = models["availableModels"] as? [[String: Any]] ?? []
		let options = availableModels.compactMap(parseDiscoveredModelOption)
		return (currentModelRaw, options)
	}

	private static func parseConfigOptionsModelSnapshot(
		from configOptions: [[String: Any]]?
	) -> (currentModelRaw: String?, options: [ACPDiscoveredModel]) {
		guard let modelOption = configOptions?.first(where: { rawOption in
			let id = normalizedACPModelString(rawOption["id"] as? String)?.lowercased()
			let category = normalizedACPModelString(rawOption["category"] as? String)?.lowercased()
			return id == "model" || category == "model"
		}) else {
			return (nil, [])
		}
		let currentModelRaw = normalizedACPModelString(modelOption["currentValue"] as? String)
		let rawOptions = modelOption["options"] as? [[String: Any]] ?? []
		let options = rawOptions.compactMap(parseDiscoveredConfigModelOption)
		return (currentModelRaw, options)
	}

	private static func mergeModelOptions(_ rawOptions: [ACPDiscoveredModel]) -> [ACPDiscoveredModel] {
		var options: [ACPDiscoveredModel] = []
		var seenModelIDs = Set<String>()
		for option in rawOptions {
			let storageKey = option.rawValue.lowercased()
			guard seenModelIDs.insert(storageKey).inserted else { continue }
			options.append(option)
		}
		return options
	}

	private static func parseDiscoveredModelOption(from rawModel: [String: Any]) -> ACPDiscoveredModel? {
		guard let rawValue = normalizedACPModelString(
			(rawModel["modelId"] as? String) ?? (rawModel["id"] as? String)
		) else {
			return nil
		}
		let displayName = normalizedACPModelString(
			(rawModel["name"] as? String) ?? (rawModel["displayName"] as? String)
		) ?? rawValue
		return ACPDiscoveredModel(
			rawValue: rawValue,
			displayName: displayName,
			description: normalizedACPModelString(rawModel["description"] as? String),
			isProviderDefault: rawModel["isDefault"] as? Bool ?? false
		)
	}

	private static func parseDiscoveredConfigModelOption(from rawOption: [String: Any]) -> ACPDiscoveredModel? {
		guard let rawValue = normalizedACPModelString(
			(rawOption["value"] as? String) ?? (rawOption["modelId"] as? String) ?? (rawOption["id"] as? String)
		) else {
			return nil
		}
		let displayName = normalizedACPModelString(
			(rawOption["name"] as? String) ?? (rawOption["displayName"] as? String)
		) ?? rawValue
		return ACPDiscoveredModel(
			rawValue: rawValue,
			displayName: displayName,
			description: normalizedACPModelString(rawOption["description"] as? String),
			isProviderDefault: rawOption["isDefault"] as? Bool ?? false
		)
	}

	private static func normalizedACPModelString(_ value: String?) -> String? {
		guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
		return trimmed
	}
}
