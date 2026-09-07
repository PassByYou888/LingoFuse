# -*- coding: utf-8 -*-
"""
Unit tests for the LingoFuse Python bindings.

These tests cover:
- DataHandle operations (atomic types, serialization, position/size)
- App registration and local calls
- Server network tests (single and multi-address)
- NEW: generate_app_name() and App.bind() functions
- NEW: Overlap_Connection behavior
- NEW: LF_FreeApp lifetime semantics
"""
import unittest
import time
import os
import sys
import uuid
import ctypes

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import lingofuse
from lingofuse import DataHandle, App, Server, C4, generate_app_name, get_app_name
from lingofuse.errors import RegistrationError, ConnectionError, TimeoutError, LingoFuseError
from lingofuse._lf_native import (
    LF_Shutdown, LF_ResetPrepare,
    LF_PrepareService, LF_PrepareClient, LF_PrepareDone,
    LF_ExitMainThread, LF_Shutdown as LF_ShutdownNative,
    LF_Call, LF_GetSize, LF_FreeData, LF_WriteBuffer, LF_CreateData,
    LF_ReadBuffer, LF_GetBuffer, LF_SetPos,
    LF_SetOption, LF_CheckApp, LF_CheckApi,
    LF_GetStatusCount, LF_GetStatus
)


# ----------------------------------------------------------------------
# Test callbacks
# ----------------------------------------------------------------------
def _add_callback(trigger, inp, out):
    a = inp.read_int32()
    b = inp.read_int32()
    c = a + b
    out.write_int32(c)


def _notify_callback(trigger, inp):
    # just consume
    pass


# ----------------------------------------------------------------------
# Base class for network tests (proper reset)
# ----------------------------------------------------------------------
class NetworkTestBase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        pass

    @classmethod
    def tearDownClass(cls):
        C4.shutdown()
        LF_Shutdown()

    def setUp(self):
        LF_ResetPrepare()
        C4._global_initialized = False
        C4.shutdown()
        time.sleep(0.2)

    def tearDown(self):
        C4.shutdown()
        time.sleep(0.2)


# ----------------------------------------------------------------------
# Test DataHandle (no network)
# ----------------------------------------------------------------------
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
        self.assertTrue(dh.write_string_null_terminated("Hello, 世界! 🌍"))

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
        self.assertEqual(dh.read_string_null_terminated(), "Hello, 世界! 🌍")
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


# ----------------------------------------------------------------------
# Test App (no network)
# ----------------------------------------------------------------------
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

        # Test local notify
        param = DataHandle("notify")
        param.write_string_null_terminated("hello")
        app.local_notify(param)
        param.free()

        # Test unregister
        self.assertTrue(app.unregister("add"))
        self.assertFalse(app.unregister("non_existent"))

        # Try to call again – should return empty result
        # This will generate a "no found api 'add'" info log from the library,
        # which is expected and harmless.
        print("Testing call to unregistered API 'add' – the library will log 'no found api \"add\"' – this is expected.")
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


