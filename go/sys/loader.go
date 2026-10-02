package sys

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sync"

	"github.com/ebitengine/purego"
)

// ---------------------------------------------------------------------------
// Platform detection
// ---------------------------------------------------------------------------

// platformFileName returns the platform-specific shared library file
// name, matching the C++, C#, Python, JavaScript, and Rust bindings.
func platformFileName() string {
	switch runtime.GOOS {
	case "windows":
		if runtime.GOARCH == "amd64" || runtime.GOARCH == "arm64" {
			return "LingoFuse64.dll"
		}
		return "LingoFuse32.dll"
	case "darwin":
		return "liblingofuse.dylib"
	default:
		return "liblingofuse.so"
	}
}

// buildSearchPaths returns the ordered list of file-system candidates
// tried before falling back to the OS loader's own search path.
//
//  1. The directory containing the current executable.
//  2. A "native" subdirectory next to the executable.
//  3. The current working directory.
func buildSearchPaths() []string {
	name := platformFileName()
	paths := make([]string, 0, 3)

	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		paths = append(paths, filepath.Join(dir, name))
		paths = append(paths, filepath.Join(dir, "native", name))
	}
	if cwd, err := os.Getwd(); err == nil {
		paths = append(paths, filepath.Join(cwd, name))
	}
	return paths
}

// ---------------------------------------------------------------------------
// Load error
// ---------------------------------------------------------------------------

// LoadError describes a failure to load the native library or resolve
// a required symbol.
type LoadError struct {
	// Attempted lists every explicit path that was tried before the
	// OS loader was asked to resolve the bare file name.
	Attempted []string

	// LastError is the diagnostic from the most recent failed attempt.
	LastError string

	// SymbolMissing is set when the library loaded but a required
	// export was absent.
	SymbolMissing string
}

