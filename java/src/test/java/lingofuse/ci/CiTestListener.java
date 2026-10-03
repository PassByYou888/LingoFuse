package lingofuse.ci;

import org.junit.platform.engine.TestExecutionResult;
import org.junit.platform.engine.support.descriptor.MethodSource;
import org.junit.platform.launcher.TestExecutionListener;
import org.junit.platform.launcher.TestIdentifier;
import org.junit.platform.launcher.TestPlan;

import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * JUnit 5 {@link TestExecutionListener} that emits machine-readable
 * JSON Lines for the LingoFuse Java CI harness.
 *
 * <p>The listener is dormant unless the system property
 * {@code lingofuse.ci} is set to {@code true}. When active, it writes
 * to stdout:
 *
 * <ul>
 *   <li>one {@code {"event":"suite_start",...}} line at the beginning;</li>
 *   <li>one {@code {"event":"test",...}} line per executed test;</li>
 *   <li>one {@code {"event":"summary",...}} line at the end.</li>
 * </ul>
 *
 * <p>The output format is modelled on the C++ ({@code test_lingofuse
 * --ci}) and C# ({@code Program.cs}) CI harnesses, so a single
 * downstream tool can consume the same JSONL stream regardless of
 * which binding produced it.
 *
 * <h2>Activation</h2>
 * <pre>
 * mvn test -Dlingofuse.ci=true
 * </pre>
 *
 * <p>When the property is false or absent, every callback is a no-op
 * and the test run is indistinguishable from a normal invocation.
 *
 * <h2>Classification</h2>
 *
 * <p>The {@code category} field is derived from the test class name:
 * {@code DataHandleSmokeTest} -> {@code DataHandle},
 * {@code AppHandleSmokeTest} -> {@code AppHandle}. The {@code SmokeTest}
 * suffix (and, failing that, the generic {@code Test} suffix) is
 * stripped. Classes without a matching suffix fall back to their
 * simple name; non-class test sources fall back to {@code General}.
 *
 * <h2>Example output</h2>
 * <pre>
 * {"event":"suite_start","suite":"lingofuse-java","total":36}
 * {"event":"test","suite":"lingofuse-java","index":1,"total":36,
 *  "category":"DataHandle","name":"DataHandle :: new DataHandle is valid",
 *  "status":"PASS","elapsed_ms":3}
 * ...
 * {"event":"summary","suite":"lingofuse-java","total":36,"passed":36,
 *  "failed":0,"elapsed_sec":12.345,"status":"PASS"}
 * </pre>
 */
public final class CiTestListener implements TestExecutionListener {

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    /** The system property that enables CI mode. */
    private static final String ENABLE_PROP = "lingofuse.ci";

    /** The suite name reported in every JSON line. */
    private static final String SUITE = "lingofuse-java";

    private static final boolean ENABLED =
        Boolean.parseBoolean(System.getProperty(ENABLE_PROP, "false"));

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------

    /** Per-test start timestamp, keyed by JUnit's unique test id. */
    private final Map<String, Long> startTimes = new ConcurrentHashMap<>();

    private final AtomicInteger total  = new AtomicInteger(0);
    private final AtomicInteger passed = new AtomicInteger(0);
    private final AtomicInteger failed = new AtomicInteger(0);
    private final AtomicInteger index  = new AtomicInteger(0);

    private volatile long suiteStartNanos = 0L;

    // ------------------------------------------------------------------
    // TestExecutionListener callbacks
    // ------------------------------------------------------------------

    @Override
    public void testPlanExecutionStarted(TestPlan plan) {
        if (!ENABLED) {
            return;
        }
        suiteStartNanos = System.nanoTime();
        int n = (int) plan.countTestIdentifiers(TestIdentifier::isTest);
        total.set(n);
        emit("{\"event\":\"suite_start\""
             + ",\"suite\":\"" + SUITE + "\""
             + ",\"total\":" + n
             + "}");
    }

    @Override
    public void executionStarted(TestIdentifier id) {
        if (!ENABLED || !id.isTest()) {
            return;
        }
        startTimes.put(id.getUniqueId(), System.nanoTime());
    }

