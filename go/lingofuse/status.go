package lingofuse

import (
	"github.com/PassByYou888/LingoFuse/go/sys"
)

// ---------------------------------------------------------------------------
// Status queue
// ---------------------------------------------------------------------------
//
// The native library maintains a bounded FIFO of log messages, up to
// 1000 entries. Older entries are dropped when the buffer is full.
//
// The queue is processed by the native simulated main thread. Before
// PrepareDone, the queue may be empty or contain stale data.
// Injection is NOT subject to the same restriction: PostStatus
// queues the message even when the main thread is not yet running.

// GetStatusCount returns the number of pending log messages.
func GetStatusCount() (int, error) {
	if err := sys.LoadLibrary(); err != nil {
		return 0, wrapErr(ErrLibraryLoadFailed, err,
			"GetStatusCount: native library not available")
	}
	return int(sys.LF_GetStatusCount()), nil
}

// GetStatus retrieves the next log message. Returns an empty string
// when the queue is empty.
//
// The native function returns a pointer into a process-wide static
// buffer that the next call overwrites. This wrapper copies the
// string immediately, so the returned value is safe to hold.
func GetStatus() (string, error) {
	if err := sys.LoadLibrary(); err != nil {
		return "", wrapErr(ErrLibraryLoadFailed, err,
			"GetStatus: native library not available")
	}
	return sys.GoString(sys.LF_GetStatus()), nil
}

// DrainStatus retrieves up to maxMessages pending status messages in
// FIFO order. Stops early when the native queue returns an empty
// message.
//
// A maxMessages value of 0 returns an empty slice without touching
// the queue.
func DrainStatus(maxMessages int) ([]string, error) {
	if maxMessages < 0 {
		return nil, newErr(ErrInvalidArgument,
			"DrainStatus: maxMessages must be non-negative, got %d",
			maxMessages)
	}
	if maxMessages == 0 {
		return []string{}, nil
	}
	pending, err := GetStatusCount()
	if err != nil {
		return nil, err
	}
	if pending <= 0 {
		return []string{}, nil
	}
	count := pending
	if count > maxMessages {
		count = maxMessages
	}
	out := make([]string, 0, count)
	for i := 0; i < count; i++ {
		msg, err := GetStatus()
		if err != nil {
			return out, err
		}
		if msg == "" {
			break
		}
		out = append(out, msg)
	}
	return out, nil
}

// PostStatus injects a custom log message into the status queue.
//
// The message is queued even when the simulated main thread is not
// yet running. The queue is bounded at 1000 entries.
func PostStatus(message string) error {
	if err := sys.LoadLibrary(); err != nil {
		return wrapErr(ErrLibraryLoadFailed, err,
			"PostStatus: native library not available")
	}
	var scope sys.CStringScope
	msg := scope.Add(message)
	sys.LF_PostStatus(msg)
	scope.Release()
	return nil
}

// ---------------------------------------------------------------------------
// Health checks — App name addressing
// ---------------------------------------------------------------------------

// CheckMainThread reports whether the simulated main thread is
// running.
func CheckMainThread() (bool, error) {
	if err := sys.LoadLibrary(); err != nil {
		return false, wrapErr(ErrLibraryLoadFailed, err,
			"CheckMainThread: native library not available")
	}
	return sys.LF_CheckMainThread() != 0, nil
}

// CheckApp reports whether an application with the given name is
// available on the mesh.
//
// The lookup uses a local cache updated by network broadcasts with an
// approximate 3-second propagation delay.
func CheckApp(appName string) (bool, error) {
	if err := sys.LoadLibrary(); err != nil {
		return false, wrapErr(ErrLibraryLoadFailed, err,
			"CheckApp: native library not available")
	}
	var scope sys.CStringScope
	name := scope.Add(appName)
	ok := sys.LF_CheckApp(name) != 0
	scope.Release()
	return ok, nil
}

// CheckApi reports whether the named API is available for the given
// application. Same cache-based caveat as CheckApp.
func CheckApi(appName, apiName string) (bool, error) {
	if err := sys.LoadLibrary(); err != nil {
		return false, wrapErr(ErrLibraryLoadFailed, err,
			"CheckApi: native library not available")
	}
	var scope sys.CStringScope
	app := scope.Add(appName)
	api := scope.Add(apiName)
	ok := sys.LF_CheckApi(app, api) != 0
	scope.Release()
	return ok, nil
}

// ---------------------------------------------------------------------------
// Health checks — UID addressing
// ---------------------------------------------------------------------------
//
// {!!!!!  UID HERE IS AN ARGUMENT VALUE, NOT SIDE DATA  !!!!!}
// The UID passed to CheckUID / CheckUIDApi is a VALUE the caller
// already possesses: typically the result of a prior "whoami" probe
// or an out-of-band discovery mechanism.
//
// {!!!!!  UID IS PASSED BY POINTER  !!!!!}
// The C ABI passes the 32-byte UID by reference. purego does not
// support struct arguments on Windows amd64, so the FFI layer
// declares the parameter as `*sys.TP2P_UID` and this wrapper takes
// the address of a local copy. See sys/bindings.go for the rationale.
//
// Like CheckApp / CheckApi, the four functions below consult a
// locally cached view of the mesh with a ~3-second propagation delay.

// CheckUID reports whether a client with the given UID is currently
// known to the mesh (locally or via the cached remote view).
func CheckUID(uid sys.TP2P_UID) (bool, error) {
	if err := sys.LoadLibrary(); err != nil {
		return false, wrapErr(ErrLibraryLoadFailed, err,
			"CheckUID: native library not available")
	}
	localUID := uid
	return sys.LF_Check_UID(&localUID) != 0, nil
}

// CheckUIDApi reports whether a client with the given UID exposes
// the named API.
func CheckUIDApi(uid sys.TP2P_UID, apiName string) (bool, error) {
	if err := sys.LoadLibrary(); err != nil {
		return false, wrapErr(ErrLibraryLoadFailed, err,
			"CheckUIDApi: native library not available")
	}
	var scope sys.CStringScope
	api := scope.Add(apiName)
	localUID := uid
	ok := sys.LF_Check_UID_Api(&localUID, api) != 0
	scope.Release()
	return ok, nil
}

// ---------------------------------------------------------------------------
// Health checks — P2PName addressing
// ---------------------------------------------------------------------------

// CheckP2PName reports whether at least one client has the given P2P
// group name.
func CheckP2PName(p2pName string) (bool, error) {
	if err := sys.LoadLibrary(); err != nil {
		return false, wrapErr(ErrLibraryLoadFailed, err,
			"CheckP2PName: native library not available")
	}
	var scope sys.CStringScope
	name := scope.Add(p2pName)
	ok := sys.LF_Check_P2PNAME(name) != 0
	scope.Release()
	return ok, nil
}

// CheckP2PNameApi reports whether at least one client in the given
// P2P group exposes the named API.
func CheckP2PNameApi(p2pName, apiName string) (bool, error) {
	if err := sys.LoadLibrary(); err != nil {
		return false, wrapErr(ErrLibraryLoadFailed, err,
			"CheckP2PNameApi: native library not available")
	}
	var scope sys.CStringScope
	group := scope.Add(p2pName)
	api := scope.Add(apiName)
	ok := sys.LF_Check_P2PNAME_Api(group, api) != 0
	scope.Release()
	return ok, nil
}
