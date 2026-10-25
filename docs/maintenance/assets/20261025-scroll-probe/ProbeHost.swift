import AppKit
import XCTest
freopen("/tmp/tokenbar-scroll-20261025/host.log", "a", stderr)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let config = URL(fileURLWithPath: "/tmp/tokenbar-scroll-probe-config.json")
let env = try JSONDecoder().decode([String:String].self, from: Data(contentsOf: config))
for (key,value) in env where key.hasPrefix("CODEX_SCROLL_") || key == "CODEX_GUIDE_SCROLL_PERF" { setenv(key,value,1) }
let bundlePath = env["test_bundle"]!
guard let bundle = Bundle(path: bundlePath), bundle.load(), let entry = NSClassFromString("TokenBarScrollProbeEntry") else { fatalError("probe bundle load") }
let selector = NSSelectorFromString("run:")
let method = class_getClassMethod(entry, selector)!
typealias Start = @convention(c) (AnyClass, Selector, @escaping @convention(block) () -> Void) -> Void
let start = unsafeBitCast(method_getImplementation(method), to: Start.self)
DispatchQueue.main.asyncAfter(deadline:.now()+1) {
    start(entry, selector, { app.terminate(nil) })
}
app.run()
