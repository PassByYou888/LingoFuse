package lingofuse;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import lingofuse.errors.LingoFuseException;
import lingofuse.errors.LingoFuseObjectDisposedException;

import java.nio.charset.StandardCharsets;
import java.util.Objects;

/**
 * Unified JSON and string I/O for LingoFuse data handles.
 *
 * <p>This class is the single place in the Java toolchain where
 * Java objects are converted to, and from, the bytes carried by a
 * {@link DataHandle}. Every service that touches a {@code DataHandle}
 * should use the helpers defined here instead of calling
 * {@code DataHandle.writeBytes} / {@code readBytes} /
 * {@code ObjectMapper} directly.
 *
 * <h2>Wire format</h2>
 *
 * <p>A JSON payload on a data handle is:
 *
 * <pre>
 * [UTF-8 encoded JSON text][NUL byte]
 * </pre>
 *
 * <p>A plain-text payload uses the same framing:
 *
 * <pre>
 * [UTF-8 text][NUL byte]
 * </pre>
 *
 * <p>A raw binary payload uses:
 *
 * <pre>
 * [arbitrary bytes][NUL byte]
 * </pre>
 *
 * <p>The receiving side ({@link #readString(DataHandle)},
 * {@link #readStringBytes(DataHandle)}, {@link #readJson(DataHandle)})
 * is fault-tolerant: if no NUL is found before the end of the buffer,
 * the entire remaining buffer is consumed. This makes the reader
 * tolerant of payloads that arrive from an HTTP bridge or any other
 * producer that does not append a NUL.
 *
 * <h2>JSON serialization policy</h2>
 *
 * <p>Every JSON string produced by this toolchain goes through
 * {@link #dumpsJson(Object)}. That method is the single source of
 * truth for the serialization policy. Its three properties are:
 *
 * <ul>
 *   <li>Compact output, no indentation, no trailing newline.
 *       This is Jackson's default behaviour.</li>
 *   <li>Non-ASCII characters emitted as literal UTF-8, not as
 *       {@code \\uXXXX} escapes. This is Jackson's default
 *       behaviour: {@code JsonWriteFeature.ESCAPE_NON_ASCII} is off
 *       by default, and the subsequent {@code String.getBytes(UTF_8)}
 *       emits the literal code points.</li>
 *   <li>Unknown types are rejected. Unlike Python's {@code default=str}
 *       fallback, this binding does NOT silently coerce arbitrary
 *       objects to strings. A caller that wants a custom type
 *       serialized must either make it Jackson-serializable or
 *       pre-convert it to a {@link JsonNode}. This is the same design
 *       decision taken by the C# binding.</li>
 * </ul>
 *
 * <p>The returned {@code String} does NOT include a trailing NUL
 * byte. Callers that want to write it to a data handle with the
 * required NUL terminator should use {@link #writeJson(DataHandle, Object)}
 * or {@link #writeString(DataHandle, String)} instead.
 *
 * <h2>JSON deserialization policy</h2>
 *
 * <p>{@link #loadsJson(String, Class)} and
 * {@link #readJson(DataHandle, Class)} are strict. Any syntax error
 * raises {@link LingoFuseException}.
 *
 * <h2>Thread safety</h2>
 *
 * <p>All helpers are stateless with respect to the handle. The
 * internal {@link ObjectMapper} is thread-safe by Jackson's contract.
 * Concurrent access to the SAME {@code DataHandle} must still be
 * serialized by the caller, matching the contract documented in
 * {@link DataHandle}.
 *
 * <h2>Error handling</h2>
 *
 * <p>All failures throw {@link LingoFuseException} or one of its
 * subclasses. Argument validation errors use the standard Java
 * exceptions ({@link NullPointerException}, {@link IllegalArgumentException}).
 * The {@code try*} family returns a {@link DataHandle.ReadResult}
 * instead of throwing for the recoverable cases.
 */
public final class LfIo {

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------

    /** The NUL byte used as the string terminator on the wire. */
    public static final byte NUL_BYTE = 0x00;

    /**
     * The single JSON codec instance used by every method in this
     * class. {@link ObjectMapper} is thread-safe once configured.
     *
     * <p>Default configuration is deliberate:
     * <ul>
     *   <li>No pretty-printing. {@code writeValueAsString} returns
     *       compact JSON.</li>
     *   <li>No ASCII escaping. Non-ASCII characters are emitted as
     *       literal Unicode code points. This matches the toolchain
     *       contract that no {@code \\uXXXX} escape ever appears on
     *       the wire.</li>
     *   <li>No automatic inclusion of null-valued properties beyond
     *       what the caller's type declares. Standard Jackson
     *       semantics.</li>
     * </ul>
     */
    private static final ObjectMapper MAPPER = new ObjectMapper();

