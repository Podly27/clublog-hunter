import AppKit
import Security

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
    private let queue = DispatchQueue(label: "DX Lovec CAT")
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
            guard !chunk.isEmpty else { return ["error": "Ovládání rádia se ukončilo. Zkus akci znovu."] }
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

final class Delegate: NSObject, NSApplicationDelegate {
    let worker = Worker()
    var window: NSWindow!
    let tabs = NSTabView()
    let status = NSTextField(labelWithString: "Rádio odpojeno")
    let radioDot = NSImageView()
    let radioLabel = NSTextField(labelWithString: "Odpojeno")
    var radioConnected = false
    var radioCheckInProgress = false
    var radioTimer: Timer?
    let log = NSTextField(labelWithString: "Spojení zatím nejsou načtená")
    let target = NSPopUpButton()
    var spotTimer: Timer?
    let refreshLabel = NSTextField(labelWithString: "Club Log —  ·  Spoty —")
    var nextClubRefresh = Date.distantPast
    var nextSpotRefresh = Date.distantPast
    var expeditionRefreshInProgress = false
    var clubExpeditions: [String]?
    var spots: [[String: Any]] = []
    var lastSpotRequest = Date.distantPast
    var spotCall = ""
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
        addTab("Přehled", buildHunt())
        addTab("CW", buildMemories())
        addTab("Nastavení", buildSetup())
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
            self.refreshSpots()
            self.connect(false)
            self.refreshClubLog()
            self.radioTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.checkRadioConnection()
            }
            self.spotTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
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

    func label(_ text: String, width: CGFloat? = nil) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        if let width { field.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return field
    }

    func buildHunt() -> NSStackView {
        let head = stack([
            label("Expedice"), target, ActionButton("Načíst spojení") { self.refreshClubLog(manual: true) },
            ActionButton("Livestream web") { self.openStream() },
            ActionButton("Načíst spoty") { self.refreshSpots(manual: true) }
        ], vertical: false)
        let heading = stack([
            label("Pásmo", width: 68), label("CW", width: 125),
            label("Phone", width: 125), label("Data / FT8", width: 125)
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
            transmit.toolTip = "Odvysílat M\(index)"
            layout.addArrangedSubview(stack([label("M\(index)", width: 34), field,
                ActionButton("Zapsat") { self.writeMemory(index) },
                transmit], vertical: false))
        }
        layout.addArrangedSubview(stack([
            ActionButton("Načíst z rádia") { self.readMemories() },
            ActionButton("Zastavit CW") { self.run("stop_cw") },
            ActionButton("Uložit sadu…") { self.saveMemories() },
            ActionButton("Otevřít sadu…") { self.loadMemories() }
        ], vertical: false))
        layout.addArrangedSubview(label("TX používá text uložený v rádiu. Vyžaduje CW a Break-in."))
        return layout
    }

    func buildSetup() -> NSStackView {
        let layout = stack([])
        let entries: [(String, NSTextField)] = [
            ("Moje značka", operatorCall), ("Sledované značky", targets),
            ("Club Log API klíč", key), ("Port CI-V", port),
            ("Rychlost", baud), ("Adresa CI-V (hex)", address)
        ]
        for (title, field) in entries {
            field.widthAnchor.constraint(equalToConstant: 370).isActive = true
            layout.addArrangedSubview(stack([label(title, width: 170), field], vertical: false))
        }
        layout.addArrangedSubview(label("Na rádiu nastav USB (B) Function na CI-V. Před laděním vypni Enable Tx ve WSJT-X."))
        layout.addArrangedSubview(stack([
            ActionButton("Uložit nastavení") { self.save(includeToken: true) },
            ActionButton("Připojit rádio") { self.connect(false) },
            ActionButton("Simulace") { self.connect(true) },
            ActionButton("Odpojit") {
                self.run("disconnect") { _ in
                    self.simulated = false
                    self.radioConnected = false
                    self.updateRadioIndicator()
                }
            }
        ], vertical: false))
        return layout
    }

    func run(_ action: String, _ data: [String: Any] = [:], completion: ((Any?) -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        status.stringValue = "Pracuji…"
        worker.request(action, data) { response in
            self.busy = false
            if let error = response["error"] as? String { self.status.stringValue = error; return }
            let result = response["result"]
            let detail = result as? String ?? "Hotovo"
            self.status.stringValue = self.simulated && !detail.hasPrefix("Simulace") && action != "disconnect"
                ? "Simulace · \(detail)" : detail
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
        radioLabel.stringValue = radioConnected ? "Připojeno" : (simulated ? "Simulace" : "Odpojeno")
    }

    func checkRadioConnection() {
        guard radioConnected, !busy, !radioCheckInProgress else { return }
        radioCheckInProgress = true
        worker.request("radio_status", [:]) { response in
            self.radioCheckInProgress = false
            guard self.radioConnected, response["result"] as? Bool != true else { return }
            self.radioConnected = false
            self.updateRadioIndicator()
            self.status.stringValue = "Rádio přestalo odpovídat."
        }
    }

    func save(includeToken: Bool = false) {
        var data: [String: Any] = fields.mapValues { $0.stringValue }
        data["frequencies"] = slots
        let token = key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        run("save", data) { _ in
            if includeToken { self.saveToken(token) }
            self.refreshTargets()
            self.refreshSpots()
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
        if let previous, target.itemTitles.contains(previous) { target.selectItem(withTitle: previous) }
        refreshSlots()
    }

    var expedition: String { target.titleOfSelectedItem ?? "" }
    var lookupKey: String { "\(operatorCall.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()):\(expedition)" }

    @objc func refreshSlots() {
        let matches = worked[lookupKey]
        if clubExpeditions?.isEmpty == true {
            log.stringValue = "Club Log · žádná expedice s QSO za posledních 7 dní."
        } else {
            log.stringValue = matches.map { "Club Log · \($0.count) hotových kombinací" } ?? "Spojení zatím nejsou načtená"
        }
        for (row, band) in bands.enumerated() {
            for (column, mode) in modes.enumerated() {
                let hit = matches?.contains("\(band):\(mode)") == true
                let saved = slots["\(expedition):\(band):\(mode)"]?["frequency"] ?? "—"
                let button = rows[row][column]
                let spot = tableSpot(band, mode)
                let frequency = spot?["frequency"] as? String
                button.title = (hit ? "✓ " : "") + (frequency.map { "● \($0)" } ?? saved)
                let workedColor = NSColor(srgbRed: 0.55, green: 0.83, blue: 0.61, alpha: 1)
                let qrvColor = NSColor(srgbRed: 1, green: 0.84, blue: 0.39, alpha: 1)
                let background = hit ? workedColor : (spot != nil ? qrvColor : nil)
                button.setBackground(background, textColor: background == nil ? .labelColor : .black)
                if let frequency, let utc = spot?["utc"] as? String {
                    let reportedMode = spot?["mode"] as? String ?? ""
                    button.toolTip = "HamQTH · \(frequency) MHz · \(reportedMode) · \(utc) UTC"
                } else {
                    button.toolTip = nil
                }
            }
        }
    }

    @objc func changeExpedition() {
        refreshSlots()
        refreshSpots()
        lookup(automatic: true)
    }

    func refreshSpots(manual: Bool = false) {
        let call = expedition
        if call != spotCall {
            spotCall = call
            spots = []
            nextSpotRefresh = Date()
            renderSpots()
        }
        guard !call.isEmpty, !busy else { return }
        guard Date().timeIntervalSince(lastSpotRequest) >= 15 else {
            if manual {
                status.stringValue = "HamQTH · další načtení je možné po 15 sekundách."
            }
            return
        }
        lastSpotRequest = Date()
        nextSpotRefresh = Date().addingTimeInterval(60)
        if manual { status.stringValue = "HamQTH · načítám spoty pro \(call)…" }
        worker.request("spots", ["target": call]) { response in
            guard self.expedition == call else { return }
            if let error = response["error"] as? String {
                self.renderSpots()
                self.status.stringValue = "HamQTH · " + error
                return
            }
            self.spots = response["result"] as? [[String: Any]] ?? []
            self.renderSpots()
            if manual {
                self.status.stringValue = self.spots.isEmpty ? "Žádné čerstvé spoty." : "Spoty načteny."
            }
        }
    }

    func renderSpots() {
        let cutoff = Date().timeIntervalSince1970 - 1800
        spots = spots.filter { ($0["timestamp"] as? Double ?? 0) >= cutoff }
        refreshSlots()
    }

    func tableSpot(_ band: Int, _ mode: String) -> [String: Any]? {
        guard spotCall == expedition else { return nil }
        let modes = ["C": ["CW"], "P": ["SSB"], "D": ["FT8", "DIGI"]]
        let cutoff = Date().timeIntervalSince1970 - 1800
        return spots.first {
            $0["band"] as? String == "\(band)M"
                && (modes[mode]?.contains($0["mode"] as? String ?? "") ?? false)
                && ($0["timestamp"] as? Double ?? 0) >= cutoff
        }
    }

    func tuneSpot(_ spot: [String: Any]) {
        guard let timestamp = spot["timestamp"] as? Double, Date().timeIntervalSince1970 - timestamp <= 1800 else {
            renderSpots()
            return
        }
        guard let mode = spot["radioMode"] as? String, !mode.isEmpty else {
            status.stringValue = "Spot nemá potvrzený režim CW, SSB ani FT8."
            return
        }
        guard let value = spot["frequency"] as? String else { return }
        frequency.stringValue = value
        tune(mode)
    }

    func openStream() {
        guard !expedition.isEmpty,
              let encoded = expedition.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://clublog.org/livestream/" + encoded) else { return }
        NSWorkspace.shared.open(url)
    }

    func saveToken(_ token: String) {
        let result = ClubLogKeychain.save(token)
        if result != errSecSuccess {
            status.stringValue = "Token se nepodařilo uložit do Klíčenky (\(result))."
        }
    }

    func updateRefreshCountdown() {
        let now = Date()
        if now >= nextSpotRefresh, !expedition.isEmpty { refreshSpots() }
        if now >= nextClubRefresh, !key.stringValue.isEmpty { refreshClubLog() }
        let club = key.stringValue.isEmpty ? "—" : "\(max(0, Int(ceil(nextClubRefresh.timeIntervalSince(now))))) s"
        let spots = expedition.isEmpty ? "—" : "\(max(0, Int(ceil(nextSpotRefresh.timeIntervalSince(now))))) s"
        refreshLabel.stringValue = "Club Log \(club)  ·  Spoty \(spots)"
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
                self.refreshSpots()
            } else if let error = response["error"] as? String {
                self.status.stringValue = "Expedice · " + error
            }
            self.lookup(automatic: !manual)
        }
    }

    func lookup(automatic: Bool = false) {
        guard !lookupInProgress else { return }
        let token = key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let operatorName = operatorCall.stringValue
        guard !token.isEmpty, !operatorName.isEmpty, !expedition.isEmpty else {
            if !automatic { status.stringValue = "V Nastavení vyplň svoji značku a token Club Logu." }
            return
        }
        let current = lookupKey
        lookupInProgress = true
        log.stringValue = "Načítám spojení z Club Logu…"
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
        if !editing, let spot = tableSpot(band, mode) {
            tuneSpot(spot)
            return
        }
        if let saved, !editing,
           let value = saved["frequency"], let radioMode = saved["mode"] {
            frequency.stringValue = value
            tune(radioMode)
            return
        }
        let alert = NSAlert()
        alert.messageText = "\(expedition) · \(band) m"
        alert.informativeText = "Zadej frekvenci v MHz."
        let field = NSTextField(string: saved?["frequency"] ?? "")
        let sideband = NSPopUpButton()
        sideband.addItems(withTitles: ["USB", "LSB"])
        sideband.selectItem(withTitle: saved?["mode"] ?? (band >= 40 ? "LSB" : "USB"))
        let fields = stack(mode == "P" ? [field, sideband] : [field], vertical: false)
        fields.frame.size = NSSize(width: 260, height: 32)
        field.widthAnchor.constraint(equalToConstant: 125).isActive = true
        alert.accessoryView = fields
        alert.addButton(withTitle: "Uložit")
        alert.addButton(withTitle: "Zrušit")
        if saved != nil { alert.addButton(withTitle: "Smazat") }
        alert.window.initialFirstResponder = field
        let result = alert.runModal()
        if result == .alertThirdButtonReturn {
            slots.removeValue(forKey: id)
            refreshSlots()
            save()
        }
        guard result == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mhz = Double(value.replacingOccurrences(of: ",", with: ".")), (0.03...74.8).contains(mhz) else {
            status.stringValue = "Zadej frekvenci v MHz, například 14.074."
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
            self.status.stringValue = self.simulated ? "Simulace · paměti M1–M8 načteny." : "Paměti M1–M8 načteny."
        }
    }

    func writeMemory(_ index: Int) {
        guard !busy else { return }
        let alert = NSAlert()
        alert.messageText = "Přepsat M\(index)?"
        alert.addButton(withTitle: "Zapsat")
        alert.addButton(withTitle: "Zrušit")
        if alert.runModal() == .alertFirstButtonReturn {
            run("write", ["index": index, "value": memories[index - 1].stringValue])
        }
    }

    func saveMemories() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "CW-pameti.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: memories.map(\.stringValue), options: [.prettyPrinted])
            try data.write(to: url, options: .atomic)
            status.stringValue = "Sada CW pamětí uložena."
        } catch { status.stringValue = error.localizedDescription }
    }

    func loadMemories() {
        let panel = NSOpenPanel()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let values = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String],
                  values.count == 8, values.allSatisfy({ $0.count <= 70 }) else {
                status.stringValue = "Sada musí obsahovat osm textů s nejvýše 70 znaky."
                return
            }
            for (field, value) in zip(memories, values) { field.stringValue = value }
            status.stringValue = "Sada načtena do editoru."
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
appMenu.addItem(withTitle: "Ukončit ClubLog Hunter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu
menu.addItem(appMenuItem)
let editItem = NSMenuItem()
let editMenu = NSMenu(title: "Úpravy")
editMenu.addItem(withTitle: "Vyjmout", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Kopírovat", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Vložit", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Vybrat vše", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu
menu.addItem(editItem)
app.mainMenu = menu
app.run()
