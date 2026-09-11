// Package testenv resolves the target environment for API, e2e and
// integration tests written in Go.
//
// Place it inside the module under test (for example internal/testenv), so
// every test package can import it. The canonical loader is
// tests/env/with-env.sh; Load falls back to reading tests/env/.env.<name>
// itself so that a bare `go test` from an IDE behaves the same way for local
// and staging. Prod goes through with-env.sh, the only thing that sets
// PROD_CONFIRM. Standard library only.
package testenv

import (
	"bufio"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// Name is the value of TEST_ENV.
type Name string

const (
	Local   Name = "local"
	Staging Name = "staging"
	Prod    Name = "prod"
)

// Env is the validated test target. Fields mirror tests/env/.env.<name>.
//
// Both origins are required because the shipped API and e2e tests read them.
// A repo with one surface drops the other field and its check in Load.
type Env struct {
	Name         Name
	APIBaseURL   string
	E2EBaseURL   string
	DatabaseURL  string // local only; empty elsewhere
	UserEmail    string // optional; from .env.<name>
	UserPassword string // optional; from .env.<name>.secret or the caller
}

// Load reads the target once per test and fails the test — never skips —
// when a required variable is missing or a lock is not held. Validation is
// per test, at the first call to Load: a test that does not call it is not
// validated, so every test in a tagged package calls Load(t) first.
func Load(t testing.TB) Env {
	t.Helper()

	raw, ok := os.LookupEnv("TEST_ENV")
	if !ok || raw == "" {
		raw = string(Local) // empty counts as unset
	}
	name := Name(raw)
	switch name {
	case Local, Staging, Prod:
	default:
		t.Fatalf("TEST_ENV=%q is not one of local, staging, prod", raw)
	}

	loadFiles(name)

	if fileName := os.Getenv("TEST_ENV"); fileName != string(name) {
		t.Fatalf("tests/env/.env.%s declares TEST_ENV=%s; the selector and the file disagree", name, fileName)
	}

	e := Env{
		Name:         name,
		APIBaseURL:   os.Getenv("API_BASE_URL"),
		E2EBaseURL:   os.Getenv("E2E_BASE_URL"),
		DatabaseURL:  os.Getenv("DATABASE_URL"),
		UserEmail:    os.Getenv("TEST_USER_EMAIL"),
		UserPassword: os.Getenv("TEST_USER_PASSWORD"),
	}

	var missing []string
	for _, v := range []struct{ key, val string }{{"API_BASE_URL", e.APIBaseURL}, {"E2E_BASE_URL", e.E2EBaseURL}} {
		if v.val == "" {
			missing = append(missing, v.key)
		} else if u, err := url.Parse(v.val); err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
			t.Fatalf("TEST_ENV=%s: %s=%q is not an http(s) URL", name, v.key, v.val)
		}
	}
	if len(missing) > 0 {
		t.Fatalf("TEST_ENV=%s: missing %s (expected in tests/env/.env.%s, secrets in .env.%s.secret, or exported by the caller)",
			name, strings.Join(missing, ", "), name, name)
	}

	if name == Prod {
		if os.Getenv("PROD_CONFIRM") != "1" {
			t.Fatalf("TEST_ENV=prod runs only through `make … ENV=prod PROD_CONFIRM=1` (with-env.sh --confirm-prod)")
		}
		if e.UserPassword != "" {
			t.Fatalf("TEST_ENV=prod is anonymous read-only: no credential may be loaded")
		}
	} else {
		// A non-prod run must not reach a prod host through a caller override.
		prodHosts := hostsDeclaredIn(filepath.Join(envDir(), ".env.prod"))
		for _, v := range []struct{ key, val string }{{"API_BASE_URL", e.APIBaseURL}, {"E2E_BASE_URL", e.E2EBaseURL}} {
			if u, err := url.Parse(v.val); err == nil && prodHosts[u.Hostname()] {
				t.Fatalf("TEST_ENV=%s: %s=%s points at a host declared in .env.prod", name, v.key, v.val)
			}
		}
	}
	return e
}

// IsRemote is true when the target is a deployment the test does not start.
func (e Env) IsRemote() bool { return e.Name != Local }

// WritesAllowed is false on prod: only read-only tests may run there.
func (e Env) WritesAllowed() bool { return e.Name != Prod }

// RequireWrites fails a mutating test that reached prod. The Makefile filters
// `-run '^TestProdSafe_'` on prod; this is the second lock in case it did not.
func (e Env) RequireWrites(t testing.TB) {
	t.Helper()
	if !e.WritesAllowed() {
		t.Fatalf("TEST_ENV=prod: %s writes data and is not on the read-only allowlist", t.Name())
	}
}

