import DFCore

/// Type-erased view of a component storage, so the world can hash, clear and
/// clean up storages without knowing their element types.
public protocol AnyComponentStorage: AnyObject {
  var componentCount: Int { get }
  var componentTypeName: String { get }
  func removeComponent(from entity: EntityID)
  func hashStorage(into hasher: inout StateHasher)
}

extension ComponentStorage: AnyComponentStorage {
  public var componentTypeName: String { String(describing: T.self) }

  public func removeComponent(from entity: EntityID) {
    remove(entity)
  }

  public func hashStorage(into hasher: inout StateHasher) {
    hash(into: &hasher)
  }
}

/// The container for all simulation state.
///
/// Holds the entity allocator and one storage per registered component type.
/// Component types must be registered explicitly at startup, in a fixed order:
/// that order determines the order in which storages fold into the tick hash,
/// so a registry built by iterating a dictionary would produce a different hash
/// on every process launch and quietly destroy replay.
public final class World: @unchecked Sendable {
  public private(set) var entities = EntityAllocator()

  /// Storages in registration order. Order is part of the hash contract.
  private var storagesInOrder: [AnyComponentStorage] = []
  /// Lookup by component type.
  private var storagesByType: [ObjectIdentifier: AnyComponentStorage] = [:]

  /// Set while a system is running, for read/write declaration checking.
  var activeSystem: SystemDescriptor?
  /// Component types touched by the active system, collected in debug builds.
  var accessedTypes: Set<ObjectIdentifier> = []
  var accessedTypeNames: [ObjectIdentifier: String] = [:]

  public init() {}

  // MARK: - Registration

  /// Registers a component type. Call once per type, at startup, in a fixed
  /// order. Registering twice is a programming error, not a no-op.
  public func register<T: Component>(_ type: T.Type, initialCapacity: Int = 64) {
    let key = ObjectIdentifier(type)
    precondition(
      storagesByType[key] == nil,
      "component type \(type) registered twice"
    )
    let storage = ComponentStorage<T>(initialCapacity: initialCapacity)
    storagesByType[key] = storage
    storagesInOrder.append(storage)
  }

  public func isRegistered<T: Component>(_ type: T.Type) -> Bool {
    storagesByType[ObjectIdentifier(type)] != nil
  }

  /// The storage for a component type.
  ///
  /// In debug builds this records the access so the scheduler can verify it
  /// against the running system's declared read/write sets.
  public func storage<T: Component>(_ type: T.Type) -> ComponentStorage<T> {
    let key = ObjectIdentifier(type)
    guard let storage = storagesByType[key] as? ComponentStorage<T> else {
      preconditionFailure(
        "component type \(type) is not registered; register it at startup"
      )
    }
    #if DEBUG
      if activeSystem != nil {
        accessedTypes.insert(key)
        accessedTypeNames[key] = String(describing: type)
      }
    #endif
    return storage
  }

  // MARK: - Entities

  public func createEntity() -> EntityID {
    entities.create()
  }

  /// Destroys an entity and strips every component it held.
  @discardableResult
  public func destroyEntity(_ entity: EntityID) -> Bool {
    guard entities.destroy(entity) else { return false }
    // Registration order, so component teardown is deterministic too.
    for storage in storagesInOrder {
      storage.removeComponent(from: entity)
    }
    return true
  }

  public func isAlive(_ entity: EntityID) -> Bool {
    entities.isAlive(entity)
  }

  public var liveEntityCount: Int { entities.liveCount }

  // MARK: - Convenience component access

  public func set<T: Component>(_ value: T, on entity: EntityID) {
    storage(T.self).set(entity, value)
  }

  public func get<T: Component>(_ type: T.Type, on entity: EntityID) -> T? {
    storage(type)[entity]
  }

  public func has<T: Component>(_ type: T.Type, on entity: EntityID) -> Bool {
    storage(type).contains(entity)
  }

  @discardableResult
  public func remove<T: Component>(_ type: T.Type, from entity: EntityID) -> Bool {
    storage(type).remove(entity)
  }

  // MARK: - Hashing

  /// Folds the entire world into the per-tick state hash.
  public func hash(into hasher: inout StateHasher) {
    entities.hash(into: &hasher)
    for storage in storagesInOrder {
      storage.hashStorage(into: &hasher)
    }
  }

  public var stateHash: UInt64 {
    var hasher = StateHasher()
    hash(into: &hasher)
    return hasher.value
  }

  // MARK: - Introspection

  /// Component counts by type name, for `dfsim` output and debugging.
  public var componentSummary: [(name: String, count: Int)] {
    storagesInOrder.map { ($0.componentTypeName, $0.componentCount) }
  }
}
