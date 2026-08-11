import Foundation

actor ActivityLogStore {
  private let defaults: UserDefaults
  private let key = "scoped-folder-mirror.activity"

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  func entries() -> [ActivityRecord] {
    guard let data = defaults.data(forKey: key) else { return [] }
    return (try? JSONDecoder().decode([ActivityRecord].self, from: data)) ?? []
  }

  func append(_ record: ActivityRecord) {
    var updated = entries()
    updated.insert(record, at: 0)
    defaults.set(try? JSONEncoder().encode(Array(updated.prefix(100))), forKey: key)
  }

  func removeAll() { defaults.removeObject(forKey: key) }
}
