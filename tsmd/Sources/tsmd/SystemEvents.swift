import Foundation
import IOKit
import IOKit.pwr_mgt

// These IOKit power management message constants are C macros that cannot be
// imported directly into Swift. Computed from:
//   sys_iokit = err_system(0x38) = 0xE0000000
//   sub_iokit_common = err_sub(0) = 0
//   iokit_common_msg(x) = sys_iokit | sub_iokit_common | x
private let ioMsgWillSleep: UInt32 = 0xE000_0280  // kIOMessageSystemWillSleep
private let ioMsgCanSleep:  UInt32 = 0xE000_0270  // kIOMessageCanSystemSleep

/// Monitors macOS system events that should trigger an immediate vault lock:
/// screen lock and impending system sleep. Starts observing on `start()`,
/// tears down on `stop()`. The `onLock` closure is called on a background
/// queue; callers must hop to the actor / queue they need.
final class SystemEvents: @unchecked Sendable {
    typealias LockHandler = @Sendable () -> Void

    private let onLock: LockHandler
    private var screenLockObserver: NSObjectProtocol?
    private var notifyPortRef: IONotificationPortRef?
    private var rootPort: io_connect_t = 0
    private var sleepNotifier: io_object_t = 0

    init(onLock: @escaping LockHandler) {
        self.onLock = onLock
    }

    func start() {
        // Screen lock — Foundation-only, no AppKit.
        screenLockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.onLock()
        }

        // System sleep — must reply IOAllowPowerChange so we don't block.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var notifierLocal: io_object_t = 0

        let port = IORegisterForSystemPower(
            selfPtr,
            &notifyPortRef,
            { (refcon, _, messageType, messageArgument) in
                guard let refcon = refcon else { return }
                let me = Unmanaged<SystemEvents>.fromOpaque(refcon).takeUnretainedValue()
                if messageType == ioMsgWillSleep {
                    me.onLock()
                    IOAllowPowerChange(me.rootPort, Int(bitPattern: messageArgument))
                } else if messageType == ioMsgCanSleep {
                    // We do not veto; ack so the system can sleep.
                    IOAllowPowerChange(me.rootPort, Int(bitPattern: messageArgument))
                }
            },
            &notifierLocal
        )
        rootPort = port
        sleepNotifier = notifierLocal

        if let portRef = notifyPortRef {
            CFRunLoopAddSource(
                CFRunLoopGetCurrent(),
                IONotificationPortGetRunLoopSource(portRef).takeUnretainedValue(),
                .defaultMode
            )
        }
    }

    func stop() {
        if let observer = screenLockObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenLockObserver = nil
        }
        if sleepNotifier != 0 {
            IODeregisterForSystemPower(&sleepNotifier)
            sleepNotifier = 0
        }
        if let portRef = notifyPortRef {
            IONotificationPortDestroy(portRef)
            notifyPortRef = nil
        }
        if rootPort != 0 {
            IOServiceClose(rootPort)
            rootPort = 0
        }
    }
}