    @Override
    public void executionFinished(TestIdentifier id,
                                  TestExecutionResult result) {
        if (!ENABLED || !id.isTest()) {
            return;
        }

        long elapsedMs = elapsedMillis(id);
        boolean ok = result.getStatus() == TestExecutionResult.Status.SUCCESSFUL;

        int i = index.incrementAndGet();
        if (ok) {
            passed.incrementAndGet();
        } else {
            failed.incrementAndGet();
        }

        StringBuilder sb = new StringBuilder(256);
        sb.append("{\"event\":\"test\"")
          .append(",\"suite\":\"").append(SUITE).append("\"")
          .append(",\"index\":").append(i)
          .append(",\"total\":").append(total.get())
          .append(",\"category\":\"")
              .append(escape(categoryOf(id))).append("\"")
          .append(",\"name\":\"")
              .append(escape(nameOf(id))).append("\"")
          .append(",\"status\":\"")
              .append(ok ? "PASS" : "FAIL").append("\"")
          .append(",\"elapsed_ms\":").append(elapsedMs);

        if (!ok) {
            String err = result.getThrowable()
                .map(t -> t.getClass().getSimpleName()
                          + ": " + t.getMessage())
                .orElse("test failed without an exception");
            sb.append(",\"error\":\"").append(escape(err)).append("\"");
        }
        sb.append("}");

        emit(sb.toString());
    }

    @Override
    public void testPlanExecutionFinished(TestPlan plan) {
        if (!ENABLED) {
            return;
        }

        double elapsedSec =
            (System.nanoTime() - suiteStartNanos) / 1_000_000_000.0;
        boolean ok = failed.get() == 0;

        StringBuilder sb = new StringBuilder(192);
        sb.append("{\"event\":\"summary\"")
          .append(",\"suite\":\"").append(SUITE).append("\"")
          .append(",\"total\":").append(total.get())
          .append(",\"passed\":").append(passed.get())
          .append(",\"failed\":").append(failed.get())
          .append(",\"elapsed_sec\":")
              .append(String.format(Locale.ROOT, "%.3f", elapsedSec))
          .append(",\"status\":\"")
              .append(ok ? "PASS" : "FAIL").append("\"")
          .append("}");

        emit(sb.toString());
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    private long elapsedMillis(TestIdentifier id) {
        Long start = startTimes.remove(id.getUniqueId());
        if (start == null) {
            return 0L;
        }
        return (System.nanoTime() - start) / 1_000_000L;
    }

    /**
     * Derive a short category label from the test identifier.
     *
     * <p>{@link TestIdentifier#getSource()} returns an
     * {@link Optional} because some identifiers (containers, for
     * example) have no source. The Optional is unwrapped here before
     * the {@code instanceof} check, so the pattern variable is bound
     * to a real {@link MethodSource}.
     */
    private static String categoryOf(TestIdentifier id) {
        Optional<org.junit.platform.engine.TestSource> source =
            id.getSource();
        if (source.isPresent() && source.get() instanceof MethodSource ms) {
            String className = ms.getClassName();
            int dot = className.lastIndexOf('.');
            String simple = (dot >= 0)
                ? className.substring(dot + 1)
                : className;
            if (simple.endsWith("SmokeTest")) {
                return simple.substring(
                    0, simple.length() - "SmokeTest".length());
            }
            if (simple.endsWith("Test")) {
                return simple.substring(
                    0, simple.length() - "Test".length());
            }
            return simple;
        }
        return "General";
    }

    private static String nameOf(TestIdentifier id) {
        return categoryOf(id) + " :: " + id.getDisplayName();
    }

    /** Minimal JSON string escaper for the fields we emit. */
    private static String escape(String s) {
        if (s == null) {
            return "";
        }
        StringBuilder sb = new StringBuilder(s.length() + 8);
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"':  sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\n': sb.append("\\n");  break;
                case '\r': sb.append("\\r");  break;
                case '\t': sb.append("\\t");  break;
                default:
                    if (c < 0x20) {
                        sb.append(String.format(
                            Locale.ROOT, "\\u%04x", (int) c));
                    } else {
                        sb.append(c);
                    }
            }
        }
        return sb.toString();
    }

    /** Serialised single-line write to stdout. */
    private static synchronized void emit(String line) {
        System.out.println(line);
        System.out.flush();
    }
}