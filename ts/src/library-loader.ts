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

import { getBinding, selectPlatformFileName } from "./binding";
import { LingoFuseLibraryLoadError } from "./errors";

export class LibraryLoader {
    public constructor() {
        try {
            getBinding();
        } catch (err) {
            const libraryName = selectPlatformFileName();
            const message = err instanceof Error ? err.message : String(err);
            throw new LingoFuseLibraryLoadError(libraryName, message, { cause: err });
        }
    }

    /**
     * Release the loader. The underlying library stays loaded for the
     * lifetime of the process, so this method is intentionally a no-op;
     * it exists for symmetry and for use with `using` declarations.
     */
    public dispose(): void {
        // Intentionally empty.
    }
}