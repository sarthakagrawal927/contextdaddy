import SwiftUI
import AppKit
import DiskCore

struct DiskMapView: View {
    @EnvironmentObject var m: ExplorerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if m.mode == .top { rankedList }
            else if m.mode == .age { ageMap }
            else {
                GeometryReader { g in
                    let shapes = layout(size: g.size)
                    Canvas { ctx, size in
                        for shape in shapes {
                            let selected = m.selected == shape.node.id
                            ctx.fill(shape.path, with: .color(Tints.forNode(shape.node).opacity(selected ? 1 : 0.9)))
                            ctx.stroke(shape.path, with: .color(selected ? Color.white : Color.black), lineWidth: selected ? 4 : 3)
                            if shape.labelRect.width > 55 && shape.labelRect.height > 28 {
                                let ink = Color(red: 0.015, green: 0.02, blue: 0.03)
                                if m.mode == .treemap, shape.labelRect.height > 65, shape.labelRect.width > 95 {
                                    let r = shape.labelRect.insetBy(dx: 14, dy: 12)
                                    ctx.draw(Text(StorageLabels.name(shape.node)).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundColor(ink), in: CGRect(x: r.minX, y: r.minY, width: r.width, height: 24))
                                    ctx.draw(Text(DiskFormat.bytes(m.bytes(shape.node))).font(.system(size: 14, weight: .medium)).foregroundColor(ink.opacity(0.8)), in: CGRect(x: r.minX, y: r.minY + 29, width: r.width, height: 20))
                                } else {
                                    let text = Text(StorageLabels.name(shape.node)).font(.system(size: 12, weight: .semibold)).foregroundColor(ink)
                                    ctx.draw(text, in: shape.labelRect.insetBy(dx: 7, dy: 5))
                                }
                            }
                        }
                    }
                    .overlay {
                        MapContextMenu(shapes: shapes, model: m)
                    }
                    .modifier(MapHoverDetails(shapes: shapes, allocated: m.allocated))
                    .gesture(
                        SpatialTapGesture(count: 2)
                            .onEnded { value in
                                guard let hit = shapes.reversed().first(where: { $0.path.contains(value.location) }) else { return }
                                if hit.node.isDirectory { m.open(hit.node) }
                                else { m.selected = hit.node.id }
                            }
                            .exclusively(before: SpatialTapGesture()
                                .onEnded { value in
                                    if let hit = shapes.reversed().first(where: { $0.path.contains(value.location) }) {
                                        m.selected = hit.node.id
                                    }
                                })
                    )
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(m.mode.rawValue) of \(m.visible.count) items. Select items using the list below.")
                }.frame(minHeight: 210, maxHeight: .infinity)
                Text(caption).font(.caption).foregroundStyle(Tints.secondaryText)
                Divider()
                itemList(m.visible).frame(maxHeight: 200)
            }
        }
    }
    private var caption: String {
        switch m.mode {
        case .sunburst: "Rings show folder depth; arc length shows size. Up to three levels and the largest 60 children per level."
        case .flame: "Width shows size; each row is a deeper folder level. Up to four levels."
        case .bubbles: "Circle area shows size among the 36 largest items. Select an item below to inspect or open."
        case .mindMap: "Branch width shows relative size. The 18 largest items branch from the current folder."
        default: "Area shows size in this folder. Select to inspect; double-click a folder tile or list item to explore it. Up to 120 items drawn."
        }
    }
    private var rankedList: some View {
        VStack(alignment: .leading) {
            Text("Largest files in this folder tree").font(.headline)
            itemList(largestFiles)
        }
    }
    private var largestFiles: [DiskNode] { m.ranked }
    private func itemList(_ items: [DiskNode]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { n in
                    Button { m.selected = n.id } label: {
                        HStack { Image(systemName: n.isDirectory ? "folder.fill" : "doc").foregroundStyle(Tints.forNode(n)); Text(StorageLabels.name(n)).lineLimit(1); Spacer(); Text(DiskFormat.bytes(m.bytes(n))).monospacedDigit(); if n.isDirectory { Image(systemName: "chevron.right") } }.padding(.vertical, 9).padding(.horizontal, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain).background(m.selected == n.id ? Tints.electricBlue.opacity(0.2) : .clear)
                        .help("\(StorageLabels.name(n)) · \(DiskFormat.bytes(m.bytes(n))) \(m.allocated ? "on disk" : "logical")")
                        .simultaneousGesture(TapGesture(count: 2).onEnded { m.open(n) })
                        .contextMenu { StorageItemMenu(node: n) }
                    Divider()
                }
            }
        }
    }
    private var ageMap: some View {
        let files = filesByAge
        let totals = files.map { $0.bytes }
        let maximum = max(1, totals.max() ?? 1)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Storage by last modified date").font(.headline)
                Text("Modification dates do not tell you when a file was last opened.").font(.caption).foregroundStyle(Tints.secondaryText)
                ForEach(0..<4) { i in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack { Text(["Last 30 days", "1–6 months", "6–12 months", "Over a year"][i]); Spacer(); Text(DiskFormat.bytes(totals[i])).monospacedDigit() }
                        GeometryReader { g in RoundedRectangle(cornerRadius: 4).fill(Tints.colors[i]).frame(width: max(2, g.size.width * Double(totals[i]) / Double(maximum))) }.frame(height: 18)
                            .help("\(files[i].count.formatted()) files · \(DiskFormat.bytes(totals[i])) \(m.allocated ? "on disk" : "logical")")
                        Text("\(files[i].count.formatted()) files").font(.caption).foregroundStyle(Tints.secondaryText)
                        ForEach(files[i].largest.sorted) { n in
                            Button { m.selected = n.id } label: { HStack { Text(StorageLabels.name(n)).lineLimit(1); Spacer(); Text(DiskFormat.bytes(m.bytes(n))) }.font(.caption) }.buttonStyle(.plain)
                                .contextMenu { StorageItemMenu(node: n) }
                        }
                    }
                }
            }
        }
    }
    private var filesByAge: [AgeSummary] { m.aged }

    private func layout(size: CGSize) -> [DiskMapTile] {
        guard let scan = m.scan else { return [] }
        let items = m.visible; var tiles: [DiskMapTile] = []
        let full = CGRect(origin: .zero, size: size)
        func weight(_ n: DiskNode) -> Double { Double(max(0, m.bytes(n))) }
        func descendants(_ n: DiskNode) -> [DiskNode] { n.children.map { scan.nodes[$0] }.sorted { weight($0) > weight($1) } }
        func rectangles(_ children: [DiskNode], _ rect: CGRect, _ depth: Int, _ flame: Bool) {
            let total = children.reduce(0.0) { $0 + weight($1) }; guard total > 0, depth < (flame ? 4 : 3) else { return }
            var offset = 0.0
            for n in children.prefix(60) {
                let fraction = weight(n) / total
                let horizontal = flame || rect.width > rect.height
                let r = horizontal ? CGRect(x: rect.minX + offset * rect.width, y: rect.minY, width: fraction * rect.width, height: flame ? size.height / 4 - 3 : rect.height) : CGRect(x: rect.minX, y: rect.minY + offset * rect.height, width: rect.width, height: fraction * rect.height)
                offset += fraction
                guard r.width > 1 && r.height > 1 else { continue }
                tiles.append(DiskMapTile(node: n, path: Path(roundedRect: r.insetBy(dx: 1, dy: 1), cornerRadius: 4), labelRect: CGRect(x: r.minX, y: r.minY, width: r.width, height: min(r.height, 30))))
                if n.isDirectory {
                    let next = flame ? CGRect(x: r.minX, y: r.minY + size.height / 4, width: r.width, height: r.height) : CGRect(x: r.minX + 4, y: r.minY + 30, width: max(0, r.width - 8), height: max(0, r.height - 34))
                    if next.width > 20 && next.height > 15 { rectangles(descendants(n), next, depth + 1, flame) }
                }
            }
        }
        switch m.mode {
        case .treemap:
            func partition(_ entries: ArraySlice<DiskNode>, _ r: CGRect) {
                guard !entries.isEmpty, r.width > 1, r.height > 1 else { return }
                if entries.count == 1, let n = entries.first {
                    let inset = r.insetBy(dx: 2, dy: 2)
                    tiles.append(DiskMapTile(node: n, path: Path(roundedRect: inset, cornerRadius: 9), labelRect: inset)); return
                }
                let total = entries.reduce(0.0) { $0 + weight($1) }; guard total > 0 else { return }
                var sum = 0.0; var split = entries.startIndex + 1
                for i in entries.indices.dropLast() {
                    sum += weight(entries[i]); split = i + 1
                    if sum >= total / 2 { break }
                }
                let ratio = sum / total
                if r.width > r.height {
                    partition(entries[..<split], CGRect(x: r.minX, y: r.minY, width: r.width * ratio, height: r.height))
                    partition(entries[split...], CGRect(x: r.minX + r.width * ratio, y: r.minY, width: r.width * (1 - ratio), height: r.height))
                } else {
                    partition(entries[..<split], CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * ratio))
                    partition(entries[split...], CGRect(x: r.minX, y: r.minY + r.height * ratio, width: r.width, height: r.height * (1 - ratio)))
                }
            }
            let positive = items.filter { weight($0) > 0 }
            let shown = Array(positive.prefix(120))
            let total = positive.reduce(0.0) { $0 + weight($1) }
            let shownTotal = shown.reduce(0.0) { $0 + weight($1) }
            partition(shown[...], CGRect(x: 0, y: 0, width: full.width * shownTotal / max(1, total), height: full.height))
        case .flame: rectangles(items, full, 0, true)
        case .sunburst:
            let center = CGPoint(x: size.width / 2, y: size.height / 2); let radius = min(size.width, size.height) / 2 - 4
            func rings(_ children: [DiskNode], _ from: Double, _ span: Double, _ depth: Int) {
                guard depth < 3 else { return }; let total = children.reduce(0.0) { $0 + weight($1) }; guard total > 0 else { return }; var angle = from
                for n in children.prefix(60) {
                    let sweep = span * weight(n) / total; let start = angle; angle += sweep
                    guard sweep > 0.001 else { continue }
                    let inner = radius * Double(depth + 1) / 4; let outer = radius * Double(depth + 2) / 4
                    var p = Path(); p.addArc(center: center, radius: outer, startAngle: .radians(start), endAngle: .radians(angle), clockwise: false); p.addArc(center: center, radius: inner, startAngle: .radians(angle), endAngle: .radians(start), clockwise: true); p.closeSubpath()
                    tiles.append(DiskMapTile(node: n, path: p, labelRect: .zero)); rings(descendants(n), start, sweep, depth + 1)
                }
            }
            rings(items, -.pi / 2, .pi * 2, 0)
        case .bubbles:
            let displayed = Array(items.prefix(36)); let columns = max(1, Int(ceil(sqrt(Double(displayed.count) * size.width / max(1, size.height)))))
            let rows = max(1, Int(ceil(Double(displayed.count) / Double(columns)))); let cell = CGSize(width: size.width / Double(columns), height: size.height / Double(rows)); let maximum = max(1, displayed.map(weight).max() ?? 1)
            for (i, n) in displayed.enumerated() {
                let diameter = min(cell.width, cell.height) * 0.93 * sqrt(weight(n) / maximum)
                let r = CGRect(x: Double(i % columns) * cell.width + (cell.width - diameter) / 2, y: Double(i / columns) * cell.height + (cell.height - diameter) / 2, width: diameter, height: diameter)
                tiles.append(DiskMapTile(node: n, path: Path(ellipseIn: r), labelRect: r.insetBy(dx: diameter * 0.15, dy: diameter * 0.25)))
            }
        case .mindMap:
            let displayed = Array(items.prefix(18)); let total = max(1, displayed.reduce(0.0) { $0 + weight($1) }); let mid = CGPoint(x: 40, y: size.height / 2)
            for (i, n) in displayed.enumerated() {
                let y = (Double(i) + 0.5) * size.height / Double(displayed.count)
                var line = Path(); line.move(to: mid); line.addCurve(to: CGPoint(x: size.width * 0.43, y: y), control1: CGPoint(x: size.width * 0.23, y: mid.y), control2: CGPoint(x: size.width * 0.25, y: y))
                tiles.append(DiskMapTile(node: n, path: line.strokedPath(StrokeStyle(lineWidth: max(2, 25 * weight(n) / total))), labelRect: .zero))
                let r = CGRect(x: size.width * 0.43, y: y - 14, width: size.width * 0.56, height: 28)
                tiles.append(DiskMapTile(node: n, path: Path(roundedRect: r, cornerRadius: 6), labelRect: r))
            }
        default: break
        }
        return tiles
    }
}