    private LfIo() {
        // Utility class; no instances.
    }

    // ==================================================================
    // JSON serialization policy
    // ==================================================================

    /**
     * Serializes {@code obj} to a compact UTF-8 JSON string.
     *
     * <p>Policy:
     * <ul>
     *   <li>Compact output: no indentation, no trailing newline.</li>
     *   <li>Non-ASCII characters stay literal. This is the single
     *       most important property: it makes the output byte-identical
     *       to what the Python, C++, C#, and JavaScript bindings
     *       produce for the same logical value.</li>
     * </ul>
     *
     * <p>The returned string does NOT include a trailing NUL byte.
     *
     * @param obj the value to serialize; may be null, which produces
     *            the four-byte literal {@code null}
     * @return the compact UTF-8 JSON text
     * @throws LingoFuseException if the value cannot be serialized
     */
    public static String dumpsJson(Object obj) {
        try {
            return MAPPER.writeValueAsString(obj);
        } catch (JsonProcessingException e) {
            String typeName = (obj == null)
                    ? "null"
                    : obj.getClass().getName();
            throw new LingoFuseException(
                    "JSON serialization failed for type '" + typeName
                            + "': " + e.getMessage(),
                    e);
        }
    }

    /**
     * Parses a UTF-8 JSON string into a tree of {@link JsonNode}.
     *
     * <p>The input may contain leading or trailing whitespace. A
     * UTF-8 BOM is NOT skipped; strip it yourself if you need to
     * accept BOM-prefixed input.
     *
     * @param text the JSON document; must not be null
     * @return the parsed {@link JsonNode} tree
     * @throws NullPointerException if {@code text} is null
     * @throws LingoFuseException   if the text is not valid JSON
     */
    public static JsonNode loadsJson(String text) {
        Objects.requireNonNull(text, "text must not be null");
        try {
            return MAPPER.readTree(text);
        } catch (JsonProcessingException e) {
            throw new LingoFuseException(
                    "Invalid JSON: " + e.getOriginalMessage(), e);
        }
    }

    /**
     * Parses a UTF-8 JSON string into an instance of the given type.
     *
     * @param text  the JSON document; must not be null
     * @param clazz the target type; must not be null
     * @param <T>   the target type parameter
     * @return the deserialized value
     * @throws NullPointerException if either argument is null
     * @throws LingoFuseException   if the text is not valid JSON, or
     *                              cannot be materialized as {@code T}
     */
    public static <T> T loadsJson(String text, Class<T> clazz) {
        Objects.requireNonNull(text, "text must not be null");
        Objects.requireNonNull(clazz, "clazz must not be null");
        try {
            return MAPPER.readValue(text, clazz);
        } catch (JsonProcessingException e) {
            throw new LingoFuseException(
                    "Invalid JSON for type '" + clazz.getName() + "': "
                            + e.getOriginalMessage(),
                    e);
        }
    }

    // ==================================================================
    // String I/O
    // ==================================================================

    /**
     * Writes {@code value} as UTF-8 bytes, followed by a NUL
     * terminator.
     *
     * <p>An empty string is written as a single NUL byte, matching
     * the wire protocol convention for empty strings.
     *
     * @param handle the target data handle; must not be null
     * @param value  the UTF-8 text; must not be null
     * @throws NullPointerException             if either argument is null
     * @throws LingoFuseObjectDisposedException if the handle has been
     *                                          closed
     * @throws lingofuse.errors.LingoFuseIoException
     *                                          if the native layer
     *                                          accepts fewer bytes than
     *                                          requested
     */
    public static void writeString(DataHandle handle, String value) {
        Objects.requireNonNull(handle, "handle must not be null");
        Objects.requireNonNull(value, "value must not be null");
        handle.writeString(value);
    }

    /**
     * Reads a UTF-8 string from the current cursor, stopping at the
     * first NUL byte. When no NUL is found, all remaining bytes are
     * consumed and returned.
     *
     * @param handle the source data handle; must not be null
     * @return the decoded string; empty at end-of-buffer or when the
     *         first byte is a NUL
     * @throws NullPointerException             if {@code handle} is null
     * @throws LingoFuseObjectDisposedException if the handle has been
     *                                          closed
     */
    public static String readString(DataHandle handle) {
        Objects.requireNonNull(handle, "handle must not be null");
        return handle.readString();
    }

