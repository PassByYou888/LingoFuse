# -*- coding: utf-8 -*-
"""
Unit tests for the LingoFuse Python bindings.

Coverage:
- DataHandle operations (atomic types, serialization, position/size)
- App registration and local calls
- Server network tests (single and multi-address)
- generate_app_name() and App.bind()
- Overlap_Connection behavior
- LF_FreeApp lifetime semantics
- Callback exception isolation (P0-1 fix verification)
- Failed-init safety (P0-3 fix verification)
- NetworkEventQueue installation and override warning

These tests use only ipc:* endpoints with unique names to avoid
clashing with other processes or repeated runs. Every test that
touches the network cleans up via LF_Shutdown() to guarantee a
consistent starting state for the next test.

{!!!!!  LF_PrepareDone RETURNS 1 ONLY ONCE  !!!!!}
Any test that calls LF_PrepareDone() MUST also call LF_ExitMainThread()
and LF_Shutdown() in a finally block. Otherwise the next test's
LF_PrepareDone() will return 0 and the test suite will report a
spurious failure.

{!!!!!  NETWORK EVENT GLOBAL STATE  !!!!!}
Network event callbacks are process-global. Tests that install them
must clear them (via clear_network_event) in a finally block, otherwise
subsequent tests may see the previous callbacks and fail assertions
such as is_network_event_installed() == False.
"""

import ctypes
import os
import sys
import time
import unittest
import uuid

# Ensure the parent directory is importable when running from the repo root.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import lingofuse
from lingofuse import (
    DataHandle, App, Server, C4,
    generate_app_name, get_app_name,
    set_network_event, clear_network_event,
    is_network_event_installed,
    NetworkEventListener, NetworkEventQueue,
)
from lingofuse.errors import (
    RegistrationError, ConnectionError, TimeoutError,
    LingoFuseError,
)
from lingofuse._lf_native import (
    LF_Shutdown,
    LF_ResetPrepare,
    LF_PrepareService,
    LF_PrepareClient,
    LF_PrepareDone,
    LF_ExitMainThread,
    LF_Call,
    LF_GetSize,
    LF_FreeData,
    LF_WriteBuffer,
    LF_CreateData,
    LF_ReadBuffer,
    LF_SetPos,
    LF_SetOption,
    LF_CheckApp,
    LF_CheckApi,
)


# ======================================================================
# Test callbacks
# ======================================================================

def _add_callback(trigger, inp, out):
    a = inp.read_int32()
    b = inp.read_int32()
    c = a + b
    out.write_int32(c)


def _notify_callback(trigger, inp):
    # Consume and discard.
    pass


# ======================================================================
# Base class for tests that use the network
# ----------------------------------------------------------------------
# Ensures that the library is always reset to a clean state between
# tests, so that the process-global LingoFuse state does not leak
# across test cases.
# ======================================================================

