import Cocoa
import WebKit
import Foundation

// ── KeyRemapper Standalone App ──────────────────────────────────
// A minimal macOS app that launches the Python backend as a
// subprocess and displays the web UI in a WKWebView window.
// Everything is bundled inside the .app — no external dependencies.
//
// The web UI is served via a custom URL scheme (keyremapper://) which
// reads static files from disk and proxies API calls to the Python
// server.  This completely bypasses App Transport Security (ATS)
// which blocks http:// connections in WKWebView.

// ── Custom URL scheme handler ───────────────────────────────────
// Serves static files from the filesystem and proxies /api/ requests
// to the Python backend over HTTP (Swift→Python, not WKWebView→Python).

class KeyRemapperSchemeHandler: NSObject, WKURLSchemeHandler {
    let resourcesPath: String
    let serverPort: Int

    init(resourcesPath: String, serverPort: Int) {
        self.resourcesPath = resourcesPath
        self.serverPort = serverPort
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(NSError(domain: "KeyRemapper", code: 1))
            return
        }

        let path = url.path == "" ? "/" : url.path

        // ── API calls: proxy to Python server ──
        if path.hasPrefix("/api/") {
            proxyToPython(urlSchemeTask, path: path, url: url)
            return
        }

        // ── Static files: serve from filesystem ──
        serveStaticFile(urlSchemeTask, path: path, url: url)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Nothing to clean up (URLSession tasks auto-cancel on dealloc)
    }

    // ── Proxy an API request to the Python HTTP server ──
    private func proxyToPython(_ task: WKURLSchemeTask, path: String, url: URL) {
        let apiUrl = URL(string: "http://127.0.0.1:\(serverPort)\(path)")!
        var request = URLRequest(url: apiUrl)
        request.httpMethod = task.request.httpMethod ?? "GET"
        request.httpBody = task.request.httpBody

        // Copy relevant headers
        if let fields = task.request.allHTTPHeaderFields {
            for (key, value) in fields {
                if key.lowercased() != "host" {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                task.didFailWithError(error)
                return
            }
            guard let httpResp = response as? HTTPURLResponse, let data = data else {
                task.didFailWithError(NSError(domain: "KeyRemapper", code: 2))
                return
            }
            // Forward the response with its original status code + headers
            let headerFields = httpResp.allHeaderFields as? [String: String]
            let response = HTTPURLResponse(
                url: url,
                statusCode: httpResp.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headerFields
            )!
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        }.resume()
    }

    private func contentTypeFor(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html":          return "text/html; charset=utf-8"
        case "css":           return "text/css; charset=utf-8"
        case "js":            return "application/javascript; charset=utf-8"
        case "mp4", "m4v":    return "video/mp4"
        case "mov":           return "video/quicktime"
        case "png":           return "image/png"
        case "jpg", "jpeg":   return "image/jpeg"
        case "svg":           return "image/svg+xml"
        case "json":          return "application/json"
        case "ico":           return "image/x-icon"
        case "woff", "woff2": return "font/woff2"
        default:              return "application/octet-stream"
        }
    }

    // ── Serve a static file from the Resources directory ──
    private func serveStaticFile(_ task: WKURLSchemeTask, path: String, url: URL) {
        let filePath: String

        if path == "/" || path == "" {
            filePath = (resourcesPath as NSString).appendingPathComponent("templates/index.html")
        } else if !path.contains("..") {
            // Everything else lives under static/ — /style.css, /app.js,
            // /videos/*.mp4, etc.
            filePath = (resourcesPath as NSString).appendingPathComponent("static" + path)
        } else {
            let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/plain"])!
            task.didReceive(resp)
            task.didReceive("Not found".data(using: .utf8) ?? Data())
            task.didFinish()
            return
        }

        let contentType = contentTypeFor((filePath as NSString).pathExtension)

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/plain"])!
            task.didReceive(resp)
            task.didReceive("File not found: \(path)".data(using: .utf8) ?? Data())
            task.didFinish()
            return
        }

        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": contentType,
                                                  "Content-Length": "\(data.count)"])!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }
}