    // ==================================================================
    // Byte I/O
    // ==================================================================

    /**
     * Writes raw bytes followed by a NUL terminator.
     *
     * <p>The bytes are written verbatim; embedded NUL bytes are
     * preserved.
     *
     * @param handle the target data handle; must not be null
     * @param data   the source bytes; must not be null; may be empty
     * @throws NullPointerException             if either argument is null
     * @throws LingoFuseObjectDisposedException if the handle has been
     *                                          closed
     * @throws lingofuse.errors.LingoFuseIoException
     *                                          if the native layer
     *                                          accepts fewer bytes than
     *                                          requested
     */
    public static void writeStringBytes(DataHandle handle, byte[] data) {
        Objects.requireNonNull(handle, "handle must not be null");
        Objects.requireNonNull(data, "data must not be null");

        if (data.length > 0) {
            handle.writeBytes(data);
        }
        handle.writeBytes(new byte[]{NUL_BYTE});
    }

    /**
     * Reads raw bytes from the handle, stopping at the first NUL.
     *
     * <p>Unlike {@link #readAllBytes(DataHandle)}, which consumes the
     * entire remaining buffer, this stops at the NUL that
     * {@link #writeString(DataHandle, String)} /
     * {@link #writeJson(DataHandle, Object)} append. The bytes are
     * returned undecoded, so the caller can inspect or forward them
     * without a UTF-8 round-trip.
     *
     * <p>This is the accessor to use inside a bridge or proxy that
     * forwards a payload unchanged to a downstream consumer.
     *
     * @param handle the source data handle; must not be null
     * @return the bytes before the NUL; empty when the cursor is at
     *         or past the end, or when the first byte is a NUL
     * @throws NullPointerException             if {@code handle} is null
     * @throws LingoFuseObjectDisposedException if the handle has been
     *                                          closed
     */
    public static byte[] readStringBytes(DataHandle handle) {
        Objects.requireNonNull(handle, "handle must not be null");

        long start = handle.position();
        long total = handle.size();
        if (start >= total) {
            return new byte[0];
        }

        java.lang.foreign.MemorySegment buffer = handle.getBufferPointer();
        if (buffer == null || buffer.address() == 0L) {
            return new byte[0];
        }
        java.lang.foreign.MemorySegment bounded = buffer.reinterpret(total);

        long scan = start;
        while (scan < total
                && bounded.get(java.lang.foreign.ValueLayout.JAVA_BYTE, scan) != 0) {
            scan++;
        }

        int length = (int) (scan - start);
        byte[] result = new byte[0];
        if (length > 0) {
            result = new byte[length];
            java.lang.foreign.MemorySegment.copy(
                    bounded,
                    java.lang.foreign.ValueLayout.JAVA_BYTE,
                    start,
                    result,
                    0,
                    length);
        }

        // Advance past the NUL when found; otherwise to one byte past
        // the end, matching the native fault-tolerant read behaviour.
        handle.setPosition(scan < total ? scan + 1 : total + 1);
        return result;
    }

    /**
     * Reads every remaining byte from the current cursor to the end of
     * the buffer, without NUL handling. The cursor advances to the end.
     *
     * @param handle the source data handle; must not be null
     * @return the remaining bytes; empty when the cursor is at or past
     *         the end
     * @throws NullPointerException             if {@code handle} is null
     * @throws LingoFuseObjectDisposedException if the handle has been
     *                                          closed
     */
    public static byte[] readAllBytes(DataHandle handle) {
        Objects.requireNonNull(handle, "handle must not be null");
        return handle.readAllBytes();
    }

    // ==================================================================
    // JSON I/O
    // ==================================================================

