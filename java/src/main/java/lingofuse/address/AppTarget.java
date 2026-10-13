package lingofuse.address;

import lingofuse.DataHandle;
import lingofuse.Framework;
import lingofuse.ffi.NativeCall;
import lingofuse.ffi.NativeMethods;

import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.util.Objects;

/**
 * Addresses a logical App by name.
 *
 * <p>Routing is LOCAL-FIRST: if the caller process itself hosts an
 * App with the matching name and the requested API, the call is
 * serviced locally without touching the network.
 *
 * <p>The App name is passed to the C ABI as the first argument of
 * {@code LF_Call} / {@code LF_Async_Call} / {@code LF_Notify} /
 * {@code LF_Sequenced_Notify}. The API name is carried by the request
 * {@link DataHandle}.
 */
public final class AppTarget extends Target {

    /** The default timeout used when the caller does not supply one. */
    public static final long DEFAULT_TIMEOUT_MS = 5000L;

    private final String appName;

    /**
     * Creates an AppTarget with the default timeout.
     *
     * @param appName the target App name; must not be null
     */
    public AppTarget(String appName) {
        this(appName, DEFAULT_TIMEOUT_MS);
    }

    /**
     * Creates an AppTarget with an explicit default timeout.
     *
     * @param appName          the target App name; must not be null
     * @param defaultTimeoutMs the default timeout in milliseconds
     */
    public AppTarget(String appName, long defaultTimeoutMs) {
        super(defaultTimeoutMs);
        this.appName = Objects.requireNonNull(appName,
                "appName must not be null");
    }

    /** Returns the App name this target addresses. */
    public String appName() {
        return appName;
    }

    // ==================================================================
    // Subclass hook implementations
    // ==================================================================

    @Override
    protected DataHandle rawCall(DataHandle param, long timeoutMs) {
        return Framework.call(appName, param, timeoutMs);
    }

    @Override
    protected int rawAsyncCall(DataHandle param, MemorySegment stub) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment nameSeg = arena.allocateFrom(appName);
            return NativeCall.callInt(
                    NativeMethods.LF_Async_Call,
                    nameSeg,
                    param.raw(),
                    MemorySegment.NULL,
                    stub);
        }
    }

    @Override
    protected int rawAsyncSequencedCall(DataHandle param, MemorySegment stub) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment nameSeg = arena.allocateFrom(appName);
            return NativeCall.callInt(
                    NativeMethods.LF_Async_Sequenced_Call,
                    nameSeg,
                    param.raw(),
                    MemorySegment.NULL,
                    stub);
        }
    }

    @Override
    protected void rawNotify(DataHandle param) {
        Framework.notify(appName, param);
    }

    @Override
    protected void rawSequencedNotify(DataHandle param) {
        Framework.sequencedNotify(appName, param);
    }

    @Override
    public String describe() {
        return "app(" + appName + ")";
    }

    // ==================================================================
    // Value semantics
    // ==================================================================

    @Override
    public String toString() {
        return "AppTarget(" + appName + ")";
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) {
            return true;
        }
        if (!(o instanceof AppTarget other)) {
            return false;
        }
        return appName.equals(other.appName);
    }

    @Override
    public int hashCode() {
        return appName.hashCode();
    }
}