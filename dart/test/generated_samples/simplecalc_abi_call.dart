import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:lingofuse/lingofuse.dart';

const String ABI_TARGET_APP = 'SimpleCalc_abi';
const int ABI_TIMEOUT_MS = 5000;

const int STATUS_OK = 0x00;
const int STATUS_ERROR = 0xFF;

int _decodeResponseInt(Uint8List? bytes) {
  if (bytes == null || bytes.isEmpty) {
    throw StateError('empty response');
  }
  final r = AbiReader(bytes);
  if (r.readUInt8() != STATUS_OK) {
    throw StateError('remote error: ' + r.readString());
  }
  return r.readInt64();
}

String _decodeResponseString(Uint8List? bytes) {
  if (bytes == null || bytes.isEmpty) {
    throw StateError('empty response');
  }
  final r = AbiReader(bytes);
  if (r.readUInt8() != STATUS_OK) {
    throw StateError('remote error: ' + r.readString());
  }
  return r.readString();
}

Future<int> add(int a, int b) {
  return Isolate.run(() => _syncAdd(ABI_TARGET_APP, a, b));
}

int _syncAdd(String target, int a, int b) {
  final req = DataHandle('add');
  try {
    final w = AbiWriter();
    w.writeInt64(a);
    w.writeInt64(b);
    req.writeBytes(w.takeBytes());
    req.position = 0;
    final resp = Framework.call(target, req, timeoutMs: ABI_TIMEOUT_MS);
    try {
      return _decodeResponseInt(resp.readAllBytes());
    } finally {
      resp.dispose();
    }
  } finally {
    req.dispose();
  }
}

Future<int> addByUid(Uint8List uid, int a, int b) {
  if (uid.length != 32) {
    throw RangeError('UID must be exactly 32 bytes');
  }
  final req = DataHandle('add');
  try {
    final w = AbiWriter();
    w.writeInt64(a);
    w.writeInt64(b);
    req.writeBytes(w.takeBytes());
    req.position = 0;
    final completer = Completer<Uint8List?>();
    Framework.uidCallAsync(uid, req, (result, error) {
      if (completer.isCompleted) return;
      if (error != null) {
        completer.completeError(StateError(error));
      } else {
        completer.complete(result);
      }
    });
    return completer.future.then(_decodeResponseInt);
  } finally {
    req.dispose();
  }
}

Future<int> addByP2PName(String name, int a, int b) {
  final req = DataHandle('add');
  try {
    final w = AbiWriter();
    w.writeInt64(a);
    w.writeInt64(b);
    req.writeBytes(w.takeBytes());
    req.position = 0;
    final completer = Completer<Uint8List?>();
    Framework.p2pnameCallAsync(name, req, (result, error) {
      if (completer.isCompleted) return;
      if (error != null) {
        completer.completeError(StateError(error));
      } else {
        completer.complete(result);
      }
    });
    return completer.future.then(_decodeResponseInt);
  } finally {
    req.dispose();
  }
}

Future<int> sub(int a, int b) {
  return Isolate.run(() => _syncSub(ABI_TARGET_APP, a, b));
}

int _syncSub(String target, int a, int b) {
  final req = DataHandle('sub');
  try {
    final w = AbiWriter();
    w.writeInt64(a);
    w.writeInt64(b);
    req.writeBytes(w.takeBytes());
    req.position = 0;
    final resp = Framework.call(target, req, timeoutMs: ABI_TIMEOUT_MS);
    try {
      return _decodeResponseInt(resp.readAllBytes());
    } finally {
      resp.dispose();
    }
  } finally {
    req.dispose();
  }
}

Future<int> subByUid(Uint8List uid, int a, int b) {
  if (uid.length != 32) {
    throw RangeError('UID must be exactly 32 bytes');
  }
  final req = DataHandle('sub');
  try {
    final w = AbiWriter();
    w.writeInt64(a);
    w.writeInt64(b);
    req.writeBytes(w.takeBytes());
    req.position = 0;
    final completer = Completer<Uint8List?>();
    Framework.uidCallAsync(uid, req, (result, error) {
      if (completer.isCompleted) return;
      if (error != null) {
        completer.completeError(StateError(error));
      } else {
        completer.complete(result);
      }
    });
    return completer.future.then(_decodeResponseInt);
  } finally {
    req.dispose();
  }
}