/// Transparent view that lets the window be dragged — the top strip
/// of the window acts as a drag region since the titlebar is hidden.
class DragRegionView: NSView {
    override var mouseDownCanMoveWindow: Bool { return true }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// ── App delegate ────────────────────────────────────────────────

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var webView: WKWebView?
    var port: Int = 0
    var serverProcess: Process?  // CRITICAL: keep alive so the child isn't killed
    var schemeHandler: KeyRemapperSchemeHandler?
    var resourcesPath: String = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        resourcesPath = findResourcesPath()

        let pythonPath = (resourcesPath as NSString).appendingPathComponent("app.py")
        let keyboardHelperPath = (resourcesPath as NSString).appendingPathComponent("keyboard_layout")

        // Remove stale runtime files before spawning — if the previous
        // instance was SIGKILLed (e.g. by the restart watchdog), the port
        // file would still hold a dead port and waitForPort() would grab
        // it before the new server writes its own.
        try? FileManager.default.removeItem(atPath: "/tmp/keyremapper-port")
        try? FileManager.default.removeItem(atPath: "/tmp/keyremapper-pid")

        // Launch the Python server directly — no shell wrapper, no nohup,
        // no backgrounding.  The Process object is stored as a class property
        // so it stays alive for the lifetime of the app.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = [pythonPath, "0"]
        task.currentDirectoryURL = URL(fileURLWithPath: resourcesPath)

        var env = ProcessInfo.processInfo.environment
        env["KEYREMAPPER_HELPER"] = keyboardHelperPath
        env["KEYREMAPPER_NO_BROWSER"] = "1"
        env["KEYREMAPPER_PORT_FILE"] = "/tmp/keyremapper-port"
        env["KEYREMAPPER_BUNDLE_PATH"] = Bundle.main.bundlePath
        task.environment = env