    /**
     * Serializes {@code obj} as UTF-8 JSON and writes it with a NUL
     * terminator.
     *
     * <p>The serialization goes through {@link #dumpsJson(Object)}, so
     * the compact, non-ASCII-literal policy is guaranteed. The output
     * never contains a {@code \\uXXXX} escape for non-ASCII text, and
     * a trailing NUL byte is always appended.
     *
     * @param handle the target data handle; must not be null
     * @param obj    the value to write; may be null, which produces
     *               the four-byte literal {@code null} followed by a
     *               NUL terminator
     * @throws NullPointerException             if {@code handle} is null
     * @throws LingoFuseObjectDisposedException if the handle has been
     *                                          closed
     * @throws LingoFuseException               if the value cannot be
     *                                          serialized
     * @throws lingofuse.errors.LingoFuseIoException
     *                                          if the native layer
     *                                          accepts fewer bytes than
     *                                          requested
     */
    public static void writeJson(DataHandle handle, Object obj) {
        Objects.requireNonNull(handle, "handle must not be null");
        String text = dumpsJson(obj);
        byte[] utf8 = text.getBytes(StandardCharsets.UTF_8);
        writeStringBytes(handle, utf8);
    }

    /**
     * Reads a NUL-framed JSON payload and returns it as a tree of
     * {@link JsonNode}.
     *
     * <p>The payload may or may not be NUL-terminated. If a NUL is
     * present, it is treated as the end of the payload; otherwise the
     * entire remaining buffer is consumed.
     *
     * <p>Returns {@code null} when the buffer contains no bytes at
     * all. This matches the convention of every other LingoFuse
     * binding: an empty payload means "no result". Note that a JSON
     * {@code null} (the four bytes {@code null}) also decodes to a
     * Jackson {@code NullNode}, not a Java {@code null}; callers that
     * need to distinguish the two must inspect the returned node's
     * type.
     *
     * @param handle the source data handle; must not be null
     * @return the parsed tree, or {@code null} for an empty payload
     * @throws NullPointerException             if {@code handle} is null
     * @throws LingoFuseObjectDisposedException if the handle has been
     *                                          closed
     * @throws LingoFuseException               if the payload is not
     *                                          valid JSON
     */
    public static JsonNode readJson(DataHandle handle) {
        Objects.requireNonNull(handle, "handle must not be null");
        byte[] raw = readStringBytes(handle);
        if (raw.length == 0) {
            return null;
        }
        String text = new String(raw, StandardCharsets.UTF_8);
        return loadsJson(text);
    }

    /**
     * Reads a NUL-framed JSON payload and deserializes it into an
     * instance of the given type.
     *
     * <p>Same three-case read semantics as {@link #readJson(DataHandle)}.
     *
     * @param handle the source data handle; must not be null
     * @param clazz  the target type; must not be null
     * @param <T>    the target type parameter
     * @return the deserialized value, or {@code null} for an empty
     *         payload (or a JSON {@code null})
     * @throws NullPointerException             if either argument is null
     * @throws LingoFuseObjectDisposedException if the handle has been
     *                                          closed
     * @throws LingoFuseException               if the payload is not
     *                                          valid JSON, or cannot be
     *                                          materialized as {@code T}
     */
    public static <T> T readJson(DataHandle handle, Class<T> clazz) {
        Objects.requireNonNull(handle, "handle must not be null");
        Objects.requireNonNull(clazz, "clazz must not be null");

        byte[] raw = readStringBytes(handle);
        if (raw.length == 0) {
            return null;
        }
        String text = new String(raw, StandardCharsets.UTF_8);
        return loadsJson(text, clazz);
    }

    /**
     * Non-throwing counterpart of {@link #readJson(DataHandle, Class)}.
     *
     * <p>The cursor is advanced regardless of whether the payload
     * parses successfully; this matches the historical behaviour of
     * the C# and C++ wrappers, and it is the only sensible choice for
     * a probe.
     *
     * @param handle the source data handle; must not be null
     * @param clazz  the target type; must not be null
     * @param <T>    the target type parameter
     * @return a two-element result: {@code [0]} is a boolean flag,
     *         {@code [1]} is the value on success
     * @throws NullPointerException             if either argument is null
     * @throws LingoFuseObjectDisposedException if the handle has been
     *                                          closed
     */
    public static <T> DataHandle.ReadResult<T> tryReadJson(
            DataHandle handle, Class<T> clazz) {
        Objects.requireNonNull(handle, "handle must not be null");
        Objects.requireNonNull(clazz, "clazz must not be null");

        byte[] raw = readStringBytes(handle);
        if (raw.length == 0) {
            return DataHandle.ReadResult.failure();
        }

        String text = new String(raw, StandardCharsets.UTF_8);
        try {
            T value = MAPPER.readValue(text, clazz);
            return DataHandle.ReadResult.success(value);
        } catch (JsonProcessingException e) {
            return DataHandle.ReadResult.failure();
        }
    }
}