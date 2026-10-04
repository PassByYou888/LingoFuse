#ifndef LINGOFUSE_HTTP_BRIDGE_CLIENT_HPP_INCLUDED
#define LINGOFUSE_HTTP_BRIDGE_CLIENT_HPP_INCLUDED

/**
 * @file lf_http_bridge_client.hpp
 * @brief C++17 client for the LingoFuse HTTP Bridge (bridge.py / bridge.exe).
 *
 * ============================================================================
 * WHAT THIS FILE IS
 * ============================================================================
 *
 * This header is the C++ counterpart of the Pascal unit
 * `lf_http_bridge_client.pas` and the Python module
 * `lingofuse.http_bridge_client`. It lets C++ code reach the outbound POST
 * proxy and the JSON repair service registered by the LingoFuse HTTP Bridge,
 * without writing any HTTP or bridge-protocol code by hand.
 *
 * It is a HEADER-ONLY library. Drop it next to `LingoFuse.hpp` and
 * `lf_io.hpp`, `#include "lf_http_bridge_client.hpp"`, and every function is
 * available.
 *
 * ============================================================================
 * WHAT THE BRIDGE IS, AND WHY IT IS CROSS-PLATFORM / CROSS-LANGUAGE
 * ============================================================================
 *
 * The LingoFuse HTTP Bridge is a standalone executable (distributed as
 * `bridge.py` or `bridge.exe`). It is a language-neutral POST gateway for
 * the LingoFuse mesh. It exposes three capabilities that are useful to a
 * C++ service:
 *
 *   1. OUTBOUND HTTP PROXY.
 *      A C++ service that has no HTTP client library (or that does not want
 *      to add one) can ask the bridge to perform an HTTP request on its
 *      behalf. The bridge returns the HTTP response as JSON.
 *
 *   2. JSON REPAIR SERVICE.
 *      LLMs, template engines, and hand-written configuration files
 *      frequently produce JSON that a strict parser rejects (trailing
 *      commas, single quotes, unbalanced braces, stray BOMs). The bridge
 *      runs the toolchain-wide canonical repair engine and returns the
 *      repaired text. A C++ service no longer needs to vendor a repair
 *      library of its own.
 *
 *   3. ROUTING AND LOAD BALANCING (via the LingoFuse mesh).
 *      Because the bridge is a LingoFuse App, calls to it are routed by the
 *      same C4 service mesh that routes every other LingoFuse call. That
 *      means:
 *        - Automatic service discovery.
 *        - Automatic load balancing across multiple bridge instances
 *          (using the mesh's least-recently-used client selection).
 *        - No hard-coded host or port in the client.
 *
 * The bridge is CROSS-PLATFORM: it runs on Windows and Linux, and its
 * behaviour is identical on both. The client side (this header) is also
 * cross-platform: it compiles on MSVC, GCC, Clang, and MinGW, on Windows,
 * Linux, macOS, and BSD.
 *
 * The bridge is CROSS-LANGUAGE: the same bridge process serves Pascal,
 * Python, C++, JavaScript, C#, Rust, Java, and any other LingoFuse client.
 * The wire contract is identical for every language: UTF-8 JSON, NUL-
 * terminated, no \uXXXX escapes.
 *
 * ============================================================================
 * WHY THIS HEADER EXISTS: THE CODE GENERATOR SYSTEM
 * ============================================================================
 *
 * This header is not meant to be hand-written in isolation. It is designed
 * to work together with the **LingoFuse-Tools code generator system**:
 *
 *     https://github.com/PassByYou888/LingoFuse-Tools
 *
 * LingoFuse-Tools converts Pascal / C function declarations into
 * cross-language ABI, HTTP/JSON, and MCP binding code. It has three
 * generators:
 *
 *     - code_decl_to_abi       → LingoFuse binary ABI bindings
 *     - code_decl_to_json_abi  → HTTP/JSON bindings (via the bridge)
 *     - code_decl_to_mcp       → MCP tool provider bindings
 *
 * Each generator targets Pascal, Python, C++, JavaScript, and other
 * languages, and each ships with GUI, CLI, and MCP entry points. The
 * generated C++ code for the HTTP/JSON target is built on top of the
 * primitives declared in this header.
 *
 * In a typical workflow:
 *
 *     1. You declare your service APIs in a Pascal unit or a C header.
 *     2. You run code_decl_to_json_abi (via GUI, CLI, or MCP).
 *     3. The generator produces:
 *           - the server-side Pascal / C service skeleton,
 *           - the client-side C++ header that calls into the bridge,
 *           - the client-side Python / JavaScript equivalents,
 *           - and a synchronized README describing the wire contract.
 *     4. The generated C++ client includes this header and uses the
 *        functions below to talk to the bridge.
 *
 * This header is therefore the **runtime half** of the HTTP/JSON binding.
 * The generator produces the **API-specific half** (one function per
 * declared API), and this header provides the **transport half** (the
 * generic bridge-call mechanics that every generated API shares).
 *
 * ============================================================================
 * CONTRACTS WITH bridge.py
 * ============================================================================
 *
 * [1] Outbound POST proxy (default API name __lf_outbound_post__)
 * ---------------------------------------------------------------
 *
 * Request JSON (sent to the bridge's __lf_outbound_post__ API):
 *
 *     {
 *         "url":     "http://example.com/api",
 *         "method":  "POST",
 *         "headers": { "X-Foo": "Bar" },
 *         "body":    { "any": "json" },
 *         "timeout": 25
 *     }
 *
 * Response JSON (returned by the bridge):
 *
 *     {
 *         "status_code": 200,
 *         "headers":     { "content-type": "application/json", ... },
 *         "body":        { ... } | "raw string if not JSON"
 *     }
 *
 * Bridge-level error (returned when the bridge itself refuses the request):
 *
 *     { "error": "description" }
 *
 * [2] JSON repair service (default API name __lf_repair_json__)
 * -------------------------------------------------------------
 *
 * Request payload: a UTF-8 encoded JSON text, possibly malformed, possibly
 * with a UTF-8 BOM, possibly with trailing NUL bytes. The C++ side sends it
 * as a NUL-terminated UTF-8 string via the LingoFuse wire protocol.
 *
 * Response payload: a UTF-8 encoded, NUL-terminated text. Its content is
 * one of the following:
 *
 *     - The repaired JSON, when the input was malformed but the bridge's
 *       repair engine could recover it.
 *     - The original text, when the input was already valid JSON (returned
 *       byte-for-byte identical).
 *     - The original text, when the input was malformed and could not be
 *       repaired.
 *     - The original raw bytes, when the input could not be decoded as
 *       text by the bridge's encoding fallback chain.
 *
 * The response is a PLAIN STRING, not a JSON envelope.
 *
 * No-escape guarantee:
 *   The bridge invokes its repair engine with ensure_ascii=False, so the
 *   returned text NEVER contains a \uXXXX escape for a character that can
 *   be emitted literally in UTF-8. Chinese characters, emoji, and other
 *   non-ASCII content arrive as literal UTF-8 bytes.
 *
 * ============================================================================
 * MATCHING PAIR: BRIDGE AND CLIENT
 * ============================================================================
 *
 * The bridge and this client are designed to work together. The following
 * contracts must hold on both sides:
 *
 * [C1] The App name must match the bridge's configured App name.
 *      Bridge side:  --bridge-app or LINGOFUSE_BRIDGE_APP
 *                    (default: __lf_http_bridge__)
 *      Client side:  kBDefaultAppName (default: __lf_http_bridge__)
 *
 * [C2] The outbound API name must match the bridge's configured name.
 *      Bridge side:  --bridge-api or LINGOFUSE_BRIDGE_API
 *                    (default: __lf_outbound_post__)
 *      Client side:  kBDefaultPostApiName (default: __lf_outbound_post__)
 *
 * [C3] The repair API name must match the bridge's configured name.
 *      Bridge side:  --bridge-repair-api or LINGOFUSE_BRIDGE_REPAIR_API
 *                    (default: __lf_repair_json__)
 *      Client side:  kBDefaultRepairApiName (default: __lf_repair_json__)
 *
 * [C4] Both sides must agree on UTF-8. The bridge emits literal UTF-8 and
 *      never produces \uXXXX escapes for characters that can be emitted
 *      literally. The C++ side reads and writes UTF-8 via lf_io.hpp.
 *
 * [C5] The LF_Call timeout must be larger than the HTTP timeout carried
 *      inside the request JSON. Otherwise the LF_Call times out before the
 *      HTTP request finishes and the caller sees an empty response.
 *
 * [C6] The bridge must be reachable on the mesh. Because the mesh uses
 *      broadcast-based service discovery with a propagation delay of about
 *      3 seconds, a caller that starts before the bridge may need a short
 *      retry loop. See the retry pattern at the bottom of this header.
 *
 * ============================================================================
 * DEPENDENCIES
 * ============================================================================
 *
 *     LingoFuse.hpp    RAII wrappers: DataHandle, App, LibraryLoader
 *     lf_io.hpp        Unified JSON and string I/O
 *     json.hpp         nlohmann/json (single-header distribution)
 *
 * The dependency direction is strictly one-way:
 *
 *     LingoFuse.h  →  lf_io.hpp  →  LingoFuse.hpp  →  lf_http_bridge_client.hpp
 *
 * This header does NOT modify any of its dependencies. It is purely
 * additive.
 *
 * ============================================================================
 * THREADING
 * ============================================================================
 *
 * All functions in this header are thread-safe, because they ultimately
 * call LF_Call, which is thread-safe. Multiple threads may call
 * httpCall(), httpPost(), httpPostBody(), or repairJson() concurrently,
 * as long as they do not share the same DataHandle instance for writing.
 *
 * The configuration constants are compile-time constants; there is no
 * mutable global state.
 *
 * ============================================================================
 * ERROR HANDLING
 * ============================================================================
 *
 * All failures are reported by throwing `lingofuse::Error` with an
 * appropriate `ErrorCode`. The exception message is in English and
 * contains the error text returned by the bridge (when the bridge
 * reported one) or a description of the transport failure.
 *
 * Callers that prefer a non-throwing interface should use the `tryXxx`
 * variants, which return `std::optional`.
 *
 * ============================================================================
 * QUICK START
 * ============================================================================
 *
 * @code
 * #include "LingoFuse.hpp"
 * #include "lf_http_bridge_client.hpp"
 * #include <iostream>
 *
 * int main() {
 *     try {
 *         lingofuse::LibraryLoader loader;
 *
 *         lingofuse::resetPrepare();
 *         lingofuse::prepareClient("ipc:compute_grid", nullptr);
 *         if (lingofuse::prepareDone() != 1) return 1;
 *
 *         // --- Outbound HTTP POST, full envelope ---
 *         nlohmann::json envelope = lingofuse::bridge::httpPost(
 *             "https://api.example.com/v1/echo",
 *             {{"message", "Hello, world 🌍"}}
 *         );
 *         std::cout << "HTTP status: "
 *                   << envelope.at("status_code").get<int>() << "\n";
 *         std::cout << "Body: "
 *                   << envelope.at("body").dump() << "\n";
 *
 *         // --- Outbound HTTP POST, body only ---
 *         nlohmann::json body = lingofuse::bridge::httpPostBody(
 *             "https://api.example.com/v1/echo",
 *             {{"message", "Hello again"}}
 *         );
 *         std::cout << "Body only: " << body.dump() << "\n";
 *
 *         // --- JSON repair ---
 *         std::string repaired = lingofuse::bridge::repairJson(
 *             "{'name': 'Alice', 'age': 30,}"
 *         );
 *         std::cout << "Repaired: " << repaired << "\n";
 *
 *         lingofuse::exitMainThread();
 *         lingofuse::shutdown();
 *     }
 *     catch (const std::exception& e) {
 *         std::cerr << "Error: " << e.what() << "\n";
 *         return 1;
 *     }
 *     return 0;
 * }
 * @endcode
 */

