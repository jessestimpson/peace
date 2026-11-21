// Command recheck checks the history of one key of a Jepsen run of peace
// for linearizability, with the Porcupine checker.
//
// Usage: recheck [-timeout SECONDS] [-workers N] HISTORY.edn...
//
// Each argument is the history of one key, as Jepsen writes it to
// store/TEST/TIME/independent/KEY/history.edn. The command prints one line
// for each history: the verdict, a tab, and the path. The verdict is one
// of:
//
//   - "ok": the history is linearizable.
//   - "ILLEGAL": the history is not linearizable.
//   - "unknown": the check did not finish within the time limit.
//
// The exit status is 1 if a history is not linearizable, 2 if no history
// is illegal and a check did not finish, and 0 otherwise.
//
// The command exists because the checker of the Jepsen test, Knossos, runs
// out of memory on some keys. See "Soak test" in ../README.md.
//
// # Model
//
// The model is a register with read, write and compare-and-set. The
// register starts with no value. A read that returned no value is legal
// only when the register holds no value.
//
// The model of the Jepsen test, the compare-and-set register of Knossos,
// differs in one rule: it accepts a read that returned no value in every
// state. This command therefore reports some histories that Knossos
// accepts. The key-value node never removes a key, so a read that returns
// no value after a write of the key is a violation.
//
// # Operations
//
// An operation is kept or dropped as follows. Knossos uses the same
// rules.
//
//   - An operation that returned "ok" is kept.
//   - An operation that returned "fail" did not happen. It is dropped.
//   - A read that returned "info", or that did not return, is dropped. A
//     read changes nothing.
//   - A write or a compare-and-set that returned "info", or that did not
//     return, has an unknown outcome. It is kept. It may take effect at
//     any time after its invocation, so its return is placed after every
//     other event. A compare-and-set with an unknown outcome changes the
//     register if the register holds the expected value, and changes
//     nothing otherwise.
package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"regexp"
	"runtime"
	"strconv"
	"sync"
	"time"

	"github.com/anishathalye/porcupine"
)

// The value of a register that holds no value.
const none = -1

type input struct {
	f string
	// For a write: the value. For a compare-and-set: the expected value.
	a int
	// For a compare-and-set: the new value.
	b int
}

type output struct {
	// Whether the outcome of the operation is known.
	known bool
	// For a read: the value.
	value int
}

var model = porcupine.Model{
	Init: func() interface{} { return none },
	Step: func(st, in, out interface{}) (bool, interface{}) {
		s := st.(int)
		i := in.(input)
		o := out.(output)
		switch i.f {
		case "read":
			return o.value == s, s
		case "write":
			return true, i.a
		default:
			if s == i.a {
				return true, i.b
			}
			// A compare-and-set that returned "ok" needs the expected
			// value. One with an unknown outcome changes nothing here.
			return !o.known, s
		}
	},
	DescribeOperation: func(in, out interface{}) string {
		i, o := in.(input), out.(output)
		result := "ok"
		if !o.known {
			result = "unknown"
		}
		switch i.f {
		case "read":
			return fmt.Sprintf("read() -> %d", o.value)
		case "write":
			return fmt.Sprintf("write(%d) -> %s", i.a, result)
		default:
			return fmt.Sprintf("cas(%d, %d) -> %s", i.a, i.b, result)
		}
	},
}

var (
	reType    = regexp.MustCompile(`:type :(\w+)`)
	reProcess = regexp.MustCompile(`:process (\d+)`)
	reF       = regexp.MustCompile(`:f :([\w-]+)`)
	reValue   = regexp.MustCompile(`:value (nil|\d+|\[(\d+) (\d+)\])`)
)

// One event of a client in a history.
type record struct {
	line    int
	kind    string
	process int
	in      input
	value   int
}

