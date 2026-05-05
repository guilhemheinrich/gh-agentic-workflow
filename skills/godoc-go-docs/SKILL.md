---
name: godoc-go-docs
description: Documents Go code with godoc conventions, generates API documentation, and follows Go documentation best practices. Use when users request "godoc", "Go documentation", "API docs", "pkgsite", or "inline documentation" in a Go project.
---

# Go Documentation (godoc)

Create comprehensive inline documentation for Go codebases following official godoc conventions.

## Core Workflow

1. **Document packages**: Package-level comments
2. **Document functions**: Purpose, parameters in prose, examples
3. **Document types**: Structs, interfaces, methods
4. **Write examples**: Testable `Example*` functions
5. **Generate docs**: `go doc` / pkgsite output
6. **Integrate CI**: Automated doc checks

## Key Convention

Go documentation comments are **plain prose** — no tags like `@param`. The comment must start with the name of the symbol it describes.

## Package Documentation

```go
// Package session provides Redis-backed session storage for the Auth
// bounded context.
//
// It implements [SessionStore] as defined in the domain/ports package,
// handling persistence, TTL management, and cache invalidation.
//
// See also: [domain/ports.SessionStore], [domain/entities.HubSession].
package session
```

For large packages, use a `doc.go` file:

```go
// Package auth implements the authentication and authorization bounded
// context for the Hub platform.
//
// # Architecture
//
// This package follows hexagonal architecture. Domain types live in the
// entities/ sub-package, port interfaces in ports/, and infrastructure
// adapters in adapters/.
//
// # Session Flow
//
// A typical login flow:
//
//  1. User redirects to Keycloak via [LoginHandler].
//  2. Keycloak calls back with an auth code.
//  3. [ExchangeCodeUseCase] trades the code for tokens.
//  4. A [HubSession] is persisted via [SessionStore].
//
// See the ADR-007 for TTL alignment details.
package auth
```

## Function Documentation

### Basic Function

```go
// CalculateTotal returns the total price including tax.
// The taxRate is expressed as a decimal (e.g., 0.08 for 8%).
func CalculateTotal(price, taxRate float64) float64 {
	return price * (1 + taxRate)
}
```

### Function with Errors

```go
// FetchUser retrieves user data from the external API.
//
// It returns a fully hydrated [User] with profile data.
// If the user does not exist, it returns [ErrNotFound].
// On network failures it returns a wrapped [NetworkError].
//
// FetchUser is called after Keycloak redirect to establish
// the authenticated context.
func FetchUser(ctx context.Context, userID string, opts ...RequestOption) (*User, error) {
	// ...
}
```

### Constructor / Factory

```go
// NewApiClient creates an [ApiClient] configured with the given options.
//
// It panics if cfg.BaseURL is empty. For a non-panicking alternative,
// use [NewApiClientFromConfig].
func NewApiClient(cfg ApiClientConfig) *ApiClient {
	if cfg.BaseURL == "" {
		panic("apiClient: base URL is required")
	}
	return &ApiClient{
		baseURL: cfg.BaseURL,
		timeout: cfg.Timeout,
		client:  &http.Client{Timeout: cfg.Timeout},
	}
}
```

## Struct Documentation

```go
// User represents a user in the Identity bounded context.
//
// A User is always created through [NewUser] or loaded via
// [UserRepository.FindByID].
type User struct {
	// ID is the unique identifier (UUID v4).
	ID string

	// Email is the user's email address.
	Email string

	// Name is the user's display name.
	Name string

	// Role is the user's role in the system.
	// Valid values: "admin", "user", "guest". Defaults to "user".
	Role string

	// CreatedAt records when the account was created.
	CreatedAt time.Time

	// UpdatedAt records the last modification time. Zero value means
	// the account has never been updated.
	UpdatedAt time.Time
}
```

## Interface Documentation

```go
// SessionStore defines the contract for session persistence.
//
// Production implementation: [RedisSessionStore] in adapters/redis/.
// Test double: [InMemorySessionStore] in adapters/memory/.
type SessionStore interface {
	// Save persists a session with automatic TTL.
	Save(ctx context.Context, session *HubSession) error

	// FindByID retrieves a session by its unique identifier.
	// It returns nil, nil if the session is expired or missing.
	FindByID(ctx context.Context, id string) (*HubSession, error)
}
```