Future<int> subByP2PName(String name, int a, int b) {
  final req = DataHandle('sub');
  try {
    final w = AbiWriter();
    w.writeInt64(a);
    w.writeInt64(b);
    req.writeBytes(w.takeBytes());
    req.position = 0;
    final completer = Completer<Uint8List?>();
    Framework.p2pnameCallAsync(name, req, (result, error) {
      if (completer.isCompleted) return;
      if (error != null) {
        completer.completeError(StateError(error));
      } else {
        completer.complete(result);
      }
    });
    return completer.future.then(_decodeResponseInt);
  } finally {
    req.dispose();
  }
}

Future<int> mul(int a, int b) {
  return Isolate.run(() => _syncMul(ABI_TARGET_APP, a, b));
}

int _syncMul(String target, int a, int b) {
  final req = DataHandle('mul');
  try {
    final w = AbiWriter();
    w.writeInt64(a);
    w.writeInt64(b);
    req.writeBytes(w.takeBytes());
    req.position = 0;
    final resp = Framework.call(target, req, timeoutMs: ABI_TIMEOUT_MS);
    try {
      return _decodeResponseInt(resp.readAllBytes());
    } finally {
      resp.dispose();
    }
  } finally {
    req.dispose();
  }
}

Future<int> mulByUid(Uint8List uid, int a, int b) {
  if (uid.length != 32) {
    throw RangeError('UID must be exactly 32 bytes');
  }
  final req = DataHandle('mul');
  try {
    final w = AbiWriter();
    w.writeInt64(a);
    w.writeInt64(b);
    req.writeBytes(w.takeBytes());
    req.position = 0;
    final completer = Completer<Uint8List?>();
    Framework.uidCallAsync(uid, req, (result, error) {
      if (completer.isCompleted) return;
      if (error != null) {
        completer.completeError(StateError(error));
      } else {
        completer.complete(result);
      }
    });
    return completer.future.then(_decodeResponseInt);
  } finally {
    req.dispose();
  }
}

Future<int> mulByP2PName(String name, int a, int b) {
  final req = DataHandle('mul');
  try {
    final w = AbiWriter();
    w.writeInt64(a);
    w.writeInt64(b);
    req.writeBytes(w.takeBytes());
    req.position = 0;
    final completer = Completer<Uint8List?>();
    Framework.p2pnameCallAsync(name, req, (result, error) {
      if (completer.isCompleted) return;
      if (error != null) {
        completer.completeError(StateError(error));
      } else {
        completer.complete(result);
      }
    });
    return completer.future.then(_decodeResponseInt);
  } finally {
    req.dispose();
  }
}

Future<String> echo(String s) {
  return Isolate.run(() => _syncEcho(ABI_TARGET_APP, s));
}

String _syncEcho(String target, String s) {
  final req = DataHandle('echo');
  try {
    final w = AbiWriter();
    w.writeString(s);
    req.writeBytes(w.takeBytes());
    req.position = 0;
    final resp = Framework.call(target, req, timeoutMs: ABI_TIMEOUT_MS);
    try {
      return _decodeResponseString(resp.readAllBytes());
    } finally {
      resp.dispose();
    }
  } finally {
    req.dispose();
  }
}

Future<String> echoByUid(Uint8List uid, String s) {
  if (uid.length != 32) {
    throw RangeError('UID must be exactly 32 bytes');
  }
  final req = DataHandle('echo');
  try {
    final w = AbiWriter();
    w.writeString(s);
    req.writeBytes(w.takeBytes());
    req.position = 0;
    final completer = Completer<Uint8List?>();
    Framework.uidCallAsync(uid, req, (result, error) {
      if (completer.isCompleted) return;
      if (error != null) {
        completer.completeError(StateError(error));
      } else {
        completer.complete(result);
      }
    });
    return completer.future.then(_decodeResponseString);
  } finally {
    req.dispose();
  }
}

