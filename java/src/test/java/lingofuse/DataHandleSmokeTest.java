package lingofuse;

import lingofuse.errors.LingoFuseIoException;
import lingofuse.errors.LingoFuseObjectDisposedException;
import lingofuse.ffi.LibraryLoader;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.lang.foreign.MemorySegment;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Smoke test for the Java binding's Phase 1 surface.
 *
 * <p>Verifies that:
 * <ul>
 *   <li>the native library loads successfully;</li>
 *   <li>the {@code DataHandle} lifecycle works as documented;</li>
 *   <li>the atomic-type and string I/O are consistent with the
 *       NUL-framed, little-endian wire format;</li>
 *   <li>the three failure modes (short read, use-after-close, null
 *       argument) surface as the documented exception types.</li>
 * </ul>
 *
 * <p>These tests do not touch the network. They run against the raw
 * native library, so they can be executed in any environment where
 * the shared library is discoverable.
 */
@DisplayName("Phase 1 smoke tests")
class DataHandleSmokeTest {

    // ==================================================================
    // Library loading
    // ==================================================================

    @Test
    @DisplayName("library loader reports the platform-specific file name")
    void libraryLoaderReportsPlatformFileName() {
        String fileName = LibraryLoader.selectPlatformFileName();
        assertNotNull(fileName);

        String osName = System.getProperty("os.name", "").toLowerCase();
        if (osName.contains("win")) {
            assertTrue(fileName.equals("LingoFuse64.dll")
                            || fileName.equals("LingoFuse32.dll"),
                    "unexpected Windows library name: " + fileName);
        } else if (osName.contains("mac") || osName.contains("darwin")) {
            assertEquals("liblingofuse.dylib", fileName);
        } else {
            assertEquals("liblingofuse.so", fileName);
        }
    }

    @Test
    @DisplayName("library loader exposes non-empty search paths")
    void libraryLoaderExposesSearchPaths() {
        List<java.nio.file.Path> paths = LibraryLoader.buildSearchPaths();
        assertNotNull(paths);
        // The current working directory is always added, so the list
        // can never be empty.
        assertFalse(paths.isEmpty(),
                "search path list should contain at least the CWD");
    }

    // ==================================================================
    // DataHandle lifecycle
    // ==================================================================

    @Test
    @DisplayName("new DataHandle is valid, owning, and empty")
    void newDataHandleIsValidAndEmpty() {
        try (DataHandle h = new DataHandle("test_new")) {
            assertTrue(h.isValid());
            assertTrue(h.isOwning());
            assertEquals(0L, h.size());
            assertEquals(0L, h.position());
        }
    }

    @Test
    @DisplayName("close() is idempotent and invalidates the handle")
    void closeIsIdempotent() {
        DataHandle h = new DataHandle("test_close");
        h.close();
        h.close();
        h.close();

        assertFalse(h.isValid());
        assertEquals(MemorySegment.NULL, h.raw());
        assertThrows(LingoFuseObjectDisposedException.class, h::size);
        assertThrows(LingoFuseObjectDisposedException.class, h::position);
        assertThrows(LingoFuseObjectDisposedException.class,
                () -> h.writeInt32(1));
    }

    @Test
    @DisplayName("permanent handle is owning and can be closed synchronously")
    void permanentHandleIsOwning() {
        DataHandle h = DataHandle.createPermanent("test_perm");
        try {
            assertTrue(h.isValid());
            assertTrue(h.isOwning());

            h.writeInt32(42);
            h.setPosition(0);
            assertEquals(42, h.readInt32());
        } finally {
            h.close();
        }
        assertFalse(h.isValid());
    }

    // ==================================================================
    // Atomic-type I/O
    // ==================================================================

    @Test
    @DisplayName("all atomic types round-trip through the buffer")
    void atomicTypesRoundTrip() {
        try (DataHandle h = new DataHandle("test_atomic")) {
            h.writeInt8((byte) -128);
            h.writeUInt8(255);
            h.writeInt16((short) -32768);
            h.writeUInt16(65535);
            h.writeInt32(-123456789);
            h.writeUInt32(0xFFFFFFFFL);
            h.writeInt64(-9876543210L);
            h.writeUInt64(0xFFFFFFFFFFFFFFFFL);
            h.writeSingle(3.14159f);
            h.writeDouble(2.718281828);

            h.setPosition(0);

            assertEquals((byte) -128, h.readInt8());
            assertEquals(255, h.readUInt8());
            assertEquals((short) -32768, h.readInt16());
            assertEquals(65535, h.readUInt16());
            assertEquals(-123456789, h.readInt32());
            assertEquals(0xFFFFFFFFL, h.readUInt32());
            assertEquals(-9876543210L, h.readInt64());
            assertEquals(0xFFFFFFFFFFFFFFFFL, h.readUInt64());
            assertEquals(3.14159f, h.readSingle(), 1e-4f);
            assertEquals(2.718281828, h.readDouble(), 1e-9);
        }
    }

