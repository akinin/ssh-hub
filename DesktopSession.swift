import SwiftUI
import AppKit
import CryptoKit
import Darwin

final class RDPBridge: @unchecked Sendable {
    private let process = Process(), input = Pipe(), output = Pipe(), diagnostic = Pipe()
    private let lock = NSLock(), inputLock = NSLock()
    private var stopped = false, errors = Data()
    func start(entry: SSHAlias, password: String, proxyPort: Int = 0, clipboard: @escaping @Sendable (String) -> Void, channelStatus: @escaping @Sendable (String) -> Void, frame: @escaping @Sendable (Int, Int, Data) -> Void, trust: @escaping @Sendable (String) -> Bool, finished: @escaping @Sendable (String) -> Void) throws {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "SSHRDP") else { throw ConfigError.message("Не найден встроенный RDP-движок.") }
        let s = entry.transport ?? ConnectionSettings()
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.olshaniki.ssh-aliases").appendingPathComponent("RDP")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        process.executableURL = helper; process.arguments = [entry.host, entry.port, entry.user, s.domain, String(s.width), String(s.height), root.path, String(s.rdpMonitors ?? 1), s.rdpClipboard == true ? "1" : "0", s.rdpSharedFolder ?? "", String(proxyPort)]
        process.standardInput = input; process.standardOutput = output; process.standardError = diagnostic
        diagnostic.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData; guard let self else { return }; self.lock.lock(); defer { self.lock.unlock() }
            self.errors.append(bytes); if self.errors.count > 6000 { self.errors.removeFirst(self.errors.count - 6000) }
        }
        try process.run()
        let secret = Data(password.utf8); guard secret.count <= 4096 else { stop(); throw ConfigError.message("Пароль RDP слишком длинный.") }
        try write(DesktopWire.be32(UInt32(secret.count)) + secret)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                while true {
                    let header = try read(8), type = DesktopWire.u32(header), length = Int(DesktopWire.u32(header, 4))
                    guard length <= 132_000_008 else { throw ConfigError.message("Некорректный размер кадра RDP.") }
                    let data = try read(length)
                    if type == 1 {
                        guard length >= 8 else { throw ConfigError.message("Повреждённый кадр RDP.") }
                        let w = Int(DesktopWire.u32(data)), h = Int(DesktopWire.u32(data, 4))
                        guard (1...8192).contains(w), (1...2160).contains(h), w * h <= 33_000_000, length == w * h * 4 + 8 else { throw ConfigError.message("Некорректный кадр RDP.") }
                        frame(w, h, Data(data.dropFirst(8)))
                    } else if type == 2, length <= 4096 {
                        let approved = trust(String(decoding: data, as: UTF8.self))
                        try write(DesktopWire.be32(approved ? 1 : 0))
                    } else if type == 3, length <= 1_048_576, let text = String(data: data, encoding: .utf8) { clipboard(text) }
                    else if type == 4, length <= 4096 { channelStatus(String(decoding: data, as: UTF8.self)) }
                    else { throw ConfigError.message("Неизвестное сообщение RDP-движка.") }
                }
            } catch {
                if process.isRunning { process.terminate() }
                process.waitUntilExit(); diagnostic.fileHandleForReading.readabilityHandler = nil
                lock.lock(); let cancelled = stopped, tail = errors; lock.unlock()
                if !cancelled { finished(process.terminationStatus == 0 ? "RDP-сеанс завершён" : String(decoding: tail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? error.localizedDescription : "RDP: " + String(decoding: tail, as: UTF8.self)) }
            }
        }
    }
    private func read(_ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try output.fileHandleForReading.read(upToCount: min(65536, count - data.count)), !chunk.isEmpty else { throw ConfigError.message("RDP-сервер закрыл соединение.") }
            data.append(chunk)
        }
        return data
    }
    private func write(_ data: Data) throws { inputLock.lock(); defer { inputLock.unlock() }; try input.fileHandleForWriting.write(contentsOf: data) }
    func clipboard(_ text: String) { let bytes = Data(text.utf8); guard bytes.count <= 1_048_576 else { return }; try? write([5,UInt32(bytes.count),0,0].reduce(into: Data()) { $0.append(DesktopWire.be32($1)) } + bytes) }
    func event(_ type: UInt32, _ a: UInt32, _ b: UInt32 = 0, _ c: UInt32 = 0) { try? write([type,a,b,c].reduce(into: Data()) { $0.append(DesktopWire.be32($1)) }) }
    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        inputLock.lock(); try? input.fileHandleForWriting.close(); inputLock.unlock()
        if process.isRunning { process.terminate(); DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) } } }
    }
}

