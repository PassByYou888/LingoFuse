// Package lingofuse is the high-level, RAII-style Go binding for the
// LingoFuse distributed RPC framework. It mirrors the C++
// lingofuse::DataHandle / lingofuse::App namespace and the Rust
// data_handle / app_handle modules.
//
// All public types in this package are safe to use from a single
// goroutine. Cross-goroutine sharing of a single DataHandle for
// writes is not supported; the native library itself requires
// serialisation on the write path.
package lingofuse

import "fmt"

// ErrorCode categorises a LingoFuse failure. The set mirrors the
// C++ lingofuse::ErrorCode and the Rust error::ErrorCode.
type ErrorCode int

const (
	// ErrGeneric is an unclassified failure.
	ErrGeneric ErrorCode = iota

	// ErrLibraryLoadFailed means the native library could not be
	// loaded or a required export was missing.
	ErrLibraryLoadFailed

	// ErrNullHandle means an operation was attempted on a nil or
	// already-closed handle.
	ErrNullHandle

	// ErrInvalidArgument means a caller-supplied argument failed
	// validation (interior NUL in a C string, negative size, ...).
	ErrInvalidArgument

	// ErrWriteFailed means a write returned fewer bytes than
	// requested.
	ErrWriteFailed

	// ErrReadFailed means an exact-read returned fewer bytes than
	// requested.
	ErrReadFailed

	// ErrCallFailed means a remote call returned a null handle. The
	// C ABI documents this as never happening for LF_Call; a null
	// here indicates a deeper transport failure.
	ErrCallFailed

	// ErrRegistrationFailed means register_call / register_notify
	// was rejected by the native layer. Almost always a duplicate
	// API name.
	ErrRegistrationFailed

	// ErrNotConnected means an operation required the framework to
	// be running but it is not.
	ErrNotConnected

	// ErrTimeout means a remote call timed out. Note that the C ABI
	// does not report timeouts as errors directly; it returns a
	// size-0 handle. Framework.TryCall converts an empty response
	// into ErrTimeout.
	ErrTimeout
)

func (c ErrorCode) String() string {
	switch c {
	case ErrGeneric:
		return "generic error"
	case ErrLibraryLoadFailed:
		return "library load failed"
	case ErrNullHandle:
		return "null handle"
	case ErrInvalidArgument:
		return "invalid argument"
	case ErrWriteFailed:
		return "write failed"
	case ErrReadFailed:
		return "read failed"
	case ErrCallFailed:
		return "call failed"
	case ErrRegistrationFailed:
		return "registration failed"
	case ErrNotConnected:
		return "not connected"
	case ErrTimeout:
		return "timeout"
	default:
		return fmt.Sprintf("unknown error code %d", int(c))
	}
}

// Error is the single error type produced by this package. It
// implements the standard error interface and supports errors.Unwrap.
type Error struct {
	// Code categorises the failure.
	Code ErrorCode

	// Message is the human-readable description, without the source
	// chain.
	Message string

	// Cause, when non-nil, is the underlying error.
	Cause error
}

func (e *Error) Error() string {
	if e == nil {
		return "<nil>"
	}
	return fmt.Sprintf("%s: %s", e.Code, e.Message)
}

// Unwrap returns the underlying cause, if any.
func (e *Error) Unwrap() error { return e.Cause }

// Is supports errors.Is(err, target) when target is an *Error with
// the same Code.
func (e *Error) Is(target error) bool {
	t, ok := target.(*Error)
	if !ok {
		return false
	}
	return e.Code == t.Code
}

// ---------------------------------------------------------------------------
// Internal constructors
// ---------------------------------------------------------------------------

func newErr(code ErrorCode, format string, args ...any) *Error {
	return &Error{Code: code, Message: fmt.Sprintf(format, args...)}
}

func wrapErr(code ErrorCode, cause error, format string, args ...any) *Error {
	return &Error{
		Code:    code,
		Message: fmt.Sprintf(format, args...),
		Cause:   cause,
	}
}
