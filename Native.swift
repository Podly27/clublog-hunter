import AppKit
import Security
import WebKit

private enum ClubLogKeychain {
    static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "cz.dxlovec.native.clublog",
        kSecAttrAccount as String: "api-token"
    ]

    static func read() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) -> OSStatus {
        if token.isEmpty {
            let result = SecItemDelete(query as CFDictionary)
            return result == errSecItemNotFound ? errSecSuccess : result
        }
        let data = Data(token.utf8)
        var request = query
        request[kSecValueData as String] = data
        let result = SecItemAdd(request as CFDictionary, nil)
        guard result == errSecDuplicateItem else { return result }
        return SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    }
}

final class Worker {
    private let queue = DispatchQueue(label: "ClubLog Hunter CAT")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()

    func request(_ action: String, _ data: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        queue.async {
            let response: [String: Any]
            do { response = try self.send(action, data) }
            catch { response = ["error": error.localizedDescription] }
            DispatchQueue.main.async { reply(response) }
        }
    }

    private func send(_ action: String, _ data: [String: Any]) throws -> [String: Any] {
        if process?.isRunning != true {
            let process = Process()
            let stdin = Pipe()
            let stdout = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-B", Bundle.main.url(forResource: "lovec", withExtension: "py")!.path]
            process.standardInput = stdin
            process.standardOutput = stdout
            try process.run()
            self.process = process
            input = stdin.fileHandleForWriting
            output = stdout.fileHandleForReading
            buffer = Data()
        }
        var request = try JSONSerialization.data(withJSONObject: ["action": action, "data": data])
        request.append(10)
        try input!.write(contentsOf: request)
        while true {
            if let end = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: end)
                buffer.removeSubrange(...end)
                if let result = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                    return result
                }
            }
            let chunk = output!.availableData
            guard !chunk.isEmpty else { return ["error": "The radio connection process stopped. Try again."] }
            buffer.append(chunk)
        }
    }
}

final class ActionButton: NSButton {
    private let actionBlock: () -> Void
    init(_ title: String, _ action: @escaping () -> Void) {
        actionBlock = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        self.action = #selector(performAction)
    }
    func setBackground(_ color: NSColor?, textColor: NSColor = .labelColor, border: NSColor? = nil) {
        isBordered = color == nil
        wantsLayer = color != nil
        layer?.cornerRadius = 6
        layer?.backgroundColor = color?.cgColor
        layer?.borderColor = border?.cgColor
        layer?.borderWidth = border == nil ? 0 : 2
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: textColor
        ])
    }

    required init?(coder: NSCoder) { nil }
    @objc private func performAction() { actionBlock() }
}

