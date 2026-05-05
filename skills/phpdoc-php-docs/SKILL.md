---
name: phpdoc-php-docs
description: Documents PHP code with PHPDoc comments, generates API documentation, and creates type-safe documentation. Use when users request "PHPDoc", "PHP documentation", "API docs", "phpDocumentor", or "inline documentation" in a PHP project.
---

# PHPDoc Documentation

Create comprehensive inline documentation for PHP codebases.

## Core Workflow

1. **Document functions**: Parameters, returns, throws, examples
2. **Document classes**: Purpose, properties, methods
3. **Document files**: File-level docblocks with namespace purpose
4. **Add type declarations**: Combine PHPDoc with PHP 8+ native types
5. **Generate docs**: phpDocumentor output
6. **Integrate CI**: Automated doc generation

## File-Level Docblock

```php
<?php

/**
 * Redis-backed implementation of SessionStoreInterface for the Auth bounded context.
 *
 * Handles session persistence, TTL management, and cache invalidation.
 * Part of the infrastructure layer — implements the port defined in
 * {@see \App\Domain\Ports\SessionStoreInterface}.
 *
 * @package App\Infrastructure\Session
 *
 * @see \App\Domain\Ports\SessionStoreInterface Port interface
 * @see \App\Domain\Entities\HubSession         Entity stored by this adapter
 */
```

## Function Documentation

### Basic Function

```php
/**
 * Calculate the total price including tax.
 *
 * @param float $price   The base price before tax.
 * @param float $taxRate The tax rate as a decimal (e.g., 0.08 for 8%).
 *
 * @return float The total price including tax.
 *
 * @example
 * ```php
 * $total = calculateTotal(100, 0.08);
 * echo $total; // 108.0
 * ```
 */
function calculateTotal(float $price, float $taxRate): float
{
    return $price * (1 + $taxRate);
}
```

### Method with Exceptions

```php
/**
 * Fetch user data from the API.
 *
 * Called after authentication to hydrate the user's profile context.
 *
 * @param string            $userId  The unique identifier of the user.
 * @param array<string,mixed>|null $options Optional request configuration.
 *
 * @return User A fully hydrated User entity with profile data.
 *
 * @throws NotFoundException When the user doesn't exist.
 * @throws NetworkException  When the HTTP request fails.
 *
 * @example
 * ```php
 * try {
 *     $user = $this->userService->fetchUser('user-123');
 *     echo $user->getName();
 * } catch (NotFoundException $e) {
 *     echo 'User not found';
 * }
 * ```
 *
 * @see UserRepository::findById() ORM-level equivalent
 */
public function fetchUser(string $userId, ?array $options = null): User
{
    // ...
}
```

### Generic / Template Method

```php
/**
 * Filter a collection based on a predicate callback.
 *
 * @template T
 *
 * @param array<T>        $items     The items to filter.
 * @param callable(T):bool $predicate Returns true for items to keep.
 *
 * @return array<T> A new array containing only matching elements.
 *
 * @example
 * ```php
 * $evens = filterItems([1, 2, 3, 4, 5], fn(int $n) => $n % 2 === 0);
 * // [2, 4]
 * ```
 */
function filterItems(array $items, callable $predicate): array
{
    return array_values(array_filter($items, $predicate));
}
```

## Class Documentation

```php
/**
 * Client for interacting with the external REST API.
 *
 * Handles authentication, retries, and error handling automatically.
 * Use the static {@see ApiClient::create()} factory to build an instance.
 *
 * @package App\Infrastructure\Http
 *
 * @example
 * ```php
 * $client = ApiClient::create([
 *     'baseUrl' => 'https://api.example.com',
 *     'apiKey'  => $_ENV['API_KEY'],
 * ]);
 * $users = $client->get('/users');
 * ```
 *
 * @see ApiClientConfig Configuration DTO
 */
class ApiClient
{
    /**
     * The base URL for all API requests.
     *
     * @var string
     * @readonly
     */
    public readonly string $baseUrl;

    /**
     * Create a configured client instance.
     *
     * @param array<string,mixed> $config Forwarded to ApiClientConfig.
     *
     * @return static A new ApiClient instance.
     */
    public static function create(array $config): static
    {
        return new static(ApiClientConfig::fromArray($config));
    }

    /**
     * Perform a GET request.
     *
     * @template T
     *
     * @param string              $endpoint The API endpoint (relative to baseUrl).
     * @param array<string,mixed> $options  Additional request options.
     *
     * @return T The parsed response body.
     *
     * @throws ApiException When the request fails.
     */
    public function get(string $endpoint, array $options = []): mixed
    {
        return $this->request('GET', $endpoint, $options);
    }
}
```

## Interface Documentation

