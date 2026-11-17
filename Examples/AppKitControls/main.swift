// A gallery of AppKit's standard controls, built the way a Mac app builds
// them: a split view controller with a sidebar outline view, a table with
// sortable columns, a form of controls, a text view, a toolbar and a
// popover.

import AppKit

// MARK: Data

struct Item {
    var name: String
    var kind: String
    var size: Int
    var modified: String
    var symbol: String
}

let allItems: [Item] = [
    Item(name: "Quarterly Report.pages", kind: "Pages Document", size: 482_113, modified: "Today, 09:41", symbol: "doc.text"),
    Item(name: "Runway Design.sketch", kind: "Sketch Document", size: 12_480_000, modified: "Yesterday, 18:02", symbol: "doc"),
    Item(name: "Launch Plan.key", kind: "Keynote Presentation", size: 8_204_331, modified: "Mon, 14:15", symbol: "doc"),
    Item(name: "Screenshots", kind: "Folder", size: 0, modified: "Mon, 10:20", symbol: "folder"),
    Item(name: "Budget 2026.numbers", kind: "Numbers Spreadsheet", size: 96_220, modified: "3 Nov 2026", symbol: "doc.text"),
    Item(name: "notes.md", kind: "Markdown Text", size: 4_096, modified: "1 Nov 2026", symbol: "doc.text"),
    Item(name: "Holiday.mov", kind: "QuickTime Movie", size: 312_440_100, modified: "28 Oct 2026", symbol: "film"),
    Item(name: "Team Photo.heic", kind: "HEIF Image", size: 3_120_554, modified: "21 Oct 2026", symbol: "photo"),
    Item(name: "Archive.zip", kind: "ZIP Archive", size: 54_002_118, modified: "12 Oct 2026", symbol: "doc"),
    Item(name: "Invoices", kind: "Folder", size: 0, modified: "2 Oct 2026", symbol: "folder"),
]

final class SidebarNode {
    let title: String
    let symbol: String?
    var children: [SidebarNode]
    let isGroup: Bool
    init(_ title: String, symbol: String? = nil, group: Bool = false, _ children: [SidebarNode] = []) {
        self.title = title; self.symbol = symbol; self.isGroup = group; self.children = children
    }
}

let sidebarTree = [
    SidebarNode("Favourites", group: true, [
        SidebarNode("Recents", symbol: "clock"),
        SidebarNode("Documents", symbol: "doc"),
        SidebarNode("Downloads", symbol: "arrow.down.circle"),
    ]),
    SidebarNode("Projects", group: true, [
        SidebarNode("Runway", symbol: "folder", [SidebarNode("Sources", symbol: "folder"), SidebarNode("Examples", symbol: "folder")]),
        SidebarNode("Flight Notes", symbol: "folder"),
        SidebarNode("Caps", symbol: "folder"),
    ]),
    SidebarNode("Tags", group: true, [
        SidebarNode("Important", symbol: "star"),
        SidebarNode("Work", symbol: "tag"),
    ]),
]

// MARK: Sidebar

final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = NSOutlineView(frame: .zero)

    override func loadView() {
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 220, height: 600))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        outline.style = .sourceList
        outline.selectionHighlightStyle = .sourceList
        outline.headerView = nil
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = self
        outline.delegate = self
        scroll.documentView = outline
        view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        for n in sidebarTree { outline.expandItem(n) }
        outline.expandItem(sidebarTree[1].children[0])
        outline.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? sidebarTree.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? sidebarTree[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? SidebarNode)?.children.isEmpty ?? true)
    }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? SidebarNode)?.isGroup ?? false }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { !((item as? SidebarNode)?.isGroup ?? false) }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        let id = NSUserInterfaceItemIdentifier(node.isGroup ? "Header" : "Cell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let c = NSTableCellView(frame: .zero)
            c.identifier = id
            let tf = NSTextField(labelWithString: "")
            c.addSubview(tf)
            c.textField = tf
            if !node.isGroup {
                let iv = NSImageView(frame: .zero)
                c.addSubview(iv)
                c.imageView = iv
            }
            return c
        }()
        cell.textField?.stringValue = node.title
        if node.isGroup {
            cell.textField?.font = .systemFont(ofSize: 11, weight: .semibold)
            cell.textField?.textColor = .tertiaryLabelColor
        }
        if let s = node.symbol {
            cell.imageView?.image = NSImage(systemSymbolName: s, accessibilityDescription: nil)
            cell.imageView?.contentTintColor = .controlAccentColor
        }
        return cell
    }
}

