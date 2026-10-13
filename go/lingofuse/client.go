package lingofuse

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/PassByYou888/LingoFuse/go/sys"
)

// ---------------------------------------------------------------------------
// Client — the high-level facade
// ---------------------------------------------------------------------------
//
// Client pairs a LingoFuse process-wide connection with the three
// addressing modes and a default timeout. It is the recommended entry
// point for new programs:
//
//	client := lingofuse.MustConnect("Calc", "ipc:demo")
//	client.App("Calc").CallAsync("add", req, func(r AsyncResult) {
//	    // business code
//	})
//
// {!!!!!  ONE CONNECTION PER PROCESS  !!!!!}
// The LingoFuse framework is a process-global singleton: one
// simulated main thread, one client pool, one service pool per
// process. A Client is therefore NOT an independent connection.
// Multiple Client instances share the same underlying connection.
//
// The FIRST Connect call in a process performs the actual network
// setup (LF_PrepareClient + LF_PrepareDone). Subsequent Connect
// calls observe that the connection is already up and return
// immediately, ignoring the endpoint argument for setup purposes.
//
// This mirrors the C++ lingofuse::LibraryLoader and the Python C4
// client, both of which document the process-global nature of the
// framework as a first-class contract.
//
// {!!!!!  ENDPOINT OF THE FIRST CALL WINS  !!!!!}
// The endpoint passed to the first Connect determines the physical
// address of the process-wide connection. Subsequent Connect calls
// with a different endpoint do not fail; their value is recorded
// for diagnostics only. In practice this is the desired behaviour:
// a library loaded into a large application may be initialised by
// several independent subsystems, only one of which actually needs
// to choose the endpoint.
//
// {!!!!!  SHUTDOWN  !!!!!}
// Closing a Client does NOT tear down the process-wide connection.
// Use the package-level functions to release resources:
//
//	lingofuse.ExitMainThread()  -- stop the network loop, keep the
//	                               library loaded (fast restart)
//	lingofuse.Shutdown()        -- stop everything and unload the
//	                               library
//
// A Client has no Close method, by design: giving one would imply
// that the connection's lifetime is scoped to the Client, which is
// not true and would invite bugs when two Clients coexist.

// Client is a lightweight facade. It holds no native resources and
// can be freely copied, stored in structs, and shared across
// goroutines.
type Client struct {
	defaultAppName string
	endpoint       string
	timeout        time.Duration
}

// ClientOption adjusts a Client at construction time.
type ClientOption func(*clientOptions)

type clientOptions struct {
	timeout time.Duration
}

// WithTimeout sets the default per-call timeout.
//
// A value of zero or less means "use the framework default" (5000
// ms). The timeout applies to the synchronous Call family and to
// CallAsyncWithTimeout when no explicit timeout is passed.
func WithTimeout(d time.Duration) ClientOption {
	return func(o *clientOptions) { o.timeout = d }
}

// ---------------------------------------------------------------------------
// Global connection state
// ---------------------------------------------------------------------------
//
// The first Client constructed in a process performs the actual
// network setup. Subsequent constructions reuse the existing
// connection. Both the setup and the check are guarded by a mutex.
//
// The variables are package-private: the public API is Connect and
// IsConnected. The error from a failed setup is cached so that a
// caller diagnosing a connect failure can retrieve it later via
// LastConnectError.

var (
	clientGlobalMu    sync.Mutex
	clientGlobalReady bool
	clientGlobalErr   error
)

