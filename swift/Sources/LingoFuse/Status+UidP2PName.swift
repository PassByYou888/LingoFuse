//
//  Status+UidP2PName.swift
//  LingoFuse
//
//  UID- and P2PName-scoped health checks on the Status facade.
//
//  COMPLEMENTS Status.swift
//  ------------------------
//  Status.swift provides App-name-scoped health checks:
//
//      Status.checkMainThread() -> Bool
//      Status.checkApp(_:) -> Bool
//      Status.checkApi(_:_:) -> Bool
//
//  This file adds the two OTHER addressing modes:
//
//      Status.checkUid(_:) -> Bool
//      Status.checkUidApi(_:_:) -> Bool
//      Status.checkP2PName(_:) -> Bool
//      Status.checkP2PNameApi(_:_:) -> Bool
//
//  CACHE SEMANTICS (SAME AS checkApp / checkApi)
//  ---------------------------------------------
//  All four functions consult a LOCALLY CACHED view of the mesh that
//  is updated by periodic broadcasts. Registration and
//  unregistration propagate to this cache with a typical delay of
//  about 3 seconds. A fresh registration may therefore return
//  `false` (a false negative) for a short window, and a fresh
//  unregistration may return `true` (a false positive).
//
//  Callers that need a definitive answer should retry, or fall back
//  to the actual call and handle the empty-response case.
//
//  UID AS AN ARGUMENT
//  ------------------
//  The UID passed to `checkUid` / `checkUidApi` is a VALUE the caller
//  already possesses: typically the result of a prior "whoami" probe
//  or an out-of-band discovery mechanism. It is NOT the sender-side
//  data that `DataHandle.p2pUid()` reads inside a callback; see the
//  docstring on `DataHandle.p2pUid()` for that other role.
//
//  The C ABI declares the UID parameter as `TP2P_UID` (the struct,
//  by value). This file wraps it through `Uid.withCValue(_:)`, which
//  materializes the struct on the local stack frame.
//

import Foundation
import CLingoFuse

extension Status {

    // ==================================================================
    // UID health checks
    // ==================================================================

    /// Returns `true` when a client with the given UID is currently
    /// known to the mesh (locally or via the cached remote view).
    ///
    /// Cache semantics are identical to `checkApp(_:)`: expect up to
    /// ~3 seconds of propagation delay.
    ///
    /// - Parameter uid: The UID to query. `Uid.null` never matches a
    ///   registered client.
    public static func checkUid(_ uid: Uid) -> Bool {
        return uid.withCValue { tp2p in
            LF_Check_UID(tp2p) != 0
        }
    }

    /// Returns `true` when a client with the given UID exposes the
    /// named API.
    ///
    /// Cache semantics are identical to `checkApi(_:_:)`.
    ///
    /// - Parameters:
    ///   - uid: The UID to query.
    ///   - apiName: The API name (case-insensitive on the wire).
    public static func checkUidApi(_ uid: Uid, _ apiName: String) -> Bool {
        return uid.withCValue { tp2p in
            LF_Check_UID_Api(tp2p, apiName) != 0
        }
    }

    // ==================================================================
    // P2PName health checks
    // ==================================================================

    /// Returns `true` when at least one client has the given P2P group
    /// name.
    ///
    /// Cache semantics are identical to `checkApp(_:)`.
    ///
    /// - Parameter groupName: The P2P group name to query.
    public static func checkP2PName(_ groupName: String) -> Bool {
        return LF_Check_P2PNAME(groupName) != 0
    }

    /// Returns `true` when at least one client in the given P2P group
    /// exposes the named API.
    ///
    /// Cache semantics are identical to `checkApi(_:_:)`.
    ///
    /// - Parameters:
    ///   - groupName: The P2P group name to query.
    ///   - apiName: The API name (case-insensitive on the wire).
    public static func checkP2PNameApi(
        _ groupName: String,
        _ apiName: String
    ) -> Bool {
        return LF_Check_P2PNAME_Api(groupName, apiName) != 0
    }
}