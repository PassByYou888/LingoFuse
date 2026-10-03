package lingofuse.errors;

/**
 * Raised when an operation is attempted on an object that has already
 * been closed or disposed.
 *
 * <p>For a Java RAII wrapper such as {@code DataHandle} or
 * {@code AppHandle}, "closed" is the terminal state of an owning
 * instance. Borrowed instances (used inside callbacks) are never
 * closed by user code and therefore never raise this exception.
 */
public class LingoFuseObjectDisposedException extends LingoFuseException {

    /** Name of the disposed object, for diagnostics. */
    private final String objectName;

    /**
     * Creates a new exception for the named object.
     *
     * @param objectName the simple class name of the disposed object
     */
    public LingoFuseObjectDisposedException(String objectName) {
        super("The " + objectName + " has already been closed.");
        this.objectName = objectName;
    }

    /**
     * Returns the simple class name of the disposed object.
     *
     * @return the object name
     */
    public String getObjectName() {
        return objectName;
    }
}