import CryptoKit
import Foundation

public enum ProbeError: Error, Equatable {
  case invalid(String)
  case identityConflict, capacityExceeded, unavailable, injectedInterruption
}
public struct ProbeLimits: Codable, Equatable {
  public var eventBytes = 64 * 1024, snapshotBytes = 8 * 1024 * 1024, manifestBytes = 16 * 1024,
    events = 2000, snapshots = 256, totalBytes = 128 * 1024 * 1024, candidates = 5000,
    references = 32, commentBytes = 8000, diagnostics = 100
  public static let pilot = ProbeLimits()
  public init() {}
}
public enum ProbeTaskState: String, Codable { case open, inProgress, done }
public enum ProbePayload: Codable, Equatable {
  case comment(id: UUID, text: String, sourceRevision: String)
  case task(taskID: UUID, state: ProbeTaskState, supersedes: [UUID], sourceRevision: String)
  case sourceProposal(baseRevision: String, proposedRevision: String)
  case sourceResolution(proposedRevision: String, supersedes: [UUID])
}
public struct ProbeEvent: Codable, Equatable {
  public var schemaVersion: Int = 1
  public var id, workspaceID, documentID, participantID, deviceID: UUID
  public var parents: [UUID]
  public var displayTime: Date
  public var payload: ProbePayload
  public init(
    id: UUID = UUID(), workspaceID: UUID, documentID: UUID, participantID: UUID, deviceID: UUID,
    parents: [UUID] = [], displayTime: Date = Date(), payload: ProbePayload
  ) {
    self.id = id
    self.workspaceID = workspaceID
    self.documentID = documentID
    self.participantID = participantID
    self.deviceID = deviceID
    self.parents = parents
    self.displayTime = displayTime
    self.payload = payload
  }
  public func validate(limits: ProbeLimits = .pilot) throws {
    guard schemaVersion == 1, parents.count <= limits.references,
      supersedes.count <= limits.references,
      Set(parents).count == parents.count, Set(supersedes).count == supersedes.count,
      !parents.contains(id), !supersedes.contains(id), revisions.allSatisfy(ProbeIO.validHash)
    else { throw ProbeError.invalid("event references/schema/hash") }
    if case .comment(_, let text, _) = payload, text.utf8.count > limits.commentBytes {
      throw ProbeError.invalid("comment limit")
    }
  }
  public var revisions: [String] {
    switch payload {
    case .comment(_, _, let h), .task(_, _, _, let h): return [h]
    case .sourceProposal(let a, let b): return [a, b]
    case .sourceResolution(let h, _): return [h]
    }
  }
  public var supersedes: [UUID] {
    switch payload {
    case .task(_, _, let ids, _), .sourceResolution(_, let ids): return ids
    default: return []
    }
  }
}
public enum SnapshotID {
  public static func hash(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
}
public struct WorkspaceManifest: Codable, Equatable {
  public var schemaVersion = 1
  public let workspaceID: UUID
  public init(workspaceID: UUID) { self.workspaceID = workspaceID }
}
public struct DocumentManifest: Codable, Equatable {
  public var schemaVersion = 1
  public let workspaceID, documentID: UUID
  public let relativePath, initialRevision: String
  public init(workspaceID: UUID, documentID: UUID, relativePath: String, initialRevision: String) {
    self.workspaceID = workspaceID
    self.documentID = documentID
    self.relativePath = relativePath
    self.initialRevision = initialRevision
  }
}
public enum ProbeIO {
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
    guard limit >= 0 else { throw ProbeError.invalid("limit") }
    let handle = try FileHandle(forReadingFrom: path)
    defer { try? handle.close() }
    var bytes = Data()
    while bytes.count <= limit {
      let part = try handle.read(upToCount: limit + 1 - bytes.count) ?? Data()
      if part.isEmpty { break }
      bytes.append(part)
    }
    guard bytes.count <= limit else { throw ProbeError.invalid("file limit") }
    return bytes
  }
  public static func durable(_ bytes: Data, at path: URL) throws {
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temp = path.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp")
    defer { try? FileManager.default.removeItem(at: temp) }
    guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
      throw ProbeError.unavailable
    }
    let handle = try FileHandle(forWritingTo: temp)
    try handle.write(contentsOf: bytes)
    try handle.synchronize()
    try handle.close()
    if rename(temp.path, path.path) != 0 { throw ProbeError.unavailable }
  }
  public static func immutable(_ bytes: Data, at path: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: path.path) {
      do {
        guard try read(path, limit: bytes.count) == bytes else { throw ProbeError.identityConflict }
      } catch ProbeError.invalid { throw ProbeError.identityConflict }
      return
    }
    try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temp = path.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp")
    defer { try? fm.removeItem(at: temp) }
    try durable(bytes, at: temp)
    do { try fm.linkItem(at: temp, to: path) } catch {
      guard fm.fileExists(atPath: path.path), try read(path, limit: bytes.count) == bytes else {
        throw ProbeError.identityConflict
      }
    }
  }
  public static func snapshot(_ bytes: Data, hash: String, limits: ProbeLimits = .pilot) throws {
    guard bytes.count <= limits.snapshotBytes, validHash(hash), SnapshotID.hash(bytes) == hash
    else { throw ProbeError.invalid("snapshot checksum/limit") }
  }
  public static func safe(_ path: URL, root: URL) throws {
    let base = root.standardizedFileURL.path
    let target = path.standardizedFileURL.path
    guard target == base || target.hasPrefix(base + "/") else {
      throw ProbeError.invalid("path escapes root")
    }
    var cursor = path.standardizedFileURL
    while cursor.path.count >= base.count {
      if (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
        throw ProbeError.invalid("symlink")
      }
      if cursor.path == base { break }
      cursor.deleteLastPathComponent()
    }
  }
  public static func decodeEvent(_ bytes: Data, limits: ProbeLimits = .pilot) throws -> ProbeEvent {
    guard bytes.count <= limits.eventBytes else { throw ProbeError.invalid("event limit") }
    let fields: Set<String> = [
      "id", "workspaceID", "documentID", "participantID", "deviceID", "taskID", "parents",
      "supersedes",
    ]
    func validateIDs(_ value: Any, key: String = "") throws {
      if let object = value as? [String: Any] {
        for (name, item) in object { try validateIDs(item, key: name) }
      } else if let array = value as? [Any] {
        for item in array { try validateIDs(item, key: key) }
      } else if fields.contains(key), let string = value as? String {
        guard let id = UUID(uuidString: string), id.uuidString == string else {
          throw ProbeError.invalid("canonical UUID")
        }
      }
    }
    try validateIDs(JSONSerialization.jsonObject(with: bytes))
    let event = try JSONDecoder().decode(ProbeEvent.self, from: bytes)
    try event.validate(limits: limits)
    return event
  }
}
