package test

import (
	"errors"
	"testing"

	"github.com/PassByYou888/LingoFuse/go/lingofuse"
)

func TestErrorCodeString(t *testing.T) {
	cases := []struct {
		code lingofuse.ErrorCode
		want string
	}{
		{lingofuse.ErrGeneric, "generic error"},
		{lingofuse.ErrLibraryLoadFailed, "library load failed"},
		{lingofuse.ErrNullHandle, "null handle"},
		{lingofuse.ErrInvalidArgument, "invalid argument"},
		{lingofuse.ErrWriteFailed, "write failed"},
		{lingofuse.ErrReadFailed, "read failed"},
		{lingofuse.ErrCallFailed, "call failed"},
		{lingofuse.ErrRegistrationFailed, "registration failed"},
		{lingofuse.ErrNotConnected, "not connected"},
		{lingofuse.ErrTimeout, "timeout"},
	}
	for _, c := range cases {
		if got := c.code.String(); got != c.want {
			t.Errorf("ErrorCode(%d).String() = %q, want %q",
				int(c.code), got, c.want)
		}
	}
}

func TestErrorIs(t *testing.T) {
	base := &lingofuse.Error{Code: lingofuse.ErrNullHandle, Message: "x"}

	same := &lingofuse.Error{Code: lingofuse.ErrNullHandle}
	if !errors.Is(base, same) {
		t.Fatal("errors.Is should match on the same code")
	}

	different := &lingofuse.Error{Code: lingofuse.ErrTimeout}
	if errors.Is(base, different) {
		t.Fatal("errors.Is should not match on different codes")
	}
}

func TestErrorUnwrap(t *testing.T) {
	cause := errors.New("underlying cause")
	top := &lingofuse.Error{
		Code:    lingofuse.ErrGeneric,
		Message: "wrapper",
		Cause:   cause,
	}
	if !errors.Is(top, cause) {
		t.Fatal("errors.Is should reach the cause via Unwrap")
	}
}

func TestNullHandleDetection(t *testing.T) {
	ensureLib(t)

	h, err := lingofuse.NewDataHandle("test_null_handle")
	if err != nil {
		t.Fatal(err)
	}
	h.Close()

	// Size on a closed handle must fail with ErrNullHandle.
	_, err = h.Size()
	if err == nil {
		t.Fatal("Size on a closed handle should fail")
	}

	var le *lingofuse.Error
	if !errors.As(err, &le) {
		t.Fatalf("error is not *lingofuse.Error: %T", err)
	}
	if le.Code != lingofuse.ErrNullHandle {
		t.Fatalf("code = %v, want ErrNullHandle", le.Code)
	}
}

func TestInvalidArgumentDetection(t *testing.T) {
	ensureLib(t)

	h, err := lingofuse.NewDataHandle("test_invalid_arg")
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	// Negative positions must be rejected with ErrInvalidArgument.
	err = h.SetPosition(-1)
	if err == nil {
		t.Fatal("SetPosition(-1) should fail")
	}
	var le *lingofuse.Error
	if !errors.As(err, &le) {
		t.Fatalf("error is not *lingofuse.Error: %T", err)
	}
	if le.Code != lingofuse.ErrInvalidArgument {
		t.Fatalf("code = %v, want ErrInvalidArgument", le.Code)
	}
}
