package test

import (
	"bytes"
	"testing"

	"github.com/PassByYou888/LingoFuse/go/lingofuse"
)

func TestScalarRoundtrip(t *testing.T) {
	ensureLib(t)

	h, err := lingofuse.NewDataHandle("test_scalar")
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	if err := h.WriteInt32(42); err != nil {
		t.Fatalf("WriteInt32: %v", err)
	}
	if err := h.WriteDouble(3.14159); err != nil {
		t.Fatalf("WriteDouble: %v", err)
	}
	if err := h.WriteUint64(0xDEADBEEFCAFEBABE); err != nil {
		t.Fatalf("WriteUint64: %v", err)
	}
	if err := h.WriteSingle(2.5); err != nil {
		t.Fatalf("WriteSingle: %v", err)
	}
	if err := h.WriteInt16(-1234); err != nil {
		t.Fatalf("WriteInt16: %v", err)
	}
	if err := h.WriteInt8(-7); err != nil {
		t.Fatalf("WriteInt8: %v", err)
	}

	// Expected wire size: 4 + 8 + 8 + 4 + 2 + 1 = 27 bytes.
	sz, err := h.Size()
	if err != nil {
		t.Fatal(err)
	}
	if sz != 27 {
		t.Fatalf("size = %d, want 27", sz)
	}

	if err := h.SetPosition(0); err != nil {
		t.Fatal(err)
	}

	if v, err := h.ReadInt32(); err != nil || v != 42 {
		t.Fatalf("ReadInt32 = %d, %v", v, err)
	}
	if v, err := h.ReadDouble(); err != nil || v != 3.14159 {
		t.Fatalf("ReadDouble = %v, %v", v, err)
	}
	if v, err := h.ReadUint64(); err != nil || v != 0xDEADBEEFCAFEBABE {
		t.Fatalf("ReadUint64 = %x, %v", v, err)
	}
	if v, err := h.ReadSingle(); err != nil || v != 2.5 {
		t.Fatalf("ReadSingle = %v, %v", v, err)
	}
	if v, err := h.ReadInt16(); err != nil || v != -1234 {
		t.Fatalf("ReadInt16 = %d, %v", v, err)
	}
	if v, err := h.ReadInt8(); err != nil || v != -7 {
		t.Fatalf("ReadInt8 = %d, %v", v, err)
	}
}

func TestStringTriState(t *testing.T) {
	ensureLib(t)

	t.Run("NULPresent", func(t *testing.T) {
		h, err := lingofuse.NewDataHandle("test_str_nul")
		if err != nil {
			t.Fatal(err)
		}
		defer h.Close()

		if err := h.WriteString("hello"); err != nil {
			t.Fatal(err)
		}
		if err := h.WriteString("world"); err != nil {
			t.Fatal(err)
		}
		if err := h.SetPosition(0); err != nil {
			t.Fatal(err)
		}

		if s, err := h.ReadString(); err != nil || s != "hello" {
			t.Fatalf("first ReadString = %q, %v", s, err)
		}
		if s, err := h.ReadString(); err != nil || s != "world" {
			t.Fatalf("second ReadString = %q, %v", s, err)
		}
	})

	t.Run("NoNUL", func(t *testing.T) {
		h, err := lingofuse.NewDataHandle("test_str_no_nul")
		if err != nil {
			t.Fatal(err)
		}
		defer h.Close()

		if err := h.WriteBytes([]byte(`{"a":1}`)); err != nil {
			t.Fatal(err)
		}
		if err := h.SetPosition(0); err != nil {
			t.Fatal(err)
		}

		if s, err := h.ReadString(); err != nil || s != `{"a":1}` {
			t.Fatalf("ReadString = %q, %v", s, err)
		}
		// Cursor advanced past the end of the buffer; subsequent
		// reads return empty.
		if s, err := h.ReadString(); err != nil || s != "" {
			t.Fatalf("post-exhausted ReadString = %q, %v", s, err)
		}
	})

	t.Run("EmptyAtEnd", func(t *testing.T) {
		h, err := lingofuse.NewDataHandle("test_str_empty")
		if err != nil {
			t.Fatal(err)
		}
		defer h.Close()

		if s, err := h.ReadString(); err != nil || s != "" {
			t.Fatalf("empty ReadString = %q, %v", s, err)
		}
	})

	t.Run("EmptyStringWritesSingleNUL", func(t *testing.T) {
		h, err := lingofuse.NewDataHandle("test_str_empty_write")
		if err != nil {
			t.Fatal(err)
		}
		defer h.Close()

		if err := h.WriteString(""); err != nil {
			t.Fatal(err)
		}
		sz, _ := h.Size()
		if sz != 1 {
			t.Fatalf("size = %d, want 1", sz)
		}
		if err := h.SetPosition(0); err != nil {
			t.Fatal(err)
		}
		if s, err := h.ReadString(); err != nil || s != "" {
			t.Fatalf("ReadString = %q, %v", s, err)
		}
	})
}