// MARK: Table

final class FilesController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView(frame: .zero)
    var items = allItems
    var onSelect: ((Item?) -> Void)?

    override func loadView() {
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 640, height: 300))
        scroll.hasVerticalScroller = true
        let columns: [(String, String, CGFloat)] = [("name", "Name", 260), ("kind", "Kind", 160), ("size", "Size", 90), ("modified", "Date Modified", 140)]
        for (id, title, width) in columns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            switch id {
            case "size": c.sortDescriptorPrototype = NSSortDescriptor(keyPath: \Item.size, ascending: true)
            case "kind": c.sortDescriptorPrototype = NSSortDescriptor(keyPath: \Item.kind, ascending: true)
            case "modified": c.sortDescriptorPrototype = NSSortDescriptor(keyPath: \Item.modified, ascending: true)
            default: c.sortDescriptorPrototype = NSSortDescriptor(keyPath: \Item.name, ascending: true)
            }
            if id == "size" { c.headerCell.alignment = .right }
            table.addTableColumn(c)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.style = .fullWidth
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.sortDescriptors = [table.tableColumns[0].sortDescriptorPrototype!]
        scroll.documentView = table
        view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first else { return }
        let asc = d.ascending
        switch d.keyPath {
        case let k where k == \Item.size: items.sort { asc ? $0.size < $1.size : $0.size > $1.size }
        case let k where k == \Item.kind: items.sort { asc ? $0.kind < $1.kind : $0.kind > $1.kind }
        case let k where k == \Item.modified: items.sort { asc ? $0.modified < $1.modified : $0.modified > $1.modified }
        default: items.sort { asc ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        }
        tableView.reloadData()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn else { return nil }
        let item = items[row]
        let id = col.identifier
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let c = NSTableCellView(frame: .zero)
            c.identifier = id
            let tf = NSTextField(labelWithString: "")
            c.addSubview(tf)
            c.textField = tf
            if id.rawValue == "name" {
                let iv = NSImageView(frame: .zero)
                c.addSubview(iv)
                c.imageView = iv
            }
            if id.rawValue != "name" { tf.textColor = .secondaryLabelColor }
            if id.rawValue == "size" { tf.alignment = .right }
            return c
        }()
        switch id.rawValue {
        case "name":
            cell.textField?.stringValue = item.name
            cell.imageView?.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
        case "kind": cell.textField?.stringValue = item.kind
        case "size": cell.textField?.stringValue = item.size == 0 ? "--" : ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)
        default: cell.textField?.stringValue = item.modified
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelect?(table.selectedRow >= 0 ? items[table.selectedRow] : nil)
    }
}

// MARK: Detail: a form and a text view

final class DetailController: NSViewController, NSTextFieldDelegate {
    let nameField = NSTextField(string: "Runway Design.sketch")
    let status = NSTextField(labelWithString: "")
    let textView = NSTextView(frame: .zero)

    func row(_ label: String, _ control: NSView) -> NSStackView {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        l.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let s = NSStackView(views: [l, control])
        s.spacing = 8
        s.alignment = .centerY
        return s
    }

