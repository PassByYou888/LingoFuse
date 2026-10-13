// ============================================================================
// File: csharp/src/LingoFuse_cs/CallbackDispatcher.cs
// ============================================================================
// CallbackDispatcher — the abstraction that decides which thread a
// LingoFuse callback body executes on.
// ============================================================================
// THE PROBLEM
// -----------
// Every LingoFuse callback (Call handler, Notify handler, network event
// handler) runs on a native worker thread. That is fine for pure
// computation, but it is a hazard for any handler that:
//
//   * touches a UI control (WPF / WinForms / MAUI / Avalonia),
//   * assumes single-threaded access to shared state,
//   * expects a specific SynchronizationContext (for example a
//     dispatcher-bound collection, an ObservableCollection, or an
//     async operation that captures the current context),
//   * must run inside a specific ambient scope installed by the
//     application (a logging scope, an authentication scope, a
//     per-request context).
//
// Pascal solves this with a parallel set of "sync" registration
// functions (LF_RegisterSyncCall_M / LF_RegisterSyncNotify_M) that
// marshal the callback body to the simulated main thread. C++ has no
// equivalent. The C# binding previously had no equivalent either:
// every callback ran inline on a worker thread, and the only way to
// get back to the UI thread was to marshal manually inside the
// handler, which is verbose and easy to forget.
//
// THE SOLUTION
// ------------
// Registration methods take an optional ILingoCallbackDispatcher. The
// dispatcher is consulted for every invocation of the handler. If no
// dispatcher is supplied, the binding uses CallbackDispatcher.Inline,
// which runs the handler directly on the calling worker thread.
// Supplying CallbackDispatcher.MainThread instead marshals the handler
// to a SynchronizationContext captured at application startup, giving
// the exact semantics of Pascal's LF_RegisterSyncCall_M.
//
// THE SYNCHRONOUS DISPATCH CONTRACT (CRITICAL)
// --------------------------------------------
// This is the single most important rule in this file.
//
//     Dispatch MUST NOT return until the callback has completed.
//
// The reason is a hard property of the C ABI:
//
//     The `input` and `output` handles passed to a callback are valid
//     ONLY for the duration of the callback body. The native layer
//     releases them the instant the callback function returns.
//
// If Dispatch were allowed to post the callback to another thread and
// return immediately, the native worker thread would return from the
// callback while the dispatched work was still pending. The framework
// would then release `input` and `output` while a UI thread (or any
// other thread) was about to read them. The result is a use-after-free
// that is not caught by any exception handler and not visible in a
// debugger until it corrupts an unrelated allocation.
//
// Therefore Dispatch is DEFINED to be synchronous: the caller (a
// native worker thread) blocks until the callback body has finished
// running on the target thread. This matches the behaviour of the
// Pascal-side TSoft_Synchronize_Tool, whose Synchronize method also
// blocks the calling worker until the marshalled action completes.
//
// The cost is that the worker thread is occupied for the full duration
// of the callback body, even when the body runs on another thread.
// This is unavoidable: it is the price of a safe cross-thread
// callback whose input can be a live view into a framework-owned
// buffer.
//
// THE LOCK / UI INTERACTION CAVEAT
// --------------------------------
// Because Dispatch blocks the worker, a handler that dispatches to
// the UI thread while the UI thread is itself blocked on a
// synchronous LingoFuse call (Framework.Call) will deadlock.
//
// This is not a defect; it is the same constraint that applies to
// Pascal's LF_RegisterSyncCall_M and to any callback bridge with a
// borrowed input buffer. The correct patterns are:
//
//   * Keep the UI thread free while a call is in flight. Use
//     Framework.CallAsync and await instead of Framework.Call.
//   * Or register the handler with CallbackDispatcher.Inline and do
//     the marshalling manually inside the body, after copying
//     whatever it needs out of `input`.
//   * Or register the handler with a SingleThreadedDispatcher and
//     never dispatch to the UI thread from it.
//
// WHAT ABOUT ASYNC CALLBACKS?
// ---------------------------
// The dispatcher abstraction applies to SERVER-SIDE callbacks
// (AppHandle.RegisterCall / RegisterNotify, and the process-wide P2P
// equivalents). It does NOT apply to CLIENT-SIDE async completion:
// when a caller awaits Framework.CallAsync, the await continuation is
// posted back to the caller's original SynchronizationContext by the
// normal C# await machinery, with no dispatcher involvement. See
// AsyncCallbackBridge.cs for the client-side contract.
//
// EXCEPTION POLICY
// ----------------
// A dispatcher NEVER catches exceptions raised by the callback. The
// managed bridge in AppHandle and Framework is responsible for that,
// because only the bridge knows which registration the callback
// belongs to and can therefore route the failure to
// Framework.ReportCallbackError with an accurate source label.
//
// A dispatcher that executes the callback on another thread must
// nevertheless propagate any exception back to the calling worker
// thread, so that the bridge can see it. The built-in dispatchers do
// this by capturing the exception on the target thread and re-throwing
// it (with the original stack trace preserved) after the
// synchronization primitive has been signalled.
//
// BUILT-IN DISPATCHERS
// --------------------
//   Inline
//       Runs the callback immediately on the calling thread. This is
//       the default and is what every registration used before this
//       abstraction existed. It has zero overhead.
//
//   MainThread
//       Marshals the callback to a SynchronizationContext that the
//       application explicitly captures via CaptureMainThread(). If
//       no context has been captured by the time a callback fires,
//       MainThread falls back to inline execution and emits a
//       one-shot warning through Trace. This is a deliberate choice:
//       a misconfigured application still functions, but the
//       misconfiguration is visible in the trace listener.
//
// FACTORY HELPERS
// ---------------
//   FromSynchronizationContext(ctx)
//       Wraps an arbitrary SynchronizationContext. Useful for
//       applications that want to target a specific dispatcher (for
//       example, a background UI thread created by a library) rather
//       than the application's main UI thread.
//
//   CreateSingleThreadedQueue(threadName)
//       Spins up a dedicated background thread and runs every
//       dispatched action on it, in FIFO order. The returned
//       dispatcher implements IDisposable; dispose it to stop the
//       thread.
//
//   CreateCustom(dispatchImpl)
//       Wraps an arbitrary Action<Action> delegate. The delegate MUST
//       honour the synchronous contract: it must not return until
//       the action has completed. This is the escape hatch for
//       applications that already have their own scheduling
//       primitive.
//
// ============================================================================

