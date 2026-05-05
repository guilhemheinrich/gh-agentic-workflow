---
name: rustdoc-rust-docs
description: Documents Rust code with rustdoc comments, generates API documentation, and follows Rust documentation best practices. Use when users request "rustdoc", "Rust documentation", "API docs", "cargo doc", or "inline documentation" in a Rust project.
---

# Rust Documentation (rustdoc)

Create comprehensive inline documentation for Rust codebases following official rustdoc conventions.

## Core Workflow

1. **Document modules**: Module-level `//!` doc comments
2. **Document functions**: Purpose, panics, errors, safety, examples
3. **Document types**: Structs, enums, traits, impls
4. **Write doc-tests**: Runnable examples in doc comments
5. **Generate docs**: `cargo doc` output
6. **Integrate CI**: `cargo test --doc` + `#![warn(missing_docs)]`

## Module-Level Documentation

```rust
//! Redis-backed session storage for the Auth bounded context.
//!
//! This module implements [`SessionStore`] as defined in `domain::ports`,
//! handling persistence, TTL management, and cache invalidation.
//!
//! # Architecture
//!
//! Part of the infrastructure layer. See [`domain::ports::SessionStore`]
//! for the port interface and [`domain::entities::HubSession`] for the
//! stored entity.
```

## Function Documentation

### Basic Function

```rust
/// Calculates the total price including tax.
///
/// # Arguments
///
/// * `price` - The base price before tax.
/// * `tax_rate` - The tax rate as a decimal (e.g., 0.08 for 8%).
///
/// # Examples
///
/// ```
/// use my_crate::calculate_total;
///
/// let total = calculate_total(100.0, 0.08);
/// assert!((total - 108.0).abs() < f64::EPSILON);
/// ```
pub fn calculate_total(price: f64, tax_rate: f64) -> f64 {
    price * (1.0 + tax_rate)
}
```

### Function with Errors

```rust
/// Fetches user data from the external API.
///
/// Called after Keycloak redirect to establish the user's
/// authenticated context.
///
/// # Errors
///
/// Returns [`Error::NotFound`] when the user does not exist.
/// Returns [`Error::Network`] on HTTP transport failures.
///
/// # Examples
///
/// ```no_run
/// # use my_crate::{fetch_user, FetchOptions};
/// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
/// let user = fetch_user("user-123", None).await?;
/// println!("{}", user.name);
/// # Ok(())
/// # }
/// ```
///
/// See also: [`UserRepository::find_by_id`] for the ORM-level equivalent.
pub async fn fetch_user(
    user_id: &str,
    options: Option<FetchOptions>,
) -> Result<User, Error> {
    // ...
}
```

### Unsafe Function

```rust
/// Reads `len` bytes from the raw buffer starting at `ptr`.
///
/// # Safety
///
/// - `ptr` must be valid for reads of `len` bytes.
/// - `ptr` must be properly aligned.
/// - The memory region must not be concurrently mutated.
///
/// # Panics
///
/// Panics if `len` exceeds `isize::MAX`.
pub unsafe fn read_raw(ptr: *const u8, len: usize) -> Vec<u8> {
    // ...
}
```

## Struct Documentation

```rust
/// A user in the Identity bounded context.
///
/// Always created through [`User::new`] or loaded via
/// [`UserRepository::find_by_id`].
///
/// # Examples
///
/// ```
/// use my_crate::User;
///
/// let user = User::new("user-123", "john@example.com", "John Doe");
/// assert_eq!(user.role(), "user");
/// ```
pub struct User {
    /// Unique identifier (UUID v4).
    id: String,

    /// The user's email address.
    email: String,

    /// The user's display name.
    name: String,

    /// The user's role. Defaults to `"user"`.
    role: String,

    /// When the account was created.
    created_at: DateTime<Utc>,

    /// When the account was last modified, if ever.
    updated_at: Option<DateTime<Utc>>,
}
```

## Trait Documentation

```rust
/// Contract for session persistence.
///
/// # Implementors
///
/// - [`RedisSessionStore`] — production implementation
/// - [`InMemorySessionStore`] — test double
pub trait SessionStore: Send + Sync {
    /// Persists a session with automatic TTL.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError::Connection`] if the backend is unreachable.
    fn save(&self, session: &HubSession) -> Result<(), StoreError>;

    /// Retrieves a session by its unique identifier.
    ///
    /// Returns `None` if the session is expired or missing.
    fn find_by_id(&self, id: &str) -> Result<Option<HubSession>, StoreError>;
}
```

## Enum Documentation

```rust
/// Processing state of an order.
///
/// Orders progress through these statuses in sequence,
/// though they may skip directly to [`OrderStatus::Cancelled`]
/// from any state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OrderStatus {
    /// Order has been created but not yet processed.
    Pending,

    /// Payment received — order is being prepared.
    Processing,

    /// Order has been shipped to the customer.
    Shipped,

    /// Order has been delivered.
    Delivered,

    /// Order has been cancelled.
    Cancelled,

    /// Order has been returned by the customer.
    Returned,
}
```

## Error Enum Documentation

```rust
/// Errors produced by user-related operations.
#[derive(Debug, thiserror::Error)]
pub enum UserError {
    /// The requested user does not exist.
    #[error("user not found: {0}")]
    NotFound(String),

