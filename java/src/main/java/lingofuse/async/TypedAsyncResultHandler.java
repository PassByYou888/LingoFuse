package lingofuse.async;

/**
 * Callback for a typed asynchronous call.
 *
 * <p>Unlike {@link AsyncResultHandler}, the value delivered to this
 * handler has ALREADY been deserialized by the framework. The caller
 * never sees a {@code DataHandle} and never has to think about its
 * lifetime.
 *
 * <h2>What the framework does before invoking the handler</h2>
 *
 * <ol>
 *   <li>Receives the raw result handle from the C side.</li>
 *   <li>Runs the user-supplied deserializer (typically
 *       {@link lingofuse.LfIo#readJson(lingofuse.DataHandle, Class)}
 *       or {@link lingofuse.LfIo#readJson(lingofuse.DataHandle)}) on
 *       it, on the native worker thread.</li>
 *   <li>Releases the result handle (which is owned by the framework
 *       and is invalid the moment the C callback returns).</li>
 *   <li>Invokes this handler with the deserialized value.</li>
 * </ol>
 *
 * <p>If deserialization fails, the handler is invoked with
 * {@code value == null} and a non-null {@code error}.
 *
 * <h2>Usage</h2>
 *
 * <p>The whole point of this interface is to make async code look
 * like ordinary business code, with no lifecycle bookkeeping:
 *
 * <pre>{@code
 * Framework.asyncCallJson(
 *     "MyApp", request, Person.class,
 *     (person, error) -> {
 *         if (error != null) {
 *             log.warn("async call failed", error);
 *             return;
 *         }
 *         System.out.println("got " + person.name);
 *     });
 * }</pre>
 *
 * <h2>Threading</h2>
 *
 * <p>Same threading contract as {@link AsyncResultHandler}: runs on a
 * native worker thread, must not block, must not touch thread-affine
 * resources.
 *
 * @param <T> the deserialized result type
 */
@FunctionalInterface
public interface TypedAsyncResultHandler<T> {

    /**
     * Called when the response has been deserialized or the operation
     * has failed.
     *
     * @param value the deserialized result; may be {@code null} when
     *              the payload is empty or when {@code error} is
     *              non-null
     * @param error {@code null} on success; a {@link Throwable}
     *              otherwise
     */
    void onResult(T value, Throwable error);
}