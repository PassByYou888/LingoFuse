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
 *   <li>the {@link FunctionDescriptor} for each of the four callback
 *       prototypes declared in the C ABI.</li>
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
 *
 * <h2>UID type: argument role versus return role</h2>
 *
 * <p>The C ABI's {@code TP2P_UID___} is {@code array[0..31] of Byte}.
 * That single Pascal type plays TWO different roles, and each role
 * requires a DIFFERENT FFM representation:
 *
 * <dl>
 *   <dt>As an argument (for example, the first parameter of
 *       {@code LF_UID_Call})</dt>
 *   <dd>
 *     In cdecl, an array parameter decays to a pointer. The FFM
 *     representation is therefore a single {@link AddressLayout} that
 *     receives a {@link java.lang.foreign.MemorySegment} pointing at
 *     32 bytes of UID data. The caller is responsible for allocating
 *     the 32 bytes and copying the UID into them.
 *   </dd>
 *   <dt>As a return value (only {@code LF_Get_P2P_UID} does this)</dt>
 *   <dd>
 *     The C ABI returns a POINTER to the 32-byte UID
 *     ({@code PP2P_UID___ = ^TUID___}), NOT the value itself. The FFM
 *     representation is again a single {@link AddressLayout}. The
 *     caller must copy the 32 bytes immediately and must NOT free
 *     the pointer (the framework releases it after approximately
 *     5 seconds).
 *   </dd>
 * </dl>
 *
 * <p>Both roles happen to use {@code ADDRESS} in FFM, but they mean
 * different things. Do not conflate them. The higher-level wrapper
 * {@code DataHandle.getP2pUid()} documents the return-role contract
 * in full.
 */
public final class NativeTypes {

    private NativeTypes() {
        // Utility class; no instances.
    }

    // ------------------------------------------------------------------
    // Value layouts
    // ------------------------------------------------------------------

    /**
     * Layout for a native pointer. Used for every handle, every
     * {@code const char*} / {@code void*} parameter, the UID argument
     * of every {@code LF_UID_*} call, and the return value of
     * {@code LF_Get_P2P_UID}.
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
     * of every call primitive.
     */
    public static final ValueLayout.OfLong C_UINT64 = ValueLayout.JAVA_LONG;

    // ------------------------------------------------------------------
    // Well-known sizes
    // ------------------------------------------------------------------

    /**
     * The size, in bytes, of a LingoFuse UID.
     *
     * <p>Every {@code LF_UID_*} argument expects exactly this many
     * bytes. The higher-level wrappers ({@code Framework.uidCall},
     * {@code UIDTarget}) validate this length at the entry point.
     */
    public static final long UID_BYTES = 32L;

    // ------------------------------------------------------------------
    // Callback prototypes
    // ------------------------------------------------------------------
    //
    // Every callback is declared with the C calling convention in the
    // header (LF_CDECL). FFM's Linker.nativeLinker() applies the
    // platform's default C convention, which matches LF_CDECL on
    // every supported 64-bit platform.
    //
    // The four descriptors below are used with Linker.upcallStub to
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
    public static final FunctionDescriptor LF_CALL_EVENT =
            FunctionDescriptor.ofVoid(
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
    public static final FunctionDescriptor LF_NOTIFY_EVENT =
            FunctionDescriptor.ofVoid(
                    ValueLayout.ADDRESS, // void* trigger
                    ValueLayout.ADDRESS  // void* input
            );

    /**
     * {@code void (*)(void* Data, TDataHnd Result_)}
     *
     * <p>The asynchronous-call result callback prototype, used by
     * {@code LF_Async_Call}, {@code LF_Async_Sequenced_Call}, and all
     * of their {@code LF_UID_*} and {@code LF_P2PNAME_*} variants.
     *
     * <p>Arguments:
     * <ul>
     *   <li>{@code Data} - the opaque pointer the caller passed at the
     *       call site. The library neither owns nor frees it. In the
     *       Java binding this argument is typically
     *       {@link java.lang.foreign.MemorySegment#NULL}, because the
     *       Java layer uses upcall stubs with an inserted holder
     *       argument instead.</li>
     *   <li>{@code Result_} - a DataHandle owned by the framework. The
     *       framework releases it IMMEDIATELY after this callback
     *       returns (Pascal side:
     *       {@code TLF_Async_Call_Bridge.Do_Th} calls
     *       {@code TLF_Data.Free_Data} on the result handle right
     *       after invoking {@code OnResult}). The callback MUST NOT
     *       call {@code LF_FreeData} on it, and MUST NOT retain the
     *       pointer beyond its own return.</li>
     * </ul>
     *
     * <p>Execution context: a native worker thread (NOT the calling
     * thread and NOT the simulated main thread). The callback MUST
     * NOT block, and MUST NOT call any blocking LingoFuse function.
     */
    public static final FunctionDescriptor LF_ASYNC_CALL_ON_RESULT =
            FunctionDescriptor.ofVoid(
                    ValueLayout.ADDRESS, // void* Data (opaque user_data)
                    ValueLayout.ADDRESS  // TDataHnd Result_
            );

    /**
     * {@code void (*)(const char* addr)}
     *
     * <p>The network event callback prototype. The {@code addr}
     * argument is a UTF-8, NUL-terminated C string whose backing
     * buffer is freed by the library as soon as the callback returns.
     */
    public static final FunctionDescriptor LF_NETWORK_EVENT =
            FunctionDescriptor.ofVoid(
                    ValueLayout.ADDRESS   // const char* addr
            );
}