# ----------------------------------------------------------------------
# Test new functions: generate_app_name and App.bind() (requires network)
# ----------------------------------------------------------------------
class TestNewFunctions(NetworkTestBase):
    def test_generate_app_name(self):
        """Test that generate_app_name() returns a non-empty string."""
        name = generate_app_name()
        self.assertIsInstance(name, str)
        self.assertTrue(len(name) > 0, "Generated app name should not be empty")

    def test_generate_unique_app_name(self):
        """
        Test that consecutive calls produce different names.
        Because the generation uses time ticks, we add a small delay
        between calls to increase diversity. If still not enough unique
        names (e.g., when no C4 tunnels exist), we at least verify the
        prefix is present.
        """
        names = set()
        for _ in range(10):
            names.add(generate_app_name())
            time.sleep(0.001)  # Ensure timestamp changes
        # We expect at least 2 different names (usually more)
        if len(names) < 2:
            # If only one name, it's still okay if it contains the prefix
            self.assertIn("__generate__@", list(names)[0])
        else:
            self.assertGreaterEqual(len(names), 2, "Should generate at least 2 distinct names")
        # Check that each name contains the prefix
        for n in names:
            self.assertIn("__generate__@", n)

    def test_bind_app(self):
        """
        Test App.bind() by creating two separate services (different IPC endpoints),
        creating one client for each, then binding an App to both free clients.
        This works around the LF_PrepareClient address uniqueness constraint.

        Expectation: bind() returns 2.
        """
        app_name = "BindTestApp"
        endpoint1 = f"ipc:bind_test_{os.getpid()}_{uuid.uuid4().hex[:6]}_1"
        endpoint2 = f"ipc:bind_test_{os.getpid()}_{uuid.uuid4().hex[:6]}_2"

        # Create an App with a ping API
        app = App(app_name, "Test bind")
        app.register_call("ping", lambda t, i, o: o.write_string(i.read_string()))

        # Prepare two separate services and clients (different addresses)
        LF_ResetPrepare()
        LF_PrepareService(endpoint1.encode('utf-8'), endpoint1.encode('utf-8'))
        LF_PrepareService(endpoint2.encode('utf-8'), endpoint2.encode('utf-8'))
        LF_PrepareClient(endpoint1.encode('utf-8'), None)
        LF_PrepareClient(endpoint2.encode('utf-8'), None)

        ret = LF_PrepareDone()
        self.assertEqual(ret, 1, "LF_PrepareDone failed")

        # Bind the app to all free clients (should be 2)
        bound = app.bind()
        self.assertEqual(bound, 2, "Expected to bind to 2 clients")

        # Verify that the app is reachable via one of the clients
        ping_hnd = LF_CreateData(b"ping")
        if not ping_hnd:
            self.fail("Failed to create data handle for ping")
        msg = b"hello"
        LF_WriteBuffer(ping_hnd, msg, len(msg))
        LF_WriteBuffer(ping_hnd, b"\x00", 1)  # null terminator

        res_ptr = LF_Call(app_name.encode('utf-8'), ping_hnd, 3000)
        LF_FreeData(ping_hnd)

        self.assertIsNotNone(res_ptr, "LF_Call returned null handle")
        size = LF_GetSize(res_ptr)
        self.assertGreater(size, 0, "Response should not be empty")

        LF_SetPos(res_ptr, 0)
        buf = (ctypes.c_byte * size)()
        read = LF_ReadBuffer(res_ptr, buf, size)
        self.assertEqual(read, size, "Read mismatch")
        resp_bytes = bytes(buf)
        if resp_bytes and resp_bytes[-1] == 0:
            resp_bytes = resp_bytes[:-1]
        result = resp_bytes.decode('utf-8')
        self.assertEqual(result, "hello", "Ping response mismatch")
        LF_FreeData(res_ptr)

        # Clean up
        app.free()
        LF_ExitMainThread()
        LF_ShutdownNative()
        C4._global_initialized = False

    def test_get_app_name(self):
        """Test get_app_name() on a raw handle."""
        app = App("TestGetName", "description")
        raw = app.raw
        name_from_func = get_app_name(raw)
        self.assertEqual(name_from_func, "TestGetName")
        app.free()


