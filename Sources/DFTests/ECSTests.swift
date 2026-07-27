import DFCore
import DFECS
import DFTesting

// Test components. Deliberately trivial: the point is storage behaviour, not
// simulation meaning.
struct TestPosition: Component {
  var coord: Coord3

  func hash(into hasher: inout StateHasher) {
    hasher.combine(coord)
  }
}

struct TestHealth: Component {
  var current: Int32
  var maximum: Int32

  func hash(into hasher: inout StateHasher) {
    hasher.combine(current)
    hasher.combine(maximum)
  }
}

func registerECSTests() {
  suite("SPEC-M0-ECS: Entity allocation") {
    test("Fresh entities are alive and distinct") {
      var allocator = EntityAllocator()
      let a = allocator.create()
      let b = allocator.create()

      expect(a != b)
      expect(allocator.isAlive(a))
      expect(allocator.isAlive(b))
      expectEqual(allocator.liveCount, 2)
    }

    test("Destroyed handles go stale, and slot reuse does not revive them") {
      // The whole reason for the generation counter. A job holding a handle to
      // a dead dwarf must get "not alive" rather than silently retargeting at
      // whoever moved into the slot.
      var allocator = EntityAllocator()
      let original = allocator.create()
      expect(allocator.destroy(original))
      expect(!allocator.isAlive(original))

      let recycled = allocator.create()
      expectEqual(recycled.index, original.index, "slot should be reused")
      expectNotEqual(recycled.generation, original.generation, "generation must advance")
      expect(allocator.isAlive(recycled))
      expect(!allocator.isAlive(original), "stale handle must not be revived by reuse")
    }

    test("Double destroy is reported, not fatal") {
      var allocator = EntityAllocator()
      let entity = allocator.create()
      expect(allocator.destroy(entity))
      expect(!allocator.destroy(entity), "second destroy should report already-dead")
      expectEqual(allocator.liveCount, 0)
    }

    test("The invalid handle is never alive") {
      var allocator = EntityAllocator()
      _ = allocator.create()
      expect(!allocator.isAlive(EntityID.invalid))
      expect(!EntityID.invalid.isValid)
      // Slot 0 generation 0 is an ordinary entity, not a sentinel.
      expect(EntityID(index: 0, generation: 0).isValid)
    }

    test("Slot reuse is LIFO and therefore replayable") {
      // The policy is arbitrary but must be fixed: it determines the slot
      // layout every component array inherits.
      var allocator = EntityAllocator()
      let first = allocator.create()
      let second = allocator.create()
      let third = allocator.create()
      allocator.destroy(first)
      allocator.destroy(second)
      allocator.destroy(third)

      expectEqual(allocator.create().index, third.index)
      expectEqual(allocator.create().index, second.index)
      expectEqual(allocator.create().index, first.index)
    }
  }

  suite("SPEC-M0-ECS: Component storage") {
    test("Set, get, contains, remove") {
      var allocator = EntityAllocator()
      let storage = ComponentStorage<TestPosition>()
      let entity = allocator.create()

      expect(!storage.contains(entity))
      expect(storage[entity] == nil)

      storage.set(entity, TestPosition(coord: Coord3(1, 2, 3)))
      expect(storage.contains(entity))
      expectEqual(storage[entity]?.coord, Coord3(1, 2, 3))
      expectEqual(storage.componentCount, 1)

      expect(storage.remove(entity))
      expect(!storage.contains(entity))
      expectEqual(storage.componentCount, 0)
      expect(!storage.remove(entity), "removing twice should report nothing removed")
    }

    test("Setting twice overwrites rather than duplicating") {
      var allocator = EntityAllocator()
      let storage = ComponentStorage<TestPosition>()
      let entity = allocator.create()

      storage.set(entity, TestPosition(coord: Coord3(1, 1, 1)))
      storage.set(entity, TestPosition(coord: Coord3(2, 2, 2)))

      expectEqual(storage.componentCount, 1)
      expectEqual(storage[entity]?.coord, Coord3(2, 2, 2))
    }

    test("Swap-remove keeps the dense array packed and the sparse map correct") {
      // The subtle failure: removing from the middle moves the last element,
      // and the moved element's sparse entry must be repaired or it becomes
      // unreachable while still occupying a dense slot.
      var allocator = EntityAllocator()
      let storage = ComponentStorage<TestHealth>()
      let entities = (0..<10).map { _ in allocator.create() }
      for (index, entity) in entities.enumerated() {
        storage.set(entity, TestHealth(current: Int32(index), maximum: 100))
      }

      storage.remove(entities[3])
      expectEqual(storage.componentCount, 9)

      // Every survivor must still be findable with the right value.
      for (index, entity) in entities.enumerated() where index != 3 {
        expectEqual(
          storage[entity]?.current, Int32(index), "entity \(index) lost after swap-remove")
      }
      expect(storage[entities[3]] == nil)
    }

    test("Removing the last element needs no swap") {
      var allocator = EntityAllocator()
      let storage = ComponentStorage<TestHealth>()
      let a = allocator.create()
      let b = allocator.create()
      storage.set(a, TestHealth(current: 1, maximum: 1))
      storage.set(b, TestHealth(current: 2, maximum: 2))

      storage.remove(b)
      expectEqual(storage.componentCount, 1)
      expectEqual(storage[a]?.current, 1)
    }

    test("Growth past initial capacity preserves everything") {
      var allocator = EntityAllocator()
      let storage = ComponentStorage<TestHealth>(initialCapacity: 2)
      let entities = (0..<500).map { _ in allocator.create() }
      for (index, entity) in entities.enumerated() {
        storage.set(entity, TestHealth(current: Int32(index), maximum: 500))
      }

      expectEqual(storage.componentCount, 500)
      for (index, entity) in entities.enumerated() {
        expectEqual(storage[entity]?.current, Int32(index), "value lost during growth")
      }
    }

    test("modify mutates in place") {
      var allocator = EntityAllocator()
      let storage = ComponentStorage<TestHealth>()
      let entity = allocator.create()
      storage.set(entity, TestHealth(current: 50, maximum: 100))

      storage.modify(entity) { $0.current -= 10 }
      expectEqual(storage[entity]?.current, 40)

      // Modifying an absent entity is a no-op, not a trap: "the target died
      // this tick" is ordinary, not exceptional.
      let absent = allocator.create()
      storage.modify(absent) { $0.current = 999 }
      expect(storage[absent] == nil)
    }

    test("Dense iteration sees every element exactly once") {
      var allocator = EntityAllocator()
      let storage = ComponentStorage<TestHealth>()
      let entities = (0..<100).map { _ in allocator.create() }
      for (index, entity) in entities.enumerated() {
        storage.set(entity, TestHealth(current: Int32(index), maximum: 100))
      }
      for index in stride(from: 0, to: 100, by: 3) {
        storage.remove(entities[index])
      }

      var seen: Set<Int32> = []
      var total = 0
      storage.withDense { values, owners in
        expectEqual(values.count, owners.count)
        for index in 0..<values.count {
          seen.insert(values[index].current)
          total += 1
        }
      }
      expectEqual(total, storage.componentCount)
      expectEqual(seen.count, storage.componentCount)
    }

    test("Storage hashing is order-independent across differing histories") {
      // Two storages holding the same entity-value pairs, built in different
      // orders and with different removal histories, must hash the same. The
      // hash tests what the simulation *is*, not how its arrays got laid out.
      var allocator = EntityAllocator()
      let entities = (0..<20).map { _ in allocator.create() }

      let forward = ComponentStorage<TestHealth>()
      for (index, entity) in entities.enumerated() {
        forward.set(entity, TestHealth(current: Int32(index), maximum: 100))
      }

      let scrambled = ComponentStorage<TestHealth>()
      // Insert in reverse, then churn with adds and removes.
      for (index, entity) in entities.enumerated().reversed() {
        scrambled.set(entity, TestHealth(current: Int32(index), maximum: 100))
      }
      scrambled.remove(entities[5])
      scrambled.remove(entities[11])
      scrambled.set(entities[5], TestHealth(current: 5, maximum: 100))
      scrambled.set(entities[11], TestHealth(current: 11, maximum: 100))

      var a = StateHasher()
      forward.hash(into: &a)
      var b = StateHasher()
      scrambled.hash(into: &b)
      expectEqual(a.value, b.value, "equal contents must hash equally")
    }

    test("Storage hashing detects a changed value") {
      var allocator = EntityAllocator()
      let entity = allocator.create()

      let original = ComponentStorage<TestHealth>()
      original.set(entity, TestHealth(current: 50, maximum: 100))
      let changed = ComponentStorage<TestHealth>()
      changed.set(entity, TestHealth(current: 51, maximum: 100))

      var a = StateHasher()
      original.hash(into: &a)
      var b = StateHasher()
      changed.hash(into: &b)
      expectNotEqual(a.value, b.value)
    }

    test("Components have no interior padding") {
      // Padding bytes are uninitialized and would feed garbage into buffer
      // hashing, producing hashes that differ run to run for no reason.
      expect(StateHasher.hasNoPadding(TestPosition.self, fieldByteCount: 12))
      expect(StateHasher.hasNoPadding(TestHealth.self, fieldByteCount: 8))
    }
  }

  suite("SPEC-M0-ECS: World") {
    test("Registered components round-trip through the world") {
      let world = World()
      world.register(TestPosition.self)
      world.register(TestHealth.self)

      let entity = world.createEntity()
      world.set(TestPosition(coord: Coord3(4, 5, 6)), on: entity)

      expect(world.has(TestPosition.self, on: entity))
      expect(!world.has(TestHealth.self, on: entity))
      expectEqual(world.get(TestPosition.self, on: entity)?.coord, Coord3(4, 5, 6))
      expectEqual(world.liveEntityCount, 1)
    }

    test("Destroying an entity strips all of its components") {
      // A component left behind on a dead entity would be resurrected the
      // moment the slot is reused, giving a newborn dwarf a corpse's wounds.
      let world = World()
      world.register(TestPosition.self)
      world.register(TestHealth.self)

      let entity = world.createEntity()
      world.set(TestPosition(coord: Coord3(1, 1, 1)), on: entity)
      world.set(TestHealth(current: 10, maximum: 10), on: entity)

      expect(world.destroyEntity(entity))
      expect(!world.isAlive(entity))
      expectEqual(world.storage(TestPosition.self).componentCount, 0)
      expectEqual(world.storage(TestHealth.self).componentCount, 0)

      let recycled = world.createEntity()
      expect(world.get(TestPosition.self, on: recycled) == nil)
      expect(world.get(TestHealth.self, on: recycled) == nil)
    }

    test("World hashing reflects contents and is stable across rebuilds") {
      func build(healthOfSecond: Int32) -> World {
        let world = World()
        world.register(TestPosition.self)
        world.register(TestHealth.self)
        let a = world.createEntity()
        let b = world.createEntity()
        world.set(TestPosition(coord: Coord3(1, 2, 3)), on: a)
        world.set(TestHealth(current: healthOfSecond, maximum: 100), on: b)
        return world
      }

      expectEqual(build(healthOfSecond: 50).stateHash, build(healthOfSecond: 50).stateHash)
      expectNotEqual(build(healthOfSecond: 50).stateHash, build(healthOfSecond: 51).stateHash)
    }

    test("Entity allocator state is part of the world hash") {
      // Two worlds with identical visible contents but different free lists
      // will diverge on the next entity creation, so they are not equal states.
      let plain = World()
      plain.register(TestPosition.self)
      _ = plain.createEntity()

      let churned = World()
      churned.register(TestPosition.self)
      let temporary = churned.createEntity()
      churned.destroyEntity(temporary)
      _ = churned.createEntity()

      expectNotEqual(plain.stateHash, churned.stateHash)
    }
  }

  suite("SPEC-M0-ECS: Tick scheduler") {
    test("Systems run in phase order regardless of registration order") {
      let world = World()
      world.register(TestPosition.self)
      let scheduler = TickScheduler(jobs: JobSystem())

      let recorder = OrderRecorder()
      // Registered out of phase order on purpose.
      scheduler.register(
        SystemDescriptor(name: "combat", phase: .combat, reads: [TestPosition.self]) { _, _ in
          recorder.append("combat")
        }
      )
      scheduler.register(
        SystemDescriptor(name: "time", phase: .time, reads: [TestPosition.self]) { _, _ in
          recorder.append("time")
        }
      )
      scheduler.register(
        SystemDescriptor(name: "jobs", phase: .jobs, reads: [TestPosition.self]) { _, _ in
          recorder.append("jobs")
        }
      )

      scheduler.tick(world)
      expectEqual(recorder.entries, ["time", "jobs", "combat"])
    }

    test("Registration order breaks ties within a phase") {
      let world = World()
      world.register(TestPosition.self)
      let scheduler = TickScheduler(jobs: JobSystem())
      let recorder = OrderRecorder()

      for name in ["first", "second", "third"] {
        scheduler.register(
          SystemDescriptor(name: name, phase: .jobs, reads: [TestPosition.self]) { _, _ in
            recorder.append(name)
          }
        )
      }

      scheduler.tick(world)
      expectEqual(recorder.entries, ["first", "second", "third"])
    }

    test("Tick count advances and systems can mutate world state") {
      let world = World()
      world.register(TestHealth.self)
      let scheduler = TickScheduler(jobs: JobSystem())

      let entity = world.createEntity()
      world.set(TestHealth(current: 0, maximum: 100), on: entity)

      scheduler.register(
        SystemDescriptor(name: "heal", phase: .growth, writes: [TestHealth.self]) { world, _ in
          world.storage(TestHealth.self).withDense { values, _ in
            for index in 0..<values.count { values[index].current += 1 }
          }
        }
      )

      scheduler.run(world, ticks: 10)
      expectEqual(scheduler.tickCount, 10)
      expectEqual(world.get(TestHealth.self, on: entity)?.current, 10)
    }

    test("Identical tick sequences produce identical state hashes") {
      // The property every replay fixture depends on.
      func runSimulation() -> UInt64 {
        let world = World()
        world.register(TestPosition.self)
        world.register(TestHealth.self)
        let scheduler = TickScheduler(jobs: JobSystem())

        for index in 0..<50 {
          let entity = world.createEntity()
          world.set(TestPosition(coord: Coord3(Int32(index), 0, 0)), on: entity)
          world.set(TestHealth(current: Int32(index), maximum: 100), on: entity)
        }

        scheduler.register(
          SystemDescriptor(
            name: "drift",
            phase: .movement,
            reads: [TestHealth.self],
            writes: [TestPosition.self]
          ) { world, _ in
            let health = world.storage(TestHealth.self)
            world.storage(TestPosition.self).withDense { values, owners in
              for index in 0..<values.count {
                let hp = health[owners[index]]?.current ?? 0
                values[index].coord.x += hp % 3
              }
            }
          }
        )

        scheduler.run(world, ticks: 100)
        return world.stateHash
      }

      expectEqual(runSimulation(), runSimulation())
    }

    test("Execution order is inspectable without reading code") {
      let scheduler = TickScheduler(jobs: JobSystem())
      scheduler.register(SystemDescriptor(name: "b", phase: .jobs) { _, _ in })
      scheduler.register(SystemDescriptor(name: "a", phase: .time) { _, _ in })
      expectEqual(scheduler.executionOrder, ["time/a", "jobs/b"])
    }
  }
}

/// Collects system execution order. A class so the escaping system closures can
/// share it; tests are serial, so no synchronisation is needed.
final class OrderRecorder: @unchecked Sendable {
  private(set) var entries: [String] = []
  func append(_ name: String) { entries.append(name) }
}
