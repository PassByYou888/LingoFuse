//go:build windows

package sys

import "syscall"

// openLibrary loads a Windows DLL by absolute path or bare name.
// The bare name is resolved against the OS loader search path
// (the directory of the executable, System32, and PATH).
func openLibrary(name string) (uintptr, error) {
	h, err := syscall.LoadLibrary(name)
	if err != nil {
		return 0, err
	}
	return uintptr(h), nil
}

// closeLibrary releases a DLL handle previously returned by
// openLibrary.
func closeLibrary(handle uintptr) {
	_ = syscall.FreeLibrary(syscall.Handle(handle))
}
