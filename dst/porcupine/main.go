// Command porcupine checks a client history of a simulated peace run for
// linearizability, with the Porcupine checker.
//
// Usage: porcupine [-html FILE] HISTORY.json
//
// The command prints "ok" and exits with status 0 if the history is
// linearizable. It prints "ILLEGAL" and exits with status 1 if the history
// is not linearizable. It prints "unknown" and exits with status 2 if the
// check did not finish within the time limit.
//
// The history format is described in dst/peace_dst_history.erl.
//
// The model is the machine of the simulation, peace_dst_machine: a log of
// values.
//
//   - append(v) adds v to the end of the log. The reply is the index of v
//     in the replicated log of peace. Indexes increase along the log. They
//     are not consecutive, because peace also uses indexes for entries
//     that are not client values.
//   - read() returns every value in the log, in order.
//
// # State
//
// A model whose state is the whole log makes the search too large: the
// simulation runs many appends at the same time, and every order of them is
// a different state. The command therefore fixes the order of the values
// before the search, from the reads.
//
// The log only grows, so in a linearizable history every read is a prefix
// of every longer read. The command first checks this, and reports ILLEGAL
// if two reads disagree. The longest read then gives the position of every
// value that any read returned. A value that no read returned was appended
// after every read. Such values follow in the order of their indexes.
//
// The state of the model is then the number of values in the log and the
// index of the last append. An append is legal if its value is the next
// value in the fixed order. A read is legal if it returned as many values
// as the log holds. Porcupine searches for an order of the operations that
// agrees with the times of their invocations and returns.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"sort"
	"time"

	"github.com/anishathalye/porcupine"
)

type event struct {
	Seq    int    `json:"seq"`
	Client int    `json:"client"`
	Type   string `json:"type"`
	Op     string `json:"op"`
	Value  int    `json:"value"`
	Index  *int   `json:"index"`
	Values *[]int `json:"values"`
}

type input struct {
	read  bool
	value int
}

type output struct {
	// For an append: the index, or 0 if the client did not learn the index.
	index int
	// For a read.
	values []int
}

type state struct {
	// The number of values in the log.
	n int
	// The index of the last append whose index is known.
	last int
}

// The position in the log of the value of each append that is checked,
// from 1.
var position = map[int]int{}

var model = porcupine.Model{
	Init: func() interface{} { return state{} },
	Step: func(st, in, out interface{}) (bool, interface{}) {
		s := st.(state)
		i := in.(input)
		o := out.(output)
		if i.read {
			return len(o.values) == s.n, s
		}
		next := state{n: s.n + 1, last: s.last}
		if position[i.value] != s.n+1 {
			return false, s
		}
		if o.index == 0 {
			return true, next
		}
		next.last = o.index
		return o.index > s.last, next
	},
	DescribeOperation: func(in, out interface{}) string {
		i, o := in.(input), out.(output)
		if i.read {
			return fmt.Sprintf("read() -> %v", o.values)
		}
		if o.index == 0 {
			return fmt.Sprintf("append(%d) -> unknown", i.value)
		}
		return fmt.Sprintf("append(%d) -> index %d", i.value, o.index)
	},
}

// order fixes the positions of the values. It returns false if a read is
// not a prefix of the longest read, or returns a value twice.
func order(events []event) bool {
	var long []int
	for _, e := range events {
		if e.Values != nil && len(*e.Values) > len(long) {
			long = *e.Values
		}
	}
	for i, v := range long {
		if _, twice := position[v]; twice {
			return false
		}
		position[v] = i + 1
	}
	for _, e := range events {
		if e.Values != nil && !equal(*e.Values, long[:len(*e.Values)]) {
			return false
		}
	}
	// The values that no read returned follow, in the order of their
	// indexes. Each of them has a known index: `operations` drops an append
	// with an unknown outcome whose value no read returned.
	value := map[int]int{}
	for _, e := range events {
		if e.Type == "invoke" && e.Op == "append" {
			value[e.Client] = e.Value
		}
	}
	var rest []event
	for _, e := range events {
		if e.Type == "ok" && e.Index != nil {
			if _, read := position[value[e.Client]]; !read {
				rest = append(rest, e)
			}
		}
	}
	sort.Slice(rest, func(i, j int) bool { return *rest[i].Index < *rest[j].Index })
	for i, e := range rest {
		position[value[e.Client]] = len(long) + i + 1
	}
	return true
}

func equal(a, b []int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// operations converts the events of a history to Porcupine events.
//
// Each client performs one operation. An operation is kept or dropped as
// follows:
//
//   - An operation that returned "ok" is kept.
//   - An operation that returned "fail" was never submitted. It is dropped.
//   - A read with any other outcome is dropped. A read changes nothing.
//   - An append with an unknown outcome is kept if some read returned its
//     value. The append then happened, at an unknown index, and it may have
//     taken effect at any time after its invocation. Its return is placed
//     after every other event.
//   - An append with an unknown outcome whose value no read returned is
//     dropped. If the append happened, it happened after every read, and
//     no client observed it.
func operations(events []event) []porcupine.Event {
	seen := map[int]bool{}
	returned := map[int]event{}
	for _, e := range events {
		if e.Type != "invoke" {
			returned[e.Client] = e
		}
		if e.Values != nil {
			for _, v := range *e.Values {
				seen[v] = true
			}
		}
	}
	var out, late []porcupine.Event
	for _, e := range events {
		if e.Type == "invoke" {
			r, done := returned[e.Client]
			read := e.Op == "read"
			known := done && r.Type == "ok"
			if !known && (read || !seen[e.Value]) {
				continue
			}
			out = append(out, porcupine.Event{
				ClientId: e.Client, Kind: porcupine.CallEvent, Id: e.Client,
				Value: input{read: read, value: e.Value},
			})
			if !known {
				late = append(late, porcupine.Event{
					ClientId: e.Client, Kind: porcupine.ReturnEvent, Id: e.Client,
					Value: output{},
				})
			}
			continue
		}
		if e.Type != "ok" {
			continue
		}
		o := output{}
		if e.Index != nil {
			o.index = *e.Index
		}
		if e.Values != nil {
			o.values = *e.Values
		}
		out = append(out, porcupine.Event{
			ClientId: e.Client, Kind: porcupine.ReturnEvent, Id: e.Client, Value: o,
		})
	}
	return append(out, late...)
}

func main() {
	html := flag.String("html", "", "write a visualization of the history to this file")
	limit := flag.Duration("timeout", 60*time.Second, "time limit for the check")
	flag.Parse()
	if flag.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: porcupine [-html FILE] HISTORY.json")
		os.Exit(3)
	}
	data, err := os.ReadFile(flag.Arg(0))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(3)
	}
	var events []event
	if err := json.Unmarshal(data, &events); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(3)
	}
	ops := operations(events)
	if !order(events) {
		fmt.Printf("ILLEGAL %d operations\n", len(ops)/2)
		os.Exit(1)
	}
	result, info := porcupine.CheckEventsVerbose(model, ops, *limit)
	if *html != "" {
		if err := porcupine.VisualizePath(model, info, *html); err != nil {
			fmt.Fprintln(os.Stderr, err)
		}
	}
	switch result {
	case porcupine.Ok:
		fmt.Printf("ok %d operations\n", len(ops)/2)
	case porcupine.Illegal:
		fmt.Printf("ILLEGAL %d operations\n", len(ops)/2)
		os.Exit(1)
	default:
		fmt.Printf("unknown %d operations\n", len(ops)/2)
		os.Exit(2)
	}
}