private enum Appearance: String, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var nativeAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    private let appearanceKey = "appearance"
    private var selectedAppearance: Appearance {
        UserDefaults.standard.string(forKey: appearanceKey)
            .flatMap(Appearance.init(rawValue:)) ?? .system
    }

    let worker = Worker()
    var window: NSWindow!
    let tabs = NSTabView()
    let status = NSTextField(labelWithString: "Radio disconnected")
    let radioDot = NSImageView()
    let radioLabel = NSTextField(labelWithString: "Disconnected")
    var radioConnected = false
    var radioCheckInProgress = false
    var radioTimer: Timer?
    let log = NSTextField(labelWithString: "Worked slots not loaded")
    let target = NSPopUpButton()
    var refreshTimer: Timer?
    let refreshLabel = NSTextField(labelWithString: "Club Log —  ·  Live —")
    var nextClubRefresh = Date.distantPast
    var nextLiveRefresh = Date.distantPast
    var expeditionRefreshInProgress = false
    var clubExpeditions: [String]?
    let lastExpeditionKey = "lastSelectedExpedition"
    private var livestream: WKWebView?
    private var streamCall = ""
    private var liveSlots: [String: [String: String]] = [:]
    private var liveSlotsValidUntil = Date.distantPast
    private var streamReadInProgress = false
    private var retryStreamAfter = Date.distantPast
    let frequency = NSTextField(string: "14.074")
    let operatorCall = NSTextField()
    let targets = NSTextField(string: "C8K")
    let port = NSComboBox()
    let baud = NSTextField(string: "57600")
    let address = NSTextField(string: "B6")
    let key = NSSecureTextField()
    let bands = [160, 80, 60, 40, 30, 20, 17, 15, 12, 10, 6, 4]
    let modes = ["C", "P", "D"]
    var slots: [String: [String: String]] = [:]
    var worked: [String: Set<String>] = [:]
    var rows: [[ActionButton]] = []
    var memories: [NSTextField] = []
    var lookupInProgress = false
    var busy = false
    var simulated = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = selectedAppearance.nativeAppearance
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 690),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "ClubLog Hunter · IC-7300MK2"
        window.minSize = NSSize(width: 720, height: 650)
        window.center()
        let spacer = NSView()
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        radioLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        radioDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        radioDot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        refreshLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        refreshLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let footer = stack([status, spacer, refreshLabel, radioDot, radioLabel], vertical: false)
        let layout = stack([tabs, footer])
        footer.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        window.contentView = viewWith(stack: layout, padding: 18, stretch: true)
        updateRadioIndicator()
        addTab("Overview", buildHunt())
        addTab("CW", buildMemories())
        addTab("Settings", buildSetup())
        target.target = self
        target.action = #selector(changeExpedition)
        port.stringValue = "/dev/cu.usbmodem12103"
        refreshTargets()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        run("setup") { [self] result in
            guard let result = result as? [String: Any] else { return }
            self.port.addItems(withObjectValues: result["ports"] as? [String] ?? [])
            let config = result["config"] as? [String: Any] ?? [:]
            for (name, field) in self.fields {
                if let saved = config[name] as? String { field.stringValue = saved }
            }
            self.slots = config["frequencies"] as? [String: [String: String]] ?? [:]
            self.key.stringValue = ClubLogKeychain.read() ?? ""
            self.refreshTargets()
            self.refreshLiveActivity()
            self.connect(false)
            self.refreshClubLog()
            self.radioTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.checkRadioConnection()
            }
            self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.updateRefreshCountdown()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    var fields: [String: NSTextField] {
        ["operator": operatorCall, "targets": targets, "port": port, "baud": baud, "address": address]
    }

    func stack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat = 8) -> NSStackView {
        let layout = NSStackView(views: views)
        layout.orientation = vertical ? .vertical : .horizontal
        layout.alignment = vertical ? .leading : .centerY
        layout.spacing = spacing
        return layout
    }

    func viewWith(stack: NSStackView, padding: CGFloat, stretch: Bool = false) -> NSView {
        let view = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -padding),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: padding),
            stretch ? stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -padding)
                : stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -padding)
        ])
        return view
    }

    func addTab(_ name: String, _ content: NSStackView) {
        let item = NSTabViewItem(identifier: name)
        item.label = name
        item.view = viewWith(stack: content, padding: 16)
        tabs.addTabViewItem(item)
        if tabs.numberOfTabViewItems == 1, let parent = tabs.superview {
            tabs.widthAnchor.constraint(equalTo: parent.widthAnchor).isActive = true
        }
    }

    func label(_ text: String, width: CGFloat? = nil, alignment: NSTextAlignment = .left) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = alignment
        if let width { field.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return field
    }

    func buildHunt() -> NSStackView {
        let head = stack([
            label("Expedition"), target, ActionButton("Refresh worked slots") { self.refreshClubLog(manual: true) },
            ActionButton("Livestream web") { self.openStream() },
            ActionButton("Refresh live activity") { self.refreshLiveActivity(manual: true) }
        ], vertical: false)
        let heading = stack([
            label("Band", width: 68, alignment: .center),
            label("CW", width: 125, alignment: .center),
            label("Phone", width: 125, alignment: .center),
            label("Data / FT8", width: 125, alignment: .center)
        ], vertical: false)
        let table = stack([heading], spacing: 2)
        for band in bands {
            let buttons = modes.map { mode in
                let button = ActionButton("—") { self.selectSlot(band, mode) }
                button.widthAnchor.constraint(equalToConstant: 125).isActive = true
                button.heightAnchor.constraint(equalToConstant: 24).isActive = true
                return button
            }
            rows.append(buttons)
            table.addArrangedSubview(stack([label("\(band) m", width: 68)] + buttons, vertical: false))
        }
        let layout = stack([head, table, log])
        layout.setCustomSpacing(18, after: head)
        layout.setCustomSpacing(12, after: table)
        layout.alignment = .centerX
        return layout
    }

    func buildMemories() -> NSStackView {
        let layout = stack([])
        layout.alignment = .centerX
        for index in 1...8 {
            let field = NSTextField()
            field.widthAnchor.constraint(equalToConstant: 420).isActive = true
            memories.append(field)
            let transmit = ActionButton("TX") { self.run("send_memory", ["index": index]) }
            transmit.widthAnchor.constraint(equalToConstant: 54).isActive = true
            transmit.heightAnchor.constraint(equalToConstant: 24).isActive = true
            transmit.setBackground(NSColor(srgbRed: 0.69, green: 0.14, blue: 0.18, alpha: 1), textColor: .white)
            transmit.toolTip = "Transmit M\(index)"
            layout.addArrangedSubview(stack([label("M\(index)", width: 34), field,
                ActionButton("Write") { self.writeMemory(index) },
                transmit], vertical: false))
        }
        layout.addArrangedSubview(stack([
            ActionButton("Read from radio") { self.readMemories() },
            ActionButton("Stop CW") { self.run("stop_cw") },
            ActionButton("Save set…") { self.saveMemories() },
            ActionButton("Open set…") { self.loadMemories() }
        ], vertical: false))
        layout.addArrangedSubview(label("TX sends the text stored in the radio. CW and break-in are required."))
        return layout
    }

    func buildSetup() -> NSStackView {
        let layout = stack([])
        let appearance = NSPopUpButton()
        appearance.addItems(withTitles: Appearance.allCases.map(\.rawValue))
        appearance.selectItem(withTitle: selectedAppearance.rawValue)
        appearance.target = self
        appearance.action = #selector(changeAppearance(_:))
        layout.addArrangedSubview(stack([label("Appearance", width: 170), appearance], vertical: false))

        let entries: [(String, NSTextField)] = [
            ("My callsign", operatorCall), ("Watched callsigns", targets),
            ("Club Log API token", key), ("CI-V port", port),
            ("Baud rate", baud), ("CI-V address (hex)", address)
        ]
        for (title, field) in entries {
            field.widthAnchor.constraint(equalToConstant: 370).isActive = true
            layout.addArrangedSubview(stack([label(title, width: 170), field], vertical: false))
        }
        layout.addArrangedSubview(label("Set USB (B) Function to CI-V on the radio. Disable Enable Tx in WSJT-X before tuning."))
        layout.addArrangedSubview(stack([
            ActionButton("Save settings") { self.save(includeToken: true) },
            ActionButton("Connect radio") { self.connect(false) },
            ActionButton("Simulation") { self.connect(true) },
            ActionButton("Disconnect") {
                self.run("disconnect") { _ in
                    self.simulated = false
                    self.radioConnected = false
                    self.updateRadioIndicator()
                }
            }
        ], vertical: false))
        return layout
    }

    @objc private func changeAppearance(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem, let appearance = Appearance(rawValue: title) else { return }
        UserDefaults.standard.set(appearance.rawValue, forKey: appearanceKey)
        NSApp.appearance = appearance.nativeAppearance
    }

    func run(_ action: String, _ data: [String: Any] = [:], completion: ((Any?) -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        status.stringValue = "Working…"
        worker.request(action, data) { response in
            self.busy = false
            if let error = response["error"] as? String { self.status.stringValue = error; return }
            let result = response["result"]
            let detail = result as? String ?? "Done"
            self.status.stringValue = self.simulated && !detail.hasPrefix("Simulation") && action != "disconnect"
                ? "Simulation · \(detail)" : detail
            completion?(result)
        }
    }

    func connect(_ simulate: Bool) {
        var data: [String: Any] = fields.mapValues { $0.stringValue }
        data["simulate"] = simulate
        run("connect", data) { _ in
            self.simulated = simulate
            self.radioConnected = !simulate
            self.updateRadioIndicator()
            self.readMemories()
        }
    }

    func updateRadioIndicator() {
        radioDot.contentTintColor = radioConnected ? .systemGreen : .systemRed
        radioLabel.stringValue = radioConnected ? "Connected" : (simulated ? "Simulation" : "Disconnected")
    }

    func checkRadioConnection() {
        guard radioConnected, !busy, !radioCheckInProgress else { return }
        radioCheckInProgress = true
        worker.request("radio_status", [:]) { response in
            self.radioCheckInProgress = false
            guard self.radioConnected, response["result"] as? Bool != true else { return }
            self.radioConnected = false
            self.updateRadioIndicator()
            self.status.stringValue = "The radio stopped responding."
        }
    }

    func save(includeToken: Bool = false) {
        var data: [String: Any] = fields.mapValues { $0.stringValue }
        data["frequencies"] = slots
        let token = key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        run("save", data) { _ in
            if includeToken { self.saveToken(token) }
            self.refreshTargets()
            self.refreshLiveActivity()
            if includeToken { self.refreshClubLog() }
        }
    }

    func refreshTargets() {
        let previous = target.titleOfSelectedItem
        var seen = Set<String>()
        let names = targets.stringValue.uppercased().split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        target.removeAllItems()
        target.addItems(withTitles: clubExpeditions ?? names.sorted())
        let saved = UserDefaults.standard.string(forKey: lastExpeditionKey)
        if let saved, target.itemTitles.contains(saved) {
            target.selectItem(withTitle: saved)
        } else if let previous, target.itemTitles.contains(previous) {
            target.selectItem(withTitle: previous)
        }
        refreshSlots()
    }

    var expedition: String { target.titleOfSelectedItem ?? "" }
    var lookupKey: String { "\(operatorCall.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()):\(expedition)" }

    @objc func refreshSlots() {
        let matches = worked[lookupKey]
        if clubExpeditions?.isEmpty == true {
            log.stringValue = "Club Log · No expeditions with a QSO in the past 7 days."
        } else {
            log.stringValue = matches.map { "Club Log · \($0.count) worked slots" } ?? "Worked slots not loaded"
        }
        for (row, band) in bands.enumerated() {
            for (column, mode) in modes.enumerated() {
                let hit = matches?.contains("\(band):\(mode)") == true
                let saved = slots["\(expedition):\(band):\(mode)"]?["frequency"]
                let button = rows[row][column]
                let spot = liveSlot(band, mode)
                let frequency = spot?["frequency"]
                let displayedFrequency = frequency ?? (spot != nil ? saved : nil)
                let frequencyTitle = displayedFrequency
                    .flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
                    .map { String(format: "%.3f", $0) }
                button.title = frequencyTitle ?? (spot != nil ? "QRV" : (hit ? "" : "—"))
                let workedColor = NSColor(srgbRed: 0.55, green: 0.83, blue: 0.61, alpha: 1)
                let qrvColor = NSColor(srgbRed: 1, green: 0.84, blue: 0.39, alpha: 1)
                let background = hit ? workedColor : (spot != nil ? qrvColor : nil)
                button.setBackground(background, textColor: background == nil ? .labelColor : .black)
                if let frequency, let reportedMode = spot?["mode"] {
                    button.toolTip = "Club Log Livestream · \(frequency) MHz · \(reportedMode)"
                } else if let saved {
                    button.toolTip = "Saved manually · \(saved) MHz · Option-click to edit"
                } else if spot != nil {
                    button.toolTip = "Club Log Livestream · Click to enter a frequency"
                } else {
                    button.toolTip = nil
                }
            }
        }
    }

    @objc func changeExpedition() {
        if !expedition.isEmpty { UserDefaults.standard.set(expedition, forKey: lastExpeditionKey) }
        refreshSlots()
        refreshLiveActivity()
        lookup(automatic: true)
    }

    func refreshLiveActivity(manual: Bool = false) {
        let call = expedition
        if call != streamCall {
            livestream?.stopLoading()
            livestream = nil
            streamCall = call
            liveSlots = [:]
            liveSlotsValidUntil = .distantPast
            streamReadInProgress = false
            refreshSlots()
        }
        guard let url = streamURL else {
            nextLiveRefresh = .distantFuture
            return
        }
        if livestream == nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 780, height: 690), configuration: configuration)
            livestream = view
            view.load(URLRequest(url: url))
            retryStreamAfter = Date().addingTimeInterval(90)
        }
        guard let view = livestream, !streamReadInProgress else { return }
        streamReadInProgress = true
        nextLiveRefresh = Date().addingTimeInterval(5)
        view.evaluateJavaScript(Self.liveActivityScript) { [weak self, weak view] result, _ in
            guard let self, let view, self.livestream === view, self.expedition == call else { return }
            self.streamReadInProgress = false
            let snapshot = result as? [String: Any]
            let slots = snapshot?["slots"] as? [String: [String: String]] ?? [:]
            let connected = snapshot?["connected"] as? Bool ?? false
            self.liveSlotsValidUntil = connected ? Date().addingTimeInterval(15) : .distantPast
            if connected {
                self.retryStreamAfter = Date().addingTimeInterval(90)
            } else if Date() >= self.retryStreamAfter {
                self.retryStreamAfter = Date().addingTimeInterval(90)
                view.load(URLRequest(url: url))
            }
            if slots != self.liveSlots {
                self.liveSlots = slots
                self.refreshSlots()
            }
            if manual {
                self.status.stringValue = connected ? "Club Log live activity refreshed." : "Club Log live activity unavailable."
            }
        }
    }

    // Read the activity grid and recent contacts from Club Log's own public page.
    private static let liveActivityScript = #"""
        (() => {
            const connected = typeof lastClubLogUpdateEpoch === 'number'
                && Date.now() - lastClubLogUpdateEpoch < 90000
                && typeof bNOAC === 'boolean' && !bNOAC
                && typeof allListEntries !== 'undefined';
            const slots = {};
            if (connected) {
                for (const cell of document.querySelectorAll('#activitygridtable td[id]')) {
                    const match = /^([CPD])(\d+)$/.exec(cell.id);
                    if (match && cell.style.backgroundColor) {
                        slots[match[2] + ':' + match[1]] = {};
                    }
                }
                // The page orders Last contacts from oldest to newest.
                for (const entry of allListEntries) {
                    const mode = ['D', 'C', 'P'][entry.mc];
                    const key = entry.band + ':' + mode;
                    if (!slots[key]) continue;
                    const frequency = Number(entry.colFreq);
                    if (!Number.isFinite(frequency) || frequency < 0.03 || frequency > 74.8) {
                        slots[key] = {};
                        continue;
                    }
                    const label = String(entry.colMode).toUpperCase();
                    const radioMode = mode === 'C' ? 'CW'
                        : ['USB', 'LSB'].includes(label) ? label
                        : ['SSB', 'PHONE'].includes(label) ? (frequency < 10 ? 'LSB' : 'USB')
                        : label === 'FT8' ? 'FT8' : '';
                    slots[key] = {frequency: String(entry.colFreq), mode: label, radioMode};
                }
            }
            return {connected, slots};
        })()
        """#

    func liveSlot(_ band: Int, _ mode: String) -> [String: String]? {
        guard streamCall == expedition, Date() < liveSlotsValidUntil else { return nil }
        return liveSlots["\(band):\(mode)"]
    }

    func tuneLiveSlot(_ spot: [String: String]) {
        guard let value = spot["frequency"] else {
            status.stringValue = "Club Log reports activity without a frequency."
            return
        }
        guard let mode = spot["radioMode"], !mode.isEmpty else {
            status.stringValue = "This mode is unavailable for automatic tuning."
            return
        }
        frequency.stringValue = value
        tune(mode)
    }

    private var streamURL: URL? {
        guard !expedition.isEmpty,
              let encoded = expedition.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "https://clublog.org/livestream/" + encoded)
    }

    func openStream() {
        if let streamURL { NSWorkspace.shared.open(streamURL) }
    }

    func saveToken(_ token: String) {
        let result = ClubLogKeychain.save(token)
        if result != errSecSuccess {
            status.stringValue = "Could not save the token in Keychain (\(result))."
        }
    }

    func updateRefreshCountdown() {
        let now = Date()
        if now >= liveSlotsValidUntil, !liveSlots.isEmpty {
            liveSlots = [:]
            refreshSlots()
        }
        if now >= nextLiveRefresh || streamCall != expedition { refreshLiveActivity() }
        if now >= nextClubRefresh, !key.stringValue.isEmpty { refreshClubLog() }
        let club = key.stringValue.isEmpty ? "—" : "\(max(0, Int(ceil(nextClubRefresh.timeIntervalSince(now))))) s"
        let live = expedition.isEmpty ? "—" : "\(max(0, Int(ceil(nextLiveRefresh.timeIntervalSince(now))))) s"
        refreshLabel.stringValue = "Club Log \(club)  ·  Live \(live)"
    }

    func refreshClubLog(manual: Bool = false) {
        guard !expeditionRefreshInProgress, !lookupInProgress else { return }
        nextClubRefresh = Date().addingTimeInterval(120)
        let token = key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("cl_") else {
            self.clubExpeditions = nil
            self.refreshTargets()
            lookup(automatic: !manual)
            return
        }
        expeditionRefreshInProgress = true
        worker.request("expeditions", ["key": token]) { response in
            self.expeditionRefreshInProgress = false
            guard self.key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == token else { return }
            if let names = response["result"] as? [String] {
                self.clubExpeditions = names
                self.refreshTargets()
                self.refreshLiveActivity()
            } else if let error = response["error"] as? String {
                self.status.stringValue = "Expedition · " + error
            }
            self.lookup(automatic: !manual)
        }
    }

    func lookup(automatic: Bool = false) {
        guard !lookupInProgress else { return }
        let token = key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let operatorName = operatorCall.stringValue
        guard !token.isEmpty, !operatorName.isEmpty, !expedition.isEmpty else {
            if !automatic { status.stringValue = "Enter your callsign and Club Log token in Settings." }
            return
        }
        let current = lookupKey
        lookupInProgress = true
        log.stringValue = "Loading worked slots from Club Log…"
        worker.request("lookup", ["operator": operatorName, "target": expedition, "key": token]) { response in
            self.lookupInProgress = false
            if let error = response["error"] as? String {
                if self.lookupKey == current { self.log.stringValue = error }
                return
            }
            let entries = response["result"] as? [[Any]] ?? []
            self.worked[current] = Set(entries.compactMap {
                guard $0.count == 2, let band = $0[0] as? Int, let mode = $0[1] as? String else { return nil }
                return "\(band):\(mode)"
            })
            if !automatic, self.key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == token {
                self.saveToken(token)
            }
            self.refreshSlots()
        }
    }

    func selectSlot(_ band: Int, _ mode: String) {
        guard !busy, !expedition.isEmpty else { return }
        let id = "\(expedition):\(band):\(mode)"
        let saved = slots[id]
        let editing = NSEvent.modifierFlags.contains(.option)
        if !editing {
            if let spot = liveSlot(band, mode) {
                if spot["frequency"] != nil {
                    tuneLiveSlot(spot)
                    return
                }
                if let value = saved?["frequency"], let radioMode = saved?["mode"] {
                    frequency.stringValue = value
                    tune(radioMode)
                    return
                }
            } else if worked[lookupKey]?.contains("\(band):\(mode)") == true {
                return
            }
        }
        let alert = NSAlert()
        alert.messageText = "\(expedition) · \(band) m"
        alert.informativeText = "Enter a frequency in MHz."
        let field = NSTextField(string: saved?["frequency"] ?? "")
        let sideband = NSPopUpButton()
        sideband.addItems(withTitles: ["USB", "LSB"])
        sideband.selectItem(withTitle: saved?["mode"] ?? (band >= 40 ? "LSB" : "USB"))
        let fields = stack(mode == "P" ? [field, sideband] : [field], vertical: false)
        fields.frame.size = NSSize(width: 260, height: 32)
        field.widthAnchor.constraint(equalToConstant: 125).isActive = true
        alert.accessoryView = fields
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if saved != nil {
            alert.addButton(withTitle: "Tune saved frequency")
            alert.addButton(withTitle: "Delete")
        }
        alert.window.initialFirstResponder = field
        let result = alert.runModal()
        if result == .alertThirdButtonReturn,
           let value = saved?["frequency"], let radioMode = saved?["mode"] {
            frequency.stringValue = value
            tune(radioMode)
            return
        }
        if result.rawValue == NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1 {
            slots.removeValue(forKey: id)
            refreshSlots()
            save()
        }
        guard result == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mhz = Double(value.replacingOccurrences(of: ",", with: ".")), (0.03...74.8).contains(mhz) else {
            status.stringValue = "Enter a frequency in MHz, for example 14.074."
            return
        }
        let radioMode = mode == "P" ? (sideband.titleOfSelectedItem ?? "USB") : (mode == "C" ? "CW" : "FT8")
        slots[id] = ["frequency": value, "mode": radioMode]
        refreshSlots()
        save()
    }

    func tune(_ mode: String) { run("tune", ["frequency": frequency.stringValue, "mode": mode]) }

    func readMemories() {
        run("read") { result in
            guard let values = result as? [String], values.count == self.memories.count else { return }
            for (field, value) in zip(self.memories, values) { field.stringValue = value }
            self.status.stringValue = self.simulated ? "Simulation · Memories M1–M8 loaded." : "Memories M1–M8 loaded."
        }
    }

    func writeMemory(_ index: Int) {
        guard !busy else { return }
        let alert = NSAlert()
        alert.messageText = "Overwrite M\(index)?"
        alert.addButton(withTitle: "Write")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            run("write", ["index": index, "value": memories[index - 1].stringValue])
        }
    }

    func saveMemories() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "CW-memories.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: memories.map(\.stringValue), options: [.prettyPrinted])
            try data.write(to: url, options: .atomic)
            status.stringValue = "CW memory set saved."
        } catch { status.stringValue = error.localizedDescription }
    }

    func loadMemories() {
        let panel = NSOpenPanel()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let values = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String],
                  values.count == 8, values.allSatisfy({ $0.count <= 70 }) else {
                status.stringValue = "A set must contain eight messages of up to 70 characters each."
                return
            }
            for (field, value) in zip(memories, values) { field.stringValue = value }
            status.stringValue = "Memory set loaded into the editor."
        } catch { status.stringValue = error.localizedDescription }
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
let menu = NSMenu()
let appMenuItem = NSMenuItem()
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit ClubLog Hunter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu
menu.addItem(appMenuItem)
let editItem = NSMenuItem()
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu
menu.addItem(editItem)
app.mainMenu = menu
app.run()
