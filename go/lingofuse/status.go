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
// message, matching the historical behaviour of the C# binding.
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
// Health checks
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
// approximate 3-second propagation delay. Do not use this as an
// authoritative existence test for critical paths.
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