private struct DiskMapTile {
    var node: DiskNode
    var path: Path
    var labelRect: CGRect
}

/// Hover state lives below layout so pointer movement never rebuilds the graph.
private struct MapHoverDetails: ViewModifier {
    let shapes: [DiskMapTile]
    let allocated: Bool
    @State private var hoveredID: Int?

    func body(content: Content) -> some View {
        let hovered = shapes.last { $0.node.id == hoveredID }
        content
            .onContinuousHover { phase in
                let id: Int?
                switch phase {
                case .active(let point): id = shapes.reversed().first { $0.path.contains(point) }?.node.id
                case .ended: id = nil
                }
                if hoveredID != id { hoveredID = id }
            }
            .overlay {
                if let hovered {
                    hovered.path.stroke(Color.white.opacity(0.9), lineWidth: 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let hovered {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(StorageLabels.name(hovered.node)).font(.headline).lineLimit(2)
                        Text(hovered.node.isDirectory ? "Folder" : "File").font(.caption).foregroundStyle(Tints.secondaryText)
                        Text("\(DiskFormat.bytes(allocated ? hovered.node.allocatedBytes : hovered.node.logicalBytes)) \(allocated ? "on disk" : "logical")")
                            .font(.callout.monospacedDigit()).foregroundStyle(Tints.mint)
                        if hovered.node.isDirectory {
                            Text("Double-click to open").font(.caption).foregroundStyle(Tints.secondaryText)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: 260, alignment: .leading)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tints.mint.opacity(0.6)))
                    .padding(8)
                    .allowsHitTesting(false)
                }
            }
            .onDisappear { hoveredID = nil }
    }
}


