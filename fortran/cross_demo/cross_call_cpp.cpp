/**
 * cross_call_cpp.cpp
 *
 * C++ caller for the cross-language demo.
 *
 * Issues the exact same requests as cross_call.f90, over the exact
 * same wire format, against the Fortran worker node registered under
 * application "demo".
 *
 * A successful run proves:
 *   - the Fortran node exposes add / inv_seri in the standard byte
 *     format shared by every LingoFuse binding,
 *   - the C++ client can reach the Fortran node through the mesh,
 *   - a Fortran service is a first-class participant in the
 *     cross-language mesh.
 *
 * The caller waits for the "demo" application to appear on the mesh
 * before issuing any call, because mesh discovery is broadcast-based
 * and has an approximately 3-second propagation delay. Without this
 * wait, the first calls would fail with "no connection".
 *
 * All output is in English.
 */

#include "LingoFuse.hpp"

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

int main() {
    std::cout << "=== Cross Call (C++ client) ===\n";

    try {
        lingofuse::LibraryLoader loader;

        lingofuse::setOption("Wait_Ready", "False");
        lingofuse::resetPrepare();

        const int tag = lingofuse::prepareClient("ipc:cross", nullptr);
        if (tag < 0) {
            std::cerr << "[FATAL] prepareClient failed.\n";
            return 1;
        }
        if (lingofuse::prepareDone() != 1) {
            std::cerr << "[FATAL] prepareDone failed.\n";
            return 1;
        }

        std::cout << "[Call] Connected to ipc:cross.\n";

        // ----------------------------------------------------------------
        // Wait for the "demo" application to appear on the mesh.
        // ----------------------------------------------------------------
        std::cout << "[Call] Waiting for 'demo' to appear on the mesh...\n";
        {
            bool seen = false;
            for (int attempt = 0; attempt < 50; ++attempt) {
                if (lingofuse::checkApp("demo")) {
                    seen = true;
                    break;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(200));
            }
            if (!seen) {
                std::cerr << "[FATAL] 'demo' did not appear within 10 seconds.\n";
                std::cerr << "        Make sure cross_node.exe is running.\n";
                return 1;
            }
        }
        std::cout << "[Call] 'demo' is online. Starting calls.\n";

        std::int64_t n_ok = 0;
        std::int64_t n_fail = 0;

        // ----------------------------------------------------------------
        // add() round-trips
        // ----------------------------------------------------------------
        std::cout << "\n[Call] Running 20 add() calls...\n";

        for (int i = 1; i <= 20; ++i) {
            const std::int32_t a = static_cast<std::int32_t>(i);
            const std::int32_t b = static_cast<std::int32_t>(i * 2);

            lingofuse::DataHandle req("add");
            req.write(a);
            req.write(b);

            auto resp = lingofuse::tryCall("demo", req, 3000);
            if (resp) {
                std::int32_t s = 0;
                if (resp->read(s) && s == a + b) {
                    ++n_ok;
                    std::cout << "[Call] add(" << a << ", " << b
                              << ") = " << s << "\n";
                } else {
                    ++n_fail;
                }
            } else {
                ++n_fail;
            }
        }

        // ----------------------------------------------------------------
        // inv_seri() round-trips
        // ----------------------------------------------------------------
        std::cout << "\n[Call] Running 5 inv_seri() calls...\n";

        const std::uint8_t  send_b   = 200;
        const std::uint16_t send_w   = 16;
        const std::uint32_t send_c   = 47;
        const std::uint64_t send_u64 = 63;
        const std::string   send_s   = "hello world";
        const float         send_f   = 3.14f;

        for (int i = 1; i <= 5; ++i) {
            lingofuse::DataHandle req("inv_seri");
            req.write(send_b);
            req.write(send_w);
            req.write(send_c);
            req.write(send_u64);
            req.write(send_s);
            req.write(send_f);

            auto resp = lingofuse::tryCall("demo", req, 3000);
            if (resp) {
                float         recv_f   = 0.0f;
                std::string   recv_s;
                std::uint64_t recv_u64 = 0;
                std::uint32_t recv_c   = 0;
                std::uint16_t recv_w   = 0;
                std::uint8_t  recv_b   = 0;

                if (resp->read(recv_f) &&
                    resp->read(recv_s) &&
                    resp->read(recv_u64) &&
                    resp->read(recv_c) &&
                    resp->read(recv_w) &&
                    resp->read(recv_b) &&
                    recv_f == send_f &&
                    recv_s == send_s &&
                    recv_u64 == send_u64 &&
                    recv_c == send_c &&
                    recv_w == send_w &&
                    recv_b == send_b) {
                    ++n_ok;
                    std::cout << "[Call] inv_seri #" << i
                              << " ok: \"" << recv_s << "\"\n";
                } else {
                    ++n_fail;
                    std::cout << "[Call] inv_seri #" << i << " mismatch\n";
                }
            } else {
                ++n_fail;
                std::cout << "[Call] inv_seri #" << i << " call failed\n";
            }
        }

        std::cout << "\n[Call] Summary\n";
        std::cout << "         success : " << n_ok << "\n";
        std::cout << "         failed  : " << n_fail << "\n";

        lingofuse::exitMainThread();
        lingofuse::shutdown();

        return (n_fail == 0) ? 0 : 1;
    }
    catch (const std::exception& e) {
        std::cerr << "[FATAL] " << e.what() << "\n";
        return 1;
    }
}