package lingofuse.ffi;

import java.lang.foreign.AddressLayout;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.ValueLayout;

/**
 * Shared type definitions for the LingoFuse native binding.
 *
 * <p>This class declares:
 * <ul>
 *   <li>the value layouts used by every downcall signature
 *       (native pointers and the two integer widths);</li>
 *   <li>the {@link FunctionDescriptor} for each of the three callback
 *       prototypes declared in {@code LingoFuse.h}.</li>
 * </ul>
 *
 * <p>No instances of this class are ever created. All members are
 * static and immutable; the class is therefore thread-safe by
 * construction.
 *
 * <p>Handle types: {@code TDataHnd} and {@code TAppHnd} are both
 * {@code void*} in the C ABI. In FFM they are represented uniformly
 * as a {@link java.lang.foreign.MemorySegment} with an ADDRESS layout.
 * The RAII wrappers in the {@code lingofuse} package own the
 * semantic distinction; this layer does not need to.
 */
public final class NativeTypes {

    private NativeTypes() {
        // Utility class; no instances.
    }

    // ------------------------------------------------------------------
    // Value layouts
    // ------------------------------------------------------------------

    /**
     * Layout for a native pointer. Used for every handle and every
     * {@code const char*} / {@code void*} parameter.
     *
     * <p>{@code ValueLayout.ADDRESS} has type {@link AddressLayout},
     * not {@code OfAddress}; there is no such type in the FFM API.
     */
    public static final AddressLayout POINTER = ValueLayout.ADDRESS;

    /**
     * Layout for a C {@code int}. Used by functions that return a
     * status code or a boolean.
     */
    public static final ValueLayout.OfInt C_INT = ValueLayout.JAVA_INT;

    /**
     * Layout for a C {@code int64_t}. Used by every position, size,
     * and byte-count parameter and return value.
     */
    public static final ValueLayout.OfLong C_INT64 = ValueLayout.JAVA_LONG;

    /**
     * Layout for a C {@code uint64_t}. Used by the timeout parameter
     * of {@code LF_Call}.
     */
    public static final ValueLayout.OfLong C_UINT64 = ValueLayout.JAVA_LONG;

    // ------------------------------------------------------------------
    // Callback prototypes
    // ------------------------------------------------------------------
    //
    // Every callback is declared with the C calling convention in the
    // header (LF_CDECL). FFM's Linker.nativeLinker() applies the
    // platform's default C convention, which matches LF_CDECL on
    // every supported 64-bit platform.
    //
    // The three descriptors below are used with Linker.upcallStub to
    // create Java-to-native trampolines.

    /**
     * {@code void (*)(void* trigger, void* input, void* output)}
     *
     * <p>The Call-mode callback prototype. All three arguments are
     * raw pointers. The library passes them to the upcall stub and
     * expects the Java code to read the request from {@code input}
     * and write the response to {@code output}.
     *
     * <p>Lifetime: the {@code input} and {@code output} handles are
     * valid only for the duration of the callback invocation. The
     * library releases them as soon as the callback returns.
     */
    public static final FunctionDescriptor LF_CALL_EVENT = FunctionDescriptor.ofVoid(
            ValueLayout.ADDRESS, // void* trigger
            ValueLayout.ADDRESS, // void* input
            ValueLayout.ADDRESS  // void* output
    );

    /**
     * {@code void (*)(void* trigger, void* input)}
     *
     * <p>The Notify-mode callback prototype. The library passes a
     * request handle and expects the Java code to consume it. No
     * output handle is provided.
     */
    public static final FunctionDescriptor LF_NOTIFY_EVENT = FunctionDescriptor.ofVoid(
            ValueLayout.ADDRESS, // void* trigger
            ValueLayout.ADDRESS  // void* input
    );

    /**
     * {@code void (*)(const char* addr)}
     *
     * <p>The network event callback prototype. The {@code addr}
     * argument is a UTF-8, NUL-terminated C string whose backing
     * buffer is freed by the library as soon as the callback returns.
     */
    public static final FunctionDescriptor LF_NETWORK_EVENT = FunctionDescriptor.ofVoid(
            ValueLayout.ADDRESS   // const char* addr
    );
}