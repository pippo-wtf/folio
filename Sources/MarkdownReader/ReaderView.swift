import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ReaderView: View {
    @ObservedObject var model: ReaderModel
    @ObservedObject var updater: FolioUpdater
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var systemScheme

    @State private var isDropTargeted: Bool = false
    @State private var sidebarSelection: String?
    @State private var previewUpdateNotice = false
    @State private var updatePreviewID = UUID()
    @FocusState private var findFieldFocused: Bool

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { model.showOutline ? .all : .detailOnly },
            set: { newValue in
                model.showOutline = (newValue != .detailOnly)
            }
        )
    }

    private var colorScheme: ColorScheme? {
        switch model.appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private var isDark: Bool { colorScheme == .dark || (colorScheme == nil && systemScheme == .dark) }
    private var inkColor: Color {
        let hex = isDark ? model.layout.darkInk : model.layout.lightInk
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0x191919
        return Color(red: Double((value >> 16) & 255)/255, green: Double((value >> 8) & 255)/255, blue: Double(value & 255)/255)
    }

    private var accentColor: Color {
        let hex = isDark ? model.layout.darkAccent : model.layout.accent
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0x2CFF05
        return Color(red: Double((value >> 16) & 255)/255, green: Double((value >> 8) & 255)/255, blue: Double(value & 255)/255)
    }

    private var paperColor: Color {
        let dark = colorScheme == .dark || (colorScheme == nil && systemScheme == .dark)
        let hex = dark ? model.layout.darkPaper : model.layout.lightPaper
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0xFFFFFF
        return Color(red: Double((value >> 16) & 255)/255, green: Double((value >> 8) & 255)/255, blue: Double(value & 255)/255)
    }

    private var nativeToolbarTitle: ToolbarDefaultItemKind? {
        if #available(macOS 15.0, *) { return .title }
        return nil
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            outlineSidebar
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(item: $model.commentDraft) { draft in
            CommentComposer(draft: draft, paper: paperColor, ink: inkColor, accent: accentColor,
                cancel: { model.commentDraft = nil }, save: { model.saveComment($0, draft: draft) })
                .preferredColorScheme(isDark ? .dark : .light)
                .presentationBackground(paperColor)
        }
        .onAppear {
            let action = openWindow
            DispatchQueue.main.async { ReaderWindowPresenter.shared.install { action(id: "reader") } }
        }
        .navigationTitle((model.title.isEmpty ? "Folio" : model.title) + (model.dirty ? " — Edited" : ""))
        .toolbar { toolbarContent }
        .toolbar(removing: nativeToolbarTitle)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background(WindowChrome(dark: colorScheme == .dark || (colorScheme == nil && systemScheme == .dark), paper: (colorScheme == .dark || (colorScheme == nil && systemScheme == .dark)) ? model.layout.darkPaper : model.layout.lightPaper))
        .preferredColorScheme(colorScheme)
        .frame(minWidth: 580, minHeight: 440)
    }

    // MARK: - Sidebar

    private var outlineSidebar: some View {
        List(selection: $sidebarSelection) {
            Section("Contents") {
                if model.headings.isEmpty {
                    Text("No headings in this document")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
                ForEach(model.headings, id: \.id) { heading in
                    Text(heading.title)
                    .font(headingFont(for: heading.level))
                    .foregroundStyle(headingColor(for: heading.level))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.vertical, 5)
                    .padding(.leading, CGFloat(max(0, heading.level - 1)) * 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .accessibilityLabel("\(heading.title), heading level \(heading.level)")
                    .tag("heading:" + heading.id)
                }
            }
            Section {
                if model.marked.isEmpty {
                    Text("Select text and choose Highlight to save a passage here.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 6)
                }
                ForEach(model.marked, id: \.id) { mark in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 9) {
                            Rectangle().fill(Color(red: 44.0/255, green: 1, blue: 5.0/255).opacity(0.5)).frame(width: 3, height: 30)
                            Text(mark.preview).font(.system(size: 13)).lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        }.accessibilityLabel("Marked text: \(mark.preview)")
                        if let comment = mark.comment { Text(comment).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3) }
                        Button(mark.comment == nil ? "Comment…" : "Edit comment…") { model.commentOnHighlight(mark.id) }
                            .font(.system(size: 11)).buttonStyle(.borderless)
                    }.padding(.vertical, 6)
                    .contextMenu {
                        Button(mark.comment == nil ? "Add Comment…" : "Edit Comment…") { model.commentOnHighlight(mark.id) }
                        Button("Remove Highlight", role: .destructive) { model.removeHighlight(mark.id) }
                    }.help(mark.comment ?? mark.quote)
                    .tag("mark:" + mark.id)
                }
            } header: {
                HStack {
                    Text("Marked")
                    Spacer()
                    if !model.marked.isEmpty { Text("\(model.marked.count)").monospacedDigit() }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: sidebarSelection) { _, selection in
            guard let selection else { return }
            if selection.hasPrefix("heading:") { model.navigate(id: String(selection.dropFirst(8))) }
            else if selection.hasPrefix("mark:") { model.navigateHighlight(id: String(selection.dropFirst(5))) }
        }
        .onChange(of: model.documentID) { _, _ in sidebarSelection = nil }
        .scrollIndicators(.hidden)
        .overlay { SidebarScrollIndicator(width: CGFloat(model.layout.scrollbarWidth)).accessibilityHidden(true) }
        .scrollContentBackground(.hidden)
        .navigationTitle("Document")
        .frame(minWidth: 220, idealWidth: 250)
        .background(paperColor.overlay(inkColor.opacity(isDark ? 0.07 : 0)))
        .foregroundStyle(inkColor)
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .system(size: 13, weight: .semibold)
        case 2: return .system(size: 13)
        default: return .system(size: 12)
        }
    }

    private func headingColor(for level: Int) -> Color {
        inkColor.opacity(level <= 2 ? 1 : 0.72)
    }

    // MARK: - Detail

    private var detailContent: some View {
        ZStack(alignment: .top) {
            paperColor
                .ignoresSafeArea()

            ReaderWebView(model: model)
                .opacity(model.writing ? 0 : 1)
                .allowsHitTesting(!model.writing)
                .accessibilityHidden(model.writing)
            MarkdownEditor(model: model).id(model.documentID)
                .opacity(model.writing ? 1 : 0)
                .allowsHitTesting(model.writing)
                .accessibilityHidden(!model.writing)

            VStack(spacing: 0) {
                errorBanner
                Spacer()
            }

            if model.loading {
                VStack {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                            .padding(12)
                        Spacer()
                    }
                    Spacer()
                }
            }

        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.showFind { findBar }
        }
        .overlay(
            Rectangle()
                .strokeBorder(isDropTargeted ? Color(red: 44/255, green: 1, blue: 5/255) : Color.clear, lineWidth: 3)
        )
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            model.openDropped(providers: providers)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.plaintext")
                .font(.system(size: 32, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("A page of your own")
                .font(.title3.weight(.medium))
            Text("Open a Markdown file, or drop one here, to begin reading.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            HStack(spacing: 10) {
                Button("Open…") { model.open() }
                    .buttonStyle(.bordered)
                Button("Show Welcome") { model.showWelcome() }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No document open. Open a Markdown file or drop one here to begin reading.")
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = model.error {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button("Retry") { model.reload() }
                        if model.dirty { Button("Save As…") { model.save(asCopy: true) } }
                        Button("Dismiss") { model.error = nil }
                    }
                    .font(.callout)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(paperColor)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .combine)
        }
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in document", text: $model.search)
                .textFieldStyle(.plain)
                .focused($findFieldFocused)
                .frame(minWidth: 60, maxWidth: .infinity)
                .onSubmit { model.find() }
            if !model.findResult.isEmpty {
                Text(model.findResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider().frame(height: 14)
            Button {
                model.find(backwards: true)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .help("Previous match")
            .accessibilityLabel("Previous match")

            Button {
                model.find()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .help("Next match")
            .accessibilityLabel("Next match")

            Button {
                model.showFind = false
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close find")
            .accessibilityLabel("Close find")
        }
        .font(.system(size: 13))
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(paperColor)
        .overlay(alignment: .bottom) { Divider() }
        .onKeyPress(.escape) {
            model.showFind = false
            return .handled
        }
        .onAppear { findFieldFocused = true }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                model.open()
            } label: {
                Label("Open", systemImage: "doc.badge.plus")
            }
            .help("Open a document")
            HStack(spacing: 12) {
                Text((model.title.isEmpty ? "Folio" : model.title) + (model.dirty ? " — Edited" : ""))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(inkColor)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .leading)
                    .help(model.title)
                if updater.updateAvailable || previewUpdateNotice {
                    Rectangle()
                        .fill(.secondary.opacity(0.25))
                        .frame(width: 1, height: 16)
                        .accessibilityHidden(true)
                    Button {
                        if previewUpdateNotice { updatePreviewID = UUID() }
                        else { updater.showAvailableUpdate() }
                    } label: {
                        UpdateNoticeText().id(updatePreviewID)
                    }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(accentColor)
                        .accessibilityLabel("App Update available. Check it out.")
                        .help("See what’s new in Folio")
                }
            }
        }

        ToolbarItem(placement: .principal) { Spacer() }

        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $model.editingEnabled) {
                Label("Write", systemImage: "pencil")
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .tint(accentColor)
            .help(model.editingEnabled ? "Finish writing · switch to Read" : "Write on the page")
            .accessibilityLabel("Writing mode")
            .accessibilityValue(model.editingEnabled ? "On" : "Off")
            .disabled(model.loading || model.preparingPrint)
            Toggle(isOn: $model.writing) {
                Label("Source", systemImage: "chevron.left.forwardslash.chevron.right")
            }.toggleStyle(.button).help("Show Markdown source").disabled(model.loading || model.preparingPrint)
            Button { model.save() } label: { Label("Save", systemImage: "square.and.arrow.down").labelStyle(.iconOnly) }
                .help("Save document (⌘S)").accessibilityLabel("Save")
                .disabled(model.loading || (!model.dirty && model.fileURL != nil))

            Button {
                model.showFind = true
            } label: {
                Label("Find", systemImage: "magnifyingglass")
            }
            .help("Find in document")

            #if FOLIO_STAGING
            PresetMenu(model: model)

            Button { openWindow(id: "layout") } label: { Label("Layout", systemImage: "slider.horizontal.3") }
                .help("Customize layout")
            #endif

            Menu {
                Button {
                    model.changeZoom(-0.1)
                } label: {
                    Label("Smaller Text", systemImage: "textformat.size.smaller")
                }

                Button {
                    model.changeZoom(0.1)
                } label: {
                    Label("Larger Text", systemImage: "textformat.size.larger")
                }

                Button {
                    model.zoom = 1
                } label: {
                    Label("Reset Zoom", systemImage: "textformat.size")
                }

                Divider()

                Picker("Appearance", selection: $model.appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            } label: {
                Label("Typography", systemImage: "textformat")
            }
            .help("Text size and appearance")

            Menu {
                Button {
                    model.chooseImageFolder()
                } label: {
                    Text(model.imagesAllowed ? "Change Image Folder…" : "Allow Image Folder…")
                }
                if model.imagesAllowed {
                    Label("Images Allowed", systemImage: "checkmark.circle")
                }
                Divider()
                Button("Copy Formatted Text") { model.copyFormatted() }.disabled(model.writing)
                Button(model.preparingPrint ? "Preparing PDF…" : "Export PDF…") { model.exportPDF() }.disabled(model.preparingPrint || model.loading)
                Divider()
                Button("Export Feedback…") { model.exportFeedback() }
                Button("Clear Exported Edit History…") { model.clearExportedEditJournal() }
                #if FOLIO_STAGING
                Divider()
                Button(previewUpdateNotice ? "Replay Update Animation" : "Preview Update Animation") {
                    updatePreviewID = UUID()
                    previewUpdateNotice = true
                }
                if previewUpdateNotice {
                    Button("Hide Update Preview") { previewUpdateNotice = false }
                }
                #endif
                Button("Export Diagnostics…") {
                    model.exportDiagnostics()
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("Image folder access and diagnostics")
        }
    }
}
