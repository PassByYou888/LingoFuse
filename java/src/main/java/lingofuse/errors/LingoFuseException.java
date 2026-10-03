package lingofuse.errors;

/**
 * Base class for all LingoFuse exceptions.
 *
 * <p>Derives from {@link RuntimeException}, so it is unchecked. This
 * mirrors the exception hierarchy of every other LingoFuse binding
 * (Python {@code LingoFuseError}, C# {@code LingoFuseException},
 * JavaScript {@code LingoFuseError}) and lets user code inside a
 * callback throw without declaring a checked exception.
 *
 * <p>Application code can catch this base type for a single,
 * catch-all handler around any LingoFuse operation.
 */
public class LingoFuseException extends RuntimeException {

    /**
     * Creates a new exception with the given message.
     *
     * @param message a human-readable description of the failure
     */
    public LingoFuseException(String message) {
        super(message);
    }

    /**
     * Creates a new exception with the given message and cause.
     *
     * @param message a human-readable description of the failure
     * @param cause   the underlying exception that triggered this one
     */
    public LingoFuseException(String message, Throwable cause) {
        super(message, cause);
    }
}