```php
/**
 * Port defining the contract for session persistence.
 *
 * Implemented by {@see RedisSessionStoreAdapter} in infrastructure/.
 *
 * @see RedisSessionStoreAdapter Production implementation
 * @see InMemorySessionStore     Test double
 */
interface SessionStoreInterface
{
    /**
     * Persist a session with automatic TTL.
     *
     * @param HubSession $session The session to persist.
     */
    public function save(HubSession $session): void;

    /**
     * Retrieve a session by its unique identifier.
     *
     * @param string $id The session identifier.
     *
     * @return HubSession|null The session, or null if expired/missing.
     */
    public function findById(string $id): ?HubSession;
}
```

## DTO / Value Object Documentation

```php
/**
 * Represents a user in the system.
 *
 * Domain entity belonging to the Identity bounded context.
 *
 * @example
 * ```php
 * $user = new User(
 *     id: 'user-123',
 *     email: 'john@example.com',
 *     name: 'John Doe',
 *     role: UserRole::Admin,
 * );
 * ```
 *
 * @see UserProfile  Extended profile settings
 * @see UserRepository Persistence port
 */
final readonly class User
{
    /**
     * @param string        $id        Unique identifier (UUID v4).
     * @param string        $email     The user's email address.
     * @param string        $name      The user's display name.
     * @param UserRole      $role      The user's role — defaults to User.
     * @param DateTimeImmutable $createdAt When the account was created.
     * @param DateTimeImmutable|null $updatedAt When last modified (may be null).
     */
    public function __construct(
        public string $id,
        public string $email,
        public string $name,
        public UserRole $role = UserRole::User,
        public DateTimeImmutable $createdAt = new DateTimeImmutable(),
        public ?DateTimeImmutable $updatedAt = null,
    ) {}
}
```

## Enum Documentation

```php
/**
 * Status codes for order processing.
 *
 * Orders progress through these statuses in sequence,
 * though they may skip directly to Cancelled from any state.
 */
enum OrderStatus: string
{
    /** Order has been created but not yet processed. */
    case Pending = 'pending';

    /** Payment received — order is being prepared. */
    case Processing = 'processing';

    /** Order has been shipped to the customer. */
    case Shipped = 'shipped';

    /** Order has been delivered. */
    case Delivered = 'delivered';

    /** Order has been cancelled. */
    case Cancelled = 'cancelled';

    /** Order has been returned by the customer. */
    case Returned = 'returned';
}
```

## Constants Documentation

```php
/**
 * Maximum session duration before forced re-authentication.
 *
 * Aligned with Keycloak realm SSO session idle timeout (ADR-007).
 */
const SESSION_TTL_SECONDS = 28800;
```

## phpDocumentor Configuration

```xml
<!-- phpdoc.dist.xml -->
<?xml version="1.0" encoding="UTF-8" ?>
<phpdocumentor
    configVersion="3"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xmlns="https://www.phpdoc.org"
>
    <title>My Library</title>
    <paths>
        <output>docs/api</output>
    </paths>
    <version number="latest">
        <api>
            <source dsn=".">
                <path>src</path>
            </source>
            <ignore>
                <path>tests</path>
                <path>vendor</path>
            </ignore>
        </api>
    </version>
</phpdocumentor>
```

## PHPDoc Tags Reference

```php
/**
 * Summary line (imperative mood, one line).
 *
 * Extended description providing additional context.
 * Mention the business intent, not just mechanics.
 *
 * @param Type   $name   Description.
 * @param Type[] $items  Array of items.
 *
 * @return Type Description of the return value.
 *
 * @throws ExceptionClass When error condition.
 *
 * @template T
 * @template-covariant T
 * @extends ParentClass<T>
 * @implements InterfaceName<T>
 *
 * @example
 * ```php
 * // Example code
 * ```
 *
 * @see RelatedClass     Description
 * @see https://example.com External link
 *
 * @deprecated 1.2.0 Use newFunction() instead.
 * @since 1.0.0
 *
 * @internal    Not for public use.
 * @readonly
 * @var Type    For properties.
 *
 * @package App\Domain\Auth
 * @author  Team Name <team@example.com>
 *
 * @phpstan-type UserArray array{id: string, name: string}
 * @phpstan-param UserArray $data
 * @phpstan-return list<User>
 */
```

## Best Practices

1. **Document public API**: All public/protected methods and properties
2. **Use `@see` tags**: Connect interfaces to implementations, entities to repositories
3. **Combine native types + PHPDoc**: Native types for runtime, PHPDoc for generics/unions
4. **Include examples**: Show realistic usage
5. **Document exceptions**: All `@throws` with when-conditions
6. **File-level docblocks**: Every file gets a header explaining the module
7. **PHPStan annotations**: Use `@phpstan-*` for complex types the engine can verify
8. **CI enforcement**: `phpcs` with doc sniffs or PHPStan `--level=max`

## Output Checklist

- [ ] All public functions/methods have docblocks
- [ ] All classes and interfaces are documented
- [ ] All parameters described with `@param`
- [ ] Return values documented with `@return`
- [ ] Exceptions documented with `@throws`
- [ ] Examples for complex functions
- [ ] File-level docblocks with `@see` references
- [ ] Native type declarations on all signatures
- [ ] phpDocumentor configuration
- [ ] Documentation build in CI pipeline
