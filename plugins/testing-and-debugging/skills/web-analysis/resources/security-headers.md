# Security Headers — HTTP Security Analysis

## Official Documentation

- **OWASP Secure Headers**: https://owasp.org/www-project-secure-headers/
- **securityheaders.com**: https://securityheaders.com/
- **MDN HTTP Headers**: https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers
- **NIST Guidelines**: https://csrc.nist.gov/

## Overview

Security headers are HTTP response headers that instruct browsers to apply security policies. They mitigate:

- **XSS (Cross-Site Scripting)** — Content-Security-Policy.
- **Clickjacking** — X-Frame-Options, Content-Security-Policy.
- **MIME sniffing** — X-Content-Type-Options.
- **Man-in-the-middle (MITM)** — Strict-Transport-Security (HSTS).
- **Information leakage** — Referrer-Policy.
- **Malicious scripts** — Permissions-Policy.

## Docker Analysis

### Quick scan

```bash
docker run --rm \
  alpine:latest \
  sh -c 'apk add curl && \
    curl -s -i https://example.com | \
    grep -i "content-security-policy\|strict-transport-security\|x-frame-options\|x-content-type-options\|referrer-policy\|permissions-policy"'
```

**Output**: List of security headers found (or empty if none).

### Detailed analysis with jq

```bash
docker run --rm \
  -v "$(pwd)/security-results:/results" \
  alpine:latest \
  sh -c '
    apk add curl jq
    
    # Fetch headers as JSON
    curl -s -i https://example.com 2>&1 | {
      grep -iE "^(content-security-policy|strict-transport-security|x-frame-options|x-content-type-options|referrer-policy|permissions-policy):" | \
      awk -F": " "{print \\\"{\\\"header\\\": \\\"\\\" \\\$1 \\\"\\\", \\\"value\\\": \\\"\\\" substr(\\\$0, index(\\\$0, \\\$2)) \\\"}\\\"}\" | \
      jq -R -s \"split(\\\"\\\\n\\\") | map(select(. != \\\"\\\")) | map(fromjson)\" > /results/headers.json
    } || echo "No security headers found" > /results/headers.json
  '
```

## Headers Reference

### Content-Security-Policy (CSP)

**Purpose**: Prevent XSS, clickjacking, data injection.

**Syntax**:

```
Content-Security-Policy: directive1 source1 source2; directive2 source3
```

**Common directives**:

| Directive | Purpose |
|-----------|---------|
| `default-src` | Default policy for all content types |
| `script-src` | Where scripts can load from |
| `style-src` | Where stylesheets can load from |
| `img-src` | Where images can load from |
| `font-src` | Where fonts can load from |
| `connect-src` | Where fetch/WebSocket can connect |
| `frame-src` | Where frames/iframes can load from |
| `object-src` | Where plugins can load from |
| `form-action` | Where forms can submit to |
| `frame-ancestors` | Where this page can be framed |

**Example (permissive)**:

```
Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline' *.example.com; style-src 'self' 'unsafe-inline'
```

**Example (strict)**:

```
Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'
```

**Recommendations**:
- Avoid `'unsafe-inline'` (allows inline scripts).
- Use `'nonce-<value>'` or `'hash-<value>'` for inline scripts.
- Set `default-src 'none'` or `'self'`.

---

### Strict-Transport-Security (HSTS)

**Purpose**: Force HTTPS, prevent downgrade attacks.

**Syntax**:

```
Strict-Transport-Security: max-age=<seconds>; includeSubDomains; preload
```

**Parameters**:

| Parameter | Purpose |
|-----------|---------|
| `max-age` | How long to enforce HTTPS (seconds) |
| `includeSubDomains` | Also apply to subdomains |
| `preload` | Include in browser preload list |

**Example**:

```
Strict-Transport-Security: max-age=31536000; includeSubDomains; preload
```

(1 year, includes subdomains, preloaded in browsers.)

**Recommendations**:
- Minimum: `max-age=31536000` (1 year).
- Include `includeSubDomains`.
- Use `preload` (adds to HSTS preload list).