#include "LingoFuse.hpp"
#include "lf_io.hpp"

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

namespace lingofuse {
    namespace bridge {

        // ============================================================================
        // Compile-time configuration
        // ============================================================================
        //
        // These constants define the default App and API names used to reach
        // the bridge. They match the bridge's own defaults. If the bridge was
        // started with --bridge-app, --bridge-api, or --bridge-repair-api
        // overrides, pass the overridden names explicitly to the functions
        // below, or wrap the calls in your own thin helpers that supply the
        // configured names.
        //
        // They are `inline constexpr` so that every translation unit sees the
        // same value with no ODR violation. They are NOT mutable at runtime;
        // this header deliberately avoids a mutable global configuration
        // object, which would introduce a data race in multi-threaded
        // callers.
        // ============================================================================

        /// Default LingoFuse App name of the bridge.
        inline constexpr const char* kBDefaultAppName = "__lf_http_bridge__";

        /// Default LingoFuse API name of the outbound POST proxy.
        inline constexpr const char* kBDefaultPostApiName =
            "__lf_outbound_post__";

        /// Default LingoFuse API name of the JSON repair service.
        inline constexpr const char* kBDefaultRepairApiName =
            "__lf_repair_json__";

        /// Default LF_Call timeout, in milliseconds, for the whole round trip
        /// to the bridge. Must be larger than the HTTP timeout carried inside
        /// the request JSON.
        inline constexpr std::uint64_t kBDefaultCallTimeoutMs = 60000;