using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.ExceptionServices;
using System.Threading;

namespace LingoFuse;

/// <summary>
/// Decides which thread a LingoFuse callback body executes on.
/// </summary>
/// <remarks>
/// <para>
/// Implementations are consulted once per callback invocation. They
/// must be thread-safe, because a single dispatcher instance is
/// typically shared by every invocation of a registered handler and
/// those invocations can arrive concurrently from multiple native
/// worker threads.
/// </para>
/// <para>
/// <b>Synchronous contract (critical):</b>
/// <see cref="Dispatch"/> MUST NOT return until the callback has
/// completed. The C ABI releases the callback's <c>input</c> and
/// <c>output</c> handles the instant the outer callback function
/// returns, so an implementation that posts the work and returns
/// early would leave another thread reading freed memory. See the
/// file-level documentation for the full rationale.
/// </para>
/// <para>
/// A dispatcher MUST NOT catch exceptions raised by the callback.
/// The managed bridge that invoked the dispatcher is responsible for
/// catching and reporting any exception, so that the failure is
/// attributed to the correct registration site. A dispatcher that
/// runs the callback on another thread MUST nevertheless propagate
/// the exception back to the calling thread, so that the bridge can
/// observe it.
/// </para>
/// </remarks>
public interface ILingoCallbackDispatcher
{
    /// <summary>
    /// Runs <paramref name="callback"/> according to the policy of
    /// this dispatcher, and blocks until the callback has completed.
    /// </summary>
    /// <param name="callback">
    /// The callback body. Must not be null. The dispatcher must not
    /// catch exceptions raised by the callback; it must propagate
    /// them to the calling thread.
    /// </param>
    void Dispatch(Action callback);
}

