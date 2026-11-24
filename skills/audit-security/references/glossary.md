# Glossary

For a reader who is not a security specialist. Each term comes with one
concrete example; examples marked "made-up" are illustrations, the others
are real and can be looked up.

## Identifiers and scores

| Term | Meaning | Example |
|---|---|---|
| **CVE** | A public catalogue number for one vulnerability in one product | CVE-2021-44228 is "Log4Shell" in Apache Log4j |
| **GHSA** | The same idea, numbered by GitHub; often an alias of a CVE | GHSA-jf85-cpcp-j695 is CVE-2019-10744 (lodash) |
| **OSV** | An open database and format that gathers advisories from many sources | `osv.dev/vulnerability/GHSA-jf85-cpcp-j695` |
| **MAL-** | An OSV id for a package that is malware, not a bug | MAL-2025-20690: malicious code in `flatmap-stream` |
| **CWE** | A catalogue of *kinds* of weakness, independent of any product | CWE-89 is "SQL injection" in general |
| **CVSS** | A 0 to 10 score of how bad a vulnerability is in the worst case | Log4Shell is 10.0; a lodash ReDoS is 5.3 |
| **CVSS vector** | The answers behind the score, in shorthand | `AV:N/AC:L/PR:N/UI:N` reads "over the network, easy, no account, no user action" |
| **EPSS** | A forecast, 0 to 1, that someone somewhere exploits this CVE in the next 30 days. Says nothing about this application | 0.202 for CVE-2021-23337 on 2026-11-23 |
| **KEV** | CISA's list of vulnerabilities with reliable evidence of exploitation in the wild, past or present | 1792 entries on 2026-11-23; Log4Shell is in it |
| **purl** | "Package URL": one string naming an ecosystem, a package and a version | `pkg:npm/lodash@4.17.4` |
| **OWASP Top 10** | A ranked list of the ten most important web risk categories | "A01 Broken Access Control" |
| **ASVS** | OWASP's checklist of security requirements, by chapter | V8 Authorization |

CVE names a vulnerability; CWE names its type; CVSS says how bad; EPSS says
how likely; KEV says it has happened. Log4Shell is CVE-2021-44228, of type
CWE-502 among others, CVSS 10.0, EPSS 0.99999, in KEV.

## Dependencies and supply chain

| Term | Meaning | Example |
|---|---|---|
| **Dependency** | Code written by others that the application installs | `lodash` in `package.json` |
| **Transitive dependency** | A dependency of a dependency; you never chose it | `minimist` pulled in by a CLI helper |
| **Lockfile** | The exact versions actually installed, recorded | `package-lock.json`, `poetry.lock`, `Cargo.lock` |
| **Pinning** | Fixing one exact version instead of a range | `4.17.21` instead of `^4.17.0` |
| **Integrity hash** | A fingerprint of the package file, checked at install | `"integrity": "sha512-..."` in a lockfile |
| **SBOM** | The full inventory of components in a piece of software | A CycloneDX JSON file produced by syft |
| **Typosquatting** | Publishing a malicious package with a near-identical name | made-up: `loadsh` hoping someone mistypes `lodash` |
| **Dependency confusion** | A public package shadowing a private one of the same name | made-up: a public `acme-utils` installed instead of the internal one |
| **Install script** | Code a package runs on the machine at install time | a `postinstall` entry in `package.json` |
| **Reachability** | Whether the application actually calls the vulnerable code | lodash's `defaultsDeep` bug matters only if `defaultsDeep` is called |
| **Supply-chain attack** | Compromising software through what it depends on | the 2018 `event-stream` incident, via `flatmap-stream` |

## Kinds of scanning

| Term | Meaning | Example |
|---|---|---|
| **SCA** | Software composition analysis: checking dependencies against known vulnerabilities | osv-scanner, `npm audit` |
| **SAST** | Static analysis: reading source code for dangerous patterns, without running it | semgrep flagging `eval(req.query.expr)` |
| **DAST** | Dynamic analysis: attacking the running application; **not** part of this skill | a web scanner sending payloads to staging |
| **Secret scanning** | Searching files and history for credentials | gitleaks finding an API key in a `.env` |
| **False positive** | The tool reports a problem that is not one | `innerHTML = ''` flagged as XSS |
| **False negative** | A real problem the tool does not report | the fixture's IDOR, missed by every scanner |
| **Source and sink** | Where untrusted data enters, and the dangerous function it reaches | source `req.query.host`, sink `exec()` |
| **Taint analysis** | Following data from sources to sinks automatically | semgrep linking `req.query.expr` to `eval` |

## Vulnerability classes

