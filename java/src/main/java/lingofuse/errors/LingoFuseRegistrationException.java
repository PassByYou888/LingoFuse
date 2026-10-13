package lingofuse.errors;

/**
 * Raised when an API registration operation fails.
 *
 * <p>Two failure modes are possible:
 *
 * <ul>
 *   <li>the API name is already taken within the target namespace
 *       (app-bound via {@code AppHandle.registerCall} /
 *       {@code AppHandle.registerNotify}, or process-wide via
 *       {@code P2PRegistry.registerCall} / {@code P2PRegistry.registerNotify});</li>
 *   <li>the native layer rejected the registration for any other
 *       reason (an allocation failure on the Pascal side, a handle
 *       that has already been closed, and so on).</li>
 * </ul>
 *
 * <p>This is a specialised subclass of {@link LingoFuseException}, so
 * existing {@code catch (LingoFuseException)} handlers continue to
 * work unchanged. The separate type exists so that callers who want
 * to distinguish "name collision" from other failures can do so with
 * a precise {@code catch (LingoFuseRegistrationException)}.
 *
 * <h2>Namespace isolation</h2>
 *
 * <p>The app-bound namespace and the process-wide P2P namespace are
 * orthogonal. A name registered in one namespace does NOT collide
 * with the same name in the other. The {@link #getNamespace()}
 * accessor reports which namespace the failed registration targeted,
 * so a diagnostic handler can produce a precise message without
 * parsing the exception text.
 */
public class LingoFuseRegistrationException extends LingoFuseException {

    /**
     * Namespace tag for an app-bound registration attempt.
     */
    public static final String NAMESPACE_APP_BOUND = "app-bound";

    /**
     * Namespace tag for a process-wide P2P registration attempt.
     */
    public static final String NAMESPACE_P2P = "p2p";

    /** The API name that failed to register. */
    private final String apiName;

    /** The namespace the registration targeted. */
    private final String namespace;

    /**
     * Creates a new registration exception.
     *
     * @param message   a human-readable description of the failure
     * @param apiName   the API name that failed to register
     * @param namespace one of {@link #NAMESPACE_APP_BOUND} or
     *                  {@link #NAMESPACE_P2P}
     */
    public LingoFuseRegistrationException(String message,
                                          String apiName,
                                          String namespace) {
        super(message);
        this.apiName = apiName;
        this.namespace = namespace;
    }

    /**
     * Returns the API name that failed to register.
     *
     * @return the API name
     */
    public String getApiName() {
        return apiName;
    }

    /**
     * Returns the namespace the registration targeted.
     *
     * @return one of {@link #NAMESPACE_APP_BOUND} or
     *         {@link #NAMESPACE_P2P}
     */
    public String getNamespace() {
        return namespace;
    }
}