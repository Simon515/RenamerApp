import Foundation

/// 有界缓存：容量上限 + 达到上限时淘汰最旧插入项（FIFO），防止常驻进程内存单调增长。
/// 非线程安全，依赖外层 actor 隔离。
public struct BoundedCache<Key: Hashable, Value> {
    private var storage: [Key: Value] = [:]
    private var order: [Key] = []          // 插入顺序，队首最旧
    private let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public subscript(key: Key) -> Value? {
        get { storage[key] }
        set {
            if let newValue {
                if storage[key] == nil { order.append(key) }
                storage[key] = newValue
                evictIfNeeded()
            } else {
                if storage.removeValue(forKey: key) != nil {
                    order.removeAll { $0 == key }
                }
            }
        }
    }

    public var count: Int { storage.count }

    private mutating func evictIfNeeded() {
        while order.count > capacity {
            let oldest = order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }
}
