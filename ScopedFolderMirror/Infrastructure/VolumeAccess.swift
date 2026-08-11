import AppKit
import Foundation

struct VolumeAssessment: Equatable, Sendable {
  let rootURL: URL
  let uuid: String
  let isExternal: Bool
  let isWritable: Bool
  let isEjectable: Bool
  let isEncrypted: Bool?
}

protocol VolumeAssessing: Sendable {
  func assess(_ destination: URL) throws -> VolumeAssessment
}

struct SystemVolumeAssessor: VolumeAssessing {
  func assess(_ destination: URL) throws -> VolumeAssessment {
    let keys: Set<URLResourceKey> = [
      .volumeURLKey, .volumeUUIDStringKey, .volumeIsInternalKey, .volumeIsLocalKey,
      .volumeIsReadOnlyKey, .volumeIsEjectableKey, .volumeIsEncryptedKey,
    ]
    let values = try destination.resourceValues(forKeys: keys)
    guard let root = values.allValues[.volumeURLKey] as? URL, let uuid = values.volumeUUIDString
    else {
      throw SyncFailure.invalidDestination(.unavailable)
    }
    return VolumeAssessment(
      rootURL: root.standardizedFileURL,
      uuid: uuid,
      isExternal: values.volumeIsInternal == false && values.volumeIsLocal == true,
      isWritable: values.volumeIsReadOnly == false,
      isEjectable: values.volumeIsEjectable == true,
      isEncrypted: values.volumeIsEncrypted
    )
  }
}

protocol VolumeEjecting: Sendable {
  func eject(_ volumeRoot: URL) throws
}

struct SystemVolumeEjector: VolumeEjecting {
  func eject(_ volumeRoot: URL) throws {
    try NSWorkspace.shared.unmountAndEjectDevice(at: volumeRoot)
  }
}
