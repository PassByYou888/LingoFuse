//
//  Framework+GetOption.swift
//  LingoFuse
//
//  String-valued runtime option reader.
//
//  COMPLEMENTS Options.swift
//  ------------------------
//  `Options.swift` provides 16 typed setter/getter pairs
//  (`Options.setQuiet(_:)`, `Options.getWaitConnectionTimeout()`, ...)
//  which are the RECOMMENDED surface for application code.
//
//  This file adds a single STRING-VALUED escape hatch to the Framework
//  facade:
//
//      Framework.setOption(_ option: String, _ value: String)
//          (already defined in Framework.swift)
//
//      Framework.getOption(_ option: String) -> String
//          (added here)
//
//  Together they cover the two use cases the typed API cannot:
//
//    1. Passing option names dynamically (e.g. from a config file).
//    2. Using an option alias that the native layer accepts but that
//       does not have a dedicated Swift getter.
//
//  Both this file and Options.swift share the same underlying C
//  primitive (`LF_GetOption` / `LF_SetOption`), so mixing them is
//  safe and consistent.
//
//  RETURN VALUE
//  ------------
//  * The option's current value as a UTF-8 `String`.
//  * An empty string (`""`) for an unknown option name, an unset
//    option, or a NULL pointer from the native layer.
//
//  The native pointer is a transient buffer released ~5 seconds
//  after the call; `String(cString:)` copies it immediately, so the
//  returned string is fully detached and safe to retain.
//
//  WRITE-ONLY OPTIONS
//  ------------------
//  Some options (currently only `"debug"`) are write-only: the
//  native layer returns a fixed placeholder string rather than a
//  stored value. This function forwards whatever the native layer
//  produces; it does not attempt to mask or normalise it.
//
//  PERSISTENCE
//  -----------
//  Options are process-global and take effect immediately, but they
//  are NOT persisted across `Framework.shutdown()`. An application
//  that restarts the framework must reapply its options on every
//  startup.
//

import Foundation
import CLingoFuse

extension Framework {

    /// Reads a runtime option as a UTF-8 string.
    ///
    /// This is the STRING-VALUED escape hatch for cases the typed
    /// `Options.*` getters do not cover:
    ///
    ///   - option names supplied dynamically (e.g. from a config file)
    ///   - option aliases accepted by the native layer but without a
    ///     dedicated Swift getter
    ///   - diagnostic tools that iterate over the full option table
    ///
    /// For every option that DOES have a typed pair in `Options.swift`,
    /// prefer the typed getter: it handles the encoding and the
    /// fallback rules for you.
    ///
    /// - Parameter option: The option name (case-insensitive).
    /// - Returns: The current value, or `""` for an unknown option.
    @discardableResult
    public static func getOption(_ option: String) -> String {
        guard let ptr = LF_GetOption(option) else { return "" }
        return String(cString: ptr)
    }
}