func (e *LoadError) Error() string {
	if e.SymbolMissing != "" {
		return fmt.Sprintf(
			"lingofuse: native library is missing a required symbol: %s",
			e.SymbolMissing,
		)
	}
	msg := "lingofuse: failed to load the native library"
	if len(e.Attempted) > 0 {
		msg += "; tried:"
		for _, p := range e.Attempted {
			msg += "\n  - " + p
		}
	}
	msg += "\nplace the platform library next to the executable, " +
		"in the current working directory, or on the system loader " +
		"search path (PATH on Windows, LD_LIBRARY_PATH on Linux, " +
		"DYLD_LIBRARY_PATH on macOS)"
	if e.LastError != "" {
		msg += "\nlast error: " + e.LastError
	}
	return msg
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

var (
	libHandle uintptr
	loadOnce  sync.Once
	loadErr   error
)

// LoadLibrary loads the LingoFuse shared library and resolves every
// exported symbol into the function variables declared in bindings.go.
//
// This is idempotent: subsequent calls return the same cached result.
// A failure is cached as well; a process restart is required to retry.
//
// Callers that want a clear startup failure should call LoadLibrary
// explicitly at program start.
func LoadLibrary() error {
	loadOnce.Do(func() {
		loadErr = doLoad()
	})
	return loadErr
}

// IsLoaded reports whether the native library is loaded and usable.
func IsLoaded() bool { return libHandle != 0 }

// PlatformFileName exposes the platform-specific file name for
// diagnostics and check-env tooling.
func PlatformFileName() string { return platformFileName() }

func doLoad() error {
	name := platformFileName()
	var attempted []string
	var lastErr string

	// Try each explicit path first.
	for _, path := range buildSearchPaths() {
		attempted = append(attempted, path)
		h, err := openLibrary(path)
		if err != nil {
			lastErr = err.Error()
			continue
		}
		if rerr := resolveAll(h); rerr != nil {
			closeLibrary(h)
			return rerr
		}
		libHandle = h
		return nil
	}

	// Fall back to the OS loader search path with the bare file name.
	h, err := openLibrary(name)
	if err == nil {
		if rerr := resolveAll(h); rerr != nil {
			closeLibrary(h)
			return rerr
		}
		libHandle = h
		return nil
	}
	lastErr = err.Error()

	return &LoadError{
		Attempted: attempted,
		LastError: lastErr,
	}
}

// resolveAll resolves every one of the 37 exported symbols into the
// package-level function variables declared in bindings.go.
//
// purego.RegisterLibFunc panics when a symbol is absent, so the whole
// resolution sequence runs inside a deferred recover. On the first
// missing symbol, the panic is converted into a *LoadError.
func resolveAll(handle uintptr) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = &LoadError{
				SymbolMissing: fmt.Sprint(r),
				LastError:     "one or more required exports are missing",
			}
		}
	}()

	// --- Data handle operations (10) ---
	purego.RegisterLibFunc(&LF_CreateData, handle, "LF_CreateData")
	purego.RegisterLibFunc(&LF_CreateData_Permanent, handle, "LF_CreateData_Permanent")
	purego.RegisterLibFunc(&LF_FreeData, handle, "LF_FreeData")
	purego.RegisterLibFunc(&LF_GetBuffer, handle, "LF_GetBuffer")
	purego.RegisterLibFunc(&LF_WriteBuffer, handle, "LF_WriteBuffer")
	purego.RegisterLibFunc(&LF_ReadBuffer, handle, "LF_ReadBuffer")
	purego.RegisterLibFunc(&LF_GetPos, handle, "LF_GetPos")
	purego.RegisterLibFunc(&LF_SetPos, handle, "LF_SetPos")
	purego.RegisterLibFunc(&LF_GetSize, handle, "LF_GetSize")
	purego.RegisterLibFunc(&LF_SetSize, handle, "LF_SetSize")

	// --- Application handle operations (5) ---
	purego.RegisterLibFunc(&LF_CreateApp, handle, "LF_CreateApp")
	purego.RegisterLibFunc(&LF_FreeApp, handle, "LF_FreeApp")
	purego.RegisterLibFunc(&LF_Generate_AppName, handle, "LF_Generate_AppName")
	purego.RegisterLibFunc(&LF_Get_AppName, handle, "LF_Get_AppName")
	purego.RegisterLibFunc(&LF_BindApp, handle, "LF_BindApp")

	// --- API registration (3) ---
	purego.RegisterLibFunc(&LF_RegisterCall, handle, "LF_RegisterCall")
	purego.RegisterLibFunc(&LF_RegisterNotify, handle, "LF_RegisterNotify")
	purego.RegisterLibFunc(&LF_Unregister, handle, "LF_Unregister")

	// --- Local execution (2) ---
	purego.RegisterLibFunc(&LF_LocalCall, handle, "LF_LocalCall")
	purego.RegisterLibFunc(&LF_LocalNotify, handle, "LF_LocalNotify")

	// --- Network preparation (5) ---
	purego.RegisterLibFunc(&LF_ResetPrepare, handle, "LF_ResetPrepare")
	purego.RegisterLibFunc(&LF_PrepareService, handle, "LF_PrepareService")
	purego.RegisterLibFunc(&LF_PrepareClient, handle, "LF_PrepareClient")
	purego.RegisterLibFunc(&LF_PrepareDone, handle, "LF_PrepareDone")
	purego.RegisterLibFunc(&LF_ExitMainThread, handle, "LF_ExitMainThread")

	// --- Remote invocation (3) ---
	purego.RegisterLibFunc(&LF_Call, handle, "LF_Call")
	purego.RegisterLibFunc(&LF_Notify, handle, "LF_Notify")
	purego.RegisterLibFunc(&LF_Sequenced_Notify, handle, "LF_Sequenced_Notify")

	// --- Options and diagnostics (7) ---
	purego.RegisterLibFunc(&LF_SetOption, handle, "LF_SetOption")
	purego.RegisterLibFunc(&LF_GetStatusCount, handle, "LF_GetStatusCount")
	purego.RegisterLibFunc(&LF_GetStatus, handle, "LF_GetStatus")
	purego.RegisterLibFunc(&LF_PostStatus, handle, "LF_PostStatus")
	purego.RegisterLibFunc(&LF_CheckMainThread, handle, "LF_CheckMainThread")
	purego.RegisterLibFunc(&LF_CheckApp, handle, "LF_CheckApp")
	purego.RegisterLibFunc(&LF_CheckApi, handle, "LF_CheckApi")

	// --- Shutdown (1) ---
	purego.RegisterLibFunc(&LF_Shutdown, handle, "LF_Shutdown")

	// --- Network events (1) ---
	purego.RegisterLibFunc(&LF_Set_Network_Event, handle, "LF_Set_Network_Event")

	return nil
}
