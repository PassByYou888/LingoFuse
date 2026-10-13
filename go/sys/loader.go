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

	// AttemptErrors is the per-attempt diagnostic, in the same order
	// as Attempted. It preserves every failure so that the operator
	// can see WHY a specific candidate path was rejected (missing
	// file, wrong architecture, missing dependency, ...).
	AttemptErrors []string

	// LastError is the diagnostic from the final attempt (the
	// OS-loader fallback). It is kept for backward compatibility
	// with callers that only inspected this field.
	LastError string

	// SymbolMissing is set when the library loaded but a required
	// export could not be resolved or registered.
	SymbolMissing string

	// RegisterError, when non-nil, is the underlying panic message
	// from purego.RegisterLibFunc. It distinguishes "symbol is not
	// exported by the DLL" from "purego does not support the
	// declared signature" -- both surface as a panic during
	// registration, but they require different fixes.
	RegisterError string
}

func (e *LoadError) Error() string {
	if e.SymbolMissing != "" {
		msg := fmt.Sprintf(
			"lingofuse: failed to register symbol %q",
			e.SymbolMissing,
		)
		if e.RegisterError != "" {
			msg += " (" + e.RegisterError + ")"
		}
		msg += "; this usually means either the DLL does not export " +
			"the symbol, or purego does not support the Go-side " +
			"signature (arrays, slices, and non-trivial structs in " +
			"argument or return positions are common causes)"
		return msg
	}
	msg := "lingofuse: failed to load the native library"

	// Print every explicit attempt with its diagnostic. This is
	// strictly more informative than the old behaviour, which kept
	// only the LAST attempt's error and could hide the actual cause
	// (for example, a present-but-wrong-architecture DLL in the
	// executable's directory, shadowed by a MISSING file on PATH).
	if len(e.Attempted) > 0 {
		msg += "; tried:"
		for i, p := range e.Attempted {
			msg += "\n  - " + p
			if i < len(e.AttemptErrors) && e.AttemptErrors[i] != "" {
				msg += "\n      error: " + e.AttemptErrors[i]
			}
		}
	}
	msg += "\nplace the platform library next to the executable, " +
		"in the current working directory, or on the system loader " +
		"search path (PATH on Windows, LD_LIBRARY_PATH on Linux, " +
		"DYLD_LIBRARY_PATH on macOS)"
	if e.LastError != "" {
		msg += "\nsystem-loader fallback error: " + e.LastError
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
	var attemptErrors []string
	var lastErr string

	// Try each explicit path first. Record EVERY failure, not just
	// the last one: the actual cause of a load failure is often
	// visible only on an earlier path (for example, the executable's
	// directory holds a wrong-architecture DLL, while the CWD entry
	// is simply missing).
	for _, path := range buildSearchPaths() {
		attempted = append(attempted, path)
		h, err := openLibrary(path)
		if err != nil {
			attemptErrors = append(attemptErrors, err.Error())
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
		Attempted:     attempted,
		AttemptErrors: attemptErrors,
		LastError:     lastErr,
	}
}

// ---------------------------------------------------------------------------
// Symbol resolution
// ---------------------------------------------------------------------------
//
// {!!!!!  PER-SYMBOL REGISTRATION  !!!!!}
// An earlier revision called purego.RegisterLibFunc in a single
// straight-line sequence, relying on a top-level defer/recover to
// convert a panic into a LoadError. That approach worked, but the
// resulting error message could not identify WHICH symbol had
// failed. On a 59-symbol table, that ambiguity turned a five-minute
// fix into a multi-hour hunt.
//
// This revision registers each symbol individually and records the
// exact name of the first one that fails, together with the panic
// message. The error message therefore names the offending symbol
// and distinguishes the two most likely causes:
//
//   - The DLL does not export the symbol.
//   - purego does not support the Go-side signature.
//
// Both manifest as a panic during RegisterLibFunc, so the recorded
// panic text is the only way to tell them apart.

// symbolBinding pairs a symbol's name with a pointer to the package
// variable that will receive the resolved function pointer.
type symbolBinding struct {
	name string
	ptr  any
}

// resolveAll resolves every one of the 59 exported symbols into the
// package-level function variables declared in bindings.go.
//
// On the first failure, resolution stops and a *LoadError is
// returned that names the offending symbol and the underlying panic
// message. This makes a signature mismatch trivially diagnosable.
func resolveAll(handle uintptr) error {
	bindings := []symbolBinding{
		// --- Data handle operations (12) ---
		{"LF_CreateData", &LF_CreateData},
		{"LF_CreateData_Permanent", &LF_CreateData_Permanent},
		{"LF_FreeData", &LF_FreeData},
		{"LF_GetBuffer", &LF_GetBuffer},
		{"LF_WriteBuffer", &LF_WriteBuffer},
		{"LF_ReadBuffer", &LF_ReadBuffer},
		{"LF_GetPos", &LF_GetPos},
		{"LF_SetPos", &LF_SetPos},
		{"LF_GetSize", &LF_GetSize},
		{"LF_SetSize", &LF_SetSize},
		{"LF_Get_P2P_UID", &LF_Get_P2P_UID},
		{"LF_Get_P2P_Name", &LF_Get_P2P_Name},

		// --- Application handle operations (5) ---
		{"LF_CreateApp", &LF_CreateApp},
		{"LF_FreeApp", &LF_FreeApp},
		{"LF_Generate_AppName", &LF_Generate_AppName},
		{"LF_Get_AppName", &LF_Get_AppName},
		{"LF_BindApp", &LF_BindApp},

		// --- API registration, app-bound (3) ---
		{"LF_RegisterCall", &LF_RegisterCall},
		{"LF_RegisterNotify", &LF_RegisterNotify},
		{"LF_Unregister", &LF_Unregister},

		// --- API registration, process-wide P2P (3) ---
		{"LF_Register_P2P_Call", &LF_Register_P2P_Call},
		{"LF_Register_P2P_Notify", &LF_Register_P2P_Notify},
		{"LF_Unregister_P2P", &LF_Unregister_P2P},

		// --- Local execution (2) ---
		{"LF_LocalCall", &LF_LocalCall},
		{"LF_LocalNotify", &LF_LocalNotify},

		// --- Network preparation (5) ---
		{"LF_ResetPrepare", &LF_ResetPrepare},
		{"LF_PrepareService", &LF_PrepareService},
		{"LF_PrepareClient", &LF_PrepareClient},
		{"LF_PrepareDone", &LF_PrepareDone},
		{"LF_ExitMainThread", &LF_ExitMainThread},

		// --- Remote invocation, app-name addressing (5) ---
		{"LF_Call", &LF_Call},
		{"LF_Async_Call", &LF_Async_Call},
		{"LF_Async_Sequenced_Call", &LF_Async_Sequenced_Call},
		{"LF_Notify", &LF_Notify},
		{"LF_Sequenced_Notify", &LF_Sequenced_Notify},

		// --- Remote invocation, UID addressing (5) ---
		{"LF_UID_Call", &LF_UID_Call},
		{"LF_UID_Async_Call", &LF_UID_Async_Call},
		{"LF_UID_Async_Sequenced_Call", &LF_UID_Async_Sequenced_Call},
		{"LF_UID_Notify", &LF_UID_Notify},
		{"LF_UID_Sequenced_Notify", &LF_UID_Sequenced_Notify},

		// --- Remote invocation, P2PName addressing (5) ---
		{"LF_P2PNAME_Call", &LF_P2PNAME_Call},
		{"LF_P2PNAME_Async_Call", &LF_P2PNAME_Async_Call},
		{"LF_P2PNAME_Async_Sequenced_Call", &LF_P2PNAME_Async_Sequenced_Call},
		{"LF_P2PNAME_Notify", &LF_P2PNAME_Notify},
		{"LF_P2PNAME_Sequenced_Notify", &LF_P2PNAME_Sequenced_Notify},

		// --- Queries (7) ---
		{"LF_CheckMainThread", &LF_CheckMainThread},
		{"LF_CheckApp", &LF_CheckApp},
		{"LF_CheckApi", &LF_CheckApi},
		{"LF_Check_UID", &LF_Check_UID},
		{"LF_Check_UID_Api", &LF_Check_UID_Api},
		{"LF_Check_P2PNAME", &LF_Check_P2PNAME},
		{"LF_Check_P2PNAME_Api", &LF_Check_P2PNAME_Api},

		// --- Runtime options (2) ---
		{"LF_SetOption", &LF_SetOption},
		{"LF_GetOption", &LF_GetOption},

		// --- Status and diagnostics (3) ---
		{"LF_GetStatusCount", &LF_GetStatusCount},
		{"LF_GetStatus", &LF_GetStatus},
		{"LF_PostStatus", &LF_PostStatus},

		// --- Network events (1) ---
		{"LF_Set_Network_Event", &LF_Set_Network_Event},

		// --- Shutdown (1) ---
		{"LF_Shutdown", &LF_Shutdown},
	}

	for _, b := range bindings {
		if errMsg := registerOne(handle, b); errMsg != "" {
			return &LoadError{
				SymbolMissing: b.name,
				RegisterError: errMsg,
			}
		}
	}
	return nil
}

// registerOne resolves a single symbol, returning an empty string on
// success or the recover() text on failure.
//
// {!!!!!  WHY PER-SYMBOL RECOVER  !!!!!}
// purego.RegisterLibFunc panics on any failure, and the panic text
// is the ONLY diagnostic it provides. Wrapping each call in its own
// recover lets us attribute the panic to a specific symbol, which is
// what makes the caller's error message actionable.
func registerOne(handle uintptr, b symbolBinding) (errMsg string) {
	defer func() {
		if r := recover(); r != nil {
			errMsg = fmt.Sprint(r)
		}
	}()
	purego.RegisterLibFunc(b.ptr, handle, b.name)
	return ""
}
