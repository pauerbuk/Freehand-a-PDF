// FreeHand a PDF: converte file FreeHand in PDF (lettura con libfreehand, disegno in FHEngine.mm).
// Uso: trascina i file (o una cartella) sulla finestra o sull'icona.
// Da Terminale: "FreeHand a PDF" --convert file1 file2 ...
import AppKit
import ImageIO

struct Outcome {
    let source: URL
    var pdf: URL? = nil
    var error: String? = nil
    var notes: [String] = []
    var info: String? = nil  // file che non è FreeHand: che cos'è, invece
    var copy: URL? = nil     // la sua copia con l'estensione giusta
}

struct FileKind {
    let description: String
    var extensions: [String] = []  // la prima è quella da usare per la copia
    var ambiguous = false          // lo stesso contenuto può avere più estensioni: meglio non sceglierne una
}

enum Converter {
    static func isFreeHand(_ url: URL) -> Bool { FHIsSupported(url.path) }

    // Riconosce il tipo dal contenuto, perché molti file vecchi non hanno estensione.
    static func identify(_ url: URL) -> FileKind? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 1 << 20), !head.isEmpty else {
            return FileKind(description: "un file vuoto (0 byte), senza alcun contenuto")
        }
        func starts(_ bytes: [UInt8]) -> Bool { head.starts(with: bytes) }
        func contains(_ text: String) -> Bool { head.range(of: Data(text.utf8)) != nil }
        func image(_ name: String, _ extensions: [String]) -> FileKind {
            var size = ""
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth], let h = props[kCGImagePropertyPixelHeight] {
                size = " (\(w) × \(h) pixel)"
            }
            return FileKind(description: name + size, extensions: extensions)
        }
        if starts(Array("%PDF".utf8)) {
            return contains("Adobe Illustrator") || contains("AIPrivateData")
                ? FileKind(description: "un file di Illustrator compatibile con PDF", extensions: ["ai", "pdf"])
                : FileKind(description: "un PDF", extensions: ["pdf"])
        }
        if starts([0x4D, 0x4D, 0x00, 0x2A]) || starts([0x49, 0x49, 0x2A, 0x00]) { return image("un'immagine TIFF", ["tif", "tiff"]) }
        if starts([0xFF, 0xD8, 0xFF]) { return image("un'immagine JPEG", ["jpg", "jpeg"]) }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return image("un'immagine PNG", ["png"]) }
        if starts(Array("GIF8".utf8)) { return image("un'immagine GIF", ["gif"]) }
        if starts(Array("BM".utf8)) { return image("un'immagine BMP", ["bmp"]) }
        if starts(Array("8BPS".utf8)) { return image("un file di Photoshop", ["psd", "psb"]) }
        if starts([0xC5, 0xD0, 0xD3, 0xC6]) { return FileKind(description: "un file EPS con anteprima", extensions: ["eps"]) }
        if starts(Array("%!".utf8)) {
            if contains("Pen Path Export") { return FileKind(description: "un tracciato esportato da Photoshop (PostScript)", extensions: ["ai", "eps"]) }
            if contains("Adobe Illustrator") { return FileKind(description: "un vecchio file di Illustrator (PostScript)", extensions: ["ai", "eps"]) }
            if contains("EPSF") { return FileKind(description: "un file EPS", extensions: ["eps"]) }
            return FileKind(description: "un file PostScript", extensions: ["ps", "eps"])
        }
        if starts(Array("FHD".utf8)) { return FileKind(description: "un file FreeHand di una versione che il programma non sa ancora leggere") }
        if starts(Array("PK".utf8) + [0x03, 0x04]) { return FileKind(description: "un archivio ZIP o un documento Office recente", extensions: ["zip", "docx", "xlsx", "pptx"], ambiguous: true) }
        if starts([0xD0, 0xCF, 0x11, 0xE0]) { return FileKind(description: "un vecchio documento Office", extensions: ["doc", "xls", "ppt"], ambiguous: true) }
        if starts(Array("RIFF".utf8)), head.count > 11, head[8...10].elementsEqual("CDR".utf8) { return FileKind(description: "un file di CorelDRAW", extensions: ["cdr"]) }
        if contains("<svg") { return FileKind(description: "un disegno SVG", extensions: ["svg"]) }
        let sample = head.prefix(4096)
        if !sample.contains(0), String(data: sample, encoding: .utf8) != nil || sample.allSatisfy({ $0 >= 9 && $0 < 0x80 }) {
            return FileKind(description: "un file di testo")
        }
        return nil
    }

    // Per i file classici del Mac il tipo può stare nelle informazioni del Finder, non nel contenuto.
    static func finderCodes(_ url: URL) -> String? {
        var info = [UInt8](repeating: 0, count: 32)
        guard getxattr(url.path, "com.apple.FinderInfo", &info, 32, 0, 0) >= 8 else { return nil }
        let printable: (UInt8) -> Bool = { $0 >= 0x20 && $0 < 0x7F }
        guard info[0..<8].allSatisfy(printable) else { return nil }
        return String(decoding: info[0..<4], as: UTF8.self) + "/" + String(decoding: info[4..<8], as: UTF8.self)
    }

    static func wrongExtension(_ url: URL, _ kind: FileKind?) -> Bool {
        guard let kind = kind, !kind.extensions.isEmpty, !url.pathExtension.isEmpty else { return false }
        return !kind.extensions.contains(url.pathExtension.lowercased())
    }

    // Che cos'è il file; se serve, ne crea una copia con l'estensione giusta accanto all'originale.
    static func describe(_ source: URL, into outcome: inout Outcome) {
        guard let kind = identify(source) else {
            outcome.error = "tipo di file non riconosciuto." + (finderCodes(source).map { " Codice Mac: \($0)." } ?? "")
            return
        }
        var text = kind.description.contains("FreeHand") ? "è \(kind.description)." : "è \(kind.description), non un file FreeHand."
        if let wanted = kind.extensions.first, !kind.ambiguous, source.pathExtension.isEmpty || wrongExtension(source, kind) {
            let fm = FileManager.default
            let exact = source.deletingPathExtension().appendingPathExtension(wanted)
            if fm.contentsEqual(atPath: source.path, andPath: exact.path) {
                text += " La copia \(exact.lastPathComponent) c'è già."
                outcome.copy = exact
            } else {
                let dest = destination(for: source, extension: wanted)
                do {
                    try fm.copyItem(at: source, to: dest)
                    text += " Ho creato la copia \(dest.lastPathComponent), pronta da aprire."
                    outcome.copy = dest
                } catch {
                    text += " Non ho potuto creare la copia: controlla di poter scrivere in quella cartella."
                }
            }
        }
        outcome.info = text
    }

    static func expand(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                while let item = items?.nextObject() as? URL {
                    guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                    // In una cartella segnala solo i file dal tipo poco chiaro: senza estensione o con quella sbagliata.
                    if isFreeHand(item) || item.pathExtension.isEmpty || wrongExtension(item, identify(item)) { files.append(item) }
                }
            } else {
                files.append(url)
            }
        }
        return files
    }

    // Guarda solo i file senza estensione o con estensione .fh…, leggendo l'inizio del file:
    // così la ricerca resta praticabile anche su un NAS.
    static func looksLikeFreeHand(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ext.isEmpty || ext.hasPrefix("fh"), let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 1 << 20), !head.isEmpty else { return false }
        for signature in ["AGD", "FHD"] {
            var from = head.startIndex
            while let r = head.range(of: Data(signature.utf8), in: from..<head.endIndex) {
                if r.upperBound < head.endIndex, (0x30...0x39).contains(head[r.upperBound]) { return isFreeHand(url) }
                from = r.upperBound
            }
        }
        return false
    }

    static func scan(_ root: URL, stopped: () -> Bool, progress: (URL, Int) -> Void, found: (URL) -> Void) -> Bool {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { return false }
        var checked = 0
        while let item = items.nextObject() as? URL {
            if stopped() { break }
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                // Cestino e miniature del Synology.
                if ["@eaDir", "#recycle"].contains(item.lastPathComponent) { items.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            checked += 1
            progress(item, checked)
            if (values.fileSize ?? 0) > 0, looksLikeFreeHand(item) { found(item) }
        }
        return true
    }

    // Non sovrascrive mai: "Nome.pdf", "Nome (2).pdf", ...
    static func destination(for source: URL, extension ext: String = "pdf", suffix: String = "") -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent + suffix
        var candidate = dir.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    // Ogni file è letto in un processo a parte: un file vecchio e danneggiato non può bloccare il programma.
    static func convert(_ source: URL, includeHidden: Bool = false, toAI: Bool = false) -> Outcome {
        var outcome = Outcome(source: source)
        guard FileManager.default.fileExists(atPath: source.path) else {
            outcome.error = "il file non si trova più."
            return outcome
        }
        guard isFreeHand(source) else {
            describe(source, into: &outcome)
            return outcome
        }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let pdf = tmp.appendingPathComponent(toAI ? "documento.ai" : "documento.pdf")
            let pipe = Pipe()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            p.arguments = ["--convert-one", source.path, pdf.path] + (includeHidden ? ["--hidden"] : []) + (toAI ? ["--ai"] : [])
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            try p.run()
            let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: watchdog)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            watchdog.cancel()
            guard p.terminationStatus == 0,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                outcome.error = "il lettore si è interrotto: il file potrebbe essere danneggiato."
                return outcome
            }
            outcome.notes = json["notes"] as? [String] ?? []
            guard json["ok"] as? Bool == true else {
                outcome.error = json["error"] as? String ?? "errore sconosciuto"
                return outcome
            }
            let dest = destination(for: source, extension: toAI ? "ai" : "pdf", suffix: json["hiddenIncluded"] as? Bool == true ? " (con livelli nascosti)" : "")
            try fm.moveItem(at: pdf, to: dest)
            outcome.pdf = dest
        } catch {
            outcome.error = error.localizedDescription
        }
        return outcome
    }
}