        // Redirect stdout/stderr to a log file
        let logPath = "/tmp/keyremapper-server.log"
        let logFD = open(logPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if logFD >= 0 {
            task.standardOutput = FileHandle(fileDescriptor: logFD, closeOnDealloc: true)
            let errFD = dup(logFD)
            if errFD >= 0 {
                task.standardError = FileHandle(fileDescriptor: errFD, closeOnDealloc: true)
            }
        }
        task.standardInput = FileHandle(forReadingAtPath: "/dev/null")

        task.terminationHandler = { process in
            let msg = "\n=== Server exited: status \(process.terminationStatus), reason \(process.terminationReason) ===\n"
            if let h = FileHandle(forWritingAtPath: logPath) {
                h.seekToEndOfFile()
                h.write(msg.data(using: .utf8) ?? Data())
                h.closeFile()
            }
        }

        do {
            try task.run()
            self.serverProcess = task
            try? String(task.processIdentifier).write(
                toFile: "/tmp/keyremapper-pid", atomically: true, encoding: .utf8)
        } catch {
            showError("Failed to start server: \(error.localizedDescription)")
            return
        }

        // Create the window
        let contentRect = NSRect(x: 0, y: 0, width: 1240, height: 760)
        let styleMask: NSWindow.StyleMask = [
            .titled, .closable, .miniaturizable, .resizable,
            .fullSizeContentView,
        ]
        window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window?.title = "KeyRemapper"
        window?.titlebarAppearsTransparent = true
        window?.titleVisibility = .hidden
        window?.center()
        window?.minSize = NSSize(width: 640, height: 540)

        // Poll until the server writes its port, then create the webview
        // with the scheme handler and load the page.
        waitForPort()

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func findResourcesPath() -> String {
        if let rp = Bundle.main.resourcePath {
            let appPy = (rp as NSString).appendingPathComponent("app.py")
            if FileManager.default.fileExists(atPath: appPy) {
                return rp
            }
        }
        let execPath = CommandLine.arguments[0]
        return (execPath as NSString).deletingLastPathComponent
    }

    /// Poll for the port file.  Once found, create the WKWebView with the
    /// custom scheme handler registered and load the page.
    func waitForPort(attempts: Int = 0) {
        guard attempts < 100 else {
            showError("Server failed to start after 10 seconds.")
            return
        }

        if let proc = serverProcess, !proc.isRunning {
            showError("Server process exited unexpectedly. Check /tmp/keyremapper-server.log")
            return
        }

        let portFile = "/tmp/keyremapper-port"
        if let content = try? String(contentsOfFile: portFile, encoding: .utf8),
           let serverPort = Int(content.trimmingCharacters(in: .whitespacesAndNewlines)),
           serverPort > 0 {
            port = serverPort
            DispatchQueue.main.async {
                self.createWebViewAndLoad()
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.waitForPort(attempts: attempts + 1)
            }
        }
    }

    /// Create the WKWebView with the custom scheme handler already registered,
    /// then load the page via keyremapper:// scheme.
    func createWebViewAndLoad() {
        // Create the scheme handler
        let handler = KeyRemapperSchemeHandler(resourcesPath: resourcesPath, serverPort: port)
        self.schemeHandler = handler

        // Create WKWebView config with the scheme handler registered
        // MUST be done before the webview is created.
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        // JS bridge for opening external links in the real browser —
        // window.open/target=_blank do nothing inside a WKWebView.
        ucc.add(self, name: "openExternal")
        config.userContentController = ucc
        config.setURLSchemeHandler(handler, forURLScheme: "keyremapper")
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let contentRect = window?.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1240, height: 760)
        let wv = WKWebView(frame: contentRect, configuration: config)
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = self
        self.webView = wv

        // Container holds the webview plus a native drag strip overlaid
        // across the top — WKWebView swallows events in subviews, so the
        // strip must be a sibling added on top, not a subview.
        let container = NSView(frame: contentRect)
        container.addSubview(wv)
        let dragHeight: CGFloat = 34
        let drag = DragRegionView(frame: NSRect(x: 0, y: contentRect.height - dragHeight,
                                                width: contentRect.width, height: dragHeight))
        drag.autoresizingMask = [.width, .minYMargin]
        container.addSubview(drag)
        window?.contentView = container

        // Load the page via our custom scheme — bypasses ATS completely
        let url = URL(string: "keyremapper:///")!
        wv.load(URLRequest(url: url))
    }

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "KeyRemapper Error"
        alert.informativeText = message
        alert.runModal()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        serverProcess?.terminate()
        try? FileManager.default.removeItem(atPath: "/tmp/keyremapper-port")
        try? FileManager.default.removeItem(atPath: "/tmp/keyremapper-pid")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

extension AppDelegate: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == "openExternal",
           let urlString = message.body as? String,
           let url = URL(string: urlString),
           url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
        }
    }
}

extension AppDelegate: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 didFinish navigation: WKNavigation!) {
        // Page loaded successfully
    }
}

// ── App entry point ────────────────────────────────────────────

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)

// The applet (the .app's CFBundleExecutable) is a background agent (LSUIElement),
// so only this Swift binary shows in the Dock.  Set its icon from the bundle's
// applet.icns so it uses the standard app icon instead of a generic exec icon.
if let iconPath = Bundle.main.path(forResource: "applet", ofType: "icns"),
   let icon = NSImage(contentsOfFile: iconPath) {
    app.applicationIconImage = icon
}

let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "About KeyRemapper", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(withTitle: "Quit KeyRemapper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu

// Edit menu — needed for Cmd+C/Cmd+V/Cmd+A to work in WKWebView text fields
let editMenuItem = NSMenuItem()
mainMenu.addItem(editMenuItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(NSMenuItem.separator())
editMenu.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")
editMenuItem.submenu = editMenu

app.mainMenu = mainMenu

app.run()