        /// Default outbound HTTP timeout, in seconds, used when the caller
        /// does not supply one. Must be smaller than kBDefaultCallTimeoutMs
        /// / 1000.
        inline constexpr double kBDefaultHttpTimeoutSec = 25.0;

        /// Upper bound on the outbound HTTP timeout, in seconds. The bridge
        /// clamps any larger value to this bound. This constant is exposed
        /// so that callers can validate their own values before sending.
        inline constexpr double kBMaxHttpTimeoutSec = 300.0;

        // ============================================================================
        // Internal helpers
        // ============================================================================
        //
        // These functions are implementation details. They are not part of
        // the public API and may change between revisions.

        namespace detail {

            /// Translate a lingofuse::io::LfIoError into a lingofuse::Error
            /// with the given ErrorCode, preserving the message.
            [[noreturn]] inline void raiseFromIo(
                ErrorCode code,
                const io::LfIoError& e
            ) {
                throw Error(code, e.what());
            }

            /// Read a bridge response envelope from a DataHandle and return
            /// it as a nlohmann::json. The handle's cursor must be at the
            /// start of the payload.
            ///
            /// Throws Error if the payload is not valid JSON.
            inline nlohmann::json readEnvelope(DataHandle& handle) {
                handle.seek(0);
                try {
                    return io::read_json(handle.get());
                }
                catch (const io::LfIoError& e) {
                    throw Error(
                        ErrorCode::ReadFailed,
                        std::string("lf_http_bridge_client: failed to read "
                                    "bridge response envelope: ") + e.what()
                    );
                }
            }