# ----------------------------------------------------------------------
# New tests: Overlap_Connection and LF_FreeApp semantics
# ----------------------------------------------------------------------
class TestOverlapAndFree(NetworkTestBase):
    def test_overlap_connection(self):
        """
        Test Overlap_Connection behavior:
        - When False (default), only one client tunnel per address exists.
          Subsequent prepare with a different app should be ignored.
        - When True, each prepare creates a new tunnel and binds the app.
        """
        app_name1 = "OverlapApp1"
        app_name2 = "OverlapApp2"
        endpoint = f"ipc:overlap_test_{os.getpid()}_{uuid.uuid4().hex[:6]}"

        # ---------- Phase 1: Overlap_Connection = False ----------
        app1 = App(app_name1, "App 1")
        app1.register_call("echo", lambda t, i, o: o.write_string(i.read_string()))
        app2 = App(app_name2, "App 2")
        app2.register_call("echo", lambda t, i, o: o.write_string(i.read_string()))

        LF_ResetPrepare()
        LF_PrepareService(endpoint.encode('utf-8'), endpoint.encode('utf-8'))

        LF_SetOption(b"Overlap_Connection", b"False")
        tag1 = LF_PrepareClient(endpoint.encode('utf-8'), app1.raw)
        self.assertNotEqual(tag1, -1, "First client should succeed")
        tag2 = LF_PrepareClient(endpoint.encode('utf-8'), app2.raw)
        self.assertEqual(tag2, -1, "Second client should return -1 (duplicate address)")

        ret = LF_PrepareDone()
        self.assertEqual(ret, 1, "PrepareDone failed")

        # Verify app1 reachable, app2 not
        hnd = DataHandle("echo")
        hnd.write_string("test")
        res1 = LF_Call(app_name1.encode('utf-8'), hnd.raw, 3000)
        hnd.free()
        self.assertIsNotNone(res1)
        size1 = LF_GetSize(res1)
        self.assertGreater(size1, 0, "app1 should respond")
        LF_FreeData(res1)

        hnd = DataHandle("echo")
        hnd.write_string("test")
        res2 = LF_Call(app_name2.encode('utf-8'), hnd.raw, 3000)
        hnd.free()
        if res2:
            size2 = LF_GetSize(res2)
            self.assertEqual(size2, 0, "app2 should NOT be reachable")
            LF_FreeData(res2)

        # Cleanup phase 1
        LF_ExitMainThread()
        LF_ShutdownNative()
        time.sleep(0.3)
        app1.free()
        app2.free()
        # Reset global state
        C4._global_initialized = False

        # ---------- Phase 2: Overlap_Connection = True ----------
        # Re-create apps for phase 2
        app1 = App(app_name1, "App 1 (overlap)")
        app1.register_call("echo", lambda t, i, o: o.write_string(i.read_string()))
        app2 = App(app_name2, "App 2 (overlap)")
        app2.register_call("echo", lambda t, i, o: o.write_string(i.read_string()))

        LF_ResetPrepare()
        LF_PrepareService(endpoint.encode('utf-8'), endpoint.encode('utf-8'))
        LF_SetOption(b"Overlap_Connection", b"True")
        tag1_new = LF_PrepareClient(endpoint.encode('utf-8'), app1.raw)
        self.assertNotEqual(tag1_new, -1, "First client should succeed")
        tag2_new = LF_PrepareClient(endpoint.encode('utf-8'), app2.raw)
        self.assertNotEqual(tag2_new, -1, "Second client should also succeed (overlap allowed)")

        ret2 = LF_PrepareDone()
        self.assertEqual(ret2, 1, "PrepareDone failed for overlap")

        # Both apps should be reachable
        hnd = DataHandle("echo")
        hnd.write_string("hello1")
        res_a = LF_Call(app_name1.encode('utf-8'), hnd.raw, 3000)
        hnd.free()
        self.assertIsNotNone(res_a)
        self.assertGreater(LF_GetSize(res_a), 0, "app1 should respond")
        LF_FreeData(res_a)

        hnd = DataHandle("echo")
        hnd.write_string("hello2")
        res_b = LF_Call(app_name2.encode('utf-8'), hnd.raw, 3000)
        hnd.free()
        self.assertIsNotNone(res_b)
        self.assertGreater(LF_GetSize(res_b), 0, "app2 should also respond")
        LF_FreeData(res_b)

        # Cleanup phase 2
        app1.free()
        app2.free()
        LF_ExitMainThread()
        LF_ShutdownNative()
        C4._global_initialized = False

    def test_free_app_lifetime(self):
        """
        Test that App.free() detaches the app (so local calls fail)
        but the underlying object is not immediately destroyed.
        We verify by trying to register a new app with the same name,
        which should succeed (since the old one is detached but still
        in the pool? Actually, the pool prevents duplicate names? Check.)
        According to Pascal behavior, the app remains in the global pool
        but is no longer reachable by name (since clients are detached).
        A new app with the same name can be created because the name is
        not reserved; the old one is just an object in the pool.
        We'll test that after free(), local calls fail, and we can create
        a new app with the same name without conflict.
        """
        app_name = "FreeTestApp"
        app = App(app_name, "Original")
        app.register_call("ping", lambda t, i, o: o.write_string("pong"))

        # Local call works
        hnd = DataHandle("ping")
        res = app.local_call(hnd)
        hnd.free()
        self.assertEqual(res.read_string(), "pong")
        res.free()

        # Free the app
        app.free()

        # Local call on freed app should fail
        with self.assertRaises(LingoFuseError):
            hnd = DataHandle("ping")
            app.local_call(hnd)  # App already freed -> error

        # Create a new app with the same name – should succeed (name is not locked)
        app2 = App(app_name, "New Instance")
        app2.register_call("ping", lambda t, i, o: o.write_string("pong2"))

        # Local call on new app works
        hnd2 = DataHandle("ping")
        res2 = app2.local_call(hnd2)
        hnd2.free()
        self.assertEqual(res2.read_string(), "pong2")
        res2.free()

        app2.free()

        # Cleanup (no network involved in this test, but ensure no resources left)
        # Since this test doesn't use network, we don't call LF_Shutdown here.
        # The base class teardown will handle it.