/// <summary>
/// Built-in implementations of <see cref="ILingoCallbackDispatcher"/>,
/// plus factories for custom dispatchers.
/// </summary>
public static class CallbackDispatcher
{
    // ====================================================================
    // Built-in singletons
    // ====================================================================

    private static readonly InlineDispatcher s_inline = new();
    private static readonly MainThreadDispatcher s_mainThread = new();

    /// <summary>
    /// Runs the callback immediately on the calling thread.
    /// </summary>
    /// <remarks>
    /// This is the default dispatcher for every registration that does
    /// not specify one. It has zero scheduling overhead: the callback
    /// body is invoked synchronously, on the native worker thread that
    /// triggered it.
    ///
    /// Use this when the handler does not need a specific thread, is
    /// purely computational, or explicitly manages its own thread
    /// marshalling.
    /// </remarks>
    public static ILingoCallbackDispatcher Inline => s_inline;

    /// <summary>
    /// Marshals the callback to the application's captured main thread.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The target SynchronizationContext must be installed by calling
    /// <see cref="CaptureMainThread"/> from the main thread before any
    /// callback registered with this dispatcher can fire. The natural
    /// place to call it is at the top of the UI entry point (WPF's
    /// <c>Application.Run</c>, WinForms' <c>Application.Run</c>,
    /// MAUI's <c>MauiProgram</c>, Avalonia's <c>BuildAvaloniaApp</c>),
    /// after the UI framework has installed its SynchronizationContext
    /// on the current thread.
    /// </para>
    /// <para>
    /// If a callback fires before a context has been captured, this
    /// dispatcher falls back to inline execution and emits a one-shot
    /// warning through <see cref="Trace"/>. The application continues
    /// to function, but the misconfiguration is visible to anyone
    /// listening on the trace channel.
    /// </para>
    /// <para>
    /// If the dispatcher is asked to run a callback while the calling
    /// thread is already the captured context's thread, it executes
    /// inline instead of posting. This avoids a needless hop and, more
    /// importantly, prevents self-deadlock when a handler that is
    /// already on the main thread triggers another registration on
    /// the same dispatcher.
    /// </para>
    /// <para>
    /// <b>Deadlock caveat:</b> the dispatch is synchronous. If the UI
    /// thread is itself blocked on a synchronous LingoFuse call when a
    /// worker attempts to dispatch to it, the two will deadlock. See
    /// the file-level documentation for the correct patterns.
    /// </para>
    /// </remarks>
    public static ILingoCallbackDispatcher MainThread => s_mainThread;

    /// <summary>
    /// True when a SynchronizationContext has been captured for
    /// <see cref="MainThread"/>.
    /// </summary>
    public static bool IsMainThreadCaptured => s_mainThread.IsCaptured;

    // ====================================================================
    // Main-thread capture
    // ====================================================================

    /// <summary>
    /// Captures the current thread's SynchronizationContext as the
    /// target of <see cref="MainThread"/>.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Call this once, from the main (UI) thread, after the UI
    /// framework has installed its SynchronizationContext. Calling it
    /// again from a different thread replaces the previous capture.
    /// </para>
    /// <para>
    /// The method throws if the current thread has no
    /// SynchronizationContext installed. That failure is not a bug in
    /// the binding; it means the caller is on the wrong thread or has
    /// called too early. Both cases are programming errors that the
    /// exception message describes explicitly.
    /// </para>
    /// </remarks>
    /// <exception cref="InvalidOperationException">
    /// Thrown when SynchronizationContext.Current is null on the
    /// current thread.
    /// </exception>
    public static void CaptureMainThread()
    {
        var ctx = SynchronizationContext.Current;
        if (ctx is null)
        {
            throw new InvalidOperationException(
                "CallbackDispatcher.CaptureMainThread: no " +
                "SynchronizationContext is installed on the current " +
                "thread. Call this method from a UI thread " +
                "(WPF / WinForms / MAUI / Avalonia) after the UI " +
                "framework has installed its context, or use " +
                "CallbackDispatcher.FromSynchronizationContext to " +
                "supply a specific context.");
        }
        s_mainThread.Use(ctx);
    }