// Connect establishes (or attaches to) the process-wide LingoFuse
// connection, then returns a Client bound to defaultAppName.
//
// The first call in a process performs the actual network setup. It
// may block for up to Wait_Connection_Timeout milliseconds (default
// 30 000) while LF_PrepareDone waits for the client to come online.
// Configure that behaviour with SetOptWaitConnectionReadyOk and
// SetOptWaitConnectionTimeout BEFORE the first Connect.
//
// Subsequent calls in the same process return immediately, regardless
// of the endpoint argument, because the process-global connection is
// already established.
//
// Errors:
//
//	ErrInvalidArgument    -- defaultAppName or endpoint is empty
//	ErrLibraryLoadFailed  -- the native library could not be loaded
//	ErrGeneric            -- the native layer rejected the endpoint
//	                         (duplicate address) or PrepareDone
//	                         returned false
func Connect(defaultAppName, endpoint string, opts ...ClientOption) (*Client, error) {
	if defaultAppName == "" {
		return nil, newErr(ErrInvalidArgument,
			"Connect: defaultAppName must not be empty")
	}
	if endpoint == "" {
		return nil, newErr(ErrInvalidArgument,
			"Connect: endpoint must not be empty")
	}

	options := clientOptions{}
	for _, o := range opts {
		o(&options)
	}

	clientGlobalMu.Lock()
	defer clientGlobalMu.Unlock()

	if !clientGlobalReady {
		if err := connectOnce(endpoint); err != nil {
			clientGlobalErr = err
			return nil, err
		}
		clientGlobalReady = true
		clientGlobalErr = nil
	}

	return &Client{
		defaultAppName: defaultAppName,
		endpoint:       endpoint,
		timeout:        options.timeout,
	}, nil
}

// MustConnect is Connect with panic-on-error semantics, intended for
// use in package-level initialization or in main().
//
// Prefer Connect in library code so that the caller can decide how to
// handle a startup failure.
func MustConnect(defaultAppName, endpoint string, opts ...ClientOption) *Client {
	c, err := Connect(defaultAppName, endpoint, opts...)
	if err != nil {
		panic(fmt.Sprintf("lingofuse.MustConnect: %v", err))
	}
	return c
}

// connectOnce performs the actual process-global setup. It is called
// at most once per process, under clientGlobalMu.
func connectOnce(endpoint string) error {
	if err := sys.LoadLibrary(); err != nil {
		return wrapErr(ErrLibraryLoadFailed, err,
			"Connect: native library not available")
	}

	if err := ResetPrepare(); err != nil {
		return err
	}

	var scope sys.CStringScope
	addr := scope.Add(endpoint)
	rc := sys.LF_PrepareClient(addr, 0)
	scope.Release()
	if rc < 0 {
		return newErr(ErrGeneric,
			"Connect: LF_PrepareClient rejected endpoint %q "+
				"(duplicate address?)", endpoint)
	}

	ok, err := PrepareDone()
	if err != nil {
		return err
	}
	if !ok {
		// A second PrepareDone in the same process returns false
		// without an error. That cannot happen here because we gate
		// on clientGlobalReady, but the branch is kept defensive.
		return newErr(ErrGeneric,
			"Connect: LF_PrepareDone returned false")
	}
	return nil
}

// ---------------------------------------------------------------------------
// Client accessors
// ---------------------------------------------------------------------------

// DefaultAppName returns the App name this Client addresses by
// default. It is the value passed to Connect.
func (c *Client) DefaultAppName() string { return c.defaultAppName }

// Endpoint returns the endpoint recorded at construction. Note that
// this is the endpoint THIS Client was constructed with; it may
// differ from the endpoint of the process-wide connection if the
// Client was not the first one in the process.
func (c *Client) Endpoint() string { return c.endpoint }

// Timeout returns the default per-call timeout. A zero value means
// "use the framework default".
func (c *Client) Timeout() time.Duration { return c.timeout }

// ---------------------------------------------------------------------------
// Target constructors
// ---------------------------------------------------------------------------

// App returns a Target that addresses a logical App by name.
//
// Routing is LOCAL-FIRST: if the caller process itself hosts an App
// with the matching name and API, the call is serviced locally.
func (c *Client) App(name string) *AppTarget {
	return NewAppTarget(name)
}