    override func loadView() {
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 300))

        // The form.
        nameField.placeholderString = "Name"
        nameField.delegate = self
        nameField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let kind = NSPopUpButton(frame: .zero, pullsDown: false)
        kind.addItems(withTitles: ["Document", "Folder", "Image", "Movie"])
        let tags = NSTokenField(frame: .zero)
        tags.widthAnchor.constraint(equalToConstant: 220).isActive = true
        tags.objectValue = ["design", "runway"]
        let share = NSSegmentedControl(labels: ["Private", "Team", "Public"], trackingMode: .selectOne, target: nil, action: nil)
        share.selectedSegment = 1
        let rating = NSLevelIndicator(frame: CGRect(x: 0, y: 0, width: 80, height: 16))
        rating.levelIndicatorStyle = .rating
        rating.maxValue = 5
        rating.doubleValue = 4
        rating.isEditable = true
        let volume = NSSlider(value: 0.6, minValue: 0, maxValue: 1, target: nil, action: nil)
        volume.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let copies = NSStepper(frame: .zero)
        copies.maxValue = 10
        copies.integerValue = 2
        let copiesLabel = NSTextField(labelWithString: "2 copies")
        copies.handler = { c in copiesLabel.stringValue = "\(c.integerValue) copies" }
        let copiesRow = NSStackView(views: [copies, copiesLabel])
        copiesRow.spacing = 6
        let checks = NSStackView(views: [
            NSButton(checkboxWithTitle: "Sync to iCloud", target: nil, action: nil),
            NSButton(checkboxWithTitle: "Lock", target: nil, action: nil),
        ])
        (checks.arrangedSubviews[0] as? NSButton)?.state = .on
        checks.spacing = 14
        let radios = NSStackView(views: [
            NSButton(radioButtonWithTitle: "Small", target: nil, action: nil),
            NSButton(radioButtonWithTitle: "Medium", target: nil, action: nil),
            NSButton(radioButtonWithTitle: "Large", target: nil, action: nil),
        ])
        (radios.arrangedSubviews[1] as? NSButton)?.state = .on
        radios.spacing = 12
        let sw = NSSwitch(frame: .zero)
        sw.state = .on
        let progress = NSProgressIndicator(frame: CGRect(x: 0, y: 0, width: 200, height: 20))
        progress.isIndeterminate = false
        progress.widthAnchor.constraint(equalToConstant: 220).isActive = true
        progress.doubleValue = 64
        let color = NSColorWell(frame: .zero)
        color.color = .systemIndigo
        let buttons = NSStackView(views: [
            NSButton(title: "Cancel", target: nil, action: nil),
            {
                let b = NSButton(title: "Save", target: nil, action: nil)
                b.keyEquivalent = "\r"
                b.handler = { [weak self] _ in self?.status.stringValue = "Saved \u{201C}\(self?.nameField.stringValue ?? "")\u{201D}" }
                return b
            }(),
        ])
        buttons.spacing = 10
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)

        let form = NSStackView(views: [
            row("Name:", nameField), row("Kind:", kind), row("Tags:", tags), row("Sharing:", share),
            row("Rating:", rating), row("Volume:", volume), row("Copies:", copiesRow), row("Options:", checks),
            row("Size:", radios), row("Offline:", sw), row("Uploaded:", progress), row("Colour:", color),
            buttons, status,
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        form.edgeInsets = NSEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        form.setCustomSpacing(16, after: form.arrangedSubviews[11])
        form.frame = CGRect(x: 0, y: 0, width: 360, height: 300)
        form.autoresizingMask = [.height]

        // A box with the text view.
        let box = NSBox(frame: CGRect(x: 360, y: 0, width: 280, height: 300))
        box.title = "Notes"
        box.autoresizingMask = [.width, .height]
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 260, height: 260))
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.autoresizingMask = [.width, .height]
        textView.frame = CGRect(x: 0, y: 0, width: 260, height: 260)
        textView.autoresizingMask = [.width]
        textView.textContainerInset = CGSize(width: 4, height: 6)
        scroll.documentView = textView
        box.contentView?.addSubview(scroll)
        scroll.frame = box.contentView?.bounds ?? .zero

        let ts = textView.textStorage!
        let body = NSFont.systemFont(ofSize: 13)
        ts.append(NSAttributedString(string: "Runway Design\n", attributes: [.font: NSFont.systemFont(ofSize: 17, weight: .bold)]))
        ts.append(NSAttributedString(string: "The layout follows the ", attributes: [.font: body]))
        ts.append(NSAttributedString(string: "Mac's", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold)]))
        ts.append(NSAttributedString(string: " metrics; colours come from the ", attributes: [.font: body]))
        ts.append(NSAttributedString(string: "system palette", attributes: [.font: body, .foregroundColor: NSColor.systemBlue, .underlineStyle: NSUnderlineStyle.single.rawValue]))
        ts.append(NSAttributedString(string: ".\n\n", attributes: [.font: body]))
        ts.append(NSAttributedString(string: "Open questions\n", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]))
        let p = NSMutableParagraphStyle()
        p.headIndent = 14
        p.firstLineHeadIndent = 2
        p.paragraphSpacing = 3
        ts.append(NSAttributedString(string: "\u{2022} Sidebar width on small screens\n\u{2022} Dark mode accent\n\u{2022} Token field completion", attributes: [.font: body, .paragraphStyle: p, .foregroundColor: NSColor.secondaryLabelColor]))

        root.addSubview(form)
        root.addSubview(box)
        view = root
    }

    func controlTextDidChange(_ obj: Notification) {
        status.stringValue = "Editing\u{2026}"
    }
}

