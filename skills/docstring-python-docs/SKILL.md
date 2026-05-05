---
name: docstring-python-docs
description: Documents Python code with docstrings (Google style), generates API documentation, and creates type-annotated documentation. Use when users request "docstring", "Python documentation", "API docs", "Sphinx", "mkdocstrings", or "inline documentation" in a Python project.
---

# Python Docstring Documentation

Create comprehensive inline documentation for Python codebases using Google-style docstrings.

## Core Workflow

1. **Document functions**: Parameters, returns, raises, examples
2. **Document classes**: Purpose, attributes, methods
3. **Document modules**: File-level docstrings with module purpose
4. **Add type hints**: Combine with docstrings for full typing
5. **Generate docs**: Sphinx / mkdocstrings output
6. **Integrate CI**: Automated doc generation

## Module-Level Docstring

```python
"""
Redis-backed implementation of SessionStore for the Auth bounded context.

Handles session persistence, TTL management, and cache invalidation.
Part of the infrastructure layer — implements the port defined in
``domain.ports.session_store.SessionStorePort``.

See Also:
    domain.ports.session_store.SessionStorePort: port interface
    domain.entities.hub_session.HubSession: entity stored by this adapter
"""
```

## Function Documentation

### Basic Function

```python
def calculate_total(price: float, tax_rate: float) -> float:
    """Calculate the total price including tax.

    Args:
        price: The base price before tax.
        tax_rate: The tax rate as a decimal (e.g., 0.08 for 8%).

    Returns:
        The total price including tax.

    Example:
        >>> calculate_total(100, 0.08)
        108.0
    """
    return price * (1 + tax_rate)
```

### Async Function

```python
async def fetch_user(
    user_id: str,
    options: FetchOptions | None = None,
) -> User:
    """Fetch user data from the API.

    Args:
        user_id: The unique identifier of the user.
        options: Optional configuration for the request.

    Returns:
        A fully hydrated ``User`` with profile data.

    Raises:
        NotFoundError: When the user doesn't exist.
        NetworkError: When the request fails.

    Example:
        >>> user = await fetch_user("user-123")
        >>> print(user.name)
        'Jane Doe'

    See Also:
        UserRepository.get_by_id: ORM-level equivalent.
    """
    response = await client.get(f"/api/users/{user_id}", **(options or {}))
    if response.status == 404:
        raise NotFoundError(f"User {user_id} not found")
    if not response.ok:
        raise NetworkError("Failed to fetch user")
    return User.model_validate(response.json())
```

### Generic / TypeVar Function

```python
from typing import TypeVar, Callable, Sequence

T = TypeVar("T")


def filter_items(items: Sequence[T], predicate: Callable[[T], bool]) -> list[T]:
    """Filter a sequence based on a predicate function.

    Args:
        items: The sequence to filter.
        predicate: A callable that returns ``True`` for items to keep.

    Returns:
        A new list containing only elements that pass the predicate.

    Example:
        >>> filter_items([1, 2, 3, 4, 5], lambda n: n % 2 == 0)
        [2, 4]
    """
    return [item for item in items if predicate(item)]
```

## Class Documentation

```python
class ApiClient:
    """Client for interacting with the external REST API.

    Handles authentication, retries, and error handling automatically.
    Use the ``create`` class method to build an instance.

    Attributes:
        base_url: The base URL for all API requests (read-only after init).
        timeout: Default request timeout in seconds.

    Example:
        >>> client = ApiClient.create(
        ...     base_url="https://api.example.com",
        ...     api_key=os.environ["API_KEY"],
        ... )
        >>> users = await client.get("/users")

    See Also:
        ApiClientConfig: configuration dataclass.
    """

    def __init__(self, config: ApiClientConfig) -> None:
        self.base_url: str = config.base_url
        self.timeout: int = config.timeout

    @classmethod
    def create(cls, **kwargs: Any) -> "ApiClient":
        """Factory method to create a configured client.

        Args:
            **kwargs: Forwarded to ``ApiClientConfig``.

        Returns:
            A new ``ApiClient`` instance.
        """
        return cls(ApiClientConfig(**kwargs))

    async def get(self, endpoint: str, **options: Any) -> Any:
        """Perform a GET request.

        Args:
            endpoint: The API endpoint (relative to ``base_url``).
            **options: Additional request options.

        Returns:
            The parsed JSON response.

        Raises:
            ApiError: When the request fails.
        """
        return await self._request("GET", endpoint, **options)
```

## Dataclass / Model Documentation

