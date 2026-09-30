"use strict";
// =============================================================================
//  index.ts
// -----------------------------------------------------------------------------
//  Public entry point for the LingoFuse TypeScript binding.
//
//  Re-exports every public symbol from the lower layers and provides
//  small lifecycle helpers. The public surface is grouped into
//  namespaces, plus a set of top-level types and functions.
// =============================================================================
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || function (mod) {
    if (mod && mod.__esModule) return mod;
    var result = {};
    if (mod != null) for (var k in mod) if (k !== "default" && Object.prototype.hasOwnProperty.call(mod, k)) __createBinding(result, mod, k);
    __setModuleDefault(result, mod);
    return result;
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.platform = exports.loadLibrary = exports.status = exports.network = exports.framework = exports.io = exports.reportCallbackError = exports.setCallbackErrorReporter = exports.AppHandle = exports.DataHandle = exports.buildSearchPaths = exports.selectPlatformFileName = exports.isNativeLoaded = exports.getBinding = exports.LibraryLoader = exports.runtime = exports.bool = exports.Option = exports.getRuntimeInfo = exports.detectRuntime = exports.LingoFuseCallbackError = exports.LingoFuseObjectDisposedError = exports.LingoFuseIoError = exports.LingoFuseCallError = exports.LingoFuseLibraryLoadError = exports.LingoFuseError = exports.ErrorCode = exports.VERSION = void 0;
// -----------------------------------------------------------------------------
//  Imports used by this module's own functions
// -----------------------------------------------------------------------------
const runtime_1 = require("./runtime");
Object.defineProperty(exports, "detectRuntime", { enumerable: true, get: function () { return runtime_1.detectRuntime; } });
Object.defineProperty(exports, "runtime", { enumerable: true, get: function () { return runtime_1.detectRuntime; } });
Object.defineProperty(exports, "getRuntimeInfo", { enumerable: true, get: function () { return runtime_1.getRuntimeInfo; } });
const binding_1 = require("./binding");
const errors_1 = require("./errors");
// -----------------------------------------------------------------------------
//  Version
// -----------------------------------------------------------------------------
/** Version of the TypeScript binding itself. */
exports.VERSION = "1.0.0";
// -----------------------------------------------------------------------------
//  Errors
// -----------------------------------------------------------------------------
var errors_2 = require("./errors");
Object.defineProperty(exports, "ErrorCode", { enumerable: true, get: function () { return errors_2.ErrorCode; } });
Object.defineProperty(exports, "LingoFuseError", { enumerable: true, get: function () { return errors_2.LingoFuseError; } });
Object.defineProperty(exports, "LingoFuseLibraryLoadError", { enumerable: true, get: function () { return errors_2.LingoFuseLibraryLoadError; } });
Object.defineProperty(exports, "LingoFuseCallError", { enumerable: true, get: function () { return errors_2.LingoFuseCallError; } });
Object.defineProperty(exports, "LingoFuseIoError", { enumerable: true, get: function () { return errors_2.LingoFuseIoError; } });
Object.defineProperty(exports, "LingoFuseObjectDisposedError", { enumerable: true, get: function () { return errors_2.LingoFuseObjectDisposedError; } });
Object.defineProperty(exports, "LingoFuseCallbackError", { enumerable: true, get: function () { return errors_2.LingoFuseCallbackError; } });
var options_1 = require("./options");
Object.defineProperty(exports, "Option", { enumerable: true, get: function () { return options_1.Option; } });
Object.defineProperty(exports, "bool", { enumerable: true, get: function () { return options_1.bool; } });
// -----------------------------------------------------------------------------
//  Library loader
// -----------------------------------------------------------------------------
var library_loader_1 = require("./library-loader");
Object.defineProperty(exports, "LibraryLoader", { enumerable: true, get: function () { return library_loader_1.LibraryLoader; } });
var binding_2 = require("./binding");
Object.defineProperty(exports, "getBinding", { enumerable: true, get: function () { return binding_2.getBinding; } });
Object.defineProperty(exports, "isNativeLoaded", { enumerable: true, get: function () { return binding_2.isLoaded; } });
Object.defineProperty(exports, "selectPlatformFileName", { enumerable: true, get: function () { return binding_2.selectPlatformFileName; } });
Object.defineProperty(exports, "buildSearchPaths", { enumerable: true, get: function () { return binding_2.buildSearchPaths; } });
// -----------------------------------------------------------------------------
//  RAII handles
// -----------------------------------------------------------------------------
var data_handle_1 = require("./data-handle");
Object.defineProperty(exports, "DataHandle", { enumerable: true, get: function () { return data_handle_1.DataHandle; } });
var app_handle_1 = require("./app-handle");
Object.defineProperty(exports, "AppHandle", { enumerable: true, get: function () { return app_handle_1.AppHandle; } });
Object.defineProperty(exports, "setCallbackErrorReporter", { enumerable: true, get: function () { return app_handle_1.setCallbackErrorReporter; } });
Object.defineProperty(exports, "reportCallbackError", { enumerable: true, get: function () { return app_handle_1.reportCallbackError; } });
// -----------------------------------------------------------------------------
//  Namespaces
// -----------------------------------------------------------------------------
const io = __importStar(require("./lf-io"));
exports.io = io;
const framework = __importStar(require("./framework"));
exports.framework = framework;
const network = __importStar(require("./network-events"));
exports.network = network;
const status = __importStar(require("./status"));
exports.status = status;
// -----------------------------------------------------------------------------
//  Lifecycle helpers
// -----------------------------------------------------------------------------
/**
 * Eagerly trigger the lazy load of the native LingoFuse library.
 * Idempotent.
 *
 * @throws {LingoFuseLibraryLoadError} When the library cannot be loaded.
 */
function loadLibrary() {
    try {
        (0, binding_1.getBinding)();
        return true;
    }
    catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        throw new errors_1.LingoFuseLibraryLoadError("LingoFuse native library", message, { cause: err });
    }
}
exports.loadLibrary = loadLibrary;
/**
 * Returns a short description of the current runtime, for diagnostics
 * and log headers.
 */
function platform() {
    const info = (0, runtime_1.getRuntimeInfo)();
    return {
        platform: info.platform,
        arch: info.arch,
        runtime: info.family,
    };
}
exports.platform = platform;
//# sourceMappingURL=index.js.map