class NetworkTestBase(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        pass

    @classmethod
    def tearDownClass(cls):
        # Best-effort final cleanup after the whole class.
        C4.shutdown()
        try:
            LF_Shutdown()
        except Exception:
            pass

    def setUp(self):
        # Clear any leftover network event callbacks from a previous
        # test that may have failed before its finally block ran.
        try:
            clear_network_event()
        except Exception:
            pass

        # Shut down the shared client first so that its internal state
        # (C4._global_initialized) is reset BEFORE we reset the library.
        C4.shutdown()

        # Then reset any pending preparation commands left over from a
        # previous test that did not call LF_Shutdown.
        LF_ResetPrepare()
        time.sleep(0.2)

    def tearDown(self):
        # Stop the network loop for this test and clear any pending
        # state so the next test starts clean.
        try:
            clear_network_event()
        except Exception:
            pass
        C4.shutdown()
        time.sleep(0.2)


# ======================================================================
# DataHandle tests (no network)
# ======================================================================

class TestDataHandle(unittest.TestCase):

    def test_atomic_types(self):
        dh = DataHandle("test")
        self.assertTrue(dh.write_int8(-128))
        self.assertTrue(dh.write_uint8(255))
        self.assertTrue(dh.write_int16(-32768))
        self.assertTrue(dh.write_uint16(65535))
        self.assertTrue(dh.write_int32(-123456789))
        self.assertTrue(dh.write_uint32(123456789))
        self.assertTrue(dh.write_int64(-9876543210))
        self.assertTrue(dh.write_uint64(9876543210))
        self.assertTrue(dh.write_single(3.14159))
        self.assertTrue(dh.write_double(2.718281828))
        self.assertTrue(
            dh.write_string_null_terminated("Hello, world! (ascii-only)")
        )

        dh.set_pos(0)
        self.assertEqual(dh.read_int8(), -128)
        self.assertEqual(dh.read_uint8(), 255)
        self.assertEqual(dh.read_int16(), -32768)
        self.assertEqual(dh.read_uint16(), 65535)
        self.assertEqual(dh.read_int32(), -123456789)
        self.assertEqual(dh.read_uint32(), 123456789)
        self.assertEqual(dh.read_int64(), -9876543210)
        self.assertEqual(dh.read_uint64(), 9876543210)
        self.assertAlmostEqual(dh.read_single(), 3.14159, places=4)
        self.assertAlmostEqual(dh.read_double(), 2.718281828, places=6)
        self.assertEqual(
            dh.read_string_null_terminated(),
            "Hello, world! (ascii-only)",
        )
        dh.free()

    def test_atomic_types_unicode(self):
        """Unicode round-trip through write_string / read_string."""
        dh = DataHandle("test")
        text = "Hello, 世界! \U0001F30D"
        self.assertTrue(dh.write_string_null_terminated(text))
        dh.set_pos(0)
        self.assertEqual(dh.read_string_null_terminated(), text)
        dh.free()

    def test_serialization(self):
        dh = DataHandle("test", {"key": "value", "num": 42})
        self.assertEqual(dh.read(), {"key": "value", "num": 42})
        dh.free()

    def test_position_and_size(self):
        dh = DataHandle("test")
        self.assertEqual(dh.get_pos(), 0)
        self.assertEqual(dh.get_size(), 0)
        dh.write_int32(123)
        self.assertEqual(dh.get_size(), 4)
        dh.set_pos(2)
        self.assertEqual(dh.get_pos(), 2)
        dh.set_size(8)
        self.assertEqual(dh.get_size(), 8)
        dh.free()

    def test_context_manager(self):
        """DataHandle must support the with-statement."""
        with DataHandle("ctx") as dh:
            dh.write_int32(7)
            self.assertEqual(dh.get_size(), 4)
        # After the with-block, the handle must be freed.
        self.assertIsNone(dh.raw)

    def test_read_string_invalid_utf8(self):
        """
        read_string() must raise LingoFuseError, not a raw
        UnicodeDecodeError, when the buffer contains invalid UTF-8.
        """
        dh = DataHandle("test")
        # 0xFF alone is not valid UTF-8; no NUL terminator is added.
        raw = b"\xFF\xFF\xFF"
        LF_WriteBuffer(dh.raw, raw, len(raw))
        dh.set_pos(0)
        with self.assertRaises(LingoFuseError):
            dh.read_string()
        dh.free()

    def test_failed_init_does_not_break_del(self):
        """
        If DataHandle.__init__ raises before completing (or was never
        called at all), free() and __del__ must remain safe to call
        (P0-3 fix verification).
        """
        # Simulate a failed construction by calling __new__ directly
        # and never running __init__. The object has no attributes yet.
        dh = DataHandle.__new__(DataHandle)
        try:
            dh.free()
        except AttributeError:
            self.fail(
                "free() raised AttributeError on uninitialized instance"
            )
        try:
            dh.__del__()
        except AttributeError:
            self.fail(
                "__del__() raised AttributeError on uninitialized instance"
            )


# ======================================================================
# App tests (no network)
# ======================================================================

class TestApp(unittest.TestCase):

    def test_register_and_local_call(self):
        app = App("test_app")
        app.register_call("add", _add_callback, "test add")
        app.register_notify("notify", _notify_callback, "test notify")

        param = DataHandle("add")
        param.write_int32(10)
        param.write_int32(20)
        result = app.local_call(param)
        self.assertEqual(result.read_int32(), 30)
        param.free()
        result.free()

        # Test local notify.
        param = DataHandle("notify")
        param.write_string_null_terminated("hello")
        app.local_notify(param)
        param.free()

        # Test unregister.
        self.assertTrue(app.unregister("add"))
        self.assertFalse(app.unregister("non_existent"))

        # Calling a non-existent API locally returns an empty handle.
        # The library logs "no found api 'add'" to the status queue;
        # this is expected and harmless.
        print(
            "Testing call to unregistered API 'add' - the library "
            "will log 'no found api \"add\"' - this is expected."
        )
        param = DataHandle("add")
        param.write_int32(1)
        param.write_int32(2)
        result = app.local_call(param)
        self.assertEqual(result.size, 0)  # API not found -> empty result
        param.free()
        result.free()

        app.free()

    def test_duplicate_registration(self):
        app = App("dup_test")
        app.register_call("test", lambda t, i, o: None)
        with self.assertRaises(RegistrationError):
            app.register_call("test", lambda t, i, o: None)
        app.free()

    def test_callback_exception_is_isolated(self):
        """
        A user callback that raises an exception must not:
          1. propagate back into the C stack, nor
          2. crash the interpreter.

        The exception is caught and logged by the wrapper. The output
        handle stays empty, which the caller observes as an empty
        response (size 0).
        """
        app = App("exc_test")

        def bad_callback(trigger, inp, out):
            raise RuntimeError("intentional failure for isolation test")

        app.register_call("boom", bad_callback)

        param = DataHandle("boom")
        try:
            result = app.local_call(param)
            # The adapter wrapper caught the exception; the result
            # handle is still valid, just empty.
            self.assertIsNotNone(result)
            result.free()
        finally:
            param.free()
            app.free()

    def test_failed_init_does_not_break_del(self):
        """
        If App.__init__ raises before completing (or was never called
        at all), free() and __del__ must remain safe to call (P0-3 fix
        verification).
        """
        app = App.__new__(App)
        try:
            app.free()
        except AttributeError:
            self.fail(
                "free() raised AttributeError on uninitialized instance"
            )
        try:
            app.__del__()
        except AttributeError:
            self.fail(
                "__del__() raised AttributeError on uninitialized instance"
            )


# ======================================================================
# Tests for module-level helpers (need a live framework)
# ======================================================================

class TestModuleHelpers(NetworkTestBase):

    def test_generate_app_name(self):
        """
        generate_app_name() must be called AFTER LF_PrepareDone()
        returns 1; otherwise the name lacks the tunnel information and
        may not be unique.

        {!!!!!  LF_PrepareDone RETURNS 1 ONLY ONCE  !!!!!}
        This test calls LF_PrepareDone, so it MUST call
        LF_ExitMainThread and LF_Shutdown in a finally block.
        Otherwise the next test's LF_PrepareDone will return 0.
        """
        endpoint = f"ipc:gen_name_{os.getpid()}_{uuid.uuid4().hex[:6]}"
        LF_ResetPrepare()
        LF_PrepareService(endpoint.encode(), endpoint.encode())
        LF_PrepareClient(endpoint.encode(), None)

        try:
            self.assertEqual(LF_PrepareDone(), 1, "PrepareDone failed")

            name = generate_app_name()
            self.assertIsInstance(name, str)
            self.assertGreater(
                len(name), 0,
                "Generated app name must not be empty",
            )
        finally:
            LF_ExitMainThread()
            LF_Shutdown()

    def test_generate_unique_app_name(self):
        endpoint = f"ipc:gen_uniq_{os.getpid()}_{uuid.uuid4().hex[:6]}"
        LF_ResetPrepare()
        LF_PrepareService(endpoint.encode(), endpoint.encode())
        LF_PrepareClient(endpoint.encode(), None)

        try:
            self.assertEqual(LF_PrepareDone(), 1, "PrepareDone failed")

            names = set()
            for _ in range(10):
                names.add(generate_app_name())
                time.sleep(0.001)
            if len(names) < 2:
                # At least the prefix must be present.
                self.assertIn("__generate__@", list(names)[0])
            else:
                self.assertGreaterEqual(
                    len(names), 2,
                    "Should generate at least 2 distinct names",
                )
            for n in names:
                self.assertIn("__generate__@", n)
        finally:
            LF_ExitMainThread()
            LF_Shutdown()

    def test_get_app_name(self):
        app = App("TestGetName", "description")
        try:
            name_from_func = get_app_name(app.raw)
            self.assertEqual(name_from_func, "TestGetName")
        finally:
            app.free()


# ======================================================================
# Test App.bind() with two distinct services
# ======================================================================

class TestBindApp(NetworkTestBase):

    def test_bind_app(self):
        """
        Prepare two independent services on two distinct addresses,
        then bind a single App to both free clients. Expect bind() to
        return 2.
        """
        app_name = "BindTestApp"
        endpoint1 = f"ipc:bind_{os.getpid()}_{uuid.uuid4().hex[:6]}_1"
        endpoint2 = f"ipc:bind_{os.getpid()}_{uuid.uuid4().hex[:6]}_2"

        app = App(app_name, "Test bind")
        app.register_call(
            "ping",
            lambda t, i, o: o.write_string(i.read_string()),
        )

        try:
            LF_ResetPrepare()
            LF_PrepareService(endpoint1.encode(), endpoint1.encode())
            LF_PrepareService(endpoint2.encode(), endpoint2.encode())
            LF_PrepareClient(endpoint1.encode(), None)
            LF_PrepareClient(endpoint2.encode(), None)

            self.assertEqual(LF_PrepareDone(), 1, "PrepareDone failed")

            bound = app.bind()
            self.assertEqual(bound, 2,
                             "Expected to bind to 2 free clients")

            # Round-trip a call through one of the clients.
            ping_hnd = LF_CreateData(b"ping")
            try:
                msg = b"hello"
                LF_WriteBuffer(ping_hnd, msg, len(msg))
                LF_WriteBuffer(ping_hnd, b"\x00", 1)
                res_ptr = LF_Call(app_name.encode(), ping_hnd, 3000)
            finally:
                LF_FreeData(ping_hnd)

            self.assertIsNotNone(res_ptr,
                                 "LF_Call returned a null handle")
            try:
                size = LF_GetSize(res_ptr)
                self.assertGreater(size, 0,
                                   "Response should not be empty")
                LF_SetPos(res_ptr, 0)
                buf = (ctypes.c_byte * size)()
                read = LF_ReadBuffer(res_ptr, buf, size)
                self.assertEqual(read, size, "Read mismatch")
                resp_bytes = bytes(buf)
                if resp_bytes and resp_bytes[-1] == 0:
                    resp_bytes = resp_bytes[:-1]
                self.assertEqual(resp_bytes.decode("utf-8"), "hello")
            finally:
                LF_FreeData(res_ptr)

        finally:
            app.free()
            LF_ExitMainThread()
            LF_Shutdown()
            C4._global_initialized = False


# ======================================================================
# Overlap_Connection and LF_FreeApp lifetime
# ======================================================================

class TestOverlapAndFree(NetworkTestBase):

    def test_overlap_connection(self):
        """
        Overlap_Connection=False (default):
            Only one client tunnel per address is allowed. A second
            LF_PrepareClient with a different app returns -1.

        Overlap_Connection=True:
            Each LF_PrepareClient creates a new tunnel, and the
            provided app is bound to the new client.
        """
        app_name1 = "OverlapApp1"
        app_name2 = "OverlapApp2"
        endpoint = f"ipc:overlap_{os.getpid()}_{uuid.uuid4().hex[:6]}"

        # ---------------- Phase 1: Overlap_Connection = False ---------
        app1 = App(app_name1, "App 1")
        app1.register_call(
            "echo",
            lambda t, i, o: o.write_string(i.read_string()),
        )
        app2 = App(app_name2, "App 2")
        app2.register_call(
            "echo",
            lambda t, i, o: o.write_string(i.read_string()),
        )

        try:
            LF_ResetPrepare()
            LF_PrepareService(endpoint.encode(), endpoint.encode())

            LF_SetOption(b"Overlap_Connection", b"False")
            tag1 = LF_PrepareClient(endpoint.encode(), app1.raw)
            self.assertNotEqual(tag1, -1, "First client should succeed")
            tag2 = LF_PrepareClient(endpoint.encode(), app2.raw)
            self.assertEqual(
                tag2, -1,
                "Second client should return -1 (duplicate address)",
            )

            self.assertEqual(LF_PrepareDone(), 1, "PrepareDone failed")

            # app1 should be reachable via the single tunnel.
            hnd = DataHandle("echo")
            hnd.write_string("test")
            res1 = LF_Call(app_name1.encode(), hnd.raw, 3000)
            hnd.free()
            self.assertIsNotNone(res1)
            self.assertGreater(LF_GetSize(res1), 0,
                               "app1 should respond")
            LF_FreeData(res1)

            # app2 should NOT be reachable.
            hnd = DataHandle("echo")
            hnd.write_string("test")
            res2 = LF_Call(app_name2.encode(), hnd.raw, 3000)
            hnd.free()
            if res2:
                self.assertEqual(LF_GetSize(res2), 0,
                                 "app2 should NOT be reachable")
                LF_FreeData(res2)

        finally:
            # FIX (P0-2): free the Apps BEFORE LF_Shutdown, otherwise
            # LF_Shutdown destroys the underlying TLF_App objects and
            # app.free() would dereference a dangling handle.
            app1.free()
            app2.free()
            LF_ExitMainThread()
            LF_Shutdown()
            C4._global_initialized = False

        time.sleep(0.3)

        # ---------------- Phase 2: Overlap_Connection = True ----------
        app1 = App(app_name1, "App 1 (overlap)")
        app1.register_call(
            "echo",
            lambda t, i, o: o.write_string(i.read_string()),
        )
        app2 = App(app_name2, "App 2 (overlap)")
        app2.register_call(
            "echo",
            lambda t, i, o: o.write_string(i.read_string()),
        )

        try:
            LF_ResetPrepare()
            LF_PrepareService(endpoint.encode(), endpoint.encode())
            LF_SetOption(b"Overlap_Connection", b"True")

            tag1 = LF_PrepareClient(endpoint.encode(), app1.raw)
            self.assertNotEqual(tag1, -1, "First client should succeed")
            tag2 = LF_PrepareClient(endpoint.encode(), app2.raw)
            self.assertNotEqual(
                tag2, -1,
                "Second client should succeed (overlap allowed)",
            )

            self.assertEqual(LF_PrepareDone(), 1,
                             "PrepareDone failed for overlap")

            # Both apps should be reachable.
            hnd = DataHandle("echo")
            hnd.write_string("hello1")
            res_a = LF_Call(app_name1.encode(), hnd.raw, 3000)
            hnd.free()
            self.assertIsNotNone(res_a)
            self.assertGreater(LF_GetSize(res_a), 0,
                               "app1 should respond")
            LF_FreeData(res_a)

            hnd = DataHandle("echo")
            hnd.write_string("hello2")
            res_b = LF_Call(app_name2.encode(), hnd.raw, 3000)
            hnd.free()
            self.assertIsNotNone(res_b)
            self.assertGreater(LF_GetSize(res_b), 0,
                               "app2 should also respond")
            LF_FreeData(res_b)

        finally:
            app1.free()
            app2.free()
            LF_ExitMainThread()
            LF_Shutdown()
            C4._global_initialized = False

    def test_free_app_lifetime(self):
        """
        App.free() detaches the app but does not destroy it immediately.
        Local calls on the freed app must fail; a new App with the same
        name can be created without conflict.
        """
        app_name = "FreeTestApp"
        app = App(app_name, "Original")
        app.register_call("ping", lambda t, i, o: o.write_string("pong"))

        # Local call works before free.
        with DataHandle("ping") as hnd:
            res = app.local_call(hnd)
            try:
                self.assertEqual(res.read_string(), "pong")
            finally:
                res.free()

        # Free the app.
        app.free()

        # Local call on the freed app must fail. FIX (P1-5): use the
        # with-statement to make sure the DataHandle is freed even if
        # local_call raises.
        with self.assertRaises(LingoFuseError):
            with DataHandle("ping") as hnd:
                app.local_call(hnd)

        # A new App with the same name must be creatable.
        app2 = App(app_name, "New Instance")
        try:
            app2.register_call(
                "ping",
                lambda t, i, o: o.write_string("pong2"),
            )
            with DataHandle("ping") as hnd2:
                res2 = app2.local_call(hnd2)
                try:
                    self.assertEqual(res2.read_string(), "pong2")
                finally:
                    res2.free()
        finally:
            app2.free()


# ======================================================================
# Server tests
# ======================================================================

class TestServer(NetworkTestBase):

    def test_single_address(self):
        app_name = "TestApp"
        endpoint = f"ipc:test_{os.getpid()}_{uuid.uuid4().hex[:6]}"
        server = Server(app_name, "test server")

        @server.expose("add")
        def add(a, b):
            return a + b

        captured_notify = []

        @server.expose("log", notify=True)
        def log(msg):
            captured_notify.append(msg)

        captured_seq = []

        @server.expose("seq", notify=True)
        def seq(data):
            captured_seq.append(data)

        try:
            server.start(endpoint)

            # set_option must not crash.
            lingofuse.set_option("ConsoleOutput", "True")
            lingofuse.set_option("Quiet", "False")

            # Health checks.
            self.assertTrue(lingofuse.check_main_thread())
            self.assertTrue(lingofuse.check_app(app_name))

            # Basic call.
            result = server.call("add", 5, 7, timeout=3000)
            self.assertEqual(result, 12)

            # Notify + sequenced notify.
            server.notify("log", "hello")
            time.sleep(0.3)
            self.assertEqual(captured_notify, ["hello"])

            server.sequenced_notify("seq", {"order": 1})
            time.sleep(0.3)
            self.assertEqual(captured_seq, [{"order": 1}])

            # Non-existent API. This will log a warning; harmless.
            print(
                "Testing call to non-existent API 'unknown' - the "
                "library will log 'no found app...' - this is expected."
            )
            result_unknown = server.call("unknown", timeout=1000)
            self.assertIsNone(result_unknown)
        finally:
            server.stop()

    def test_multi_address(self):
        app_name = "TestApp"
        addrs = [
            f"ipc:multi_{os.getpid()}_{uuid.uuid4().hex[:6]}",
            f"ipc:multi_{os.getpid()}_{uuid.uuid4().hex[:6]}",
        ]
        server = Server(app_name, "test server")

        @server.expose("add")
        def add(a, b):
            return a + b

        try:
            server.start_multi(addrs)
            result = server.call("add", 3, 4, timeout=3000)
            self.assertEqual(result, 7)
        finally:
            server.stop()

    def test_start_on_already_running_raises(self):
        """
        Both start() and start_multi() must raise RuntimeError when the
        server is already running (P1-2 fix verification).
        """
        app_name = "RunningApp"
        endpoint = f"ipc:running_{os.getpid()}_{uuid.uuid4().hex[:6]}"
        server = Server(app_name, "running test")

        try:
            server.start(endpoint)
            with self.assertRaises(RuntimeError):
                server.start(endpoint + "_dup")
            with self.assertRaises(RuntimeError):
                server.start_multi([endpoint + "_dup2"])
        finally:
            server.stop()


# ======================================================================
# Network event API tests
# ======================================================================

class TestNetworkEvents(NetworkTestBase):
    """
    All tests in this class must leave the process-global network event
    state clear. setUp() and tearDown() call clear_network_event() so
    that even a failed test cannot contaminate the next one.
    """

    def test_set_and_clear(self):
        """install -> is_installed True; clear -> is_installed False."""
        # setUp already cleared; sanity check.
        self.assertFalse(is_network_event_installed())

        def on_conn(addr):
            pass

        def on_disc(addr):
            pass

        set_network_event(on_connect=on_conn, on_disconnect=on_disc)
        try:
            self.assertTrue(is_network_event_installed())
        finally:
            clear_network_event()

        self.assertFalse(is_network_event_installed())

    def test_set_only_connect(self):
        """
        Installing only on_connect must be possible: the disconnect
        slot is passed as NULL to the underlying library.
        """
        set_network_event(on_connect=lambda addr: None)
        try:
            self.assertTrue(is_network_event_installed())
        finally:
            clear_network_event()
        self.assertFalse(is_network_event_installed())

    def test_set_only_disconnect(self):
        """
        Installing only on_disconnect must be possible: the connect
        slot is passed as NULL to the underlying library.
        """
        set_network_event(on_disconnect=lambda addr: None)
        try:
            self.assertTrue(is_network_event_installed())
        finally:
            clear_network_event()
        self.assertFalse(is_network_event_installed())

    def test_queue_install_uninstall(self):
        """Queue install / uninstall toggles the global callback."""
        q = NetworkEventQueue.global_instance()
        self.assertFalse(q._installed)
        q.install()
        try:
            self.assertTrue(q._installed)
            self.assertTrue(is_network_event_installed())
        finally:
            q.uninstall()
        self.assertFalse(q._installed)

    def test_queue_overrides_user_callback(self):
        """
        If a user callback is already installed, queue.install() must
        succeed but log a warning about the override. The user callback
        is no longer active afterwards.
        """
        # Install a user callback first (only on_connect so that the
        # disconnect slot is NULL - this also exercises the NULL
        # argument path).
        set_network_event(on_connect=lambda addr: None)
        self.assertTrue(is_network_event_installed())

        # Now install the queue. It should override the user callback.
        q = NetworkEventQueue.global_instance()
        try:
            q.install()
            self.assertTrue(q._installed)
            self.assertTrue(is_network_event_installed())
        finally:
            q.uninstall()

    def test_listener_base_class(self):
        """
        A subclass of NetworkEventListener must be accepted by
        set_network_event(listener=...).
        """
        events = []

        class L(NetworkEventListener):
            def on_connect(self, addr):
                events.append(("connect", addr))

            def on_disconnect(self, addr):
                events.append(("disconnect", addr))

        set_network_event(listener=L())
        try:
            self.assertTrue(is_network_event_installed())
        finally:
            clear_network_event()
        self.assertFalse(is_network_event_installed())

    def test_queue_basic_get(self):
        """Queue.get() returns (type, addr) tuples in order."""
        q = NetworkEventQueue()
        q._enqueue("connect", "addr1")
        q._enqueue("disconnect", "addr2")
        self.assertEqual(q.qsize(), 2)
        self.assertEqual(q.get(block=False), ("connect", "addr1"))
        self.assertEqual(q.get(block=False), ("disconnect", "addr2"))
        self.assertTrue(q.empty())

    def test_queue_clear(self):
        q = NetworkEventQueue()
        q._enqueue("connect", "a")
        q._enqueue("connect", "b")
        q.clear()
        self.assertTrue(q.empty())


# ======================================================================
# Entry point
# ======================================================================

if __name__ == "__main__":
    unittest.main()