**Note**: Do NOT use preload unless certain — once in the list, browsers always enforce HTTPS and cannot be removed for 1+ years.

---

### X-Frame-Options (Clickjacking Protection)

**Purpose**: Prevent page from being embedded in iframes (clickjacking attack).

**Syntax**:

```
X-Frame-Options: DENY | SAMEORIGIN | ALLOW-FROM https://example.com
```

**Values**:

| Value | Meaning |
|-------|---------|
| `DENY` | Cannot be framed anywhere |
| `SAMEORIGIN` | Can only be framed by same origin |
| `ALLOW-FROM https://example.com` | Can only be framed by specific origin (deprecated in modern browsers; use CSP `frame-ancestors` instead) |

**Example**:

```
X-Frame-Options: SAMEORIGIN
```

**Recommendations**:
- Use `DENY` if page should never be framed.
- Use `SAMEORIGIN` if internal framing is needed.
- Prefer CSP `frame-ancestors` in modern implementations.

---

### X-Content-Type-Options

**Purpose**: Prevent MIME sniffing (browser guessing file type).

**Syntax**:

```
X-Content-Type-Options: nosniff
```

**Recommendation**: Always set to `nosniff` to prevent attack vectors.

---

### Referrer-Policy

**Purpose**: Control how much referrer information is sent to external sites.

**Syntax**:

```
Referrer-Policy: policy-value
```

**Common values**:

| Policy | Behavior |
|--------|----------|
| `strict-origin-when-cross-origin` | Send origin only on cross-origin (recommended) |
| `no-referrer` | Never send referrer |
| `same-origin` | Send referrer only to same origin |
| `origin` | Send only origin (not full URL) |
| `strict-origin` | Send origin only over HTTPS |

**Example**:

```
Referrer-Policy: strict-origin-when-cross-origin
```

**Recommendation**: `strict-origin-when-cross-origin` balances privacy and compatibility.

---

### Permissions-Policy (formerly Feature-Policy)

**Purpose**: Control access to browser features (geolocation, microphone, camera, etc.).

**Syntax**:

```
Permissions-Policy: feature=(allowlist)
```

**Common features**:

| Feature | Use Case |
|---------|----------|
| `geolocation` | Request user location |
| `microphone` | Access microphone |
| `camera` | Access camera |
| `payment` | Payment Request API |
| `usb` | USB access |
| `magnetometer` | Device orientation |
| `accelerometer` | Device motion |
| `gyroscope` | Device rotation |

**Example (disable all)**:

```
Permissions-Policy: geolocation=(), microphone=(), camera=(), payment=()
```

**Example (allow only self)**:

```
Permissions-Policy: geolocation=(self), microphone=(self), camera=(self)
```

**Recommendation**: Set default policy to deny all, then explicitly allow required features.

---

## Scoring System (securityheaders.com)

The securityheaders.com service grades sites:

| Grade | Criteria |
|-------|----------|
| **A+** | All major headers present, well configured |
| **A** | Most headers present, minor issues |
| **B** | Some headers missing or misconfigured |
| **C** | Multiple headers missing |
| **D** | Very few headers, security concerns |
| **E** | No security headers |
| **F** | Active security issues (e.g., broken CSP) |

### Example: Checks for A grade

- ✅ CSP present and reasonable
- ✅ HSTS with `max-age >= 31536000`
- ✅ X-Frame-Options set
- ✅ X-Content-Type-Options: nosniff
- ✅ Referrer-Policy present
- ✅ HTTPS enforced
- ✅ No CSP `'unsafe-inline'`

## Scanning Examples

### Minimal curl check

```bash
curl -s -i https://example.com | head -30
```

Look for headers starting with `Content-Security-Policy`, `Strict-Transport-Security`, etc.

### JSON report

