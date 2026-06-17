import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
extension FloatingTokenPanelController {
    func saveLockedOrigin(_ origin: NSPoint, throttled: Bool = false) {
        guard throttled else {
            persistLockedOrigin(origin)
            return
        }

        pendingLockedOriginToPersist = origin
        let elapsed = Date().timeIntervalSince(lastLockedOriginPersistAt)
        if elapsed >= lockedOriginPersistInterval {
            flushPendingLockedOriginSave()
            return
        }

        guard lockedOriginPersistTimer == nil else { return }
        let timer = Timer(timeInterval: max(0.05, lockedOriginPersistInterval - elapsed), repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.flushPendingLockedOriginSave()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        lockedOriginPersistTimer = timer
    }

    func flushPendingLockedOriginSave() {
        lockedOriginPersistTimer?.invalidate()
        lockedOriginPersistTimer = nil
        guard let origin = pendingLockedOriginToPersist else { return }
        pendingLockedOriginToPersist = nil
        persistLockedOrigin(origin)
    }

    func persistLockedOrigin(_ origin: NSPoint) {
        let defaults = UserDefaults.standard
        defaults.set(Double(origin.x), forKey: lockedOriginXKey)
        defaults.set(Double(origin.y), forKey: lockedOriginYKey)
        lastLockedOriginPersistAt = Date()
    }

    func savedLockedOrigin() -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: lockedOriginXKey) != nil,
              defaults.object(forKey: lockedOriginYKey) != nil else {
            return nil
        }
        return NSPoint(x: defaults.double(forKey: lockedOriginXKey), y: defaults.double(forKey: lockedOriginYKey))
    }
}