/// Hit-test the actual right-click position, never a stale hover or selection.
private struct MapContextMenu: NSViewRepresentable {
    let shapes: [DiskMapTile]
    let model: ExplorerModel
    func makeNSView(context: Context) -> MenuView { MenuView() }
    func updateNSView(_ view: MenuView, context: Context) { view.shapes = shapes; view.model = model }

    final class MenuView: NSView {
        var shapes: [DiskMapTile] = []
        weak var model: ExplorerModel?
        private var candidate: DiskNode?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else { return nil }
            return super.hitTest(point)
        }
        override func mouseDown(with event: NSEvent) { rightMouseDown(with: event) }
        override func rightMouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard let model, let node = shapes.reversed().first(where: { $0.path.contains(point) })?.node else { return }
            candidate = node
            let menu = NSMenu()
            menu.autoenablesItems = false
            func add(_ title: String, _ action: Selector, enabled: Bool = true) {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self; item.isEnabled = enabled; menu.addItem(item)
            }
            add("Inspect", #selector(inspectItem))
            if node.isDirectory { add("Open Folder", #selector(openItem)) }
            add("Reveal in Finder", #selector(revealItem))
            menu.addItem(.separator())
            add(model.staged.contains(node.id) ? "Added to Cleanup" : "Add to Cleanup", #selector(stageItem),
                enabled: !model.busy && !model.monitoring && !model.staged.contains(node.id) && node.parent != nil)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
        @objc private func inspectItem() { if let candidate { model?.selected = candidate.id } }
        @objc private func openItem() { if let candidate { model?.open(candidate) } }
        @objc private func revealItem() { if let candidate { model?.reveal(candidate.id) } }
        @objc private func stageItem() { if let candidate { model?.stage(candidate.id) } }
    }
}
