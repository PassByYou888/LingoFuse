//
//  DataHandle+P2PIdentity.swift
//  LingoFuse
//
//  Side-data accessors on `DataHandle`: read the SENDER'S identity
//  from the INPUT handle of a registered callback.
//
//  {!!!!!  SIDE DATA, NOT A HANDLE PROPERTY  !!!!!}
//
//  Every inbound request payload carries two identity fields that the
//  SENDER'S transport layer writes into the payload header BEFORE
//  transmission (Pascal side:
//  TC40_LF_Client.Send_* -> TMemory_Param_Tool.Rebuild_UID_and_P2PName):
//
//      * FromUID      32 bytes       the sender's session UID
//      * FromP2PName  UTF-8 string   the sender's user-supplied P2P name
//
//  These two fields are "SIDE DATA". They are NOT properties of the
//  handle itself. They are metadata that the sender wrote into the
//  payload, and the receiver therefore sees them in the Data_Param of
//  the INPUT handle it receives from the framework.
//
//  CONSEQUENCE -- the two accessors work ONLY on INPUT handles:
//
//      VALID    -- the `input` argument of a registered Call / Notify
//                  callback.
//      VALID    -- the input of a local call / notify (the framework
//                  injects identity on the local path too).
//      INVALID  -- an OUTPUT handle (no Data_Param side data). The
//                  native layer logs a warning and returns a pointer
//                  to a zero-filled UID / an empty string. The Swift
//                  accessors surface those as `Uid.null` / "".
//      INVALID  -- a caller-created handle (LF_CreateData / LF_CreateData_
//                  Permanent). Such a handle has no "sender", so the
//                  same zero result applies.
//
//  POINTER LIFETIME
//  ----------------
//  LF_Get_P2P_UID returns a `const TP2P_UID*` pointer to a library-owned
//  buffer released ~5 seconds after the call. LF_Get_P2P_Name returns a
//  `const char*` pointer with the same release rule. Both accessors in
//  this file COPY THE VALUE IMMEDIATELY (into a fresh `Uid` / `String`)
//  and never expose the raw pointer to the caller.
//
//  WHOAMI PATTERN
//  --------------
//  To learn a client's own UID, register a Call API on the target side
//  whose callback reads the caller's UID from its INPUT handle:
//
//      app.registerCall("whoami") { input, output in
//          let uid = input.p2pUid()
//          let name = input.p2pName()
//          try? LfIo.writeJson(output, WhoamiReply(uid: uid.toHex(),
//                                                 name: name))
//      }
//
//  The client then calls `whoami` and caches the returned UID. Because
//  the UID is regenerated on every TunnelLink, the client MUST re-probe
//  it after a link loss.
//

import Foundation
import CLingoFuse

extension DataHandle {

    // ------------------------------------------------------------------
    // Side-data accessors
    // ------------------------------------------------------------------

    /// Returns the SENDER'S 32-byte session UID.
    ///
    /// **Valid only on the `input` handle of a registered callback.**
    /// On OUTPUT handles or caller-created handles the native layer
    /// logs a warning and returns a pointer to a zero-filled UID; this
    /// accessor surfaces that as `Uid.null` and never throws.
    ///
    /// The returned `Uid` is a fresh value; it is fully detached from
    /// the library's transient buffer and is safe to retain.
    ///
    /// Calling this on a disposed handle returns `Uid.null` (a
    /// well-defined value, not a crash and not a throw).
    public func p2pUid() -> Uid {
        guard isValid else {
            return .null
        }
        // `raw` is a precondition-guarded accessor; the `isValid`
        // check above ensures the precondition will not fire.
        guard let ptr = LF_Get_P2P_UID(raw) else {
            // The native layer returns NULL only when the library is
            // not loaded, which cannot happen here. Defensive return.
            return .null
        }
        return Uid.fromCStruct(ptr)
    }

    /// Returns the SENDER'S P2P group name.
    ///
    /// **Valid only on the `input` handle of a registered callback.**
    /// On OUTPUT handles or caller-created handles the native layer
    /// logs a warning and returns an empty string; this accessor
    /// surfaces that as `""` and never throws.
    ///
    /// An empty string is a legitimate result: the default P2P name is
    /// empty, and a sender that did not opt into P2P routing produces
    /// exactly that. Callers that need to distinguish "no name" from
    /// "name is literally empty" must inspect `p2pUid().isNull` as
    /// well.
    ///
    /// The returned `String` is a fresh copy; it is fully detached from
    /// the library's transient buffer and is safe to retain.
    ///
    /// Calling this on a disposed handle returns `""` (a well-defined
    /// value, not a crash and not a throw).
    public func p2pName() -> String {
        guard isValid else {
            return ""
        }
        guard let ptr = LF_Get_P2P_Name(raw) else {
            return ""
        }
        // `String(cString:)` copies the bytes immediately, so the
        // transient pointer is not retained past this call.
        return String(cString: ptr)
    }
}