            /// If the parsed envelope is a bridge-level error
            /// (`{"error": "..."}`), throw it as a lingofuse::Error.
            /// Otherwise return normally.
            inline void promoteBridgeError(const nlohmann::json& envelope) {
                if (envelope.is_object() && envelope.contains("error")) {
                    throw Error(
                        ErrorCode::CallFailed,
                        std::string("lf_http_bridge_client: bridge error: ")
                        + envelope.at("error").get<std::string>()
                    );
                }
            }

        } // namespace detail

        // ============================================================================
        // Core function: outbound HTTP proxy, full control
        // ============================================================================

        /**
         * @brief Send an HTTP request through the LingoFuse bridge.
         *
         * This is the lowest-level entry point. It exposes every parameter of
         * the bridge's outbound POST contract: URL, method, request body,
         * and HTTP timeout. It returns the bridge's full response envelope
         * as a JSON object.
         *
         * The returned envelope has the shape:
         *
         *     {
         *         "status_code": 200,
         *         "headers":     { "content-type": "application/json", ... },
         *         "body":        { ... } | "raw string if not JSON"
         *     }
         *
         * The remote HTTP server's actual response body is inside the
         * "body" field. Do not parse the envelope as if it were the remote
         * server's response.
         *
         * If the bridge itself refuses the request (missing URL, method not
         * in its allow-list, malformed headers, internal failure), the
         * envelope is instead `{"error": "..."}`. This function promotes
         * that into a thrown lingofuse::Error, so a successful return
         * always means the bridge attempted the HTTP request.
         *
         * @param url             Target HTTP URL. Must not be empty.
         * @param method          HTTP method. An empty string defaults to
         *                        "POST". The bridge enforces an allow-list:
         *                        GET, POST, PUT, PATCH, DELETE, HEAD,
         *                        OPTIONS.
         * @param request_body    Request body as a JSON value. Pass a default-
         *                        constructed nlohmann::json (JSON null) for
         *                        no body. Use nlohmann::json::value_t::discarded
         *                        if you want to be explicit about "no body".
         * @param http_timeout_sec
         *                        Outbound HTTP timeout in seconds. Pass 0 to
         *                        use kBDefaultHttpTimeoutSec. Values larger
         *                        than kBMaxHttpTimeoutSec are clamped by the
         *                        bridge.
         * @param app_name        Bridge App name. Pass nullptr or an empty
         *                        string to use kBDefaultAppName.
         * @param api_name        Bridge outbound API name. Pass nullptr or
         *                        an empty string to use kBDefaultPostApiName.
         * @param call_timeout_ms LF_Call timeout in milliseconds. Pass 0 to
         *                        use kBDefaultCallTimeoutMs.
         *
         * @return The bridge's full response envelope as a JSON object.
         *
         * @throws lingofuse::Error with ErrorCode::InvalidArgument if the URL
         *         is empty or the JSON body cannot be serialized.
         * @throws lingofuse::Error with ErrorCode::CallFailed if the bridge
         *         returns a bridge-level error, or if the LF_Call times out
         *         or fails.
         * @throws lingofuse::Error with ErrorCode::ReadFailed if the bridge's
         *         response cannot be parsed as JSON.
         */
        inline nlohmann::json httpCall(
            std::string_view url,
            std::string_view method,
            const nlohmann::json& request_body,
            double http_timeout_sec = 0.0,
            const char* app_name = nullptr,
            const char* api_name = nullptr,
            std::uint64_t call_timeout_ms = 0
        ) {
            if (url.empty()) {
                throw Error(
                    ErrorCode::InvalidArgument,
                    "lf_http_bridge_client::httpCall: URL is empty"
                );
            }

            const char* effective_app =
                (app_name != nullptr && *app_name != '\0')
                    ? app_name : kBDefaultAppName;
            const char* effective_api =
                (api_name != nullptr && *api_name != '\0')
                    ? api_name : kBDefaultPostApiName;
            const std::uint64_t effective_call_timeout =
                (call_timeout_ms != 0)
                    ? call_timeout_ms : kBDefaultCallTimeoutMs;
            const double effective_http_timeout =
                (http_timeout_sec > 0.0)
                    ? http_timeout_sec : kBDefaultHttpTimeoutSec;

            // Build the request JSON exactly as the bridge expects it.
            //
            // We deliberately use nlohmann::json to build the request rather
            // than concatenating strings, so that quoting and escaping are
            // handled by the JSON library.
            nlohmann::json request;
            request["url"] = std::string(url);
            request["method"] = method.empty()
                ? std::string("POST") : std::string(method);

            if (!request_body.is_null() && !request_body.is_discarded()) {
                request["body"] = request_body;
            }

            request["timeout"] = static_cast<int>(
                effective_http_timeout + 0.5
            );

            // Create the input handle and write the request.
            DataHandle param(effective_api);
            try {
                param.writeJson(request);
            }
            catch (const lingofuse::Error&) {
                throw;
            }
            catch (const std::exception& e) {
                throw Error(
                    ErrorCode::WriteFailed,
                    std::string("lf_http_bridge_client::httpCall: failed to "
                                "serialize request: ") + e.what()
                );
            }

            // Perform the call.
            TDataHnd raw = LF_Call(
                effective_app,
                param.get(),
                effective_call_timeout
            );
            DataHandle response(raw, true);

            if (response.size() == 0) {
                throw Error(
                    ErrorCode::CallFailed,
                    std::string("lf_http_bridge_client::httpCall: bridge "
                                "returned an empty response (timeout or "
                                "bridge unreachable on the mesh)")
                );
            }

            // Parse the envelope and promote a bridge-level error.
            nlohmann::json envelope = detail::readEnvelope(response);
            detail::promoteBridgeError(envelope);
            return envelope;
        }