    // ====================================================================
    // Factories
    // ====================================================================

    /// <summary>
    /// Wraps an arbitrary SynchronizationContext as a dispatcher.
    /// </summary>
    /// <param name="context">
    /// The target context. Must not be null.
    /// </param>
    /// <remarks>
    /// Use this instead of <see cref="MainThread"/> when you want to
    /// target a specific context that is not the application's main
    /// UI thread, or when you want to keep the target local to a
    /// subsystem rather than sharing a process-wide capture.
    /// </remarks>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="context"/> is null.
    /// </exception>
    public static ILingoCallbackDispatcher FromSynchronizationContext(
        SynchronizationContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return new SyncContextDispatcher(context);
    }

    /// <summary>
    /// Creates a dispatcher backed by a dedicated single-threaded
    /// queue.
    /// </summary>
    /// <param name="threadName">
    /// Optional name for the worker thread. Useful in debuggers and
    /// thread dumps.
    /// </param>
    /// <remarks>
    /// <para>
    /// The returned dispatcher owns a background thread. Every
    /// dispatched action runs on that thread, in FIFO order, and the
    /// caller blocks until the action has completed. This is the
    /// correct choice when a handler must serialize access to a
    /// resource that is not thread-safe and cannot tolerate
    /// concurrent access, but must not run on a native worker thread.
    /// </para>
    /// <para>
    /// The returned dispatcher implements IDisposable. Dispose it to
    /// stop the worker thread and release its resources. Disposing is
    /// idempotent.
    /// </para>
    /// <para>
    /// Because the returned type is exposed as
    /// <see cref="ILingoCallbackDispatcher"/>, callers that need to
    /// dispose it must cast, or store the concrete type when creating
    /// it:
    /// <code>
    /// using var dispatcher =
    ///     CallbackDispatcher.CreateSingleThreadedQueue("my-handler");
    /// </code>
    /// The second form works because SingleThreadedDispatcher is a
    /// public sealed nested type; the compiler can see the IDisposable
    /// implementation and will emit the correct call to Dispose on
    /// scope exit.
    /// </para>
    /// </remarks>
    public static SingleThreadedDispatcher CreateSingleThreadedQueue(
        string? threadName = null)
    {
        return new SingleThreadedDispatcher(threadName);
    }

    /// <summary>
    /// Wraps an arbitrary scheduling delegate as a dispatcher.
    /// </summary>
    /// <param name="dispatchImpl">
    /// A delegate that arranges for its argument to be executed
    /// according to some policy, and does not return until that
    /// execution has completed. Must not be null.
    /// </param>
    /// <remarks>
    /// <para>
    /// This is the escape hatch for applications that already have a
    /// scheduling primitive: a custom event loop, an actor mailbox, a
    /// TaskScheduler adapter, a channel-based pipeline.
    /// </para>
    /// <para>
    /// The wrapper does not add any behavior. It exists only so that
    /// the primitive can be passed where an
    /// <see cref="ILingoCallbackDispatcher"/> is expected.
    /// </para>
    /// <para>
    /// <b>The delegate must honour the synchronous contract.</b> If it
    /// returns before its action has executed, the caller
    /// (a native worker thread) will return from the callback while
    /// the framework-owned input and output handles are still about to
    /// be read by another thread. See the file-level documentation for
    /// the full rationale.
    /// </para>
    /// </remarks>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="dispatchImpl"/> is null.
    /// </exception>
    public static ILingoCallbackDispatcher CreateCustom(
        Action<Action> dispatchImpl)
    {
        ArgumentNullException.ThrowIfNull(dispatchImpl);
        return new CustomDispatcher(dispatchImpl);
    }

    // ====================================================================
    // Private implementations
    // ====================================================================

