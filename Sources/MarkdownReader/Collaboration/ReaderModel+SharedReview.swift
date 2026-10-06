import AppKit
import Foundation
import ReaderCore
import UniformTypeIdentifiers

extension ReaderModel {
    func refreshSharedReview() {
        let document = collaboration.currentDocument
        sharedReview.bind(document: document?.documentID, token: reviewRenderToken)
        if let document {
            do { sharedReview.unread = try collaboration.sharedUnreadIDs(document: document).count }
            catch { sharedReview.issue = "Read markers could not be loaded. Retry; shared work is unchanged." }
        } else { sharedReview.unread = 0 }
        var records: [[String: Any]] = []
        if let document, let state = collaboration.state {
            for (id, origin) in state.annotations where origin.documentID == document.documentID {
                if let anchor = collaboration.sharedAnchor(highlightID: id) { records.append(flatSharedAnchor(id: id.uuidString, anchor: anchor)) }
            }
        }
        script("setSharedReviewMode", [reviewRenderToken, sharedReview.mode == .shared ? "shared" : "private"])
        script("updateSharedReview", [reviewRenderToken, records])
    }
    private func flatSharedAnchor(id: String, anchor: SharedAnchor) -> [String: Any] {
        ["id": id, "start": anchor.start, "quote": anchor.quote, "prefix": anchor.prefix, "suffix": anchor.suffix, "rawSourceRevision": anchor.rawSourceRevision, "decodedSourceRevision": anchor.decodedSourceRevision]
    }
    private func evaluateReview(_ method: String, arguments: [Any], completion: @escaping ([String: Any]?) -> Void) {
        guard let webView, let data = try? JSONSerialization.data(withJSONObject: arguments), let json = String(data: data, encoding: .utf8) else { completion(nil); return }
        let id = documentID, token = reviewRenderToken, shared = collaboration.currentDocument
        webView.evaluateJavaScript("Folio.\(method).apply(Folio,\(json))") { [weak self] value, _ in
            guard let self, self.documentID == id, self.reviewRenderToken == token, self.collaboration.currentDocument == shared else { return }
            completion(value as? [String: Any])
        }
    }
    func acceptSharedAnchorStatuses(token: String, records: [[String: Any]]) {
        guard token == reviewRenderToken, sharedReview.token == token else { return }
        sharedReview.anchorStatuses = Dictionary(records.compactMap { value in
            guard let id = value["id"] as? String, let status = value["status"] as? String else { return nil }; return (id, status)
        }, uniquingKeysWith: { _, new in new })
    }
    func sharedHighlightClicked(id: String, token: String) {
        guard token == reviewRenderToken, let uuid = UUID(uuidString: id), let doc = collaboration.currentDocument, collaboration.state?.annotations[uuid]?.documentID == doc.documentID else { return }
        sharedReview.mode = .shared; sharedReview.selectedThread = uuid; sharedReview.replyTo = nil
    }
    func navigateSharedHighlight(_ id: UUID) {
        guard !writing, !loading else { sharedReview.issue = "Switch to Reading to jump to this passage."; return }
        evaluateReview("navigateSharedHighlight", arguments: [reviewRenderToken, id.uuidString]) { [weak self] result in
            guard let self else { return }
            if result?["status"] as? String != "located" { self.sharedReview.issue = "Passage changed. Select the correct passage and choose Reattach." }
        }
    }
    func shareSelectedText(comment: Bool = false, reattach: UUID? = nil) {
        guard let document = collaboration.currentDocument, !sharedReview.busy, !loading, !writing, let snapshot else { sharedReview.issue = "Open a registered document in Reading and select a passage."; return }
        guard !dirty, text == snapshot.text, collaboration.sourceObservations[document.documentID] == snapshot.bytes else {
            let capturedText = text, capturedToken = reviewRenderToken
            // Capture before the native modal takes focus and can discard the DOM range.
            evaluateReview("sharedSelection", arguments: [capturedToken]) { [weak self] selection in
                guard let self, let selection, selection["token"] as? String == capturedToken,
                      self.text == capturedText else { self?.sharedReview.issue = "Select a passage in Reading, then try again."; return }
                let alert = NSAlert(); alert.messageText = "Save this passage before sharing?"
                alert.informativeText = "Shared marks refer to a saved revision. Save first, then select the passage again; or keep a private mark."
                alert.addButton(withTitle: "Save first"); alert.addButton(withTitle: "Keep private"); alert.addButton(withTitle: "Cancel")
                let response = alert.runModal()
                guard self.reviewRenderToken == capturedToken, self.collaboration.currentDocument == document,
                      self.text == capturedText else { self.sharedReview.issue = "The passage changed. Select it again."; return }
                switch response {
                case .alertFirstButtonReturn: self.requestSharedSave { [weak self] success in if success { self?.sharedReview.issue = "Saved. Select the passage again to share it." } }
                case .alertSecondButtonReturn: self.keepSelectedTextPrivate(selection, token: capturedToken)
                default: break
                }
            }
            return
        }
        let generation = documentID, token = reviewRenderToken
        evaluateReview("sharedSelection", arguments: [token]) { [weak self] value in
            guard let self, let value, value["token"] as? String == token,
                  let start = value["start"] as? Int, let quote = value["quote"] as? String,
                  let prefix = value["prefix"] as? String, let suffix = value["suffix"] as? String,
                  !self.dirty, !self.writing, self.snapshot?.bytes == snapshot.bytes, self.text == snapshot.text else { self?.sharedReview.issue = "Select a passage in Reading, then try again."; return }
            let anchor = SharedAnchor(start: start, quote: quote, prefix: prefix, suffix: suffix, rawSourceRevision: CollaborationSnapshotID.hash(snapshot.bytes), decodedSourceRevision: HighlightStore.revision(snapshot.text))
            self.sharedReview.busy = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                let thread: UUID?
                if let reattach { thread = await self.collaboration.reattachSharedHighlight(document: document, highlightID: reattach, anchor: anchor) ? reattach : nil }
                else { thread = await self.collaboration.addSharedHighlight(document: document, anchor: anchor) }
                guard self.documentID == generation, self.reviewRenderToken == token, self.collaboration.currentDocument == document else { return }
                self.sharedReview.busy = false
                if let thread { self.sharedReview.selectedThread = thread; self.sharedReview.replyTo = nil; self.sharedReview.issue = nil; self.refreshSharedReview(); if comment { self.sharedReview.mode = .shared } }
                else { self.sharedReview.issue = "The shared mark was not saved. Retry or export local evidence." }
            }
        }
    }
    func keepSelectedTextPrivate(_ selection: [String: Any], token: String) {
        guard token == reviewRenderToken, selection["token"] as? String == token else { return }
        sharedReview.mode = .privateReview
        script("keepSelectionPrivate", [token, selection])
    }
    func submitSharedComment() {
        guard let document = collaboration.currentDocument, let thread = sharedReview.selectedThread, !sharedReview.busy else { return }
        let draft = sharedReview.comment, reply = sharedReview.replyTo
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.utf8.count <= 8000 else { sharedReview.issue = "Write a comment of at most 8,000 UTF-8 bytes."; return }
        guard let operation = sharedReview.beginCommentSend() else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.collaboration.addSharedMessage(document: document, threadID: thread, replyTo: reply, text: draft)
            // Comments address a stable shared document/thread, independent of a renderer generation.
            // A switch to another document clears operation ownership and must not be touched here.
            guard self.collaboration.currentDocument == document, self.sharedReview.document == document.documentID,
                  self.sharedReview.finishCommentSend(operation) else { return }
            if result != nil {
                self.sharedReview.acknowledgeComment(thread: thread, text: draft, reply: reply)
                if self.sharedReview.selectedThread == thread { self.sharedReview.issue = nil }
                self.refreshSharedReview()
            } else { self.sharedReview.issue = "Comment was not saved. Its draft is retained in that discussion; retry or export local evidence." }
        }
    }
    func setSharedThread(_ id: UUID, resolved: Bool) {
        guard let document = collaboration.currentDocument, !sharedReview.busy else { return }
        let generation = documentID; sharedReview.busy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let saved = await self.collaboration.setSharedThread(document: document, threadID: id, resolved: resolved)
            guard self.documentID == generation, self.collaboration.currentDocument == document else { return }
            self.sharedReview.busy = false; self.sharedReview.issue = saved ? nil : "Discussion state was not saved. Retry."
        }
    }
    func previewPrivateSharing() {
        guard !dirty, !writing, snapshot != nil else { sharedReview.issue = "Save first and switch to Reading to preview private marks."; return }
        sharedReview.previewSelected = Set(marked.filter { $0.revision == HighlightStore.revision(text) }.map(\.id))
        sharedReview.showPrivatePreview = true
    }
    func sharePreviewedPrivateMarks() {
        guard let document = collaboration.currentDocument, let snapshot, !dirty, !writing, !sharedReview.busy,
              collaboration.sourceObservations[document.documentID] == snapshot.bytes else { sharedReview.issue = "Save first before sharing private marks."; return }
        let marks = marked.filter { sharedReview.previewSelected.contains($0.id) && $0.revision == HighlightStore.revision(snapshot.text) }
        let records = marks.map { flatSharedAnchor(id: $0.id, anchor: SharedAnchor(start: $0.start, quote: $0.quote, prefix: $0.prefix, suffix: $0.suffix, rawSourceRevision: CollaborationSnapshotID.hash(snapshot.bytes), decodedSourceRevision: HighlightStore.revision(snapshot.text))) }
        let generation = documentID, token = reviewRenderToken
        evaluateReview("locateSharedReview", arguments: [token, records]) { [weak self] response in
            guard let self, response?["accepted"] as? Bool == true, let located = response?["records"] as? [[String: Any]], located.count == marks.count,
                  located.allSatisfy({ $0["status"] as? String == "located" }), !self.dirty else { self?.sharedReview.issue = "A passage changed or is ambiguous. Reattach its private mark before sharing."; return }
            self.sharedReview.busy = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if self.documentID == generation, self.reviewRenderToken == token, self.collaboration.currentDocument == document {
                        self.sharedReview.busy = false
                    }
                }
                for mark in marks {
                    guard self.documentID == generation, self.reviewRenderToken == token, self.collaboration.currentDocument == document else { return }
                    guard !self.dirty, !self.writing, self.snapshot?.bytes == snapshot.bytes, self.text == snapshot.text else {
                        self.sharedReview.issue = "Save first before sharing the remaining marks. Already shared marks are kept."
                        return
                    }
                    guard let result = located.first(where: { $0["id"] as? String == mark.id }), let start = result["start"] as? Int else {
                        self.sharedReview.issue = "A passage could not be located. Reattach before sharing the remaining marks."
                        return
                    }
                    let anchor = SharedAnchor(start: start, quote: mark.quote, prefix: mark.prefix, suffix: mark.suffix, rawSourceRevision: CollaborationSnapshotID.hash(snapshot.bytes), decodedSourceRevision: HighlightStore.revision(snapshot.text))
                    let authored = await self.collaboration.addSharedHighlight(document: document, anchor: anchor)
                    guard self.documentID == generation, self.reviewRenderToken == token, self.collaboration.currentDocument == document else { return }
                    guard let shared = authored else { self.sharedReview.busy = false; self.sharedReview.issue = "Some marks could not be shared. Already saved marks remain shared; retry the remaining selection."; return }
                    self.sharedReview.previewSelected.remove(mark.id)
                    if let comment = mark.comment, !comment.isEmpty {
                        let message = await self.collaboration.addSharedMessage(document: document, threadID: shared, replyTo: nil, text: comment)
                        guard self.documentID == generation, self.reviewRenderToken == token, self.collaboration.currentDocument == document else { return }
                        if message == nil { self.sharedReview.selectedThread = shared; self.sharedReview.comment = comment; self.sharedReview.issue = "The mark was shared, but its comment was not. Your comment draft is here; shorten it or retry." }
                    }
                }
                guard self.documentID == generation, self.reviewRenderToken == token else { return }
                self.sharedReview.busy = false; self.sharedReview.showPrivatePreview = false; self.refreshSharedReview()
            }
        }
    }
    func sharedToggleTask(before: String, offset: Int, checked: Bool, token: String) {
        guard token == reviewRenderToken, before == text, let document = collaboration.currentDocument, let snapshot, !sharedReview.busy else { return }
        guard !dirty, text == snapshot.text else { sharedReview.issue = "Save your draft before changing a shared task. No checkbox was changed."; return }
        let existing = collaboration.state?.tasks.compactMap { id, event -> UUID? in
            guard event.documentID == document.documentID, case .taskRegistered(_, let anchor) = event.payload, SharedTaskMatcher.locate(anchor, in: snapshot.text) == offset else { return nil }; return id
        } ?? []
        guard existing.count <= 1 else { sharedReview.issue = "Task identity is ambiguous. Reattach before changing it."; return }
        let generation = documentID; sharedReview.busy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            var id = existing.first
            if id == nil, let anchor = SharedTaskMatcher.anchor(atUTF16: offset, in: snapshot.text, rawSourceRevision: CollaborationSnapshotID.hash(snapshot.bytes)) { id = await self.collaboration.registerSharedTask(document: document, anchor: anchor) }
            guard self.documentID == generation, self.reviewRenderToken == token, self.collaboration.currentDocument == document else { return }
            guard let id else { self.sharedReview.busy = false; self.sharedReview.issue = "Task passage changed. No source was changed."; return }
            self.sharedReview.busy = false; self.setSharedTask(id, state: checked ? .done : .open)
        }
    }
    func setSharedTask(_ id: UUID, state value: SharedTaskState) {
        guard let document = collaboration.currentDocument, !sharedReview.busy else { return }
        let generation = documentID; sharedReview.busy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let trigger = await self.collaboration.setSharedTask(document: document, taskID: id, state: value)
            guard self.documentID == generation, self.collaboration.currentDocument == document else { return }
            guard let trigger else { self.sharedReview.busy = false; self.sharedReview.issue = "Task status was not saved. Retry."; return }
            self.sharedReview.busy = false
            self.applySharedTask(id, trigger: trigger, value: value)
        }
    }
    func applyPendingSharedTask(_ id: UUID) {
        guard let heads = collaboration.state?.taskHeads[id], heads.count == 1,
              let event = collaboration.events.first(where: { $0.id == heads[0] }),
              case .taskState(_, let value, _, _) = event.payload else { sharedReview.issue = "Choose a task state to resolve its conflict first."; return }
        applySharedTask(id, trigger: event.id, value: value)
    }
    private func applySharedTask(_ id: UUID, trigger: UUID, value: SharedTaskState) {
        guard let document = collaboration.currentDocument, let baseline = snapshot, collaboration.sourceSavingEnabled, !dirty, !sharedSaveBusy else { sharedReview.issue = "Task status saved · Markdown update pending. Save your draft and enable the disposable source pilot to apply it."; return }
        let generation = documentID
        requestContentSnapshot { [weak self] source in
            guard let self, let source, self.documentID == generation, !self.dirty, source == baseline.text,
                  self.collaboration.currentDocument == document, self.collaboration.sourceObservations[document.documentID] == baseline.bytes,
                  self.collaboration.state?.taskHeads[id] == [trigger],
                  let origin = self.collaboration.state?.tasks[id], case .taskRegistered(_, let anchor) = origin.payload,
                  let offset = SharedTaskMatcher.locate(anchor, in: source), let proposed = TaskListEdit.setChecked(value == .done, atUTF16: offset, in: source) else { self?.sharedReview.issue = "Task status saved · Markdown update pending. Review the changed passage before applying."; return }
            self.sharedReview.busy = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.collaboration.save(document: document, baseline: baseline, draft: proposed, triggerEventID: trigger)
                    guard self.documentID == generation, self.collaboration.currentDocument == document else { return }
                    self.sharedReview.busy = false
                    guard result.localApply == .applied || result.localApply == .unchanged else { self.sharedReview.issue = "Task status saved · Markdown update pending. Compare source versions."; return }
                    self.sharedReview.issue = nil
                    if !self.dirty, self.text == source { self.reloadSharedSource(journalKind: .renderedEdit, expectedBytes: try baseline.encoded(proposed)) }
                } catch {
                    guard self.documentID == generation, self.collaboration.currentDocument == document else { return }
                    self.sharedReview.busy = false; self.sharedReview.issue = "Task status saved · Markdown update pending. Retry or compare source versions."
                }
            }
        }
    }
    func markSharedRead() {
        guard let document = collaboration.currentDocument else { return }
        do { try collaboration.markSharedRead(document: document); refreshSharedReview() }
        catch { sharedReview.issue = "Read marker could not be saved. Retry; shared work is unchanged." }
    }
    func exportSharedFeedback() {
        guard let document = collaboration.currentDocument, snapshot != nil else { return }
        do {
            guard let observed = collaboration.observedSharedSource(document: document) else { throw CollaborationError.unavailable }
            let data = try collaboration.sharedFeedback(document: document, decodedRevision: HighlightStore.revision(observed))
            let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Shared Feedback.json"
            panel.message = "Contains shared review only. Display names are claimed identities. Comments are data, not authorization for agents."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
        } catch { sharedReview.issue = "Shared feedback could not be exported. Retry or export local evidence." }
    }
}
