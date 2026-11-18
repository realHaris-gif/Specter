import Foundation
import os

/// Single-producer / single-consumer Float ring buffer.
///
/// - Storage is preallocated; no Swift arrays are touched on the audio thread.
/// - Block copies (memcpy) instead of per-sample modulo loops, so the lock is held for microseconds.
/// - os_unfair_lock instead of NSLock (no ObjC messaging, no allocation).
/// - When full, the OLDEST samples are dropped (same behaviour as before) and counted in `overrunCount`.
/// - Full `capacity` is usable (the old version could only hold capacity - 1).
///
/// NOTE: a fully lock-free SPSC needs real atomics (Swift `Synchronization` module on iOS 18+, or the
/// Atomics package, which the guide forbids without approval). This is the safest option that keeps
/// iOS 16 support. VERIFY ON DEVICE: Instruments -> System Trace should show no audible glitches.
public final class RingBuffer {
    private let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var head = 0      // next write index
    private var tail = 0      // next read index
    private var used = 0      // samples currently stored
    private var overruns = 0  // samples discarded because the consumer fell behind

    public init(capacity: Int = 32768) {
        let cap = max(1, capacity)
        let mem = UnsafeMutablePointer<Float>.allocate(capacity: cap)
        mem.initialize(repeating: 0, count: cap)
        let l = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        l.initialize(to: os_unfair_lock())
        self.capacity = cap
        self.storage = mem
        self.lock = l
    }

    deinit {
        storage.deallocate()
        lock.deallocate()
    }

    /// Number of samples ready to read.
    public var availableToRead: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return used
    }

    /// Total samples dropped because the reader was too slow.
    public var overrunCount: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return overruns
    }

    /// Discard everything (call on stop/restart so stale audio is never processed).
    public func reset() {
        os_unfair_lock_lock(lock)
        head = 0
        tail = 0
        used = 0
        overruns = 0
        os_unfair_lock_unlock(lock)
    }

    public func write(_ data: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        var src = data
        var remaining = count

        // More than the whole buffer: only the newest `capacity` samples matter.
        if remaining >= capacity {
            let skip = remaining - capacity
            overruns += skip + used
            src += skip
            remaining = capacity
            head = 0
            tail = 0
            used = 0
        }

        // Make room by dropping the oldest samples.
        let free = capacity - used
        if remaining > free {
            let drop = remaining - free
            tail = (tail + drop) % capacity
            used -= drop
            overruns += drop
        }

        let stride = MemoryLayout<Float>.stride
        let first = min(remaining, capacity - head)
        memcpy(storage + head, src, first * stride)
        let second = remaining - first
        if second > 0 {
            memcpy(storage, src + first, second * stride)
        }
        head = (head + remaining) % capacity
        used += remaining
    }

    /// Pointer variant (no array bounds traps). Named differently from `read(into:count:)`
    /// to avoid overload ambiguity with `&array`.
    @discardableResult
    public func readRaw(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        let n = min(count, used)
        guard n > 0 else { return 0 }

        let stride = MemoryLayout<Float>.stride
        let first = min(n, capacity - tail)
        memcpy(destination, storage + tail, first * stride)
        let second = n - first
        if second > 0 {
            memcpy(destination + first, storage, second * stride)
        }
        tail = (tail + n) % capacity
        used -= n
        return n
    }

    /// Original API, unchanged. Now safe if `destination` is smaller than `count`.
    public func read(into destination: inout [Float], count: Int) -> Int {
        let n = min(count, destination.count)
        guard n > 0 else { return 0 }
        return destination.withUnsafeMutableBufferPointer { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            return self.readRaw(into: base, count: n)
        }
    }
}