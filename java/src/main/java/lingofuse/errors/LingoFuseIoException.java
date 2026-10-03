package lingofuse.errors;

/**
 * Raised when a byte-level I/O operation on a data handle fails.
 *
 * <p>Two failure modes are possible:
 * <ul>
 *   <li>a short read when the caller requested a fixed number of
 *       bytes and fewer were available;</li>
 *   <li>a short write when the native layer accepted fewer bytes than
 *       requested.</li>
 * </ul>
 *
 * <p>Argument validation errors use the standard Java exceptions
 * ({@link NullPointerException}, {@link IllegalArgumentException}),
 * not this type.
 *
 * <p>The {@link #getOperation()} accessor names the failing operation
 * (for example {@code "writeString"}), so a diagnostic handler can
 * produce a precise message without parsing the exception text.
 */
public class LingoFuseIoException extends LingoFuseException {

    /** Name of the failing I/O operation, or null when unknown. */
    private final String operation;

    /**
     * Creates a new I/O exception.
     *
     * @param message   a description of the failure
     * @param operation the name of the failing operation, or null
     */
    public LingoFuseIoException(String message, String operation) {
        super(message);
        this.operation = operation;
    }

    /**
     * Returns the name of the failing I/O operation.
     *
     * @return the operation name, or null when unknown
     */
    public String getOperation() {
        return operation;
    }
}