```bash
#!/bin/bash
docker run --rm alpine:latest \
  sh -c '
    apk add curl jq
    
    echo "Checking security headers for https://example.com..."
    
    # Fetch headers and format as JSON
    curl -s -i https://example.com 2>&1 | {
      echo "{"
      echo "  \"headers\": {"
      
      grep -iE "^content-security-policy:" && echo "    \"CSP\": \"present\"," || echo "    \"CSP\": \"missing\","
      grep -iE "^strict-transport-security:" && echo "    \"HSTS\": \"present\"," || echo "    \"HSTS\": \"missing\","
      grep -iE "^x-frame-options:" && echo "    \"X-Frame-Options\": \"present\"," || echo "    \"X-Frame-Options\": \"missing\","
      grep -iE "^x-content-type-options:" && echo "    \"X-Content-Type-Options\": \"present\"" || echo "    \"X-Content-Type-Options\": \"missing\""
      
      echo "  }"
      echo "}"
    }
  '
```

### Full header extraction

```bash
docker run --rm \
  -v "$(pwd)/security-results:/results" \
  alpine:latest \
  sh -c '
    apk add curl
    
    {
      echo "=== Security Headers for https://example.com ==="
      echo ""
      
      curl -s -i -H "User-Agent: Mozilla/5.0" https://example.com 2>&1 | \
      grep -iE "^(content-security-policy|strict-transport-security|x-frame-options|x-content-type-options|referrer-policy|permissions-policy):" || \
      echo "No security headers detected"
    } | tee /results/headers.txt
  '
```

## Common Misconfigurations

### ❌ `Content-Security-Policy: default-src *`

**Risk**: Allows scripts from anywhere (defeats CSP purpose).

**Fix**: Use specific sources or `'self'`.

### ❌ `Content-Security-Policy: script-src 'unsafe-inline'`

**Risk**: Allows inline scripts (XSS vulnerability).

**Fix**: Use `'nonce-...'` or externalize scripts.

### ❌ No HSTS header

**Risk**: First visit vulnerable to downgrade attack (MITM).

**Fix**: Add `Strict-Transport-Security: max-age=31536000; includeSubDomains`.

### ❌ `X-Frame-Options: ALLOW-FROM *`

**Risk**: Page can be framed from anywhere (clickjacking).

**Fix**: Use `SAMEORIGIN` or `DENY`.

### ❌ No Referrer-Policy

**Risk**: Full URL (including query params) leaked to external sites.

**Fix**: Add `Referrer-Policy: strict-origin-when-cross-origin`.

## Troubleshooting

### Headers not returned

**Cause**: Server doesn't send headers, or TLS/DNS issue.

**Fix**: Check connectivity, verify URL is correct:

```bash
docker run --rm alpine:latest \
  sh -c 'apk add curl && curl -v https://example.com 2>&1 | head -50'
```

### Headers present but values look malformed

**Cause**: Possibly wrapped across multiple lines or encoding issue.

**Fix**: Fetch raw headers and inspect:

```bash
curl -i https://example.com | hexdump -C | head -100
```

## Integration with CI/CD

### GitHub Actions

```yaml
- name: Check security headers
  run: |
    docker run --rm alpine:latest \
      sh -c '
        apk add curl
        HEADERS=$(curl -s -i ${{ env.TARGET_URL }} 2>&1)
        
        if ! echo "$HEADERS" | grep -q "Strict-Transport-Security"; then
          echo "Missing HSTS header"
          exit 1
        fi
        
        if ! echo "$HEADERS" | grep -q "X-Content-Type-Options"; then
          echo "Missing X-Content-Type-Options header"
          exit 1
        fi
        
        if ! echo "$HEADERS" | grep -q "X-Frame-Options"; then
          echo "Missing X-Frame-Options header"
          exit 1
        fi
        
        echo "All required security headers present"
      '
```

## Resources

- **OWASP**: https://owasp.org/www-project-secure-headers/
- **MDN Headers**: https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers
- **securityheaders.com**: https://securityheaders.com/
- **CSP Guide**: https://developer.mozilla.org/en-US/docs/Web/HTTP/CSP
- **HSTS Preload**: https://hstspreload.org/