final class DropView: NSView {
    var onFiles: (([URL]) -> Void)?
    private var highlighted = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !urls(sender).isEmpty else { return [] }
        highlighted = true
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        onFiles?(urls(sender))
        return true
    }
    override func mouseDown(with event: NSEvent) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Scegli i file FreeHand da convertire, oppure una cartella"
        panel.prompt = "Converti"
        if panel.runModal() == .OK { onFiles?(panel.urls) }
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12)
        if highlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            path.fill()
        }
        (highlighted ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        path.lineWidth = 2
        path.setLineDash([7, 5], count: 2, phase: 0)
        path.stroke()
    }
}

final class Found: NSObject {
    let url: URL
    let folder: String
    let date: Date?
    let size: Int
    var hasPDF: Bool
    var hasAI: Bool

    init(url: URL, root: URL) {
        self.url = url
        let parent = url.deletingLastPathComponent().path
        let inside = parent.hasPrefix(root.path) ? String(parent.dropFirst(root.path.count)) : parent
        folder = inside.isEmpty ? "/" : inside
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        date = values?.contentModificationDate
        size = values?.fileSize ?? 0
        let base = url.deletingPathExtension()
        hasPDF = FileManager.default.fileExists(atPath: base.appendingPathExtension("pdf").path)
        hasAI = FileManager.default.fileExists(atPath: base.appendingPathExtension("ai").path)
    }
}