        // ============================================================================
        // Convenience: outbound HTTP POST, full envelope
        // ============================================================================

        /**
         * @brief POST a JSON body to a URL through the bridge and return the
         *        full response envelope.
         *
         * This is the middle-level entry point. It always uses POST and the
         * default HTTP and LF_Call timeouts. Use httpCall() when you need a
         * different method, an explicit timeout, or a non-default bridge App
         * or API name.
         *
         * @param url          Target HTTP URL. Must not be empty.
         * @param request_body Request body as a JSON value. Pass JSON null
         *                     for no body.
         * @param app_name     Bridge App name. Pass nullptr for the default.
         * @param api_name     Bridge outbound API name. Pass nullptr for the
         *                     default.
         *
         * @return The bridge's full response envelope as a JSON object.
         *
         * @throws lingofuse::Error on any failure, as described for
         *         httpCall().
         */
        inline nlohmann::json httpPost(
            std::string_view url,
            const nlohmann::json& request_body,
            const char* app_name = nullptr,
            const char* api_name = nullptr
        ) {
            return httpCall(
                url,
                "POST",
                request_body,
                0.0,
                app_name,
                api_name,
                0
            );
        }

        // ============================================================================
        // Convenience: outbound HTTP POST, response body only
        // ============================================================================

        /**
         * @brief POST a JSON body to a URL through the bridge and return only
         *        the remote server's response body.
         *
         * This is the highest-level convenience overload. It unwraps the
         * bridge's envelope and hands back just the payload that the remote
         * HTTP server returned. It does NOT surface the HTTP status code or
         * response headers; use httpCall() or httpPost() when you need those.
         *
         * If the remote server returned no body, the returned JSON value is
         * a null JSON (nlohmann::json()).
         *
         * @param url          Target HTTP URL. Must not be empty.
         * @param request_body Request body as a JSON value. Pass JSON null
         *                     for no body.
         * @param app_name     Bridge App name. Pass nullptr for the default.
         * @param api_name     Bridge outbound API name. Pass nullptr for the
         *                     default.
         *
         * @return The remote server's response body as a JSON value, or a
         *         null JSON if the remote server returned no body.
         *
         * @throws lingofuse::Error on any failure, as described for
         *         httpCall().
         */
        inline nlohmann::json httpPostBody(
            std::string_view url,
            const nlohmann::json& request_body,
            const char* app_name = nullptr,
            const char* api_name = nullptr
        ) {
            nlohmann::json envelope = httpPost(
                url, request_body, app_name, api_name
            );
            if (!envelope.is_object() || !envelope.contains("body")) {
                return nlohmann::json();
            }
            const auto& body = envelope.at("body");
            if (body.is_null()) {
                return nlohmann::json();
            }
            return body;
        }

