import Foundation
import TransportProbe

struct SimulatedCourier {
  static func transfer(from: URL, to: URL, relativePaths: [String], repeats: Int = 1) throws {
    for _ in 0..<repeats {
      for path in relativePaths {
        let src = from.appendingPathComponent(path)
        let dst = to.appendingPathComponent(path)
        let bytes = try Data(contentsOf: src)
        do { try ProbeIO.immutable(bytes, at: dst) } catch {
          let evidence = to.appendingPathComponent("Folio Review/conflicts").appendingPathComponent(
            UUID().uuidString + ".json")
          try ProbeIO.immutable(bytes, at: evidence)
          throw error
        }
      }
    }
  }
  static func paths(_ root: URL, kind: String) -> [String] {
    let path = "Folio Review/" + kind
    return
      ((try? FileManager.default.contentsOfDirectory(
        at: root.appendingPathComponent(path), includingPropertiesForKeys: nil)) ?? []).map {
        path + "/" + $0.lastPathComponent
      }.sorted()
  }
}
func fixed(_ n: Int) -> UUID {
  UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
}