final class SearchController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let root: URL
    private let onConvert: ([URL]) -> Void
    private let convertsToAI: () -> Bool
    private let onClose: (SearchController) -> Void
    private let window: NSWindow
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let stopButton = NSButton(title: "Interrompi", target: nil, action: nil)
    private let allButton = NSButton(title: "Seleziona tutti", target: nil, action: nil)
    private let revealButton = NSButton(title: "Mostra nel Finder", target: nil, action: nil)
    private let convertButton = NSButton(title: "Converti i selezionati", target: nil, action: nil)
    private var items: [Found] = []
    private let lock = NSLock()
    private var stopRequested = false
    private let dates: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    init(root: URL, onConvert: @escaping ([URL]) -> Void, convertsToAI: @escaping () -> Bool, onClose: @escaping (SearchController) -> Void) {
        self.root = root
        self.onConvert = onConvert
        self.convertsToAI = convertsToAI
        self.onClose = onClose
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 500), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "File FreeHand in \(root.lastPathComponent)"
        window.minSize = NSSize(width: 620, height: 320)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        buildContent()
        window.makeKeyAndOrderFront(nil)
        start()
    }

    private func buildContent() {
        let content = window.contentView!
        for (id, title, width) in [("name", "Nome", 190.0), ("folder", "Cartella", 230.0), ("date", "Modificato", 85.0), ("size", "Dimensione", 70.0), ("pdf", "Già fatti", 60.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = CGFloat(width)
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.style = .plain
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.usesAlternatingRowBackgroundColors = true
        table.target = self
        table.doubleAction = #selector(showInFinder)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        status.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: 12)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        stopButton.target = self; stopButton.action = #selector(stopSearch)
        allButton.target = self; allButton.action = #selector(selectAll)
        revealButton.target = self; revealButton.action = #selector(showInFinder)
        convertButton.target = self; convertButton.action = #selector(convertSelected)
        convertButton.keyEquivalent = "\r"
        updateButtons()

        let top = NSStackView(views: [spinner, status, stopButton])
        top.orientation = .horizontal
        top.spacing = 8
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [allButton, spacer, revealButton, convertButton])
        bottom.orientation = .horizontal
        bottom.spacing = 8
        for v in [top, scroll, bottom] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            bottom.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            bottom.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    private var stopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopRequested
    }

    private func start() {
        spinner.startAnimation(nil)
        status.stringValue = "Cerco in \(root.path)…"
        let root = self.root
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var last = Date.distantPast
            var total = 0
            let ok = Converter.scan(root, stopped: { self.stopped }, progress: { url, checked in
                total = checked
                guard Date().timeIntervalSince(last) > 0.25 else { return }
                last = Date()
                let folder = url.deletingLastPathComponent().lastPathComponent
                DispatchQueue.main.async {
                    self.status.stringValue = "\(checked) file esaminati, \(self.items.count) FreeHand trovati. Sto guardando in: \(folder)"
                }
            }, found: { url in
                let item = Found(url: url, root: root)
                DispatchQueue.main.async {
                    self.items.append(item)
                    self.table.insertRows(at: IndexSet(integer: self.items.count - 1))
                }
            })
            DispatchQueue.main.async {
                self.spinner.stopAnimation(nil)
                self.stopButton.isHidden = true
                let what = self.stopped ? "Ricerca interrotta" : "Ricerca finita"
                self.status.stringValue = ok ? "\(what): \(total) file esaminati, \(self.items.count) FreeHand trovati." : "Non riesco a leggere questa cartella."
            }
        }
    }

    @objc private func stopSearch() {
        lock.lock(); stopRequested = true; lock.unlock()
        stopButton.isEnabled = false
        status.stringValue = "Interrompo…"
    }
    @objc private func selectAll() { table.selectAll(nil) }
    private var selected: [Found] { table.selectedRowIndexes.map { items[$0] } }

    @objc private func showInFinder() {
        let urls = selected.map(\.url)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    @objc private func convertSelected() {
        var chosen = selected
        guard !chosen.isEmpty else { return }
        // Conta solo i file già convertiti nel formato scelto ora.
        let toAI = convertsToAI()
        let done: (Found) -> Bool = { toAI ? $0.hasAI : $0.hasPDF }
        let already = chosen.filter(done)
        if !already.isEmpty {
            let kind = toAI ? ".ai" : "PDF"
            let alert = NSAlert()
            alert.messageText = already.count == 1 ? "Un file ha già il suo \(kind)" : "\(already.count) file hanno già il loro \(kind)"
            alert.informativeText = "Se li rifai, quelli esistenti non vengono toccati: i nuovi avranno un numero nel nome, come \"Nome (2)\"."
            alert.addButton(withTitle: "Salta questi")
            alert.addButton(withTitle: "Rifai anche questi")
            alert.addButton(withTitle: "Annulla")
            switch alert.runModal() {
            case .alertFirstButtonReturn: chosen.removeAll(where: done)
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        chosen.forEach { if toAI { $0.hasAI = true } else { $0.hasPDF = true } }
        table.reloadData()
        if !chosen.isEmpty { onConvert(chosen.map(\.url)) }
    }

    private func updateButtons() {
        let any = table.numberOfSelectedRows > 0
        revealButton.isEnabled = any
        convertButton.isEnabled = any
        convertButton.title = any ? "Converti i selezionati (\(table.numberOfSelectedRows))" : "Converti i selezionati"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "name": text = item.url.lastPathComponent
        case "folder": text = item.folder
        case "date": text = item.date.map { dates.string(from: $0) } ?? ""
        case "size": text = ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)
        default: text = [item.hasPDF ? "PDF" : nil, item.hasAI ? "AI" : nil].compactMap { $0 }.joined(separator: ", ")
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = tableColumn?.identifier.rawValue == "folder" ? item.url.path : nil
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let sort = tableView.sortDescriptors.first, let key = sort.key else { return }
        let chosen = Set(selected.map(\.url))
        items.sort { a, b in
            let ascending: Bool
            switch key {
            case "name": ascending = a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
            case "folder": ascending = a.folder.localizedStandardCompare(b.folder) == .orderedAscending
            case "date": ascending = (a.date ?? .distantPast) < (b.date ?? .distantPast)
            case "size": ascending = a.size < b.size
            default: ascending = (a.hasPDF ? 1 : 0) + (a.hasAI ? 2 : 0) < (b.hasPDF ? 1 : 0) + (b.hasAI ? 2 : 0)
            }
            return sort.ascending ? ascending : !ascending
        }
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(items.indices.filter { chosen.contains(items[$0].url) }), byExtendingSelection: false)
    }

    func windowWillClose(_ notification: Notification) {
        lock.lock(); stopRequested = true; lock.unlock()
        onClose(self)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let title = NSTextField(labelWithString: "Trascina qui i file FreeHand")
    private let subtitle = NSTextField(labelWithString: "oppure clicca per sceglierli. Il file viene salvato accanto all'originale.")
    private let spinner = NSProgressIndicator()
    private let log = NSTextView()
    private let reveal = NSButton(title: "Mostra nel Finder", target: nil, action: nil)
    private let search = NSButton(title: "Cerca file FreeHand…", target: nil, action: nil)
    private var searches: [SearchController] = []
    private let hiddenLayers = NSButton(checkboxWithTitle: "Includi i livelli nascosti", target: nil, action: nil)
    private let format = NSPopUpButton(frame: .zero, pullsDown: false)
    private let queue = DispatchQueue(label: "conversioni")
    private var pending = 0
    private var total = 0
    private var done = 0
    private var pdfs: [URL] = []  // i file creati, da mostrare nel Finder

    func applicationWillFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let i = CommandLine.arguments.firstIndex(of: "--cerca"), i + 1 < CommandLine.arguments.count {
            startSearch(URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func application(_ application: NSApplication, open urls: [URL]) { enqueue(urls) }

    private func buildMenu() {
        let main = NSMenu()
        let item = NSMenuItem()
        main.addItem(item)
        let menu = NSMenu()
        menu.addItem(withTitle: "Cerca file FreeHand…", action: #selector(chooseSearchFolder), keyEquivalent: "f").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Esci da FreeHand a PDF", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = menu
        NSApp.mainMenu = main
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 420), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "FreeHand a PDF"
        window.minSize = NSSize(width: 680, height: 340)
        window.center()
        let content = window.contentView!

        let drop = DropView(frame: .zero)
        drop.onFiles = { [weak self] in self?.enqueue($0) }
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.alignment = .center
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.lineBreakMode = .byTruncatingMiddle
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let stack = NSStackView(views: [title, subtitle, spinner])
        stack.orientation = .vertical
        stack.spacing = 6
        drop.addSubview(stack)

        log.isEditable = false
        log.font = .systemFont(ofSize: 12)
        log.textContainerInset = NSSize(width: 6, height: 6)
        log.textColor = .labelColor
        log.backgroundColor = .textBackgroundColor
        let scroll = NSScrollView()
        scroll.documentView = log
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        log.autoresizingMask = [.width]
        log.isVerticallyResizable = true
        log.textContainer?.widthTracksTextView = true

        reveal.target = self
        reveal.action = #selector(showInFinder)
        reveal.isEnabled = false
        search.target = self
        search.action = #selector(chooseSearchFolder)
        hiddenLayers.state = UserDefaults.standard.bool(forKey: "includiLivelliNascosti") ? .on : .off
        hiddenLayers.target = self
        hiddenLayers.action = #selector(hiddenLayersChanged)
        format.addItems(withTitles: ["PDF", "Illustrator (.ai)"])
        format.selectItem(at: UserDefaults.standard.bool(forKey: "formatoAI") ? 1 : 0)
        format.target = self
        format.action = #selector(formatChanged)
        format.toolTip = "Il formato .ai conserva i livelli di FreeHand, compresi quelli nascosti."
        hiddenLayers.isEnabled = format.indexOfSelectedItem == 0
        hiddenLayers.toolTip = "Disegna anche i livelli che in FreeHand erano nascosti. Il PDF si chiamerà \"Nome (con livelli nascosti).pdf\"."

        for v in [drop, scroll, reveal, search, hiddenLayers, format, stack] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        content.addSubview(drop)
        content.addSubview(scroll)
        content.addSubview(reveal)
        content.addSubview(search)
        content.addSubview(hiddenLayers)
        content.addSubview(format)
        NSLayoutConstraint.activate([
            drop.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            drop.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            drop.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            drop.heightAnchor.constraint(equalToConstant: 150),
            stack.centerXAnchor.constraint(equalTo: drop.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: drop.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: drop.widthAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: drop.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: drop.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: drop.trailingAnchor),
            reveal.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            reveal.trailingAnchor.constraint(equalTo: drop.trailingAnchor),
            reveal.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            search.leadingAnchor.constraint(equalTo: drop.leadingAnchor),
            search.centerYAnchor.constraint(equalTo: reveal.centerYAnchor),
            format.leadingAnchor.constraint(equalTo: search.trailingAnchor, constant: 10),
            format.centerYAnchor.constraint(equalTo: reveal.centerYAnchor),
            format.widthAnchor.constraint(equalToConstant: 130),
            hiddenLayers.leadingAnchor.constraint(equalTo: format.trailingAnchor, constant: 10),
            hiddenLayers.centerYAnchor.constraint(equalTo: reveal.centerYAnchor),
        ])
    }

    private func append(_ line: String, color: NSColor = .labelColor) {
        let text = NSAttributedString(string: line + "\n", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color])
        log.textStorage?.append(text)
        log.scrollToEndOfDocument(nil)
    }

    private func updateStatus() {
        if pending > 0 {
            subtitle.stringValue = "Converto \(done + 1) di \(total)…"
            spinner.startAnimation(nil)
        } else {
            subtitle.stringValue = "oppure clicca per sceglierli. Il file viene salvato accanto all'originale."
            spinner.stopAnimation(nil)
            total = 0
            done = 0
        }
    }

    private func enqueue(_ urls: [URL]) {
        let includeHidden = hiddenLayers.state == .on
        let toAI = format.indexOfSelectedItem == 1
        queue.async {
            let files = Converter.expand(urls)
            DispatchQueue.main.async {
                if files.isEmpty { self.append("✗ Nessun file da controllare in quello che hai trascinato.", color: .systemRed) }
                self.pending += files.count
                self.total += files.count
                self.updateStatus()
            }
            for file in files {
                let outcome = Converter.convert(file, includeHidden: includeHidden, toAI: toAI)
                DispatchQueue.main.async { self.finished(outcome) }
            }
        }
    }

    private func finished(_ outcome: Outcome) {
        let name = outcome.source.lastPathComponent
        if let info = outcome.info {
            append("ⓘ \(name): \(info)", color: .secondaryLabelColor)
            if let copy = outcome.copy {
                pdfs.append(copy)
                reveal.isEnabled = true
            }
        } else if let pdf = outcome.pdf {
            append("✓ \(name) → \(pdf.lastPathComponent)")
            pdfs.append(pdf)
            reveal.isEnabled = true
            for note in outcome.notes { append("   ⚠︎ \(note)", color: .systemOrange) }
        } else {
            append("✗ \(name): \(outcome.error ?? "errore sconosciuto")", color: .systemRed)
        }
        pending -= 1
        done += 1
        updateStatus()
    }

    @objc private func showInFinder() { NSWorkspace.shared.activateFileViewerSelecting(pdfs) }

    @objc private func formatChanged() {
        UserDefaults.standard.set(format.indexOfSelectedItem == 1, forKey: "formatoAI")
        hiddenLayers.isEnabled = format.indexOfSelectedItem == 0
    }

    @objc private func hiddenLayersChanged() {
        UserDefaults.standard.set(hiddenLayers.state == .on, forKey: "includiLivelliNascosti")
    }

    @objc private func chooseSearchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Scegli dove cercare: una cartella, un disco o il NAS. I file non vengono modificati."
        panel.prompt = "Cerca"
        if panel.runModal() == .OK, let folder = panel.url { startSearch(folder) }
    }

    private func startSearch(_ folder: URL) {
        let controller = SearchController(root: folder, onConvert: { [weak self] urls in
            self?.enqueue(urls)
            self?.window.makeKeyAndOrderFront(nil)
        }, convertsToAI: { [weak self] in
            self?.format.indexOfSelectedItem == 1
        }, onClose: { [weak self] closed in
            self?.searches.removeAll { $0 === closed }
        })
        searches.append(controller)
    }
}

let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "--search" {
    var total = 0
    let ok = Converter.scan(URL(fileURLWithPath: arguments[2]), stopped: { false }, progress: { _, n in total = n }, found: { print($0.path); fflush(stdout) })
    print(ok ? "--- esaminati \(total)" : "--- cartella non leggibile")
    exit(ok ? 0 : 1)
}
if arguments.count >= 4, arguments[1] == "--convert-one" {
    let result = (arguments.contains("--ai") ? FHConvertToAI(arguments[2], arguments[3]) : FHConvertToPDF(arguments[2], arguments[3], arguments.contains("--hidden")))!
    let json: [String: Any] = ["ok": result.ok, "error": result.error ?? "", "notes": result.notes ?? [], "hiddenIncluded": result.includedHiddenLayers]
    FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: json))
    exit(0)
}
if let i = arguments.firstIndex(of: "--convert") {
    var failed = false
    let includeHidden = arguments.contains("--livelli-nascosti")
    let toAI = arguments.contains("--ai")
    for file in Converter.expand(arguments[(i + 1)...].filter { !["--livelli-nascosti", "--ai"].contains($0) }.map { URL(fileURLWithPath: $0) }) {
        let outcome = Converter.convert(file, includeHidden: includeHidden, toAI: toAI)
        if let info = outcome.info {
            print("INFO \(file.path): \(info)")
        } else if let pdf = outcome.pdf {
            print("OK  \(file.path) -> \(pdf.path)")
            for note in outcome.notes { print("    \(note)") }
        } else {
            print("ERR \(file.path): \(outcome.error ?? "errore sconosciuto")")
            failed = true
        }
    }
    exit(failed ? 1 : 0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
