//go:build !windows

package sys

import "github.com/ebitengine/purego"

// openLibrary loads a shared object via the platform's dlopen.
// RTLD_NOW resolves all symbols at load time; RTLD_GLOBAL makes the
// loaded symbols visible to other libraries.
func openLibrary(name string) (uintptr, error) {
	return purego.Dlopen(name, purego.RTLD_NOW|purego.RTLD_GLOBAL)
}

// closeLibrary releases a handle previously returned by openLibrary.
func closeLibrary(handle uintptr) {
	purego.Dlclose(handle)
}
