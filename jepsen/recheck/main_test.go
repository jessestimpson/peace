package main

import (
	"testing"
	"time"

	"github.com/anishathalye/porcupine"
)

func verdict(t *testing.T, records []record) porcupine.CheckResult {
	t.Helper()
	evs, err := convert("test", records)
	if err != nil {
		t.Fatal(err)
	}
	return porcupine.CheckEventsTimeout(model, evs, 10*time.Second)
}

func op(kind string, process int, f string, a, b int) record {
	r := record{kind: kind, process: process, value: none, in: input{f: f, a: a, b: b}}
	if f == "read" {
		r.value = a
	}
	return r
}

func expect(t *testing.T, want porcupine.CheckResult, records []record) {
	t.Helper()
	if got := verdict(t, records); got != want {
		t.Fatalf("verdict %v, expected %v", got, want)
	}
}

// A read returns the value of the last write.
func TestWriteThenRead(t *testing.T) {
	expect(t, porcupine.Ok, []record{
		op("invoke", 0, "read", none, none), op("ok", 0, "read", none, none),
		op("invoke", 0, "write", 1, none), op("ok", 0, "write", 1, none),
		op("invoke", 1, "read", none, none), op("ok", 1, "read", 1, none),
	})
}

// A read that returns a value that was replaced is illegal.
func TestStaleRead(t *testing.T) {
	expect(t, porcupine.Illegal, []record{
		op("invoke", 0, "write", 1, none), op("ok", 0, "write", 1, none),
		op("invoke", 0, "write", 2, none), op("ok", 0, "write", 2, none),
		op("invoke", 1, "read", none, none), op("ok", 1, "read", 1, none),
	})
}

// A read that returns a value that no client wrote is illegal.
func TestReadOfNoWrite(t *testing.T) {
	expect(t, porcupine.Illegal, []record{
		op("invoke", 0, "write", 1, none), op("ok", 0, "write", 1, none),
		op("invoke", 1, "read", none, none), op("ok", 1, "read", 3, none),
	})
}

// A write with an unknown outcome may take effect after later operations.
func TestUnknownWriteTakesEffectLater(t *testing.T) {
	expect(t, porcupine.Ok, []record{
		op("invoke", 0, "write", 1, none), op("info", 0, "write", 1, none),
		op("invoke", 1, "write", 2, none), op("ok", 1, "write", 2, none),
		op("invoke", 2, "read", none, none), op("ok", 2, "read", 2, none),
		op("invoke", 3, "read", none, none), op("ok", 3, "read", 1, none),
	})
}

// A write with an unknown outcome takes effect at most once.
func TestUnknownWriteTakesEffectOnce(t *testing.T) {
	expect(t, porcupine.Illegal, []record{
		op("invoke", 0, "write", 1, none), op("info", 0, "write", 1, none),
		op("invoke", 2, "read", none, none), op("ok", 2, "read", 1, none),
		op("invoke", 1, "write", 2, none), op("ok", 1, "write", 2, none),
		op("invoke", 3, "read", none, none), op("ok", 3, "read", 1, none),
	})
}

// A write that did not return may take effect.
func TestWriteWithoutReturn(t *testing.T) {
	expect(t, porcupine.Ok, []record{
		op("invoke", 0, "write", 1, none),
		op("invoke", 1, "read", none, none), op("ok", 1, "read", 1, none),
	})
}

// A write that failed did not happen.
func TestFailedWrite(t *testing.T) {
	expect(t, porcupine.Illegal, []record{
		op("invoke", 0, "write", 1, none), op("fail", 0, "write", 1, none),
		op("invoke", 1, "read", none, none), op("ok", 1, "read", 1, none),
	})
}

// A compare-and-set that returned "ok" needs the expected value.
func TestCas(t *testing.T) {
	expect(t, porcupine.Ok, []record{
		op("invoke", 0, "write", 1, none), op("ok", 0, "write", 1, none),
		op("invoke", 0, "cas", 1, 2), op("ok", 0, "cas", 1, 2),
		op("invoke", 1, "read", none, none), op("ok", 1, "read", 2, none),
	})
	expect(t, porcupine.Illegal, []record{
		op("invoke", 0, "write", 1, none), op("ok", 0, "write", 1, none),
		op("invoke", 0, "cas", 3, 2), op("ok", 0, "cas", 3, 2),
	})
}

// A compare-and-set with an unknown outcome may change the register, and
// may change nothing.
func TestUnknownCas(t *testing.T) {
	prefix := []record{
		op("invoke", 0, "write", 1, none), op("ok", 0, "write", 1, none),
		op("invoke", 0, "cas", 1, 2), op("info", 0, "cas", 1, 2),
		op("invoke", 1, "read", none, none),
	}
	expect(t, porcupine.Ok, append(append([]record{}, prefix...), op("ok", 1, "read", 2, none)))
	expect(t, porcupine.Ok, append(append([]record{}, prefix...), op("ok", 1, "read", 1, none)))
	expect(t, porcupine.Illegal, append(append([]record{}, prefix...), op("ok", 1, "read", 3, none)))
}

// A read with an unknown outcome is dropped.
func TestUnknownRead(t *testing.T) {
	expect(t, porcupine.Ok, []record{
		op("invoke", 0, "write", 1, none), op("ok", 0, "write", 1, none),
		op("invoke", 1, "read", none, none), op("info", 1, "read", none, none),
	})
}