func TestExactReadRestoresCursor(t *testing.T) {
	ensureLib(t)

	h, err := lingofuse.NewDataHandle("test_exact")
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	if err := h.WriteBytes([]byte{1, 2}); err != nil {
		t.Fatal(err)
	}
	if err := h.SetPosition(0); err != nil {
		t.Fatal(err)
	}

	// ReadBytesExact(4) on a 2-byte buffer: must fail and restore
	// the cursor.
	if _, err := h.ReadBytesExact(4); err == nil {
		t.Fatal("ReadBytesExact(4) should fail on a 2-byte buffer")
	}
	pos, _ := h.Position()
	if pos != 0 {
		t.Fatalf("cursor after failed exact read = %d, want 0", pos)
	}

	// TryReadBytes(4): returns (nil, false, nil), cursor unchanged.
	data, ok, err := h.TryReadBytes(4)
	if err != nil {
		t.Fatal(err)
	}
	if ok || data != nil {
		t.Fatalf("TryReadBytes should fail: ok=%v data=%v", ok, data)
	}
	pos, _ = h.Position()
	if pos != 0 {
		t.Fatalf("cursor after failed try read = %d, want 0", pos)
	}

	// ReadBytesExact(2) on a 2-byte buffer: must succeed.
	data, err = h.ReadBytesExact(2)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(data, []byte{1, 2}) {
		t.Fatalf("data = %v, want [1 2]", data)
	}
}

func TestJSONRoundtrip(t *testing.T) {
	ensureLib(t)

	h, err := lingofuse.NewDataHandle("test_json_rt")
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	type args struct {
		A int `json:"a"`
		B int `json:"b"`
	}
	if err := lingofuse.WriteJSON(h, args{A: 5, B: 7}); err != nil {
		t.Fatal(err)
	}
	if err := h.SetPosition(0); err != nil {
		t.Fatal(err)
	}

	var out args
	if err := lingofuse.ReadJSON(h, &out); err != nil {
		t.Fatal(err)
	}
	if out.A != 5 || out.B != 7 {
		t.Fatalf("roundtrip mismatch: %+v", out)
	}
}