        // ============================================================================
        // Core function: JSON repair
        // ============================================================================

        /**
         * @brief Repair a malformed JSON string via the bridge's
         *        __lf_repair_json__ API.
         *
         * The bridge's repair engine applies the toolchain's canonical JSON
         * repair policy: it validates the input against strict JSON, attempts
         * a conservative repair if strict parsing fails, re-validates its own
         * output, and returns either the repaired text or the original text
         * unchanged.
         *
         * Typical inputs that benefit from this API:
         *   - LLM-generated JSON with trailing commas, single quotes, or
         *     unbalanced braces.
         *   - Config files edited by hand and saved with a UTF-8 BOM.
         *   - Payloads that arrived with a stray trailing NUL.
         *   - Payloads produced by a non-UTF-8 producer and mis-tagged.
         *
         * The following outcomes are all reported as SUCCESS (the function
         * returns normally):
         *
         *   - The input was already valid JSON. The returned string equals
         *     the input byte-for-byte.
         *   - The input was malformed but repairable. The returned string
         *     contains the repaired text. The bridge emits one WARNING to its
         *     own log.
         *   - The input was malformed and unrepairable. The returned string
         *     equals the input unchanged. The bridge emits one ERROR to its
         *     own log.
         *   - The input could not be decoded as text at all (the bridge's
         *     encoding fallback chain UTF-8 -> GBK -> Latin-1 failed, which
         *     is unreachable in practice). The returned string contains the
         *     original raw bytes decoded as Latin-1.
         *   - The input was empty or whitespace-only, and the repair engine
         *     reduced it to an empty string. The returned string is empty.
         *
         * No-escape guarantee:
         *   The bridge invokes its repair engine with ensure_ascii=False, so
         *   the returned text NEVER contains a \uXXXX escape for a character
         *   that can be emitted literally in UTF-8. Chinese characters,
         *   emoji, and other non-ASCII content are returned as literal UTF-8
         *   bytes.
         *
         * Distinguishing "already valid" from "repaired":
         *   This function does NOT compare the input to the output. Both
         *   outcomes are legitimate successes. If you need to know whether
         *   the input was modified, compare the two strings yourself:
         *
         *     std::string repaired = repairJson(input);
         *     if (input == repaired) {
         *         // input was already valid, or unrepairable
         *     } else {
         *         // input was repaired
         *     }
         *
         * @param input_json      The JSON text to repair. May be malformed.
         *                        May contain a UTF-8 BOM or trailing NULs.
         * @param app_name        Bridge App name. Pass nullptr for the default.
         * @param api_name        Bridge repair API name. Pass nullptr for the
         *                        default.
         * @param call_timeout_ms LF_Call timeout in milliseconds. Pass 0 to
         *                        use kBDefaultCallTimeoutMs.
         *
         * @return The repaired JSON text, or the original text unchanged.
         *
         * @throws lingofuse::Error with ErrorCode::CallFailed if the LF_Call
         *         times out or the bridge returns an empty payload.
         * @throws lingofuse::Error with ErrorCode::ReadFailed if the response
         *         cannot be decoded as UTF-8.
         */
        inline std::string repairJson(
            std::string_view input_json,
            const char* app_name = nullptr,
            const char* api_name = nullptr,
            std::uint64_t call_timeout_ms = 0
        ) {
            const char* effective_app =
                (app_name != nullptr && *app_name != '\0')
                    ? app_name : kBDefaultAppName;
            const char* effective_api =
                (api_name != nullptr && *api_name != '\0')
                    ? api_name : kBDefaultRepairApiName;
            const std::uint64_t effective_call_timeout =
                (call_timeout_ms != 0)
                    ? call_timeout_ms : kBDefaultCallTimeoutMs;

            DataHandle param(effective_api);
            try {
                // The repair API takes a plain string, not a JSON envelope.
                // io::write_string appends the NUL terminator that the
                // LingoFuse wire protocol requires.
                io::write_string(
                    param.get(),
                    input_json
                );
            }
            catch (const io::LfIoError& e) {
                detail::raiseFromIo(ErrorCode::WriteFailed, e);
            }

            TDataHnd raw = LF_Call(
                effective_app,
                param.get(),
                effective_call_timeout
            );
            DataHandle response(raw, true);

            if (response.size() == 0) {
                throw Error(
                    ErrorCode::CallFailed,
                    std::string("lf_http_bridge_client::repairJson: bridge "
                                "returned an empty response (timeout or "
                                "bridge unreachable on the mesh)")
                );
            }

            response.seek(0);
            try {
                return io::read_string(response.get());
            }
            catch (const io::LfIoError& e) {
                detail::raiseFromIo(ErrorCode::ReadFailed, e);
            }
        }