    /// <summary>
    /// Executes the callback on the calling thread. Zero overhead.
    /// </summary>
    private sealed class InlineDispatcher : ILingoCallbackDispatcher
    {
        public void Dispatch(Action callback)
        {
            ArgumentNullException.ThrowIfNull(callback);
            callback();
        }
    }

    /// <summary>
    /// Executes the callback on the SynchronizationContext captured
    /// via <see cref="CaptureMainThread"/>.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The context is stored in a volatile field. Reads and writes are
    /// therefore visible across threads without an external lock.
    /// The only race that matters is "callback fires before the
    /// application has captured the context" and the fallback path
    /// handles that case correctly.
    /// </para>
    /// <para>
    /// The one-shot warning uses Interlocked.Exchange on an int
    /// sentinel to guarantee that only the first miss is logged, no
    /// matter how many worker threads race into the fallback path
    /// simultaneously.
    /// </para>
    /// </remarks>
    private sealed class MainThreadDispatcher : ILingoCallbackDispatcher
    {
        private volatile SynchronizationContext? _context;
        private int _warnedOnce;

        public bool IsCaptured => _context is not null;

        public void Use(SynchronizationContext context)
        {
            _context = context;
        }

        public void Dispatch(Action callback)
        {
            ArgumentNullException.ThrowIfNull(callback);

            var ctx = _context;

            if (ctx is null)
            {
                // One-shot warning. The first worker that reaches this
                // path emits a diagnostic; subsequent arrivals see the
                // sentinel and skip the message.
                if (Interlocked.Exchange(ref _warnedOnce, 1) == 0)
                {
                    Trace.WriteLine(
                        "[LingoFuse] CallbackDispatcher.MainThread: " +
                        "no main thread has been captured. Falling " +
                        "back to inline execution on the worker " +
                        "thread. Call " +
                        "CallbackDispatcher.CaptureMainThread() from " +
                        "the UI thread before registering any " +
                        "callback that requires main-thread " +
                        "execution.");
                }
                callback();
                return;
            }

            // Already on the target context's thread: execute inline
            // to avoid a needless round-trip and to prevent
            // self-deadlock when a handler running on the main thread
            // triggers another dispatch on the same context.
            if (SynchronizationContext.Current == ctx)
            {
                callback();
                return;
            }

            // Synchronous post: signal a ManualResetEventSlim once the
            // marshalled action has completed on the target thread,
            // and block the calling worker until then. The
            // ExceptionDispatchInfo preserves the original stack trace
            // of any exception raised by the callback.
            ExceptionDispatchInfo? captured = null;
            using var done = new ManualResetEventSlim(false);

            ctx.Post(_ =>
            {
                try
                {
                    callback();
                }
                catch (Exception ex)
                {
                    captured = ExceptionDispatchInfo.Capture(ex);
                }
                finally
                {
                    done.Set();
                }
            }, null);

            done.Wait();
            captured?.Throw();
        }
    }

    /// <summary>
    /// Executes the callback on a specific SynchronizationContext,
    /// with the same self-dispatch short-circuit and synchronous
    /// contract as <see cref="MainThreadDispatcher"/>.
    /// </summary>
    private sealed class SyncContextDispatcher : ILingoCallbackDispatcher
    {
        private readonly SynchronizationContext _context;

        public SyncContextDispatcher(SynchronizationContext context)
        {
            _context = context;
        }

        public void Dispatch(Action callback)
        {
            ArgumentNullException.ThrowIfNull(callback);

            if (SynchronizationContext.Current == _context)
            {
                callback();
                return;
            }

            ExceptionDispatchInfo? captured = null;
            using var done = new ManualResetEventSlim(false);

            _context.Post(_ =>
            {
                try
                {
                    callback();
                }
                catch (Exception ex)
                {
                    captured = ExceptionDispatchInfo.Capture(ex);
                }
                finally
                {
                    done.Set();
                }
            }, null);

            done.Wait();
            captured?.Throw();
        }
    }

    /// <summary>
    /// Executes the callback through a user-supplied scheduling
    /// delegate. The delegate is expected to honour the synchronous
    /// contract documented on <see cref="CreateCustom"/>.
    /// </summary>
    private sealed class CustomDispatcher : ILingoCallbackDispatcher
    {
        private readonly Action<Action> _dispatchImpl;

