package lingofuse.demo;

import java.util.concurrent.BlockingQueue;
import java.util.concurrent.LinkedBlockingQueue;

/**
 * Minimal log probe with no LingoFuse dependency.
 *
 * <p>Spawns a dedicated daemon thread that consumes lines from a
 * queue and writes each line to stdout. The main thread enqueues 10
 * numbered lines and waits for the queue to drain.
 *
 * <p>Purpose: to verify whether the host terminal delivers Java
 * stdout line-by-line, or buffers it. If this program prints 10
 * lines on 10 separate rows, the terminal is fine and any remaining
 * issue is elsewhere. If it prints them all at once at the end, the
 * terminal is buffering stdout when the JVM is its child process.
 *
 * <pre>
 * java -cp target\classes lingofuse.demo.LogProbe
 * </pre>
 */
public final class LogProbe {

    private static final BlockingQueue<String> QUEUE =
            new LinkedBlockingQueue<>();

    private LogProbe() {
        // Entry point; no instances.
    }

    public static void main(String[] args) throws Exception {
        Thread writer = new Thread(() -> {
            try {
                while (true) {
                    String line = QUEUE.take();
                    System.out.print(line);
                    System.out.print('\n');
                    System.out.flush();
                }
            } catch (InterruptedException ignored) {
                Thread.currentThread().interrupt();
            }
        }, "log-probe-writer");
        writer.setDaemon(true);
        writer.start();

        for (int i = 1; i <= 10; i++) {
            QUEUE.offer("Probe line " + i);
            Thread.sleep(200);
        }

        // Give the writer time to drain.
        Thread.sleep(500);
        System.out.println("Probe complete.");
    }
}