    @Test
    @DisplayName("position and size accessors match the buffer state")
    void positionAndSizeAccessors() {
        try (DataHandle h = new DataHandle("test_pos_size")) {
            assertEquals(0L, h.position());
            assertEquals(0L, h.size());

            h.writeInt32(123);
            assertEquals(4L, h.size());
            assertEquals(4L, h.position());

            h.setPosition(2);
            assertEquals(2L, h.position());

            h.setPosition(0);
            assertEquals(123, h.readInt32());

            h.setSize(8);
            assertEquals(8L, h.size());

            assertThrows(IllegalArgumentException.class,
                    () -> h.setPosition(-1));
            assertThrows(IllegalArgumentException.class,
                    () -> h.setSize(-1));
        }
    }

    // ==================================================================
    // Byte I/O semantics
    // ==================================================================

    @Test
    @DisplayName("readBytes is partial and never throws on short read")
    void readBytesIsPartial() {
        try (DataHandle h = new DataHandle("test_partial")) {
            h.writeBytes(new byte[]{1, 2, 3});

            h.setPosition(0);
            byte[] got = h.readBytes(10);
            assertEquals(3, got.length);
            assertArrayEquals(new byte[]{1, 2, 3}, got);
            assertEquals(3L, h.position());
        }
    }

    @Test
    @DisplayName("readBytesExact throws on short read and restores position")
    void readBytesExactThrowsOnShortRead() {
        try (DataHandle h = new DataHandle("test_exact")) {
            h.writeBytes(new byte[]{1, 2});
            h.setPosition(0);

            LingoFuseIoException ex = assertThrows(
                    LingoFuseIoException.class,
                    () -> h.readBytesExact(4));
            assertEquals("readBytesExact", ex.getOperation());
            // The cursor must be restored to its pre-call value.
            assertEquals(0L, h.position());
        }
    }

    @Test
    @DisplayName("tryReadBytes returns a failure result on short read")
    void tryReadBytesReturnsFailure() {
        try (DataHandle h = new DataHandle("test_try")) {
            h.writeBytes(new byte[]{1, 2});
            h.setPosition(0);

            DataHandle.ReadResult<byte[]> result = h.tryReadBytes(4);
            assertFalse(result.isOk());
            assertEquals(0L, h.position());

            DataHandle.ReadResult<byte[]> ok = h.tryReadBytes(2);
            assertTrue(ok.isOk());
            assertArrayEquals(new byte[]{1, 2}, ok.getValue());
            assertEquals(2L, h.position());
        }
    }

    @Test
    @DisplayName("readAllBytes consumes the remaining buffer")
    void readAllBytesConsumesRemainder() {
        try (DataHandle h = new DataHandle("test_all")) {
            h.writeBytes(new byte[]{1, 2, 3, 4, 5});
            h.setPosition(2);

            byte[] rest = h.readAllBytes();
            assertArrayEquals(new byte[]{3, 4, 5}, rest);
            assertEquals(5L, h.position());
        }
    }

    // ==================================================================
    // String I/O
    // ==================================================================

    @Test
    @DisplayName("writeString appends exactly one NUL terminator")
    void writeStringAppendsNul() {
        try (DataHandle h = new DataHandle("test_nul")) {
            h.writeString("abc");
            assertEquals(4L, h.size());

            h.setPosition(0);
            byte[] bytes = h.readBytes(4);
            assertArrayEquals(
                    new byte[]{'a', 'b', 'c', 0}, bytes);
        }
    }

    @Test
    @DisplayName("empty string writes exactly one NUL byte")
    void emptyStringWritesSingleNul() {
        try (DataHandle h = new DataHandle("test_empty")) {
            h.writeString("");
            assertEquals(1L, h.size());

            h.setPosition(0);
            byte[] bytes = h.readBytes(1);
            assertArrayEquals(new byte[]{0}, bytes);

            h.setPosition(0);
            assertEquals("", h.readString());
            assertEquals(1L, h.position());
        }
    }

    @Test
    @DisplayName("readString handles unicode end to end")
    void readStringHandlesUnicode() {
        try (DataHandle h = new DataHandle("test_unicode")) {
            String text = "Hello, \u4e16\u754c! \uD83C\uDF0D";
            h.writeString(text);

            h.setPosition(0);
            assertEquals(text, h.readString());
        }
    }