// MARK: Content: the table over the detail

final class ContentController: NSSplitViewController {
    let files = FilesController()
    let detail = DetailController()
    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        addSplitViewItem(NSSplitViewItem(viewController: files))
        let d = NSSplitViewItem(viewController: detail)
        d.holdingPriority = NSLayoutConstraint.Priority(260)
        addSplitViewItem(d)
        files.onSelect = { [weak self] item in
            if let item { self?.detail.nameField.stringValue = item.name }
        }
    }
}

// MARK: The window

final class MainController: NSSplitViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        addSplitViewItem(NSSplitViewItem(sidebarWithViewController: SidebarController()))
        addSplitViewItem(NSSplitViewItem(viewController: ContentController()))
    }
}

@MainActor final class ToolbarController: NSObject, NSToolbarDelegate {
    weak var window: NSWindow?
    let popover = NSPopover()

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, "view", .flexibleSpace, "share", "add", "search"]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case "view":
            let g = NSToolbarItemGroup(itemIdentifier: id, images: [
                NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Icons")!,
                NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List")!,
            ], selectionMode: .selectOne, labels: ["Icons", "List"], target: nil, action: nil)
            g.selectedIndex = 1
            return g
        case "share":
            let i = NSToolbarItem(itemIdentifier: id)
            i.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")
            i.label = "Share"
            return i
        case "add":
            let i = NSToolbarItem(itemIdentifier: id)
            i.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Info")
            i.label = "Info"
            i.handler = { [weak self] item in self?.showInfo() }
            return i
        case "search":
            let s = NSSearchToolbarItem(itemIdentifier: id)
            s.preferredWidthForSearchField = 170
            return s
        default:
            return nil
        }
    }

    /// A popover with a little form, pointing at the window's content.
    func showInfo() {
        guard let content = window?.contentView else { return }
        let vc = NSViewController()
        let v = NSStackView(views: [
            NSTextField(labelWithString: "Runway Design.sketch"),
            {
                let l = NSTextField(wrappingLabelWithString: "Sketch Document \u{2022} 12.5 MB\nModified yesterday at 18:02")
                l.textColor = .secondaryLabelColor
                l.font = .systemFont(ofSize: 11)
                return l
            }(),
            NSButton(checkboxWithTitle: "Show in sidebar", target: nil, action: nil),
        ])
        v.orientation = .vertical
        v.alignment = .leading
        v.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        (v.arrangedSubviews[0] as? NSTextField)?.font = .systemFont(ofSize: 13, weight: .semibold)
        v.frame = CGRect(x: 0, y: 0, width: 240, height: 100)
        vc.view = v
        popover.contentViewController = vc
        popover.contentSize = CGSize(width: 240, height: 100)
        popover.behavior = .transient
        popover.show(relativeTo: CGRect(x: content.bounds.width - 120, y: 4, width: 20, height: 4), of: content, preferredEdge: .minY)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let toolbarController = ToolbarController()
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1180, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Files"
        window.subtitle = "10 items"
        window.contentViewController = MainController()
        window.setContentSize(CGSize(width: 1180, height: 760))
        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = toolbarController
        toolbarController.window = window
        window.toolbar = toolbar
        window.makeKeyAndOrderFront(nil)

        // A menu-bar extra (a tray item where the desktop has one).
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Files")
        let menu = NSMenu(title: "Files")
        menu.addItem(withTitle: "Open Files", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: Selector("terminate:"), keyEquivalent: "q")
        item.menu = menu
        statusItem = item

        if ProcessInfo.processInfo.environment["DEMO_POPOVER"] != nil {
            toolbarController.showInfo()
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