## Method Documentation

```go
// Get performs an HTTP GET request to the given endpoint.
//
// The endpoint is relative to the client's base URL. Response body
// is decoded into the value pointed to by result.
//
// It returns an [ApiError] on non-2xx status codes.
func (c *ApiClient) Get(ctx context.Context, endpoint string, result any) error {
	return c.request(ctx, http.MethodGet, endpoint, nil, result)
}
```

## Constants and Variables

```go
// SessionTTL is the maximum session duration before forced
// re-authentication. Aligned with Keycloak realm SSO session idle
// timeout (ADR-007).
const SessionTTL = 8 * time.Hour
```

```go
// Sentinel errors for the user domain.
var (
	// ErrNotFound is returned when a user does not exist.
	ErrNotFound = errors.New("user: not found")

	// ErrDuplicateEmail is returned when the email is already registered.
	ErrDuplicateEmail = errors.New("user: duplicate email")
)
```

## Enum-like Constants (iota)

```go
// OrderStatus represents the processing state of an order.
//
// Orders progress through these statuses in sequence,
// though they may skip directly to [OrderCancelled] from any state.
type OrderStatus int

const (
	// OrderPending means the order has been created but not yet processed.
	OrderPending OrderStatus = iota

	// OrderProcessing means payment was received and preparation started.
	OrderProcessing

	// OrderShipped means the order has been shipped to the customer.
	OrderShipped

	// OrderDelivered means the order has been delivered.
	OrderDelivered

	// OrderCancelled means the order has been cancelled.
	OrderCancelled

	// OrderReturned means the order was returned by the customer.
	OrderReturned
)
```

## Testable Examples

```go
func ExampleCalculateTotal() {
	total := CalculateTotal(100, 0.08)
	fmt.Println(total)
	// Output: 108
}

func ExampleApiClient_Get() {
	client := NewApiClient(ApiClientConfig{
		BaseURL: "https://api.example.com",
	})

	var users []User
	err := client.Get(context.Background(), "/users", &users)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(len(users))
}
```

## Documentation Commands

```bash
# View package docs locally
go doc ./...

# View a specific symbol
go doc ApiClient.Get

# Run a local pkgsite server
go install golang.org/x/pkgsite/cmd/pkgsite@latest
pkgsite -http=:6060

# Verify examples compile and pass
go test -run Example ./...
```

## Go Doc Conventions Reference

- Comment starts with the **name** of the declared symbol
- First sentence is the summary (shown in package index)
- Use `[Symbol]` to create doc links (Go 1.19+)
- Headings: lines starting with `# ` in package comments
- Lists: lines starting with `  - ` or numbered `  1. `
- Code blocks: indented by one tab or space relative to surrounding text
- Paragraphs separated by blank comment lines
- `// Deprecated: Use [NewThing] instead.` marks deprecation

## Best Practices

1. **Document all exported symbols**: The first sentence is the summary
2. **Start with the symbol name**: `// FetchUser retrieves...` not `// This function retrieves...`
3. **Write complete sentences**: Proper punctuation, imperative mood
4. **Use doc links**: `[Symbol]` for cross-references (Go 1.19+)
5. **Write testable examples**: `Example*` functions in `_test.go` files
6. **Package doc in doc.go**: For packages with rich documentation
7. **Document errors**: Mention which sentinel errors or error types are returned
8. **Keep it prose**: No `@param`-style tags — describe parameters in natural language

## Output Checklist

- [ ] All exported functions have doc comments starting with their name
- [ ] All exported types (structs, interfaces) are documented
- [ ] All exported struct fields have comments
- [ ] All exported constants/variables are documented
- [ ] Package comment present (in doc.go for large packages)
- [ ] Testable Example functions for key APIs
- [ ] Error return values documented
- [ ] Doc links (`[Symbol]`) used for cross-references
- [ ] `go vet` passes (includes doc comment checks)
- [ ] Examples compile and pass (`go test -run Example`)