        // ============================================================================
        // Non-throwing variants
        // ============================================================================

        /**
         * @brief Non-throwing variant of httpCall().
         *
         * @return An engaged std::optional holding the response envelope on
         *         success, or std::nullopt on any failure.
         */
        inline std::optional<nlohmann::json> tryHttpCall(
            std::string_view url,
            std::string_view method,
            const nlohmann::json& request_body,
            double http_timeout_sec = 0.0,
            const char* app_name = nullptr,
            const char* api_name = nullptr,
            std::uint64_t call_timeout_ms = 0
        ) noexcept {
            try {
                return httpCall(
                    url, method, request_body,
                    http_timeout_sec, app_name, api_name, call_timeout_ms
                );
            }
            catch (...) {
                return std::nullopt;
            }
        }

        /**
         * @brief Non-throwing variant of httpPost().
         *
         * @return An engaged std::optional holding the response envelope on
         *         success, or std::nullopt on any failure.
         */
        inline std::optional<nlohmann::json> tryHttpPost(
            std::string_view url,
            const nlohmann::json& request_body,
            const char* app_name = nullptr,
            const char* api_name = nullptr
        ) noexcept {
            return tryHttpCall(
                url, "POST", request_body,
                0.0, app_name, api_name, 0
            );
        }

        /**
         * @brief Non-throwing variant of httpPostBody().
         *
         * @return An engaged std::optional holding the remote server's
         *         response body on success, or std::nullopt on any failure.
         *         Note that a successful call with an empty remote body
         *         yields an engaged optional holding a null JSON, not
         *         std::nullopt.
         */
        inline std::optional<nlohmann::json> tryHttpPostBody(
            std::string_view url,
            const nlohmann::json& request_body,
            const char* app_name = nullptr,
            const char* api_name = nullptr
        ) noexcept {
            try {
                return httpPostBody(url, request_body, app_name, api_name);
            }
            catch (...) {
                return std::nullopt;
            }
        }

