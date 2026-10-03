package lingofuse.ffi;

import java.lang.foreign.Arena;
import java.lang.foreign.SymbolLookup;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.regex.Pattern;

/**
 * Loads the platform-specific LingoFuse shared library and exposes the
 * resulting {@link SymbolLookup} to {@link NativeMethods}.
 *
 * <p>Search order:
 * <ol>
 *   <li>The platform's default loader search path
 *       ({@code PATH} on Windows, {@code LD_LIBRARY_PATH} on Linux,
 *       {@code DYLD_LIBRARY_PATH} on macOS).</li>
 *   <li>Every directory on the JVM property {@code java.library.path}.</li>
 *   <li>The current working directory ({@code user.dir}).</li>
 * </ol>
 *
 * <p>The arena that owns the loaded library is {@link Arena#global()},
 * i.e. it lives for the entire JVM lifetime and is never closed. This
 * is intentional: the downcall handles created from the returned
 * {@link SymbolLookup} are also cached for the JVM lifetime, so the
 * arena must outlive all of them.
 *
 * <p>This class is thread-safe: the library is loaded exactly once,
 * during class initialisation.
 */
public final class LibraryLoader {

    /**
     * The arena that owns the loaded library. {@link Arena#global()}
     * is never closed and is safe to use across threads.
     */
    private static final Arena LIBRARY_ARENA = Arena.global();

    /**
     * The resolved symbol lookup for the LingoFuse library. Populated
     * once, during class initialisation. Throws
     * {@link UnsatisfiedLinkError} if the library cannot be found.
     */
    private static final SymbolLookup SYMBOL_LOOKUP = loadLibrary();

    private LibraryLoader() {
        // Utility class; no instances.
    }

    /**
     * Returns the {@link SymbolLookup} for the LingoFuse shared library.
     *
     * @return a symbol lookup backed by a JVM-lifetime arena
     */
    public static SymbolLookup lookup() {
        return SYMBOL_LOOKUP;
    }

    /**
     * Returns the platform-specific shared library file name, chosen
     * from the operating system name and CPU architecture reported by
     * the JVM.
     *
     * @return one of {@code "LingoFuse64.dll"}, {@code "LingoFuse32.dll"},
     *         {@code "liblingofuse.dylib"}, or {@code "liblingofuse.so"}
     */
    public static String selectPlatformFileName() {
        String osName = System.getProperty("os.name", "").toLowerCase(Locale.ROOT);
        String osArch = System.getProperty("os.arch", "").toLowerCase(Locale.ROOT);

        if (osName.contains("win")) {
            boolean is64Bit =
                    osArch.contains("64")
                            || osArch.equals("amd64")
                            || osArch.equals("aarch64");
            return is64Bit ? "LingoFuse64.dll" : "LingoFuse32.dll";
        }
        if (osName.contains("mac") || osName.contains("darwin")) {
            return "liblingofuse.dylib";
        }
        // Linux, BSD, and any other ELF-based system.
        return "liblingofuse.so";
    }

    /**
     * Returns the list of absolute candidate paths, in the order in
     * which {@link #loadLibrary()} will try them. Exposed for
     * diagnostics and for the {@code check-env} style smoke tests.
     *
     * @return a fresh mutable list of candidate paths
     */
    public static List<Path> buildSearchPaths() {
        return buildSearchPaths(selectPlatformFileName());
    }

    private static List<Path> buildSearchPaths(String fileName) {
        List<Path> paths = new ArrayList<>();

        // 1. Every directory on java.library.path.
        String javaLibPath = System.getProperty("java.library.path");
        if (javaLibPath != null && !javaLibPath.isEmpty()) {
            String separator = System.getProperty("path.separator", ":");
            for (String dir : javaLibPath.split(Pattern.quote(separator))) {
                if (!dir.isEmpty()) {
                    paths.add(Paths.get(dir, fileName));
                }
            }
        }

        // 2. Current working directory.
        String userDir = System.getProperty("user.dir");
        if (userDir != null && !userDir.isEmpty()) {
            paths.add(Paths.get(userDir, fileName));
        }

        return paths;
    }

    private static SymbolLookup loadLibrary() {
        String fileName = selectPlatformFileName();
        List<String> errors = new ArrayList<>();

        // Attempt 1: the platform's default loader search path.
        // On Windows the OS searches PATH; on Linux, LD_LIBRARY_PATH;
        // on macOS, DYLD_LIBRARY_PATH and the standard framework paths.
        try {
            return SymbolLookup.libraryLookup(fileName, LIBRARY_ARENA);
        } catch (Throwable t) {
            errors.add("system loader path: " + t.getMessage());
        }

        // Attempt 2: every explicit candidate path.
        List<Path> candidates = buildSearchPaths(fileName);
        for (Path candidate : candidates) {
            if (!Files.exists(candidate)) {
                continue;
            }
            try {
                return SymbolLookup.libraryLookup(candidate, LIBRARY_ARENA);
            } catch (Throwable t) {
                errors.add(candidate + ": " + t.getMessage());
            }
        }

        // Both attempts failed. Build a detailed, actionable error.
        StringBuilder sb = new StringBuilder();
        sb.append("Failed to load the LingoFuse native library: ")
          .append(fileName)
          .append(System.lineSeparator());
        sb.append("Searched (explicit candidates):")
          .append(System.lineSeparator());
        if (candidates.isEmpty()) {
            sb.append("  (none)").append(System.lineSeparator());
        } else {
            for (Path p : candidates) {
                sb.append("  - ").append(p).append(System.lineSeparator());
            }
        }
        sb.append("Errors:").append(System.lineSeparator());
        for (String e : errors) {
            sb.append("  - ").append(e).append(System.lineSeparator());
        }
        sb.append("Place the library next to the executable, in the ")
          .append("current working directory, on java.library.path, ")
          .append("or on the system loader search path.");

        throw new UnsatisfiedLinkError(sb.toString());
    }
}