# -*- coding: utf-8 -*-
import unittest
import time
import os
import sys
import uuid
import atexit

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import lingofuse
from lingofuse import DataHandle, App, Server, C4
from lingofuse.errors import RegistrationError, ConnectionError, TimeoutError
from lingofuse._lf_native import LF_Shutdown, LF_ResetPrepare


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