    /// The email address is already registered.
    #[error("duplicate email: {0}")]
    DuplicateEmail(String),

    /// An unexpected persistence error.
    #[error(transparent)]
    Store(#[from] StoreError),
}
```

## Impl Block Documentation

```rust
impl ApiClient {
    /// Creates an [`ApiClient`] configured with the given options.
    ///
    /// # Panics
    ///
    /// Panics if `config.base_url` is empty.
    ///
    /// # Examples
    ///
    /// ```
    /// use my_crate::{ApiClient, ApiClientConfig};
    ///
    /// let client = ApiClient::new(ApiClientConfig {
    ///     base_url: "https://api.example.com".into(),
    ///     timeout: std::time::Duration::from_secs(30),
    /// });
    /// ```
    pub fn new(config: ApiClientConfig) -> Self {
        assert!(!config.base_url.is_empty(), "base_url must not be empty");
        // ...
    }

    /// Performs an HTTP GET request to the given endpoint.
    ///
    /// The endpoint is relative to the client's base URL.
    ///
    /// # Errors
    ///
    /// Returns [`ApiError`] on non-2xx status codes or transport failures.
    pub async fn get<T: DeserializeOwned>(&self, endpoint: &str) -> Result<T, ApiError> {
        self.request(Method::GET, endpoint, Option::<()>::None).await
    }
}
```

## Constants Documentation

```rust
/// Maximum session duration before forced re-authentication.
///
/// Aligned with Keycloak realm SSO session idle timeout (ADR-007).
pub const SESSION_TTL: Duration = Duration::from_secs(28800);
```

## Doc-Test Features

```rust
/// Demonstrates various doc-test annotations.
///
/// ```
/// // Normal test — compiled and run
/// assert_eq!(2 + 2, 4);
/// ```
///
/// ```no_run
/// // Compiled but not executed (e.g., needs network)
/// let _ = reqwest::get("https://api.example.com").await;
/// ```
///
/// ```compile_fail
/// // Must NOT compile — verifies the type system catches this
/// let x: u32 = "hello";
/// ```
///
/// ```ignore
/// // Not compiled at all — only for illustration
/// ```
///
/// ```should_panic
/// // Must panic to pass
/// panic!("expected");
/// ```
pub fn doc_test_demo() {}
```

## Cargo Doc Configuration

```toml
# Cargo.toml
[package.metadata.docs.rs]
all-features = true
rustdoc-args = ["--cfg", "docsrs"]

# lib.rs — enable unstable doc features on docs.rs
#![cfg_attr(docsrs, feature(doc_cfg))]
```

## Enforcing Documentation

```rust
// lib.rs — enforce docs on all public items
#![warn(missing_docs)]
#![warn(rustdoc::missing_crate_level_docs)]
#![warn(rustdoc::broken_intra_doc_links)]
```

## Rustdoc Conventions Reference

- `///` for item docs (functions, structs, fields, etc.)
- `//!` for module/crate-level docs
- First paragraph is the summary (shown in module index)
- Use `# Heading` for sections: `# Examples`, `# Errors`, `# Panics`, `# Safety`
- Use `` [`Symbol`] `` for intra-doc links (resolved at compile time)
- Code blocks default to Rust and are **compiled as tests**
- Mark code blocks `no_run`, `ignore`, `compile_fail`, `should_panic` as needed
- Use `# ` prefix inside code blocks to hide boilerplate lines

## Best Practices

1. **Document all `pub` items**: Enforce with `#![warn(missing_docs)]`
2. **Write doc-tests**: Every `# Examples` block is a compiled test
3. **Document errors**: `# Errors` section listing each error variant
4. **Document panics**: `# Panics` section when the function can panic
5. **Document safety**: `# Safety` section for all `unsafe` functions
6. **Use intra-doc links**: `` [`Symbol`] `` for type-safe cross-references
7. **First line is the summary**: Keep it concise, starts with a verb
8. **No `@param` tags**: Describe parameters in prose or `# Arguments` section

## Output Checklist

- [ ] All `pub` items have `///` doc comments
- [ ] Module-level `//!` docs present
- [ ] `# Examples` with runnable doc-tests for key APIs
- [ ] `# Errors` section on all fallible functions
- [ ] `# Panics` section where applicable
- [ ] `# Safety` section on all `unsafe` functions
- [ ] Intra-doc links (`` [`Symbol`] ``) for cross-references
- [ ] `#![warn(missing_docs)]` enabled
- [ ] `cargo test --doc` passes
- [ ] `cargo doc --no-deps` builds without warnings
