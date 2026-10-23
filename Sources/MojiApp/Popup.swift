import AppKit
import MojiCore
import SwiftUI

final class PopupModel: ObservableObject {
    @Published var results: [SearchResult] = []
    @Published var selection = 0
    @Published var tone = 0
}

struct PopupView: View {
    @ObservedObject var model: PopupModel
    var onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(model.results.enumerated()), id: \.offset) { i, result in
                row(result, selected: i == model.selection)
                    .contentShape(Rectangle())
                    .onTapGesture { onPick(i) }
            }
        }
        .padding(5)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.primary.opacity(0.08)))
    }

    private func row(_ result: SearchResult, selected: Bool) -> some View {
        HStack(spacing: 9) {
            Text(result.emoji.withTone(model.tone))
                .font(.system(size: 19))
                .frame(width: 26)
            Text(":\(result.emoji.primaryShortcode):")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .layoutPriority(1)
            Text(result.reason ?? result.emoji.name)
                .font(.system(size: 11.5))
                .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if selected {
                Text("↩").font(.system(size: 11, weight: .semibold)).opacity(0.7)
            }
        }
        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 7)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
        )
    }
}

/// A floating panel that never takes focus, so typing keeps going to the app underneath.
final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class PopupController {
    let model = PopupModel()
    var onPick: ((Int) -> Void)?
    private lazy var panel: PopupPanel = {
        let panel = PopupPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = ClickThroughHostingView(rootView: PopupView(model: model) { [weak self] in self?.onPick?($0) })
        return panel
    }()

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    func show(results: [SearchResult], selection: Int, tone: Int, anchor: NSRect) {
        model.results = results
        model.selection = selection
        model.tone = tone
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        panel.setContentSize(size)

        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var origin = NSPoint(x: anchor.minX - 12, y: anchor.minY - size.height - 6)
        if origin.y < visible.minY { origin.y = anchor.maxY + 6 }  // no room below: flip above the line
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    func select(_ index: Int) {
        model.selection = index
    }

    func hide() {
        if panel.isVisible { panel.orderOut(nil) }
    }
}