Future<String> echoByP2PName(String name, String s) {
  final req = DataHandle('echo');
  try {
    final w = AbiWriter();
    w.writeString(s);
    req.writeBytes(w.takeBytes());
    req.position = 0;
    final completer = Completer<Uint8List?>();
    Framework.p2pnameCallAsync(name, req, (result, error) {
      if (completer.isCompleted) return;
      if (error != null) {
        completer.completeError(StateError(error));
      } else {
        completer.complete(result);
      }
    });
    return completer.future.then(_decodeResponseString);
  } finally {
    req.dispose();
  }
}

Future<int> get_ts() {
  return Isolate.run(() => _syncGetTs(ABI_TARGET_APP));
}

int _syncGetTs(String target) {
  final req = DataHandle('get_ts');
  try {
    final resp = Framework.call(target, req, timeoutMs: ABI_TIMEOUT_MS);
    try {
      return _decodeResponseInt(resp.readAllBytes());
    } finally {
      resp.dispose();
    }
  } finally {
    req.dispose();
  }
}

Future<int> get_tsByUid(Uint8List uid) {
  if (uid.length != 32) {
    throw RangeError('UID must be exactly 32 bytes');
  }
  final req = DataHandle('get_ts');
  try {
    final completer = Completer<Uint8List?>();
    Framework.uidCallAsync(uid, req, (result, error) {
      if (completer.isCompleted) return;
      if (error != null) {
        completer.completeError(StateError(error));
      } else {
        completer.complete(result);
      }
    });
    return completer.future.then(_decodeResponseInt);
  } finally {
    req.dispose();
  }
}

Future<int> get_tsByP2PName(String name) {
  final req = DataHandle('get_ts');
  try {
    final completer = Completer<Uint8List?>();
    Framework.p2pnameCallAsync(name, req, (result, error) {
      if (completer.isCompleted) return;
      if (error != null) {
        completer.completeError(StateError(error));
      } else {
        completer.complete(result);
      }
    });
    return completer.future.then(_decodeResponseInt);
  } finally {
    req.dispose();
  }
}

void logNotify(String s) {
  final req = DataHandle('log');
  try {
    final w = AbiWriter();
    w.writeString(s);
    req.writeBytes(w.takeBytes());
    req.position = 0;
    Framework.notify(ABI_TARGET_APP, req);
  } finally {
    req.dispose();
  }
}

void logSequencedNotify(String s) {
  final req = DataHandle('log');
  try {
    final w = AbiWriter();
    w.writeString(s);
    req.writeBytes(w.takeBytes());
    req.position = 0;
    Framework.sequencedNotify(ABI_TARGET_APP, req);
  } finally {
    req.dispose();
  }
}

void logNotifyByUid(Uint8List uid, String s) {
  if (uid.length != 32) {
    throw RangeError('UID must be exactly 32 bytes');
  }
  final req = DataHandle('log');
  try {
    final w = AbiWriter();
    w.writeString(s);
    req.writeBytes(w.takeBytes());
    req.position = 0;
    Framework.uidNotify(uid, req);
  } finally {
    req.dispose();
  }
}

void logSequencedNotifyByUid(Uint8List uid, String s) {
  if (uid.length != 32) {
    throw RangeError('UID must be exactly 32 bytes');
  }
  final req = DataHandle('log');
  try {
    final w = AbiWriter();
    w.writeString(s);
    req.writeBytes(w.takeBytes());
    req.position = 0;
    Framework.uidSequencedNotify(uid, req);
  } finally {
    req.dispose();
  }
}

void logNotifyByP2PName(String name, String s) {
  final req = DataHandle('log');
  try {
    final w = AbiWriter();
    w.writeString(s);
    req.writeBytes(w.takeBytes());
    req.position = 0;
    Framework.p2pnameNotify(name, req);
  } finally {
    req.dispose();
  }
}

void logSequencedNotifyByP2PName(String name, String s) {
  final req = DataHandle('log');
  try {
    final w = AbiWriter();
    w.writeString(s);
    req.writeBytes(w.takeBytes());
    req.position = 0;
    Framework.p2pnameSequencedNotify(name, req);
  } finally {
    req.dispose();
  }
}