    @Test
    @DisplayName("readString is fault-tolerant when no NUL is present")
    void readStringIsFaultTolerantWithoutNul() {
        try (DataHandle h = new DataHandle("test_fault")) {
            // Write raw bytes with no NUL terminator.
            h.writeBytes(new byte[]{'a', 'b', 'c', 'd', 'e', 'f'});
            assertEquals(6L, h.size());

            h.setPosition(0);
            assertEquals("abcdef", h.readString());
            // The cursor advances to size + 1, matching the native
            // fault-tolerant read behaviour.
            assertEquals(7L, h.position());
        }
    }

    @Test
    @DisplayName("readString on an exhausted buffer returns empty")
    void readStringOnExhaustedBuffer() {
        try (DataHandle h = new DataHandle("test_exhausted")) {
            assertEquals("", h.readString());
            assertEquals(0L, h.position());
        }
    }

    // ==================================================================
    // Wire format
    // ==================================================================

    @Test
    @DisplayName("int32 is little-endian on the wire")
    void int32IsLittleEndian() {
        try (DataHandle h = new DataHandle("test_le")) {
            // 0x01020304 -> 04 03 02 01
            h.writeInt32(0x01020304);
            h.setPosition(0);
            byte[] bytes = h.readBytes(4);
            assertArrayEquals(
                    new byte[]{0x04, 0x03, 0x02, 0x01}, bytes);
        }
    }

    @Test
    @DisplayName("uint16 is little-endian on the wire")
    void uint16IsLittleEndian() {
        try (DataHandle h = new DataHandle("test_le16")) {
            // 0xAABB -> BB AA
            h.writeUInt16(0xAABB);
            h.setPosition(0);
            byte[] bytes = h.readBytes(2);
            assertArrayEquals(new byte[]{(byte) 0xBB, (byte) 0xAA}, bytes);
        }
    }

    @Test
    @DisplayName("JSON wire bytes match the toolchain contract")
    void jsonWireBytesMatchContract() {
        // The logical payload {"a":1} must be encoded as
        // 7B 22 61 22 3A 31 7D 00 across every binding.
        try (DataHandle h = new DataHandle("test_wire")) {
            LfIo.writeJson(h, java.util.Map.of("a", 1));
            h.setPosition(0);
            byte[] bytes = LfIo.readStringBytes(h);

            assertArrayEquals(
                    new byte[]{
                            0x7B, 0x22, 0x61, 0x22, 0x3A, 0x31, 0x7D
                    },
                    bytes);
        }
    }

    @Test
    @DisplayName("JSON output contains no \\uXXXX escape")
    void jsonOutputContainsNoUnicodeEscapes() {
        try (DataHandle h = new DataHandle("test_no_escape")) {
            LfIo.writeJson(h, java.util.Map.of("msg", "\u4f60\u597d"));
            h.setPosition(0);
            String text = LfIo.readString(h);

            // No escape sequence at all.
            assertFalse(text.contains("\\u"),
                    "JSON output must not contain \\uXXXX escapes: " + text);
            // The two Han characters must be present literally.
            assertTrue(text.contains("\u4f60\u597d"));
        }
    }

    // ==================================================================
    // Argument validation
    // ==================================================================

    @Test
    @DisplayName("null arguments raise NullPointerException")
    void nullArgumentsRaiseNpe() {
        assertThrows(NullPointerException.class,
                () -> new DataHandle(null));
        assertThrows(NullPointerException.class,
                () -> DataHandle.createPermanent(null));

        try (DataHandle h = new DataHandle("test_npe")) {
            assertThrows(NullPointerException.class,
                    () -> h.writeBytes(null));
            assertThrows(NullPointerException.class,
                    () -> h.writeString(null));
        }
    }

    @Test
    @DisplayName("LfIo rejects null handles and values")
    void lfIoRejectsNull() {
        assertThrows(NullPointerException.class,
                () -> LfIo.writeString(null, "x"));
        assertThrows(NullPointerException.class,
                () -> LfIo.readString(null));

        try (DataHandle h = new DataHandle("test_lfio_npe")) {
            assertThrows(NullPointerException.class,
                    () -> LfIo.writeString(h, null));
            assertThrows(NullPointerException.class,
                    () -> LfIo.writeStringBytes(h, null));
        }
    }

    // ==================================================================
    // Sanity: no cross-test interference
    // ==================================================================

    @Test
    @DisplayName("independent handles do not share state")
    void independentHandlesDoNotShareState() {
        try (DataHandle a = new DataHandle("test_a");
             DataHandle b = new DataHandle("test_b")) {

            a.writeInt32(1);
            b.writeInt32(2);

            assertNotEquals(a.raw(), b.raw());
            assertEquals(4L, a.size());
            assertEquals(4L, b.size());

            a.setPosition(0);
            b.setPosition(0);
            assertEquals(1, a.readInt32());
            assertEquals(2, b.readInt32());
        }
    }
}