// Keep only the newest pending frame while the main actor is busy with layout or a dialog.
final class DesktopFrameDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: (Int,Int,Data)?
    private var scheduled = false
    private let receive: @MainActor @Sendable (Int,Int,Data) -> Void
    init(_ receive: @escaping @MainActor @Sendable (Int,Int,Data) -> Void) { self.receive = receive }
    func submit(_ w: Int, _ h: Int, _ data: Data) {
        lock.lock(); latest = (w,h,data); let schedule = !scheduled; scheduled = true; lock.unlock()
        if schedule { Task { @MainActor in if let frame = self.take() { self.receive(frame.0,frame.1,frame.2) } } }
    }
    private func take() -> (Int,Int,Data)? { lock.lock(); defer { lock.unlock() }; let value = latest; latest = nil; scheduled = false; return value }
}

@MainActor final class DesktopSession: ObservableObject {
    let entry: SSHAlias, config: URL
    @Published var image: CGImage?
    @Published var status = "Подключение по кнопке"
    @Published var connected = false
    @Published var starting = false
    var onRequestStart: (() -> Void)?
    var onRequestStop: (() -> Void)?
    var tunnelPort = 0
    @Published var monitor = -1
    @Published var displayControl = false
    private var clipboardChange = -1
    private var clipboardFocused = false
    private var resizeTask: Task<Void, Never>?
    private var lastSize = NSSize.zero
    var monitorCount: Int { entry.recordKind == .rdp ? entry.transport?.rdpMonitors ?? 1 : 1 }
    var displayImage: CGImage? { guard let image else { return nil }; guard monitor >= 0, monitor < monitorCount else { return image }; let width = image.width / monitorCount; return image.cropping(to: CGRect(x: monitor * width, y: 0, width: width, height: image.height)) }
    var monitorOffset: Int { monitor >= 0 ? (image?.width ?? 0) / monitorCount * monitor : 0 }
    func requestStart() { if let onRequestStart { onRequestStart() } else { start() } }
    func requestStop() { if let onRequestStop { onRequestStop() } else { stop() } }
    func receiveClipboard(_ text: String) { guard entry.transport?.rdpClipboard == true, clipboardFocused, NSApp.isActive else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); clipboardChange = NSPasteboard.general.changeCount }
    func syncClipboard(focused: Bool) { clipboardFocused = focused; guard focused, NSApp.isActive, connected, entry.transport?.rdpClipboard == true else { return }; let board = NSPasteboard.general; if board.changeCount != clipboardChange { clipboardChange = board.changeCount; if let text = board.string(forType: .string) { bridge?.clipboard(text) } } }
    func sendClipboard() { guard entry.transport?.rdpClipboard == true, let text = NSPasteboard.general.string(forType: .string) else { return }; bridge?.clipboard(text); clipboardChange = NSPasteboard.general.changeCount }
    func requestClipboard() { clipboardFocused = true; bridge?.event(6,0) }
    func viewport(_ size: NSSize) {
        guard connected, displayControl, entry.recordKind == .rdp, entry.transport?.rdpAutoResize != false, size.width >= 100, size.height >= 100 else { return }
        let width = min(3840, 8192 / monitorCount, max(320, Int(size.width) / (monitor < 0 ? monitorCount : 1))) / 2 * 2
        let height = min(2160, max(200, Int(size.height)))
        let value = NSSize(width: width, height: height); guard value != lastSize else { return }; lastSize = value
        resizeTask?.cancel(); resizeTask = Task { [weak self] in try? await Task.sleep(for: .milliseconds(350)); guard !Task.isCancelled, let self else { return }; self.bridge?.event(7, UInt32(width), UInt32(height), UInt32(self.monitorCount)) }
    }
    private var bridge: RDPBridge?
    private var vnc: VNCConnection?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    init(entry: SSHAlias, config: URL) { self.entry = entry; self.config = config }
    func start() {
        guard !starting, !connected else { return }
        do {
            let password = try ConnectionPassword.read(entry, config: config)
            generation = UUID(); let token = generation; displayControl = false; lastSize = .zero; clipboardChange = -1; starting = true; status = "Подключение…"; image = nil
            let frames = DesktopFrameDelivery { [weak self] w,h,data in if self?.generation == token { self?.update(w,h,data) } }
            if entry.recordKind == .rdp {
                let bridge = RDPBridge(); self.bridge = bridge
                try bridge.start(entry: entry, password: password, proxyPort: tunnelPort, clipboard: { [weak self] text in Task { @MainActor in if self?.generation == token { self?.receiveClipboard(text) } } }, channelStatus: { [weak self] _ in Task { @MainActor in if self?.generation == token { self?.displayControl = true } } }, frame: { w,h,data in frames.submit(w,h,data) }, trust: { [weak self] certificate in
                    var accepted = false
                    DispatchQueue.main.sync { if self?.generation == token { accepted = self?.trust(certificate) == true } }
                    return accepted
                }, finished: { [weak self] text in Task { @MainActor in if self?.generation == token { self?.status = text; self?.connected = false; self?.starting = false } } })
            } else {
                guard let port = UInt16(entry.port), port > 0 else { throw ConfigError.message("Некорректный порт VNC.") }
                let client = VNCConnection(host: tunnelPort == 0 ? entry.host : "127.0.0.1", port: tunnelPort == 0 ? port : UInt16(tunnelPort)); vnc = client
                task = Task { [weak self] in
                    do { try await client.run(password: password) { w,h,data in frames.submit(w,h,data) } }
                    catch { if self?.generation == token { self?.status = error.localizedDescription; self?.connected = false; self?.starting = false } }
                }
            }
        } catch is CancellationError { starting = false; status = "Подключение отменено" }
        catch { starting = false; status = error.localizedDescription }
    }
    private func trust(_ certificate: String) -> Bool {
        let key = "rdpCertificate.v1." + SHA256.hash(data: Data((entry.favoriteID + entry.host + entry.port).utf8)).map { String(format: "%02x", $0) }.joined()
        if UserDefaults.standard.string(forKey: key) == certificate { return true }
        let alert = NSAlert(); alert.messageText = "Проверка сертификата RDP"
        alert.informativeText = (UserDefaults.standard.string(forKey: key) == nil ? "Сертификат не подтверждён доверенным центром. Сверь отпечаток с администратором сервера.\n\n" : "Сертификат сервера изменился. Сверь новый отпечаток перед подключением.\n\n") + certificate
        alert.addButton(withTitle: "Доверять этому сертификату"); alert.addButton(withTitle: "Отмена")
        if alert.runModal() == .alertFirstButtonReturn { UserDefaults.standard.set(certificate, forKey: key); return true }; return false
    }
    private func update(_ w: Int, _ h: Int, _ data: Data) {
        guard w > 0, h > 0, data.count == w * h * 4, let provider = CGDataProvider(data: data as CFData) else { return }
        image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        starting = false; connected = true; status = "\(entry.recordKind?.title ?? "") · \(w) × \(h)"
    }
    func stop() { resizeTask?.cancel(); resizeTask = nil; clipboardFocused = false; generation = UUID(); task?.cancel(); task = nil; vnc?.stop(); vnc = nil; bridge?.stop(); bridge = nil; starting = false; connected = false; status = "Сеанс завершён" }
    func pointer(_ x: Int, _ y: Int, buttons: UInt8, changed: UInt8 = 0, down: Bool = false, wheel: Int = 0) {
        guard connected else { return }
        if let vnc {
            if wheel != 0 { vnc.pointer(x: x, y: y, buttons: buttons | (wheel > 0 ? 8 : 16)); vnc.pointer(x: x, y: y, buttons: buttons) }
            else { vnc.pointer(x: x, y: y, buttons: buttons) }
        }
        if let bridge {
            var flags: UInt32 = 0x0800
            if changed != 0 { flags = changed == 1 ? 0x1000 : changed == 4 ? 0x2000 : 0x4000; if down { flags |= 0x8000 } }
            if wheel != 0 { flags = 0x0200 | (wheel > 0 ? 120 : 0x0100 | 0x88) }
            bridge.event(1, flags, UInt32(x), UInt32(y))
        }
    }
    func key(_ code: UInt16, text: String?, down: Bool, physical: Bool = false) {
        guard connected else { return }
        // Hardware keys are used for navigation/modifiers; printable text uses Unicode.
        let special: [UInt16:(UInt32,UInt32)] = [36:(0xff0d,0x1c),48:(0xff09,0x0f),51:(0xff08,0x0e),53:(0xff1b,0x01),117:(0xffff,0x153),123:(0xff51,0x14b),124:(0xff53,0x14d),125:(0xff54,0x150),126:(0xff52,0x148),115:(0xff50,0x147),119:(0xff57,0x14f),116:(0xff55,0x149),121:(0xff56,0x151),56:(0xffe1,0x2a),60:(0xffe2,0x36),59:(0xffe3,0x1d),62:(0xffe4,0x11d),58:(0xffe9,0x38),61:(0xffea,0x138),55:(0xffeb,0x15b),54:(0xffec,0x15c),122:(0xffbe,0x3b),120:(0xffbf,0x3c),99:(0xffc0,0x3d),118:(0xffc1,0x3e),96:(0xffc2,0x3f),97:(0xffc3,0x40),98:(0xffc4,0x41),100:(0xffc5,0x42),101:(0xffc6,0x43),109:(0xffc7,0x44),103:(0xffc8,0x57),111:(0xffc9,0x58)]
        if let pair = special[code] {
            vnc?.key(pair.0, down: down)
            bridge?.event(3, (down ? 0 : 0x8000) | (pair.1 > 255 ? 0x0100 : 0), pair.1 & 255)
        } else if let text {
            for scalar in text.unicodeScalars { vnc?.key(scalar.value <= 255 ? scalar.value : 0x01000000 | scalar.value, down: down) }
            let scan: [UInt16:UInt32] = [0:0x1e,1:0x1f,2:0x20,3:0x21,4:0x23,5:0x22,6:0x2c,7:0x2d,8:0x2e,9:0x2f,11:0x30,12:0x10,13:0x11,14:0x12,15:0x13,16:0x15,17:0x14,18:0x02,19:0x03,20:0x04,21:0x05,22:0x07,23:0x06,24:0x0d,25:0x0a,26:0x08,27:0x0c,28:0x09,29:0x0b,30:0x1b,31:0x18,32:0x16,33:0x1a,34:0x17,35:0x19,37:0x26,38:0x24,39:0x28,40:0x25,41:0x27,42:0x2b,43:0x33,44:0x35,45:0x31,46:0x32,47:0x34,49:0x39,50:0x29]
            if physical, let value = scan[code] { bridge?.event(3, down ? 0 : 0x8000, value) }
            else { for value in text.utf16 { bridge?.event(2, down ? 0 : 0x8000, UInt32(value)) } }
        }
    }
    func ctrlAltDelete() { key(59, text: nil, down: true); key(58, text: nil, down: true); key(117, text: nil, down: true); key(117, text: nil, down: false); key(58, text: nil, down: false); key(59, text: nil, down: false) }
}
struct DesktopPageView: View {
    @ObservedObject var session: DesktopSession
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(session.status).font(.caption).lineLimit(2); Spacer(); if session.starting { ProgressView().controlSize(.small); Button("Отмена") { session.requestStop() } } else if !session.connected { Button("Подключиться") { session.requestStart() } }; Button("Ctrl+Alt+Del") { session.ctrlAltDelete() }.disabled(!session.connected) }.padding(8).controlSize(.small)
            if session.entry.recordKind == .rdp {
                ViewThatFits(in: .horizontal) {
                    rdpControls
                    ScrollView(.horizontal) { rdpControls }
                }.padding(.horizontal, 8).padding(.bottom, 6).controlSize(.small)
            }
            Divider()
            if session.image != nil { DesktopSurface(session: session) }
            else { VStack(spacing: 12) { Image(systemName: "desktopcomputer").font(.system(size: 38)); Text(session.entry.recordKind?.title ?? "Рабочий стол").font(.headline); Text("Управление мышью и клавиатурой во вкладке").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
    }
}
private extension DesktopPageView {
    var rdpControls: some View {
        HStack {
            if session.monitorCount > 1 { Picker("Экран", selection: $session.monitor) { Text("Все мониторы").tag(-1); ForEach(0..<session.monitorCount, id: \.self) { Text("Монитор \($0 + 1)").tag($0) } }.frame(width: 180) }
            if session.entry.transport?.rdpClipboard == true { Button("Вставить с Mac") { session.sendClipboard() }.disabled(!session.connected); Button("Копировать с Windows") { session.requestClipboard() }.disabled(!session.connected) }
            if session.entry.transport?.rdpSharedFolder != nil { Label("HubFiles", systemImage: "folder").help("Папка Mac в Windows: \\\\tsclient\\HubFiles") }
            if session.entry.transport?.rdpAutoResize != false { Text(session.displayControl ? "Авторазрешение" : "Ожидание Display Control").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
struct DesktopSurface: NSViewRepresentable {
    @ObservedObject var session: DesktopSession
    func makeNSView(context: Context) -> DesktopCanvas { DesktopCanvas(session: session) }
    func updateNSView(_ view: DesktopCanvas, context: Context) { view.needsDisplay = true; session.viewport(view.bounds.size) }
}
final class DesktopCanvas: NSView {
    let session: DesktopSession
    private var buttons: UInt8 = 0
    private var modifiers = Set<UInt16>()
    private var pressed: [UInt16:(String?,Bool)] = [:]
    private var clipboardTimer: Timer?
    override func layout() { super.layout(); session.viewport(bounds.size) }
    override func becomeFirstResponder() -> Bool { clipboardTimer?.invalidate(); clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in Task { @MainActor in guard let self else { return }; self.session.syncClipboard(focused: self.window?.firstResponder === self && self.window?.isKeyWindow == true) } }; session.syncClipboard(focused: true); return true }
    init(session: DesktopSession) { self.session = session; super.init(frame: .zero); wantsLayer = true }
    deinit { clipboardTimer?.invalidate() }
    required init?(coder: NSCoder) { return nil }
    override var acceptsFirstResponder: Bool { true }
    private var displayRect: NSRect {
        guard let image = session.displayImage else { return bounds }
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) { NSColor.black.setFill(); bounds.fill(); if let image = session.displayImage { NSGraphicsContext.current?.cgContext.draw(image, in: displayRect) } }
    private func pointer(_ event: NSEvent, changed: UInt8 = 0, down: Bool = false, wheel: Int = 0) {
        guard let image = session.displayImage else { return }; let rect = displayRect, p = convert(event.locationInWindow, from: nil)
        if changed != 0 { if down { buttons |= changed } else { buttons &= ~changed } }
        let x = min(image.width - 1, max(0, Int((p.x - rect.minX) * CGFloat(image.width) / max(1, rect.width))))
        let y = min(image.height - 1, max(0, Int((rect.maxY - p.y) * CGFloat(image.height) / max(1, rect.height))))
        session.pointer(x + session.monitorOffset,y,buttons: buttons,changed: changed,down: down,wheel: wheel)
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); pointer(event, changed: 1, down: true) }
    override func mouseUp(with event: NSEvent) { pointer(event, changed: 1) }
    override func rightMouseDown(with event: NSEvent) { pointer(event, changed: 4, down: true) }
    override func rightMouseUp(with event: NSEvent) { pointer(event, changed: 4) }
    override func otherMouseDown(with event: NSEvent) { pointer(event, changed: 2, down: true) }
    override func otherMouseUp(with event: NSEvent) { pointer(event, changed: 2) }
    override func mouseDragged(with event: NSEvent) { pointer(event) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event) }
    override func scrollWheel(with event: NSEvent) { if event.scrollingDeltaY != 0 { pointer(event, wheel: event.scrollingDeltaY > 0 ? 1 : -1) } }
    override func mouseMoved(with event: NSEvent) { pointer(event) }
    override func updateTrackingAreas() { for area in trackingAreas { removeTrackingArea(area) }; addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved,.activeInKeyWindow,.inVisibleRect], owner: self)) }
    override func keyDown(with event: NSEvent) { session.syncClipboard(focused: true); let physical = !event.modifierFlags.intersection([.control,.option,.command]).isEmpty; let text = physical ? event.charactersIgnoringModifiers : event.characters; pressed[event.keyCode] = (text,physical); session.key(event.keyCode, text: text, down: true, physical: physical) }
    override func keyUp(with event: NSEvent) { let value = pressed.removeValue(forKey: event.keyCode); session.key(event.keyCode, text: value?.0 ?? event.characters, down: false, physical: value?.1 ?? false) }
    override func flagsChanged(with event: NSEvent) {
        let flags: [UInt16:NSEvent.ModifierFlags] = [56:.shift,60:.shift,59:.control,62:.control,58:.option,61:.option,55:.command,54:.command]
        guard let flag = flags[event.keyCode] else { return }; let down = event.modifierFlags.contains(flag) && !modifiers.contains(event.keyCode)
        if down { modifiers.insert(event.keyCode) } else { modifiers.remove(event.keyCode) }; session.key(event.keyCode, text: nil, down: down)
    }
    override func resignFirstResponder() -> Bool { clipboardTimer?.invalidate(); clipboardTimer = nil; session.syncClipboard(focused: false); for (code,value) in pressed { session.key(code,text: value.0,down: false,physical: value.1) }; pressed = [:]; for code in modifiers { session.key(code, text: nil, down: false) }; modifiers = []; if buttons != 0 { for button in [UInt8(1),2,4] where buttons & button != 0 { session.pointer(0,0,buttons: 0,changed: button) }; buttons = 0 }; return super.resignFirstResponder() }
}