        public CustomDispatcher(Action<Action> dispatchImpl)
        {
            _dispatchImpl = dispatchImpl;
        }

        public void Dispatch(Action callback)
        {
            ArgumentNullException.ThrowIfNull(callback);
            _dispatchImpl(callback);
        }
    }

    // ====================================================================
    // SingleThreadedDispatcher — public so callers can dispose it
    // ====================================================================

    /// <summary>
    /// A dispatcher that owns a dedicated background thread and runs
    /// dispatched actions on it in FIFO order, synchronously from the
    /// caller's point of view.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Dispose the instance to stop the thread. Disposing is
    /// idempotent. After dispose, further calls to
    /// <see cref="Dispatch"/> throw
    /// <see cref="ObjectDisposedException"/>.
    /// </para>
    /// <para>
    /// The thread is created with IsBackground = true, so a program
    /// that forgets to dispose it will still exit cleanly. Forgetting
    /// to dispose is nevertheless discouraged: pending actions are
    /// abandoned, and the thread lives until the process ends.
    /// </para>
    /// </remarks>
    public sealed class SingleThreadedDispatcher
        : ILingoCallbackDispatcher, IDisposable
    {
        private readonly BlockingCollection<WorkItem> _queue;
        private readonly Thread _worker;
        private int _disposed;

        internal SingleThreadedDispatcher(string? threadName)
        {
            _queue = new BlockingCollection<WorkItem>();
            _worker = new Thread(WorkerLoop)
            {
                IsBackground = true,
                Name = threadName ?? "LingoFuse-SingleThreadedDispatcher",
            };
            _worker.Start();
        }

        /// <inheritdoc/>
        public void Dispatch(Action callback)
        {
            ArgumentNullException.ThrowIfNull(callback);

            if (Volatile.Read(ref _disposed) != 0)
            {
                throw new ObjectDisposedException(
                    nameof(SingleThreadedDispatcher));
            }

            var item = new WorkItem(callback);

            try
            {
                _queue.Add(item);
            }
            catch (InvalidOperationException)
            {
                // The collection was completed between the disposed
                // check above and the Add call. Surface it as the
                // documented disposed exception rather than leaking
                // the collection's own error.
                throw new ObjectDisposedException(
                    nameof(SingleThreadedDispatcher));
            }

            // Block until the worker thread has finished running the
            // callback. This is what makes the dispatcher honour the
            // synchronous contract and keeps the framework-owned
            // input / output handles alive for the duration of the
            // handler body.
            item.Completion.Wait();
            item.Error?.Throw();
        }

        /// <summary>
        /// Stops the worker thread and releases its resources.
        /// Idempotent. Pending actions are abandoned.
        /// </summary>
        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0)
            {
                return;
            }

            _queue.CompleteAdding();
        }

        private void WorkerLoop()
        {
            try
            {
                foreach (var item in _queue.GetConsumingEnumerable())
                {
                    try
                    {
                        item.Callback();
                    }
                    catch (Exception ex)
                    {
                        // Capture with the original stack trace so that
                        // the calling worker thread can re-throw it
                        // with full fidelity. The managed bridge will
                        // then report it through
                        // Framework.ReportCallbackError.
                        item.Error = ExceptionDispatchInfo.Capture(ex);
                    }
                    finally
                    {
                        item.Completion.Set();
                    }
                }
            }
            catch (ObjectDisposedException)
            {
                // CompleteAdding was called during shutdown.
            }
            catch (InvalidOperationException)
            {
                // Same case, observed through a different code path.
            }
        }

        /// <summary>
        /// The per-dispatch work item carrying the callback, a
        /// completion signal, and (on failure) the captured exception.
        /// </summary>
        private sealed class WorkItem
        {
            public readonly Action Callback;
            public readonly ManualResetEventSlim Completion = new(false);
            public ExceptionDispatchInfo? Error;

            public WorkItem(Action callback)
            {
                Callback = callback;
            }
        }
    }
}