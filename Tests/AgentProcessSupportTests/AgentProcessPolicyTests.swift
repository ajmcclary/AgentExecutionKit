import AgentProcessSupport
import XCTest

final class AgentProcessPolicyTests: XCTestCase {
    func testLaunchSourceIsExplicitAndHostNeutral() {
        let environment = ["HOST_LAUNCH_SOURCE": "launchservices", "XCTestSessionIdentifier": "test"]
        XCTAssertEqual(ProcessLaunchContext.detect(from: environment, launchSourceEnvironmentKey: "HOST_LAUNCH_SOURCE").source, .launchServices)
        XCTAssertEqual(ProcessLaunchContext.detect(from: environment).source, .xcode)
    }

    func testTerminalRequiresAnActualTerminalMarkerAndRichPath() {
        XCTAssertEqual(ProcessLaunchContext.detect(from: ["TERM": "xterm", "PATH": "/usr/bin:/bin"]).source, .unknown)
        XCTAssertEqual(ProcessLaunchContext.detect(from: ["TERM": "xterm", "PATH": "/opt/tools:/bin"]).source, .terminalInherited)
        XCTAssertEqual(ProcessLaunchContext.detect(from: ["PATH": "/opt/tools:/bin"]).source, .unknown)
    }

    func testSanitizationDropsLoaderPrefixesAndInjectedRemovalKeys() {
        let environment = ["PATH": "/bin", "DYLD_INSERT_LIBRARIES": "x", "__XPC_DYLD_CUSTOM": "x", "NODE_OPTIONS": "x", "NORMAL_VALUE": "y"]
        XCTAssertEqual(ProcessEnvironmentSanitizer.sanitizedForChildLaunch(environment, additionalRemovedKeys: ["NODE_OPTIONS"]), ["PATH": "/bin", "NORMAL_VALUE": "y"])
    }

    func testContextKeepsTheProvidedPathShellAndHome() {
        let context = ProcessLaunchContext.detect(from: ["PATH": "/custom:/bin", "SHELL": "/bin/zsh", "HOME": "/fixture/home"])
        XCTAssertEqual(context.inheritedEnvironmentPath, "/custom:/bin")
        XCTAssertEqual(context.shell, "/bin/zsh")
        XCTAssertEqual(context.home, "/fixture/home")
    }
}