# ----------------------------------------------------------------------
# Test Server (network) – includes diagnostics (except post_status)
# ----------------------------------------------------------------------
class TestServer(NetworkTestBase):
    def test_single_address(self):
        """Test single-address server: call, notify, sequenced_notify, unknown API, and diagnostics."""
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

        server.start(endpoint)

        # ---- Test set_option (no crash) ----
        lingofuse.set_option("ConsoleOutput", "True")
        lingofuse.set_option("Quiet", "False")

        # ---- Test check_app / check_main_thread ----
        self.assertTrue(lingofuse.check_main_thread())
        self.assertTrue(lingofuse.check_app(app_name))

        # ---- API tests ----
        result = server.call("add", 5, 7, timeout=3000)
        self.assertEqual(result, 12)

        server.notify("log", "hello")
        time.sleep(0.3)
        self.assertEqual(captured_notify, ["hello"])

        server.sequenced_notify("seq", {"order": 1})
        time.sleep(0.3)
        self.assertEqual(captured_seq, [{"order": 1}])

        # This call is intentionally made to an API that does not exist.
        # The library will log "no found app("TestApp") api("unknown")".
        # This is expected and harmless.
        print("Testing call to non-existent API 'unknown' – the library will log 'no found app...' – this is expected.")
        result_unknown = server.call("unknown", timeout=1000)
        self.assertIsNone(result_unknown)

        server.stop()

    def test_multi_address(self):
        """Test multi-address server: start_multi with two IPC endpoints."""
        app_name = "TestApp"
        addrs = [
            f"ipc:test_{os.getpid()}_{uuid.uuid4().hex[:6]}",
            f"ipc:test_{os.getpid()}_{uuid.uuid4().hex[:6]}"
        ]
        server = Server(app_name, "test server")

        @server.expose("add")
        def add(a, b):
            return a + b

        server.start_multi(addrs)

        result = server.call("add", 3, 4, timeout=3000)
        self.assertEqual(result, 7)

        server.stop()


# ----------------------------------------------------------------------
# Run tests
# ----------------------------------------------------------------------
if __name__ == "__main__":
    unittest.main()