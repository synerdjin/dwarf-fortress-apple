import DFCore
import DFECS
import DFTesting

/// Stand-in for a body part / inventory entry / skill record.
struct TestPart: PlainData {
  var kind: Int32
  var health: Int32

  func hash(into hasher: inout StateHasher) {
    hasher.combine(kind)
    hasher.combine(health)
  }
}

func registerListStorageTests() {
  suite("SPEC-M0-ECS: Variable-length list storage") {
    test("Set and read a list") {
      var allocator = EntityAllocator()
      let storage = ListStorage<TestPart>()
      let entity = allocator.create()

      expect(!storage.contains(entity))
      expectEqual(storage.count(for: entity), 0)
      expect(storage.list(entity).isEmpty)

      storage.set(entity, [TestPart(kind: 1, health: 10), TestPart(kind: 2, health: 20)])
      expect(storage.contains(entity))
      expectEqual(storage.count(for: entity), 2)
      expectEqual(storage.list(entity).map(\.kind), [1, 2])
      expectEqual(storage[entity, 1]?.health, 20)
      expect(storage[entity, 2] == nil, "out-of-range index must return nil")
    }

    test("Append grows the run and preserves order") {
      var allocator = EntityAllocator()
      let storage = ListStorage<TestPart>()
      let entity = allocator.create()

      for index in 0..<100 {
        storage.append(entity, TestPart(kind: Int32(index), health: 1))
      }
      expectEqual(storage.count(for: entity), 100)
      expectEqual(storage.list(entity).map(\.kind), Array(0..<100).map(Int32.init))
    }

    test("Interleaved appends across entities do not corrupt each other") {
      // The failure this catches: a run growing in place over its neighbour.
      var allocator = EntityAllocator()
      let storage = ListStorage<TestPart>()
      let entities = (0..<8).map { _ in allocator.create() }

      for round in 0..<40 {
        for (slot, entity) in entities.enumerated() {
          storage.append(entity, TestPart(kind: Int32(slot), health: Int32(round)))
        }
      }

      for (slot, entity) in entities.enumerated() {
        let list = storage.list(entity)
        expectEqual(list.count, 40, "entity \(slot) lost elements")
        expect(list.allSatisfy { $0.kind == Int32(slot) }, "entity \(slot) got foreign elements")
        expectEqual(list.map(\.health), Array(0..<40).map(Int32.init))
      }
    }

    test("Element removal preserves order") {
      // Order-preserving on purpose: wounds and equipment refer to body parts
      // by index, so swap-removal would reattach a wound to a different limb.
      var allocator = EntityAllocator()
      let storage = ListStorage<TestPart>()
      let entity = allocator.create()
      storage.set(entity, (0..<5).map { TestPart(kind: Int32($0), health: 0) })

      expect(storage.remove(entity, at: 1))
      expectEqual(storage.list(entity).map(\.kind), [0, 2, 3, 4])

      expect(!storage.remove(entity, at: 99), "out-of-range removal reports false")
      expect(storage.remove(entity, at: 3))
      expectEqual(storage.list(entity).map(\.kind), [0, 2, 3])
    }

    test("Dropping a list frees it and leaves neighbours intact") {
      var allocator = EntityAllocator()
      let storage = ListStorage<TestPart>()
      let a = allocator.create()
      let b = allocator.create()
      let c = allocator.create()
      storage.set(a, [TestPart(kind: 1, health: 1)])
      storage.set(b, [TestPart(kind: 2, health: 2)])
      storage.set(c, [TestPart(kind: 3, health: 3)])

      expect(storage.removeList(b))
      expect(!storage.contains(b))
      expect(!storage.removeList(b), "second drop reports false")
      expectEqual(storage.list(a).map(\.kind), [1])
      expectEqual(storage.list(c).map(\.kind), [3])
      expectEqual(storage.listCount, 2)
    }

    test("Empty lists are representable and distinct from absent ones") {
      var allocator = EntityAllocator()
      let storage = ListStorage<TestPart>()
      let entity = allocator.create()

      storage.set(entity, [])
      expect(storage.contains(entity), "an empty list is present, not absent")
      expectEqual(storage.count(for: entity), 0)
    }

    test("Hashing is blind to allocation history") {
      // The property this type exists for. Two storages with identical contents
      // must hash identically even when one reached them through growth,
      // removal and reuse -- otherwise replay breaks for reasons that have
      // nothing to do with the simulation.
      var allocator = EntityAllocator()
      let entities = (0..<6).map { _ in allocator.create() }
      let target = (0..<6).map { slot in
        (0..<(slot + 2)).map { TestPart(kind: Int32(slot), health: Int32($0)) }
      }

      let direct = ListStorage<TestPart>()
      for (slot, entity) in entities.enumerated() {
        direct.set(entity, target[slot])
      }

      let churned = ListStorage<TestPart>(initialCapacity: 1)
      // Build in reverse, with junk written and removed along the way.
      for (slot, entity) in entities.enumerated().reversed() {
        for _ in 0..<20 {
          churned.append(entity, TestPart(kind: -1, health: -1))
        }
        churned.removeList(entity)
        for part in target[slot] {
          churned.append(entity, part)
        }
      }
      let scratch = allocator.create()
      churned.set(scratch, (0..<50).map { TestPart(kind: 99, health: Int32($0)) })
      churned.removeList(scratch)

      var a = StateHasher()
      direct.hash(into: &a)
      var b = StateHasher()
      churned.hash(into: &b)
      expectEqual(a.value, b.value, "identical contents must hash identically")
      expect(churned.garbageSlots > 0, "the churned storage should actually have garbage")
    }

    test("Compaction reclaims garbage without changing the hash") {
      var allocator = EntityAllocator()
      let storage = ListStorage<TestPart>(initialCapacity: 2)
      let entities = (0..<10).map { _ in allocator.create() }
      for (slot, entity) in entities.enumerated() {
        for index in 0..<(slot + 1) {
          storage.append(entity, TestPart(kind: Int32(slot), health: Int32(index)))
        }
      }
      for slot in stride(from: 0, to: 10, by: 3) {
        storage.removeList(entities[slot])
      }

      var before = StateHasher()
      storage.hash(into: &before)
      let liveBefore = storage.elementCount
      expect(storage.garbageSlots > 0)

      storage.compact()

      var after = StateHasher()
      storage.hash(into: &after)
      expectEqual(after.value, before.value, "compaction must not perturb the hash")
      expectEqual(storage.garbageSlots, 0)
      expectEqual(storage.elementCount, liveBefore)

      // And the lists must still be readable and correct afterwards.
      for (slot, entity) in entities.enumerated() where slot % 3 != 0 {
        expectEqual(storage.count(for: entity), slot + 1, "entity \(slot) wrong after compaction")
        expect(storage.list(entity).allSatisfy { $0.kind == Int32(slot) })
      }
    }

    test("Compaction on a clean storage is a no-op") {
      var allocator = EntityAllocator()
      let storage = ListStorage<TestPart>()
      let entity = allocator.create()
      storage.set(entity, [TestPart(kind: 1, health: 1)])

      var before = StateHasher()
      storage.hash(into: &before)
      storage.compact()
      var after = StateHasher()
      storage.hash(into: &after)
      expectEqual(after.value, before.value)
    }

    test("Hashing detects a changed element and a changed length") {
      var allocator = EntityAllocator()
      let entity = allocator.create()

      func digest(_ parts: [TestPart]) -> UInt64 {
        let storage = ListStorage<TestPart>()
        storage.set(entity, parts)
        var hasher = StateHasher()
        storage.hash(into: &hasher)
        return hasher.value
      }

      let base = [TestPart(kind: 1, health: 10), TestPart(kind: 2, health: 20)]
      expectNotEqual(digest(base), digest([TestPart(kind: 1, health: 11), base[1]]))
      expectNotEqual(digest(base), digest(base + [TestPart(kind: 3, health: 30)]))
      expectNotEqual(digest(base), digest([base[1], base[0]]), "order must matter")
    }

    test("Ownership is per-entity, so two entities with equal lists still differ") {
      var allocator = EntityAllocator()
      let a = allocator.create()
      let b = allocator.create()
      let part = TestPart(kind: 1, health: 1)

      let first = ListStorage<TestPart>()
      first.set(a, [part])
      let second = ListStorage<TestPart>()
      second.set(b, [part])

      var x = StateHasher()
      first.hash(into: &x)
      var y = StateHasher()
      second.hash(into: &y)
      expectNotEqual(x.value, y.value, "the same list on a different entity is different state")
    }
  }
}