func TestJSONUnicodePreservedLiterally(t *testing.T) {
	ensureLib(t)

	h, err := lingofuse.NewDataHandle("test_json_unicode")
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	type msg struct {
		Text string `json:"text"`
	}
	const original = "你好 🌍"
	if err := lingofuse.WriteJSON(h, msg{Text: original}); err != nil {
		t.Fatal(err)
	}

	// Inspect the wire bytes: must contain literal UTF-8, not
	// \uXXXX escapes.
	if err := h.SetPosition(0); err != nil {
		t.Fatal(err)
	}
	raw, err := lingofuse.ReadStringBytes(h)
	if err != nil {
		t.Fatal(err)
	}
	s := string(raw)
	if !bytes.Contains(raw, []byte("你好")) {
		t.Fatalf("CJK not literal in payload: %q", s)
	}
	if bytes.Contains(raw, []byte(`\u`)) {
		t.Fatalf("payload contains \\uXXXX escapes: %q", s)
	}

	// Full round trip.
	if err := h.SetPosition(0); err != nil {
		t.Fatal(err)
	}
	var back msg
	if err := lingofuse.ReadJSON(h, &back); err != nil {
		t.Fatal(err)
	}
	if back.Text != original {
		t.Fatalf("roundtrip = %q, want %q", back.Text, original)
	}
}

func TestReadJSONOrBytesVariants(t *testing.T) {
	ensureLib(t)

	t.Run("Empty", func(t *testing.T) {
		h, err := lingofuse.NewDataHandle("test_job_empty")
		if err != nil {
			t.Fatal(err)
		}
		defer h.Close()

		v, err := lingofuse.ReadJSONOrBytes(h)
		if err != nil {
			t.Fatal(err)
		}
		if !v.Empty {
			t.Fatalf("expected Empty, got %+v", v)
		}
	})

	t.Run("ValidJSON", func(t *testing.T) {
		h, err := lingofuse.NewDataHandle("test_job_json")
		if err != nil {
			t.Fatal(err)
		}
		defer h.Close()

		if err := lingofuse.WriteString(h, `{"a":1}`); err != nil {
			t.Fatal(err)
		}
		if err := h.SetPosition(0); err != nil {
			t.Fatal(err)
		}

		v, err := lingofuse.ReadJSONOrBytes(h)
		if err != nil {
			t.Fatal(err)
		}
		if !v.IsJSON || v.Empty {
			t.Fatalf("expected JSON, got %+v", v)
		}
	})

	t.Run("NonJSONBytes", func(t *testing.T) {
		h, err := lingofuse.NewDataHandle("test_job_bytes")
		if err != nil {
			t.Fatal(err)
		}
		defer h.Close()

		if err := lingofuse.WriteString(h, "hello world"); err != nil {
			t.Fatal(err)
		}
		if err := h.SetPosition(0); err != nil {
			t.Fatal(err)
		}

		v, err := lingofuse.ReadJSONOrBytes(h)
		if err != nil {
			t.Fatal(err)
		}
		if v.Empty || v.IsJSON {
			t.Fatalf("expected Bytes, got %+v", v)
		}
		if string(v.Bytes) != "hello world" {
			t.Fatalf("bytes = %q", v.Bytes)
		}
	})
}

func TestPermanentHandleStillWorks(t *testing.T) {
	ensureLib(t)

	h, err := lingofuse.CreatePermanent("test_perm")
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	// 0x12345678 fits in int32; 0xCAFEBABE would overflow.
	const want int32 = 0x12345678
	if err := h.WriteInt32(want); err != nil {
		t.Fatal(err)
	}
	if err := h.SetPosition(0); err != nil {
		t.Fatal(err)
	}
	v, err := h.ReadInt32()
	if err != nil || v != want {
		t.Fatalf("roundtrip = %x, %v (want %x)", v, err, want)
	}
}

// TestPermanentHandleUint32 also exercises the 0xCAFEBABE value, but
// through the uint32 API where it fits without overflow.
func TestPermanentHandleUint32(t *testing.T) {
	ensureLib(t)

	h, err := lingofuse.CreatePermanent("test_perm_u32")
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	const want uint32 = 0xCAFEBABE
	if err := h.WriteUint32(want); err != nil {
		t.Fatal(err)
	}
	if err := h.SetPosition(0); err != nil {
		t.Fatal(err)
	}
	v, err := h.ReadUint32()
	if err != nil || v != want {
		t.Fatalf("roundtrip = %x, %v (want %x)", v, err, want)
	}
}
