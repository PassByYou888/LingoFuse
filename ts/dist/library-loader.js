"use strict";
// =============================================================================
//  library-loader.ts
// -----------------------------------------------------------------------------
//  RAII wrapper that forces an eager library load.
//
//  NOTE: Unlike the C++ binding, the TypeScript binding cannot unload
//  the native library. Koffi loads it once and keeps it loaded for the
//  lifetime of the process; forcing an unload would leave dangling
//  function pointers. LibraryLoader therefore exists for API
//  familiarity: it makes a missing-library error visible at a
//  well-defined point, and it gives callers a symmetric release point
//  if they use the `using` declaration.
// =============================================================================
Object.defineProperty(exports, "__esModule", { value: true });
exports.LibraryLoader = void 0;
const binding_1 = require("./binding");
const errors_1 = require("./errors");
class LibraryLoader {
    constructor() {
        try {
            (0, binding_1.getBinding)();
        }
        catch (err) {
            const libraryName = (0, binding_1.selectPlatformFileName)();
            const message = err instanceof Error ? err.message : String(err);
            throw new errors_1.LingoFuseLibraryLoadError(libraryName, message, { cause: err });
        }
    }
    /**
     * Release the loader. The underlying library stays loaded for the
     * lifetime of the process, so this method is intentionally a no-op;
     * it exists for symmetry and for use with `using` declarations.
     */
    dispose() {
        // Intentionally empty.
    }
}
exports.LibraryLoader = LibraryLoader;
//# sourceMappingURL=library-loader.js.map