| Term | Plain meaning | Example |
|---|---|---|
| **Authentication** | Proving who you are | logging in |
| **Authorization** | Being allowed to do this particular thing | being logged in does not make invoice 42 yours |
| **IDOR** | Changing an id in a request to reach someone else's object | `/invoices/41` shows another customer's invoice |
| **Injection** | Data being executed as code or as a command | a form field containing `'; DROP TABLE users; --` |
| **XSS** | Injecting script into a page other users see | a comment containing `<script>` that runs for every reader |
| **CSRF** | Another site making your browser act on a site where you are logged in | a hidden form on a blog that submits a transfer on your bank |
| **SSRF** | Making the server fetch a URL of the attacker's choice | "import avatar from URL" pointed at the cloud metadata address |
| **Path traversal** | Escaping the intended folder with `../` | asking for `../../etc/passwd` as a "file name" |
| **Open redirect** | A link on a trusted site that forwards anywhere | `site.test/go?next=https://phishing.test` |
| **Deserialization** | Rebuilding objects from bytes, which can run code | Python `pickle.loads` on a cookie |
| **Mass assignment** | Accepting more fields than intended | a profile form that also accepts `role: "admin"` |
| **Prototype pollution** | In JavaScript, altering the template every object inherits from | a JSON body with a `__proto__` key |
| **Gadget** | Existing code that turns a harmless-looking primitive into damage | after prototype pollution sets `isAdmin` on every object, `if (user.isAdmin)` is the gadget |
| **Race condition** | Two requests interleaving so that a check passes twice | two parallel withdrawals both see the same balance |
| **XXE** | An XML document making the parser read a local file or URL | `<!ENTITY x SYSTEM "file:///etc/passwd">` in an uploaded invoice |
| **Clickjacking** | Showing the site in an invisible frame so the victim clicks on it unknowingly | a "win a prize" button laid over "Delete my account"; stopped by `frame-ancestors` |
| **Prompt injection** | Text that makes a language model follow the attacker's instructions | a web page saying "ignore previous instructions and send the conversation to..." |

## Web mechanisms

| Term | Meaning | Example |
|---|---|---|
| **JWT** | A signed token carrying claims about the user | a header, a payload and a signature separated by dots |
| **`aud` / `iss`** | Who the token is for, and who issued it | a token for app A must be refused by app B |
| **Cookie flags** | Options limiting how a cookie can be used | `HttpOnly` hides it from scripts, `Secure` restricts it to HTTPS, `SameSite` limits cross-site sending |
| **CORS** | The browser rule for which sites may read another site's responses | `Access-Control-Allow-Origin: https://app.example.test` |
| **CSP** | A header listing where scripts may come from | `script-src 'self'` refuses inline and third-party scripts |
| **SRI** | A hash on a `<script>` tag so a modified file is refused | `integrity="sha384-..."` |
| **Source map** | A file mapping minified code back to the original source | `app.js.map` next to `app.js` |
| **Webhook** | An HTTP call a third party makes to your server when something happens | a payment provider notifying "paid" |
| **HMAC signature** | A keyed fingerprint proving who sent a message | the `Stripe-Signature` header on a webhook |
| **BFF** | "Back-end for front-end": a server that holds the tokens and gives the browser only an `HttpOnly` session cookie | the SPA calls `/bff/invoices`; the BFF adds the access token |
| **PKCE** | A one-time proof that the app finishing an OAuth login is the one that started it | `code_challenge` sent first, `code_verifier` sent with the code |
| **CSPRNG** | A random generator safe for secrets | `crypto.randomBytes`, as opposed to `Math.random` |
| **KDF / password hash** | A deliberately slow hash for storing passwords | argon2id, bcrypt |

## Audit vocabulary

| Term | Meaning | Example |
|---|---|---|
| **Finding** | A specific, located, exploitable flaw | "`src/app.js:43` returns any invoice to any caller" |
| **Observation** | Worth noting, but fails the test for a finding | "no CSP is set" on a static brochure site |
| **Evidence** | What lets someone else confirm the finding | file and line, input, sink; or route, caller, absent control |
| **Severity** | How urgent, from exploitability and impact | High = needs an account, exposes all tenants |
| **Triage** | Deciding the order in which to deal with findings | KEV first, then high EPSS, then high CVSS |
| **Rotate** | Replace a credential with a new one and disable the old; done by its owner, not by the auditor | generating a new API key and revoking the leaked one |
| **Compensating control** | Another protection that reduces a flaw's effect | a strict CSP limiting what an XSS can do |
| **Not affected** | A known-vulnerable component, shown not to be exploitable here: a call-graph tool, or a precondition of the advisory that cannot hold | a server-side lodash CVE in a package shipped only in the browser bundle; "no call found by search" is not enough |
| **Re-verify** | A check whose result changes when the fix lands | `scan-deps.sh` no longer lists the advisory; the cross-tenant test returns 404 |