// history reads the history in the file `path` and converts it to
// Porcupine events.
func history(path string) ([]porcupine.Event, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	var records []record
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 1<<20), 1<<26)
	for n := 1; scanner.Scan(); n++ {
		line := scanner.Text()
		p := reProcess.FindStringSubmatch(line)
		if p == nil {
			// An event of the nemesis.
			continue
		}
		t := reType.FindStringSubmatch(line)
		f := reF.FindStringSubmatch(line)
		v := reValue.FindStringSubmatch(line)
		if t == nil || f == nil || v == nil {
			return nil, fmt.Errorf("%s:%d: cannot read the event", path, n)
		}
		if f[1] != "read" && f[1] != "write" && f[1] != "cas" {
			return nil, fmt.Errorf("%s:%d: unknown operation %s", path, n, f[1])
		}
		r := record{line: n, kind: t[1], value: none, in: input{f: f[1], a: none, b: none}}
		r.process, _ = strconv.Atoi(p[1])
		if v[2] != "" {
			r.in.a, _ = strconv.Atoi(v[2])
			r.in.b, _ = strconv.Atoi(v[3])
		} else if v[1] != "nil" {
			r.value, _ = strconv.Atoi(v[1])
			r.in.a = r.value
		}
		records = append(records, r)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return convert(path, records)
}

// convert converts the events of the clients to Porcupine events. The
// identifier of an operation is the position of its invocation in
// `records`.
func convert(path string, records []record) ([]porcupine.Event, error) {
	// The outcome of each invocation: "ok", "fail", "info", or "" for an
	// invocation that did not return.
	outcome := map[int]string{}
	// The invocation of each process that has not returned.
	open := map[int]int{}
	for i, r := range records {
		switch r.kind {
		case "invoke":
			if _, busy := open[r.process]; busy {
				return nil, fmt.Errorf("%s:%d: process %d has two invocations", path, r.line, r.process)
			}
			open[r.process] = i
		case "ok", "fail", "info":
			id, found := open[r.process]
			if !found {
				return nil, fmt.Errorf("%s:%d: process %d returns without an invocation", path, r.line, r.process)
			}
			if records[id].in.f != r.in.f {
				return nil, fmt.Errorf("%s:%d: process %d returns from another operation", path, r.line, r.process)
			}
			delete(open, r.process)
			outcome[id] = r.kind
		default:
			return nil, fmt.Errorf("%s:%d: unknown type %s", path, r.line, r.kind)
		}
	}
	var evs []porcupine.Event
	var unknown []int
	for i, r := range records {
		switch r.kind {
		case "invoke":
			switch {
			case outcome[i] == "ok":
				evs = append(evs, porcupine.Event{ClientId: r.process, Kind: porcupine.CallEvent, Value: r.in, Id: i})
			case outcome[i] != "fail" && r.in.f != "read":
				evs = append(evs, porcupine.Event{ClientId: r.process, Kind: porcupine.CallEvent, Value: r.in, Id: i})
				unknown = append(unknown, i)
			}
			open[r.process] = i
		case "ok":
			id := open[r.process]
			evs = append(evs, porcupine.Event{ClientId: r.process, Kind: porcupine.ReturnEvent, Value: output{known: true, value: r.value}, Id: id})
		}
	}
	for _, id := range unknown {
		evs = append(evs, porcupine.Event{ClientId: records[id].process, Kind: porcupine.ReturnEvent, Value: output{}, Id: id})
	}
	return evs, nil
}

func main() {
	timeout := flag.Int("timeout", 300, "time limit for one history, in seconds")
	workers := flag.Int("workers", runtime.NumCPU(), "number of histories that are checked at the same time")
	flag.Parse()
	paths := flag.Args()
	verdicts := make([]string, len(paths))
	var wg sync.WaitGroup
	var mu sync.Mutex
	jobs := make(chan int)
	for w := 0; w < *workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range jobs {
				v := check(paths[i], time.Duration(*timeout)*time.Second)
				mu.Lock()
				verdicts[i] = v
				fmt.Printf("%s\t%s\n", v, paths[i])
				mu.Unlock()
			}
		}()
	}
	for i := range paths {
		jobs <- i
	}
	close(jobs)
	wg.Wait()
	status := 0
	for _, v := range verdicts {
		switch {
		case v == "ILLEGAL":
			status = 1
		case v != "ok" && status == 0:
			status = 2
		}
	}
	os.Exit(status)
}

// check returns the verdict for the history in the file `path`.
func check(path string, timeout time.Duration) string {
	evs, err := history(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return "error"
	}
	switch porcupine.CheckEventsTimeout(model, evs, timeout) {
	case porcupine.Ok:
		return "ok"
	case porcupine.Illegal:
		return "ILLEGAL"
	default:
		return "unknown"
	}
}