// RequireLocal fails an integration test pointed at a remote target, unless
// the caller opted into the live lane with TEST_LIVE=1. Prod is refused
// unconditionally: there is no live lane against production data.
func (e Env) RequireLocal(t testing.TB) {
	t.Helper()
	if e.Name == Prod {
		t.Fatalf("integration tests never target prod")
	}
	if e.IsRemote() && os.Getenv("TEST_LIVE") != "1" {
		t.Fatalf("integration tests target local backing services; TEST_ENV=%s needs TEST_LIVE=1 to opt into the live lane", e.Name)
	}
	if e.DatabaseURL == "" {
		t.Fatalf("TEST_ENV=%s: DATABASE_URL missing in tests/env/.env.%s", e.Name, e.Name)
	}
}

// RequireUser returns the demo credentials or fails with the file to fix.
func (e Env) RequireUser(t testing.TB) (email, password string) {
	t.Helper()
	if e.UserEmail == "" || e.UserPassword == "" {
		t.Fatalf("TEST_ENV=%s: TEST_USER_EMAIL / TEST_USER_PASSWORD missing (email in .env.%s, password in .env.%s.secret)",
			e.Name, e.Name, e.Name)
	}
	return e.UserEmail, e.UserPassword
}

// runFlags are honoured only when with-env.sh set them (it leaves the
// TEST_ENV_LOADER marker). In a bare `go test` they are discarded whatever
// their source — a file, or an `export PROD_CONFIRM=1` in a shell profile —
// so the bare path can never reach prod or the live lane.
var runFlags = []string{"PROD_CONFIRM", "TEST_LIVE"}

const loaderMarker = "with-env"

// loadMu serialises the os.Setenv calls: Load is called from every test and
// tests may run with t.Parallel().
var loadMu sync.Mutex

// loadFiles applies .env.<name>.secret then .env.<name> into the process
// environment. A variable already present is never overridden, so the order
// gives: caller > .secret > committed file — the same precedence as
// with-env.sh. Values are set process-wide on purpose: an app booted
// in-process by an integration test reads the same os.Getenv.
func loadFiles(name Name) {
	loadMu.Lock()
	defer loadMu.Unlock()

	loadedByShell := os.Getenv("TEST_ENV_LOADER") == loaderMarker
	caller := map[string]*string{}
	for _, k := range runFlags {
		if v, ok := os.LookupEnv(k); ok && loadedByShell {
			caller[k] = &v
		} else {
			caller[k] = nil
		}
	}

	dir := envDir()
	for _, f := range []string{".env." + string(name) + ".secret", ".env." + string(name)} {
		for k, v := range parseDotenv(filepath.Join(dir, f)) {
			if _, present := os.LookupEnv(k); !present {
				os.Setenv(k, v)
			}
		}
	}

	for k, v := range caller {
		if v == nil {
			os.Unsetenv(k)
		} else {
			os.Setenv(k, *v)
		}
	}
}

// hostsDeclaredIn returns the hostnames of every *_BASE_URL in an env file.
func hostsDeclaredIn(path string) map[string]bool {
	hosts := map[string]bool{}
	for k, v := range parseDotenv(path) {
		if !strings.HasSuffix(k, "_BASE_URL") {
			continue
		}
		if u, err := url.Parse(v); err == nil && u.Hostname() != "" {
			hosts[u.Hostname()] = true
		}
	}
	return hosts
}

// envDir honours TEST_ENV_DIR, else walks up from the working directory to
// the first ancestor that contains tests/env. Monorepos with go.mod below
// the repo root are covered by the walk; set TEST_ENV_DIR to pin it.
func envDir() string {
	if d := os.Getenv("TEST_ENV_DIR"); d != "" {
		return d
	}
	dir, err := os.Getwd()
	if err != nil {
		return filepath.Join("tests", "env")
	}
	for {
		candidate := filepath.Join(dir, "tests", "env")
		if st, err := os.Stat(candidate); err == nil && st.IsDir() {
			return candidate
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return filepath.Join("tests", "env")
		}
		dir = parent
	}
}

// parseDotenv reads KEY=VALUE lines into a map. It accepts the strict grammar
// with-env.sh checks before sourcing: blank lines, full-line comments, single
// or double quotes around the whole value. No interpolation, no inline
// comments, no `export`. A missing file is an empty map.
func parseDotenv(path string) map[string]string {
	out := map[string]string{}
	f, err := os.Open(path)
	if err != nil {
		return out
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, val, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		val = strings.TrimSpace(val)
		if n := len(val); n >= 2 && ((val[0] == '"' && val[n-1] == '"') || (val[0] == '\'' && val[n-1] == '\'')) {
			val = val[1 : n-1]
		}
		out[key] = val
	}
	return out
}
