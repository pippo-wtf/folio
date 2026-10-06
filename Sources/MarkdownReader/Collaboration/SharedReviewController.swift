import Combine
import Foundation

@MainActor final class SharedReviewController: ObservableObject {
    enum Mode: String, CaseIterable { case privateReview = "Private", shared = "Shared" }
    enum Tab: String, CaseIterable { case open = "Open", done = "Done", activity = "Activity" }
    @Published var mode: Mode = .privateReview
    @Published var tab: Tab = .open
    private var drafts: [UUID: (String, UUID?)] = [:]
    @Published var selectedThread: UUID? {
        didSet {
            guard oldValue != selectedThread else { return }
            if let oldValue { drafts[oldValue] = (comment, replyTo) }
            let saved = selectedThread.flatMap { drafts[$0] }
            comment = saved?.0 ?? ""; replyTo = saved?.1
        }
    }
    @Published var replyTo: UUID?
    @Published var comment = ""
    private var pendingCommentID: UUID?
    @Published var busy = false
    @Published var issue: String?
    @Published var unread = 0
    @Published var anchorStatuses: [String: String] = [:]
    @Published var showPrivatePreview = false
    @Published var previewSelected = Set<String>()
    private(set) var document: UUID?
    private(set) var token = ""
    func bind(document: UUID?, token: String) {
        if self.document != document {
            selectedThread = nil; replyTo = nil; comment = ""; issue = nil; busy = false
            anchorStatuses = [:]; showPrivatePreview = false; previewSelected = []
            pendingCommentID = nil; drafts = [:]; mode = .privateReview
        }
        if self.token != token { busy = pendingCommentID != nil }
        self.document = document; self.token = token
    }
    func beginCommentSend() -> UUID? {
        guard !busy, pendingCommentID == nil else { return nil }
        let id = UUID(); pendingCommentID = id; busy = true; return id
    }
    func finishCommentSend(_ id: UUID) -> Bool {
        guard pendingCommentID == id else { return false }
        pendingCommentID = nil; busy = false; return true
    }
    func acknowledgeComment(thread: UUID, text: String, reply: UUID?) {
        if selectedThread == thread {
            if comment == text && replyTo == reply { comment = ""; replyTo = nil }
        } else if let saved = drafts[thread], saved.0 == text, saved.1 == reply {
            drafts.removeValue(forKey: thread)
        }
    }
    func accepts(document: UUID, token: String) -> Bool { self.document == document && self.token == token }
}