```python
from dataclasses import dataclass
from datetime import datetime
from typing import Literal


@dataclass(frozen=True)
class User:
    """Represents a user in the system.

    Domain entity belonging to the Identity bounded context.

    Attributes:
        id: Unique identifier (UUID v4).
        email: The user's email address.
        name: The user's display name.
        role: The user's role — defaults to ``"user"``.
        created_at: When the account was created.
        updated_at: When the account was last modified (may be ``None``).

    Example:
        >>> user = User(
        ...     id="user-123",
        ...     email="john@example.com",
        ...     name="John Doe",
        ...     role="admin",
        ...     created_at=datetime.now(),
        ... )

    See Also:
        UserProfile: extended profile settings.
        UserRepository: persistence port.
    """

    id: str
    email: str
    name: str
    role: Literal["admin", "user", "guest"] = "user"
    created_at: datetime = datetime.now()
    updated_at: datetime | None = None
```

## Protocol (Interface) Documentation

```python
from typing import Protocol, runtime_checkable


@runtime_checkable
class SessionStore(Protocol):
    """Port defining the contract for session persistence.

    Implemented by ``RedisSessionStoreAdapter`` in infrastructure/.

    See Also:
        RedisSessionStoreAdapter: production implementation.
        InMemorySessionStore: test double.
    """

    async def save(self, session: HubSession) -> None:
        """Persist a session with automatic TTL."""
        ...

    async def find_by_id(self, session_id: str) -> HubSession | None:
        """Retrieve a session by its unique identifier, or ``None`` if expired."""
        ...
```

## Enum Documentation

```python
from enum import StrEnum


class OrderStatus(StrEnum):
    """Status codes for order processing.

    Orders progress through these statuses in sequence,
    though they may skip directly to ``CANCELLED`` from any state.
    """

    PENDING = "pending"
    """Order has been created but not yet processed."""

    PROCESSING = "processing"
    """Payment received — order is being prepared."""

    SHIPPED = "shipped"
    """Order has been shipped to the customer."""

    DELIVERED = "delivered"
    """Order has been delivered."""

    CANCELLED = "cancelled"
    """Order has been cancelled."""

    RETURNED = "returned"
    """Order has been returned by the customer."""
```

## Constants Documentation

```python
SESSION_TTL_SECONDS: int = 28800
"""Maximum session duration before forced re-authentication.

Aligned with Keycloak realm SSO session idle timeout (ADR-007).
"""
```

## Documentation Generation — Sphinx

```python
# docs/conf.py
project = "My Library"
extensions = [
    "sphinx.ext.autodoc",
    "sphinx.ext.napoleon",   # Google-style docstrings
    "sphinx.ext.intersphinx",
    "sphinx.ext.viewcode",
]
napoleon_google_docstring = True
napoleon_numpy_docstring = False
```

## Documentation Generation — mkdocstrings

```yaml
# mkdocs.yml
plugins:
  - mkdocstrings:
      handlers:
        python:
          options:
            docstring_style: google
            show_source: true
            show_root_heading: true
```

## Docstring Tags Reference (Google Style)

```python
"""Summary line (imperative mood, one line).

Extended description providing additional context.
Mention the business intent, not just mechanics.

Args:
    name: Parameter description.
    other (int): With explicit type when not obvious from annotation.

Returns:
    Description of the return value.

Yields:
    Description of yielded values (for generators).

Raises:
    ValueError: When something is invalid.
    TypeError: When types don't match.

Example:
    >>> result = my_function("hello")
    >>> print(result)
    'HELLO'

Note:
    Additional implementation notes.

See Also:
    RelatedClass: why it's related.
    other_module.other_function: related function.

.. deprecated:: 1.2.0
    Use ``new_function`` instead.
"""
```

## Best Practices

1. **Document public API**: All exported symbols need docstrings
2. **Use Google style**: Consistent, readable, supported by all major tools
3. **Add type hints AND docstrings**: Types say what, docstrings say why
4. **Include doctests**: `>>>` examples are runnable via `pytest --doctest-modules`
5. **Link related symbols**: Use `See Also` sections liberally
6. **Document exceptions**: All `Raises` with when-conditions
7. **Keep docstrings synced**: Update when signature changes
8. **CI enforcement**: `pydocstyle --convention=google` or `ruff` D rules

## Output Checklist

- [ ] All public functions have docstrings
- [ ] All classes and their public methods are documented
- [ ] All parameters described in Args
- [ ] Return values documented
- [ ] Exceptions documented in Raises
- [ ] Examples for complex functions (doctest-compatible)
- [ ] Module-level docstrings with See Also
- [ ] Type annotations on all public signatures
- [ ] Sphinx or mkdocstrings configuration
- [ ] Documentation build in CI pipeline
