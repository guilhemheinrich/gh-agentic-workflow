//go:build api

// Package api_test holds HTTP-level tests against API_BASE_URL.
//
// Run:   make test-api-go ENV=staging
// Bare:  go test -tags api ./tests/api/... (testenv loads tests/env/.env.local)
//
// Naming is the allowlist: TestProdSafe_* are read-only and are the only
// tests the Makefile runs on prod (`-run TestProdSafe`). Anything that
// writes calls env.RequireWrites(t) as the second lock.
package api_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"example.com/app/internal/testenv" // adjust to your module path
)

var client = &http.Client{Timeout: 10 * time.Second}

func TestProdSafe_Health(t *testing.T) {
	env := testenv.Load(t)

	res, err := client.Get(env.APIBaseURL + "/health")
	if err != nil {
		t.Fatalf("GET /health: %v", err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("GET /health: want 200, got %d", res.StatusCode)
	}
}

func TestProdSafe_Version(t *testing.T) {
	env := testenv.Load(t)

	res, err := client.Get(env.APIBaseURL + "/version")
	if err != nil {
		t.Fatalf("GET /version: %v", err)
	}
	defer res.Body.Close()

	var body struct {
		Version string `json:"version"`
	}
	if err := json.NewDecoder(res.Body).Decode(&body); err != nil {
		t.Fatalf("decode /version: %v", err)
	}
	if body.Version == "" {
		t.Fatalf("GET /version: empty version")
	}
}

func TestCreateItem(t *testing.T) {
	env := testenv.Load(t)
	env.RequireWrites(t)
	email, password := env.RequireUser(t)

	login, err := json.Marshal(map[string]string{"email": email, "password": password})
	if err != nil {
		t.Fatalf("marshal login: %v", err)
	}
	res, err := client.Post(env.APIBaseURL+"/auth/login", "application/json", bytes.NewReader(login))
	if err != nil {
		t.Fatalf("POST /auth/login: %v", err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("POST /auth/login: want 200, got %d", res.StatusCode)
	}
	var auth struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(res.Body).Decode(&auth); err != nil {
		t.Fatalf("decode login: %v", err)
	}

	// Run-scoped payload: staging is shared, cleanup must find its own rows.
	payload, err := json.Marshal(map[string]string{"name": "e2e-" + string(env.Name) + "-" + time.Now().Format("20060102T150405")})
	if err != nil {
		t.Fatalf("marshal item: %v", err)
	}
	req, err := http.NewRequest(http.MethodPost, env.APIBaseURL+"/items", bytes.NewReader(payload))
	if err != nil {
		t.Fatalf("build POST /items: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+auth.Token)
	req.Header.Set("Content-Type", "application/json")
	created, err := client.Do(req)
	if err != nil {
		t.Fatalf("POST /items: %v", err)
	}
	defer created.Body.Close()
	if created.StatusCode != http.StatusCreated {
		t.Fatalf("POST /items: want 201, got %d", created.StatusCode)
	}
	var item struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(created.Body).Decode(&item); err != nil {
		t.Fatalf("decode item: %v", err)
	}
	t.Cleanup(func() {
		del, err := http.NewRequest(http.MethodDelete, env.APIBaseURL+"/items/"+item.ID, nil)
		if err != nil {
			t.Errorf("build DELETE /items/%s: %v", item.ID, err)
			return
		}
		del.Header.Set("Authorization", "Bearer "+auth.Token)
		res, err := client.Do(del)
		if err != nil {
			t.Errorf("DELETE /items/%s: %v (row left on %s)", item.ID, err, env.Name)
			return
		}
		res.Body.Close()
		if res.StatusCode != http.StatusNoContent {
			t.Errorf("DELETE /items/%s: want 204, got %d", item.ID, res.StatusCode)
		}
	})
}