// UID returns a Target that addresses a specific session by its
// 32-byte UID.
//
// See NewUIDTarget for how to obtain a UID (the "whoami" pattern).
func (c *Client) UID(uid sys.TP2P_UID) *UIDTarget {
	return NewUIDTarget(uid)
}

// P2P returns a Target that addresses a group of clients sharing a
// user-supplied P2P name.
//
// Routing is NOT local-first: the call is always forwarded to the
// server for dispatch.
func (c *Client) P2P(group string) *P2PNameTarget {
	return NewP2PNameTarget(group)
}

// DefaultTarget returns an AppTarget for this Client's default App
// name. It is a shorthand for c.App(c.DefaultAppName()).
func (c *Client) DefaultTarget() *AppTarget {
	return NewAppTarget(c.defaultAppName)
}

// ---------------------------------------------------------------------------
// Shortcut methods
// ---------------------------------------------------------------------------
//
// The methods below forward to the equivalent method on the Client's
// DefaultTarget, substituting the Client's default timeout where
// applicable. They exist so that a caller who is already holding a
// Client does not need to spell out the target for the common case
// of "call the default App".

// CallAsync is a shortcut for c.DefaultTarget().CallAsync(...).
func (c *Client) CallAsync(api string, payload any, cb func(AsyncResult)) error {
	return c.DefaultTarget().CallAsync(api, payload, cb)
}

// CallAsyncWithTimeout is a shortcut for
// c.DefaultTarget().CallAsyncWithTimeout(...).
func (c *Client) CallAsyncWithTimeout(
	api string,
	payload any,
	timeout time.Duration,
	cb func(AsyncResult),
) error {
	return c.DefaultTarget().CallAsyncWithTimeout(api, payload, timeout, cb)
}

// Call is a shortcut for c.DefaultTarget().Call(...). When timeoutMs
// is 0, the Client's default timeout is used; when that is also 0,
// the framework default (5000 ms) applies.
func (c *Client) Call(
	api string,
	payload any,
	timeoutMs uint64,
) (*DataHandle, error) {
	if timeoutMs == 0 {
		timeoutMs = c.defaultTimeoutMs()
	}
	return c.DefaultTarget().Call(api, payload, timeoutMs)
}

// CallCtx is a shortcut for c.DefaultTarget().CallCtx(...).
func (c *Client) CallCtx(
	ctx context.Context,
	api string,
	payload any,
) (*DataHandle, error) {
	return c.DefaultTarget().CallCtx(ctx, api, payload)
}

// Notify is a shortcut for c.DefaultTarget().Notify(...).
func (c *Client) Notify(api string, payload any) error {
	return c.DefaultTarget().Notify(api, payload)
}

// SequencedNotify is a shortcut for
// c.DefaultTarget().SequencedNotify(...).
func (c *Client) SequencedNotify(api string, payload any) error {
	return c.DefaultTarget().SequencedNotify(api, payload)
}

// defaultTimeoutMs converts the Client's default timeout to
// milliseconds, falling back to 0 (framework default) when unset.
func (c *Client) defaultTimeoutMs() uint64 {
	if c.timeout <= 0 {
		return 0
	}
	return uint64(c.timeout / time.Millisecond)
}

// ---------------------------------------------------------------------------
// Package-level introspection
// ---------------------------------------------------------------------------

// IsConnected reports whether the process-wide connection is up.
//
// This is a pure Go check: it does not consult the native library
// and does not perform any I/O. It returns true if and only if a
// successful Connect has completed in this process.
func IsConnected() bool {
	clientGlobalMu.Lock()
	defer clientGlobalMu.Unlock()
	return clientGlobalReady
}

// LastConnectError returns the error from the most recent failed
// Connect attempt, or nil if the connection is up.
//
// Useful for diagnostics: a caller that observes a nil Client from
// Connect can retrieve the precise failure here.
func LastConnectError() error {
	clientGlobalMu.Lock()
	defer clientGlobalMu.Unlock()
	return clientGlobalErr
}
