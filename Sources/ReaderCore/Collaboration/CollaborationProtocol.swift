import CryptoKit
import Foundation

public enum CollaborationError: Error, Equatable {
  case invalid(String)
  case identityConflict, capacityExceeded, unavailable, injectedInterruption
}
public struct CollaborationLimits: Codable, Equatable {
  public var eventBytes = 64 * 1024, snapshotBytes = 8 * 1024 * 1024, manifestBytes = 16 * 1024,
    events = 2000, snapshots = 256, totalBytes = 128 * 1024 * 1024, candidates = 5000,
    references = 32, commentBytes = 8000, diagnostics = 100, documents = 8
  public static let pilot = CollaborationLimits()
  public init() {}
}
public struct ParticipantProfile: Codable, Equatable {
  public let participantID, deviceID: UUID
  public let displayName: String
  public init(participantID: UUID, deviceID: UUID, displayName: String) {
    self.participantID = participantID; self.deviceID = deviceID; self.displayName = displayName
  }
}
public struct SharedDocumentRef: Codable, Equatable {
  public let workspaceID, documentID: UUID
  public let relativePath: String
  public init(workspaceID: UUID, documentID: UUID, relativePath: String) {
    self.workspaceID = workspaceID; self.documentID = documentID; self.relativePath = relativePath
  }
}
public struct SharedAnchor: Codable, Equatable {
  public let start: Int
  public let quote, prefix, suffix, rawSourceRevision, decodedSourceRevision: String
  public init(start: Int, quote: String, prefix: String, suffix: String, rawSourceRevision: String, decodedSourceRevision: String) {
    self.start = start; self.quote = quote; self.prefix = prefix; self.suffix = suffix
    self.rawSourceRevision = rawSourceRevision; self.decodedSourceRevision = decodedSourceRevision
  }
  func validate() throws {
    guard start >= 0, !quote.isEmpty, quote.utf16.count <= 20000, prefix.utf16.count <= 64, suffix.utf16.count <= 64,
      CollaborationIO.validHash(rawSourceRevision), CollaborationIO.validHash(decodedSourceRevision) else { throw CollaborationError.invalid("anchor bounds") }
  }
}
public struct SharedTaskAnchor: Codable, Equatable {
  public let sourceOffsetUTF16: Int
  public let line, prefix, suffix, rawSourceRevision, decodedSourceRevision: String
  public init(sourceOffsetUTF16: Int, line: String, prefix: String, suffix: String, rawSourceRevision: String, decodedSourceRevision: String) {
    self.sourceOffsetUTF16 = sourceOffsetUTF16; self.line = line; self.prefix = prefix; self.suffix = suffix
    self.rawSourceRevision = rawSourceRevision; self.decodedSourceRevision = decodedSourceRevision
  }
  func validate() throws {
    guard sourceOffsetUTF16 >= 0, !line.isEmpty, line.utf16.count <= 20000, !line.contains("\n"), !line.contains("\r"), prefix.utf16.count <= 64, suffix.utf16.count <= 64,
      CollaborationIO.validHash(rawSourceRevision), CollaborationIO.validHash(decodedSourceRevision) else { throw CollaborationError.invalid("task anchor bounds") }
  }
}
public enum SharedTaskState: String, Codable { case open, inProgress, done }
public enum CollaborationPayload: Codable, Equatable {
  case highlightAdded(highlightID: UUID, anchor: SharedAnchor)
  case highlightRemoved(highlightID: UUID, supersedes: [UUID])
  case highlightReattached(highlightID: UUID, anchor: SharedAnchor, supersedes: [UUID])
  case commentAdded(threadID: UUID, messageID: UUID, replyTo: UUID?, text: String)
  case threadState(threadID: UUID, resolved: Bool, supersedes: [UUID])
  case taskRegistered(taskID: UUID, anchor: SharedTaskAnchor)
  case taskState(taskID: UUID, state: SharedTaskState, supersedes: [UUID], rawSourceRevision: String)
  case sourceProposal(baseRevision: String, proposedRevision: String, triggerEventID: UUID?)
  case sourceResolution(baseRevision: String, proposedRevision: String, supersedes: [UUID])
}
public struct CollaborationEvent: Codable, Equatable {
  public var schemaVersion = 2
  public var id, workspaceID, documentID, participantID, deviceID: UUID
  public var authorName, rawSourceRevision: String
  public var parents: [UUID]
  public var displayTime: Date
  public var payload: CollaborationPayload
  public init(id: UUID = UUID(), workspaceID: UUID, documentID: UUID, participantID: UUID, deviceID: UUID,
    authorName: String, rawSourceRevision: String, parents: [UUID] = [], displayTime: Date = Date(), payload: CollaborationPayload) {
    self.id=id; self.workspaceID=workspaceID; self.documentID=documentID; self.participantID=participantID; self.deviceID=deviceID
    self.authorName=authorName; self.rawSourceRevision=rawSourceRevision; self.parents=parents; self.displayTime=displayTime; self.payload=payload
  }
  public var supersedes: [UUID] {
    switch payload {
    case .highlightRemoved(_, let ids), .highlightReattached(_, _, let ids), .threadState(_, _, let ids), .taskState(_, _, let ids, _), .sourceResolution(_, _, let ids): return ids
    default: return []
    }
  }
  public var revisions: [String] {
    switch payload {
    case .sourceProposal(let a,let b,_), .sourceResolution(let a,let b,_): return [a,b]
    default: return [rawSourceRevision]
    }
  }
  public var isSource: Bool { switch payload { case .sourceProposal,.sourceResolution: return true; default:return false } }
  public var entityKey: String {
    switch payload {
    case .highlightAdded(let id,_), .highlightRemoved(let id,_), .highlightReattached(let id,_,_): return "highlight/"+id.uuidString
    case .commentAdded(_,let id,_,_): return "message/"+id.uuidString
    case .threadState(let id,_,_):return "thread/"+id.uuidString
    case .taskRegistered(let id,_), .taskState(let id,_,_,_):return "task/"+id.uuidString
    case .sourceProposal,.sourceResolution:return "source"
    }
  }
  public func validate(limits: CollaborationLimits = .pilot) throws {
    guard schemaVersion == 2, CollaborationIO.validName(authorName), displayTime.timeIntervalSinceReferenceDate.isFinite,
      parents.count <= limits.references, supersedes.count <= limits.references, Set(parents).count == parents.count,
      Set(supersedes).count == supersedes.count, !parents.contains(id), !supersedes.contains(id),
      revisions.allSatisfy(CollaborationIO.validHash), CollaborationIO.validHash(rawSourceRevision) else { throw CollaborationError.invalid("schema/actor/references/hash") }
    switch payload {
    case .highlightAdded(_,let a), .highlightReattached(_,let a,_):try a.validate(); guard a.rawSourceRevision == rawSourceRevision else { throw CollaborationError.invalid("anchor revision") }
    case .taskRegistered(_,let a):try a.validate(); guard a.rawSourceRevision == rawSourceRevision else { throw CollaborationError.invalid("task revision") }
    case .taskState(_,_,_,let hash):guard hash == rawSourceRevision else { throw CollaborationError.invalid("task revision") }
    case .commentAdded(_,_,_,let text):guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, text.utf8.count <= limits.commentBytes else { throw CollaborationError.invalid("comment bounds") }
    case .sourceProposal(let base,_,_), .sourceResolution(let base,_,_):guard base == rawSourceRevision else { throw CollaborationError.invalid("source base") }
    default:break
    }
  }
}
public enum CollaborationSnapshotID {
  public static func hash(_ bytes: Data) -> String { SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined() }
}
public struct CollaborationWorkspaceManifest: Codable, Equatable {
  public var schemaVersion = 2
  public let workspaceID: UUID
  public init(workspaceID:UUID) { self.workspaceID=workspaceID }
}
public struct CollaborationDocumentManifest: Codable, Equatable {
  public var schemaVersion = 2
  public let workspaceID, documentID: UUID
  public let relativePath, initialRevision: String
  public init(workspaceID:UUID, documentID:UUID, relativePath:String, initialRevision:String) {
    self.workspaceID=workspaceID; self.documentID=documentID; self.relativePath=relativePath; self.initialRevision=initialRevision
  }
}
public enum CollaborationIO {
  public static func validHash(_ hash: String) -> Bool {
    hash.utf8.count == 64
      && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return try e.encode(value)
  }
  public static func read(_ path: URL, limit: Int) throws -> Data {
    guard limit >= 0 else { throw CollaborationError.invalid("limit") }
    let handle = try FileHandle(forReadingFrom: path)
    defer { try? handle.close() }
    var bytes = Data()
    while bytes.count <= limit {
      let part = try handle.read(upToCount: limit + 1 - bytes.count) ?? Data()
      if part.isEmpty { break }
      bytes.append(part)
    }
    guard bytes.count <= limit else { throw CollaborationError.invalid("file limit") }
    return bytes
  }
  public static func durable(_ bytes: Data, at path: URL) throws {
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temp = path.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp")
    defer { try? FileManager.default.removeItem(at: temp) }
    guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
      throw CollaborationError.unavailable
    }
    let handle = try FileHandle(forWritingTo: temp)
    try handle.write(contentsOf: bytes)
    try handle.synchronize()
    try handle.close()
    if rename(temp.path, path.path) != 0 { throw CollaborationError.unavailable }
  }
  public static func immutable(_ bytes: Data, at path: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: path.path) {
      do {
        guard try read(path, limit: bytes.count) == bytes else { throw CollaborationError.identityConflict }
      } catch CollaborationError.invalid { throw CollaborationError.identityConflict }
      return
    }
    try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temp = path.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp")
    defer { try? fm.removeItem(at: temp) }
    try durable(bytes, at: temp)
    do { try fm.linkItem(at: temp, to: path) } catch {
      guard fm.fileExists(atPath: path.path), try read(path, limit: bytes.count) == bytes else {
        throw CollaborationError.identityConflict
      }
    }
  }
  public static func snapshot(_ bytes: Data, hash: String, limits: CollaborationLimits = .pilot) throws {
    guard bytes.count <= limits.snapshotBytes, validHash(hash), CollaborationSnapshotID.hash(bytes) == hash
    else { throw CollaborationError.invalid("snapshot checksum/limit") }
  }
  public static func safe(_ path: URL, root: URL) throws {
    let base = root.standardizedFileURL.path
    let target = path.standardizedFileURL.path
    guard target == base || target.hasPrefix(base + "/") else {
      throw CollaborationError.invalid("path escapes root")
    }
    var cursor = path.standardizedFileURL
    while cursor.path.count >= base.count {
      if (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
        throw CollaborationError.invalid("symlink")
      }
      if cursor.path == base { break }
      cursor.deleteLastPathComponent()
    }
  }
  public static func decodeEvent(_ bytes: Data, limits: CollaborationLimits = .pilot) throws -> CollaborationEvent {
    guard bytes.count <= limits.eventBytes else { throw CollaborationError.invalid("event limit") }
    let value = try JSONSerialization.jsonObject(with: bytes)
    guard let object = value as? [String: Any], Set(object.keys) == Set(["schemaVersion", "id", "workspaceID", "documentID", "participantID", "deviceID", "authorName", "rawSourceRevision", "parents", "displayTime", "payload"]),
      let payload = object["payload"] as? [String: Any], payload.count == 1,
      let action = payload.keys.first, let fields = payload[action] as? [String: Any],
      let allowed = payloadFields[action], Set(fields.keys).isSubset(of: allowed)
    else { throw CollaborationError.invalid("unknown event/action fields") }
    let ids: Set<String> = ["id", "workspaceID", "documentID", "participantID", "deviceID", "highlightID", "threadID", "messageID", "replyTo", "taskID", "triggerEventID", "parents", "supersedes"]
    func validate(_ value: Any, key: String = "") throws {
      if let obj = value as? [String:Any] { for (name,item) in obj { try validate(item,key:name) } }
      else if let array = value as? [Any] { for item in array { try validate(item,key:key) } }
      else if ids.contains(key), !(value is NSNull) {
        guard let s = value as? String, let id = UUID(uuidString:s), id.uuidString == s else { throw CollaborationError.invalid("canonical UUID") }
      }
    }
    try validate(value)
    if let anchor = fields["anchor"] as? [String:Any] {
      let expected = action == "taskRegistered" ? Set(["sourceOffsetUTF16", "line", "prefix", "suffix", "rawSourceRevision", "decodedSourceRevision"]) : Set(["start", "quote", "prefix", "suffix", "rawSourceRevision", "decodedSourceRevision"])
      guard Set(anchor.keys) == expected else { throw CollaborationError.invalid("unknown anchor fields") }
    }
    let event = try JSONDecoder().decode(CollaborationEvent.self,from:bytes)
    try event.validate(limits:limits)
    return event
  }
  static let payloadFields: [String:Set<String>] = [
    "highlightAdded": ["highlightID","anchor"], "highlightRemoved": ["highlightID","supersedes"],
    "highlightReattached": ["highlightID","anchor","supersedes"],
    "commentAdded": ["threadID","messageID","replyTo","text"],
    "threadState": ["threadID","resolved","supersedes"],
    "taskRegistered": ["taskID","anchor"], "taskState": ["taskID","state","supersedes","rawSourceRevision"],
    "sourceProposal": ["baseRevision","proposedRevision","triggerEventID"],
    "sourceResolution": ["baseRevision","proposedRevision","supersedes"]
  ]
  public static func decodeWorkspace(_ bytes:Data, limits:CollaborationLimits = .pilot) throws -> CollaborationWorkspaceManifest {
    try validateManifest(bytes,keys:["schemaVersion","workspaceID"],limit:limits.manifestBytes)
    let value=try JSONDecoder().decode(CollaborationWorkspaceManifest.self,from:bytes)
    guard value.schemaVersion == 2 else { throw CollaborationError.invalid("schema-2 workspace required; schema-1 cannot be joined") }
    return value
  }
  public static func decodeDocument(_ bytes:Data, limits:CollaborationLimits = .pilot) throws -> CollaborationDocumentManifest {
    try validateManifest(bytes,keys:["schemaVersion","workspaceID","documentID","relativePath","initialRevision"],limit:limits.manifestBytes)
    let value=try JSONDecoder().decode(CollaborationDocumentManifest.self,from:bytes)
    guard value.schemaVersion == 2, validRelativePath(value.relativePath), validHash(value.initialRevision) else { throw CollaborationError.invalid("document identity/path/revision") }
    return value
  }
  static func validateManifest(_ bytes:Data,keys:Set<String>,limit:Int) throws {
    guard bytes.count <= limit, let object=try JSONSerialization.jsonObject(with:bytes) as? [String:Any], Set(object.keys)==keys else { throw CollaborationError.invalid("manifest fields/limit") }
    for key in ["workspaceID","documentID"] where keys.contains(key) {
      guard let string=object[key] as? String, let id=UUID(uuidString:string), id.uuidString==string else { throw CollaborationError.invalid("canonical manifest UUID") }
    }
  }
  public static func validName(_ name: String) -> Bool {
    !name.isEmpty && name == name.trimmingCharacters(in:.whitespacesAndNewlines) && name.utf8.count <= 100 && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }
  public static func validRelativePath(_ path: String) -> Bool {
    !path.isEmpty && path.utf8.count <= 4096 && !path.hasPrefix("/") && !path.contains("\\") && !path.split(separator:"/",omittingEmptySubsequences:false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) && path.split(separator:"/").first != "Folio Review" && ["md","markdown"].contains((path as NSString).pathExtension.lowercased())
  }
}