        /**
         * @brief Non-throwing variant of repairJson().
         *
         * @return An engaged std::optional holding the repaired text on
         *         success, or std::nullopt on any transport-level failure.
         *         An empty repaired string is a legitimate result and is
         *         returned as an engaged optional holding "".
         */
        inline std::optional<std::string> tryRepairJson(
            std::string_view input_json,
            const char* app_name = nullptr,
            const char* api_name = nullptr,
            std::uint64_t call_timeout_ms = 0
        ) noexcept {
            try {
                return repairJson(
                    input_json, app_name, api_name, call_timeout_ms
                );
            }
            catch (...) {
                return std::nullopt;
            }
        }

        // ============================================================================
        // Retry helper
        // ============================================================================

        /**
         * @brief Wait until the bridge's App is visible on the mesh.
         *
         * Because the LingoFuse mesh discovers services by broadcast, a
         * freshly started bridge may not be visible to a caller for up to
         * about 3 seconds. This helper polls checkApp() until the bridge
         * appears or the timeout expires.
         *
         * This is the C++ equivalent of the retry pattern described in the
         * Pascal guide (LF-NET-004, LF-CHK-001).
         *
         * @param app_name       Bridge App name to wait for. Pass nullptr for
         *                       kBDefaultAppName.
         * @param timeout_ms     Maximum time to wait, in milliseconds.
         * @param poll_interval_ms
         *                       Time between polls, in milliseconds.
         *
         * @return true if the bridge became visible within the timeout,
         *         false otherwise.
         */
        inline bool waitForBridge(
            const char* app_name = nullptr,
            std::uint64_t timeout_ms = 10000,
            std::uint64_t poll_interval_ms = 200
        ) {
            const char* effective_app =
                (app_name != nullptr && *app_name != '\0')
                    ? app_name : kBDefaultAppName;

            const auto start = std::chrono::steady_clock::now();
            while (true) {
                if (lingofuse::checkApp(effective_app)) {
                    return true;
                }
                const auto elapsed = std::chrono::duration_cast<
                    std::chrono::milliseconds
                >(std::chrono::steady_clock::now() - start).count();
                if (static_cast<std::uint64_t>(elapsed) >= timeout_ms) {
                    return false;
                }
                std::this_thread::sleep_for(
                    std::chrono::milliseconds(poll_interval_ms)
                );
            }
        }

    } // namespace bridge
} // namespace lingofuse

#endif // LINGOFUSE_HTTP_BRIDGE_CLIENT_HPP_INCLUDED