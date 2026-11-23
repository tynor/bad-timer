// Regenerate: go run tests/duration_oracle.go > src/duration_cases.json
package main

import (
	"encoding/json"
	"os"
	"time"
)

func main() {
	type entry struct {
		Text        string `json:"text"`
		Nanoseconds *int64 `json:"nanoseconds"`
	}
	var cases []entry
	for _, text := range []string{
		"0", "+0", "-0", "0s", "-0.1ns", "1h30m", "2.5h", "300ms", ".5s", "1.s", "1h.5m", "1s2s", "1us", "1µs", "1μs", "1.0000000009s", "0.9ns0.9ns", "0.333333333333333333333333h", "0.999999999999999999999999h", "2562047h47m16.854775807s", "9223372036854775807ns", "9223372036854775808ns", "-9223372036854775808ns", "-1s", "", "+", "-", ".s", "1", "00", "1d", "1e3s", " 1s", "1s ", "1S", "1s-1s", "1s+1s", "1..0s", "1.2.3s", "999999999999999999999h", "9223372036854775807ns1ns", "0.000000000000000000001h",
	} {
		c := entry{Text: text}
		if d, err := time.ParseDuration(text); err == nil && d >= 0 {
			n := int64(d)
			c.Nanoseconds = &n
		}
		cases = append(cases, c)
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(cases); err != nil {
		panic(err)
	}
}
