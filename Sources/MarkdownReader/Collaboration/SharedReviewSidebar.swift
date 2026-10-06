import AppKit
import ReaderCore
import SwiftUI

struct SharedReviewSidebar: View {
    @ObservedObject var model: ReaderModel
    @ObservedObject private var collaboration: CollaborationCoordinator
    @ObservedObject private var review: SharedReviewController
    let paper, ink, accent: Color
    init(model: ReaderModel, paper: Color, ink: Color, accent: Color) {
        self.model = model; collaboration = model.collaboration; review = model.sharedReview
        self.paper = paper; self.ink = ink; self.accent = accent
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ReviewTabs(label: "Highlight and comment privacy", selection: $review.mode,
                       options: SharedReviewController.Mode.allCases.map { ($0, $0.rawValue) }, ink: ink, accent: accent)
            Text(review.mode == .shared ? "New marks are shared with this folder." : "New marks stay private on this Mac.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if review.mode == .shared {
                HStack {
                    Button("Highlight selection") { model.shareSelectedText() }
                    Button("Comment") { model.shareSelectedText(comment: true) }
                }.font(.system(size: 11)).buttonStyle(.borderless).disabled(review.busy || model.writing)
            }
            Button("Share private marks…") { model.previewPrivateSharing() }
                .font(.system(size: 11)).buttonStyle(.borderless).disabled(model.marked.isEmpty || review.busy)
            ReviewTabs(label: "Shared review view", selection: $review.tab,
                       options: SharedReviewController.Tab.allCases.map { ($0, $0.rawValue) }, ink: ink, accent: accent)
            if let document = collaboration.currentDocument {
                if review.tab == .activity { activity(document) }
                else { work(document) }
                HStack {
                    Button("Mark read") { model.markSharedRead() }.disabled(review.unread == 0)
                    if review.unread > 0 { Text("\(review.unread) unread").monospacedDigit() }
                }.font(.system(size: 11)).buttonStyle(.borderless)
                Button("Export Shared Feedback…") { model.exportSharedFeedback() }.font(.system(size: 11)).buttonStyle(.borderless)
            }
            if review.busy { ProgressView().controlSize(.small).accessibilityLabel("Saving shared review") }
            if let issue = review.issue { Text(issue).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        // Sidebar lists default to one line; shared comments and recovery hints need their full height.
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: review.mode) { _, _ in model.refreshSharedReview() }
        .sheet(isPresented: $review.showPrivatePreview) { privatePreview }
    }
    @ViewBuilder private func work(_ document: SharedDocumentRef) -> some View {
        let annotations = collaboration.state?.annotations.filter { $0.value.documentID == document.documentID }.keys.sorted { $0.uuidString < $1.uuidString } ?? []
        let visible = annotations.filter { collaboration.sharedThreadResolved(threadID: $0) == (review.tab == .done) }
        ForEach(visible, id: \.self) { id in thread(id, document: document) }
        let tasks = collaboration.state?.tasks.filter { $0.value.documentID == document.documentID }.keys.sorted { $0.uuidString < $1.uuidString } ?? []
        ForEach(tasks.filter { (collaboration.sharedTaskStates(taskID: $0) == [.done]) == (review.tab == .done) }, id: \.self) { id in task(id) }
        if visible.isEmpty && tasks.isEmpty { Text(review.tab == .done ? "No completed shared work." : "Select a passage or a Markdown checkbox to start shared work.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    }
    @ViewBuilder private func thread(_ id: UUID, document: SharedDocumentRef) -> some View {
        if let origin = collaboration.state?.annotations[id], case .highlightAdded(_, let originalAnchor) = origin.payload {
            let anchor = collaboration.sharedAnchor(highlightID: id) ?? originalAnchor
            let heads = collaboration.state?.annotationHeads[id] ?? []
            let removed = heads.count == 1 && collaboration.events.contains { event in if event.id == heads[0], case .highlightRemoved = event.payload { return true }; return false }
            if !removed {
                VStack(alignment: .leading, spacing: 6) {
                    Button { review.selectedThread = id; review.replyTo = nil; model.navigateSharedHighlight(id) } label: {
                        Text(anchor.quote.split(whereSeparator: \.isWhitespace).joined(separator: " ")).font(.system(size: 13)).lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    attribution(origin)
                    if heads.count > 1 || (collaboration.state?.threadHeads[id]?.count ?? 0) > 1 { Text("Conflicting review actions · Choose Resolve, Reopen or Reattach").font(.system(size: 11)).foregroundStyle(.secondary) }
                    if heads.count > 1 || (review.anchorStatuses[id.uuidString].map { $0 != "located" } ?? false) {
                        Text("Passage changed").font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("Reattach to selection") { model.shareSelectedText(reattach: id) }.font(.system(size: 11)).buttonStyle(.borderless).disabled(review.busy || model.writing)
                    }
                    HStack {
                        Button("Reply") { review.selectedThread = id; review.replyTo = nil }
                        Button(collaboration.sharedThreadResolved(threadID: id) ? "Reopen discussion" : "Resolve discussion") { model.setSharedThread(id, resolved: !collaboration.sharedThreadResolved(threadID: id)) }
                    }.font(.system(size: 11)).buttonStyle(.borderless).disabled(review.busy)
                    if review.selectedThread == id {
                        ForEach(collaboration.sharedMessages(document: document, threadID: id), id: \.id) { message in
                            if case .commentAdded(_, let messageID, let parent, let text) = message.payload {
                                VStack(alignment: .leading, spacing: 3) {
                                    attribution(message)
                                    if parent != nil { Text("Reply").font(.system(size: 10)).foregroundStyle(.secondary) }
                                    Text(text).font(.system(size: 12)).textSelection(.enabled)
                                    Button("Reply to message") { review.replyTo = messageID }.font(.system(size: 11)).buttonStyle(.borderless)
                                }.padding(.leading, 8)
                            }
                        }
                        if review.replyTo != nil { HStack { Text("Replying to a message").font(.system(size: 11)); Button("Cancel reply") { review.replyTo = nil }.font(.system(size: 11)).buttonStyle(.borderless) } }
                        CommentTextField(text: $review.comment, ink: ink, accent: accent) { model.submitSharedComment() }.frame(minHeight: 65, maxHeight: 100).disabled(review.busy)
                        Button("Send comment") { model.submitSharedComment() }.font(.system(size: 11)).buttonStyle(.borderless).disabled(review.busy || review.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Text("Enter to send · Shift+Enter for a new line").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 5)
            }
        }
    }
    @ViewBuilder private func task(_ id: UUID) -> some View {
        if let origin = collaboration.state?.tasks[id], case .taskRegistered(_, let anchor) = origin.payload {
            VStack(alignment: .leading, spacing: 5) {
                Text(anchor.line).font(.system(size: 13)).lineLimit(2)
                let heads = Set(collaboration.state?.taskHeads[id] ?? [])
                ForEach(collaboration.events.filter { heads.contains($0.id) }, id: \.id) { event in
                    if case .taskState(_, let state, _, _) = event.payload { Text(taskLabel(state)).font(.system(size: 11)); attribution(event) }
                }
                Text(collaboration.sharedTaskSourceStatus(taskID: id, source: collaboration.currentDocument.flatMap { collaboration.observedSharedSource(document: $0) } ?? model.snapshot?.text ?? model.text)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Apply status to Markdown") { model.applyPendingSharedTask(id) }.font(.system(size: 11)).buttonStyle(.borderless).disabled(review.busy || heads.count != 1)
                Menu("Set task state") {
                    Button("Open") { model.setSharedTask(id, state: .open) }
                    Button("In progress") { model.setSharedTask(id, state: .inProgress) }
                    Button("Done") { model.setSharedTask(id, state: .done) }
                }.font(.system(size: 11)).menuStyle(.borderlessButton).disabled(review.busy)
            }.padding(.vertical, 5)
        }
    }
    @ViewBuilder private func activity(_ document: SharedDocumentRef) -> some View {
        let events = collaboration.sharedActivity(document: document)
        if events.isEmpty { Text("No shared activity yet.").font(.system(size: 12)).foregroundStyle(.secondary) }
        ForEach(events, id: \.id) { event in
            VStack(alignment: .leading, spacing: 4) {
                Text(action(event)).font(.system(size: 12)).lineLimit(2)
                attribution(event)
                if let id = threadID(event), let anchor = collaboration.sharedAnchor(highlightID: id) {
                    Button(anchor.quote) { review.selectedThread = id; model.navigateSharedHighlight(id) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                if collaboration.state?.pendingEventIDs.contains(event.id) == true { Text("Pending dependencies").font(.system(size: 11)).foregroundStyle(.secondary) }
                if collaboration.state?.invalidIDs.contains(event.id) == true { Text("Rejected event · Export evidence").font(.system(size: 11)).foregroundStyle(.secondary) }
            }.padding(.vertical, 4)
        }
    }
    private func attribution(_ event: CollaborationEvent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(event.authorName) · \(String(event.participantID.uuidString.prefix(8)))").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(event.displayTime.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary)
        }.accessibilityLabel("\(event.authorName), claimed identity \(event.participantID.uuidString), \(event.displayTime.formatted())")
    }
    private func taskLabel(_ state: SharedTaskState) -> String { state == .inProgress ? "In progress" : state.rawValue.capitalized }
    private func threadID(_ event: CollaborationEvent) -> UUID? {
        switch event.payload {
        case .highlightAdded(let id, _), .highlightReattached(let id, _, _), .highlightRemoved(let id, _), .commentAdded(let id, _, _, _), .threadState(let id, _, _): return id
        default: return nil
        }
    }
    private func action(_ event: CollaborationEvent) -> String {
        switch event.payload {
        case .highlightAdded: return "Shared a passage"
        case .highlightRemoved: return "Removed a shared mark"
        case .highlightReattached: return "Reattached a passage"
        case .commentAdded(_, _, let reply, let text): return (reply == nil ? "Commented: " : "Replied: ") + text
        case .threadState(_, let resolved, _): return resolved ? "Resolved discussion" : "Reopened discussion"
        case .taskRegistered: return "Registered a Markdown task"
        case .taskState(_, let state, _, _): return "Set task to " + taskLabel(state)
        case .sourceProposal: return "Proposed a saved source version"
        case .sourceResolution: return "Recorded a source resolution"
        }
    }
    private var privatePreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Share private marks for this document").font(.headline)
            Text("Only selected passages and their current comments will be copied into new shared discussions. Your originals stay private. Private edit history is excluded.").font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.marked, id: \.id) { mark in
                        let current = mark.revision == HighlightStore.revision(model.text)
                        Toggle(isOn: Binding(get: { review.previewSelected.contains(mark.id) }, set: { selected in if selected { review.previewSelected.insert(mark.id) } else { review.previewSelected.remove(mark.id) } })) {
                            VStack(alignment: .leading) {
                                Text(mark.quote).lineLimit(2)
                                if let comment = mark.comment { Text(comment).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                                if !current { Text("Passage changed · Reattach before sharing").font(.caption).foregroundStyle(.secondary) }
                            }
                        }.disabled(!current || review.busy)
                    }
                }
            }.frame(maxHeight: 300)
            if let issue = review.issue { Text(issue).font(.caption).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("Cancel") { review.showPrivatePreview = false }.disabled(review.busy); Button("Share selected") { model.sharePreviewedPrivateMarks() }.disabled(review.previewSelected.isEmpty || review.busy) }
        }.padding(24).frame(width: 470).buttonStyle(.plain).background(paper).foregroundStyle(ink).tint(accent)
    }
}
