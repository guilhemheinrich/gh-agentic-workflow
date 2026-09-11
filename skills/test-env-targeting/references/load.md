# Load tests

Read this when a k6 (or similar) script hits a deployment. Common rules
(R1–R8) are in `SKILL.md`. This category adds nothing to the model; it only
confirms that the same variables reach a runner that is not Node or Go.

## k6 reads `__ENV`

k6 exposes the process environment as `__ENV`. With `with-env.sh` in front,
the script needs no `-e` flags and no dotenv extension:

```js
// tests/load/lib/target.js
const required = (name) => {
  const v = __ENV[name];
  if (!v) throw new Error(`${name} missing — run through make test-load ENV=<env>`);
  return v;
};

export const TEST_ENV = required("TEST_ENV");
export const API_BASE_URL = required("API_BASE_URL");
```

```make
test-load-smoke: $(STACK) ## k6 smoke against ENV (never prod)
	$(REFUSE_PROD)
	$(WITH_ENV) k6 run tests/load/smoke.js
```

`modelo-bill-e/tests/load/k6/lib/auth.js` reads
`__ENV.BASE_URL || "http://localhost:8080"`. Under this skill the name becomes
`API_BASE_URL` and the default disappears: a load test that silently falls
back to localhost reports a beautiful p95 of nothing.

`xk6-dotenv` exists for loading files inside k6. It is unnecessary here and
would reintroduce a per-runner loader.

## k6 in a container

The official image needs the variables forwarded, not copied:

```make
test-load-smoke: $(STACK) ## k6 smoke against ENV (containerised runner, never prod)
	$(REFUSE_PROD)
	$(WITH_ENV) docker run --rm -i --network host -e TEST_ENV -e API_BASE_URL -e TEST_USER_EMAIL -e TEST_USER_PASSWORD -v $$(pwd)/tests/load:/scripts grafana/k6 run /scripts/smoke.js
```

`--network host` makes `127.0.0.1` in `.env.local` reach the compose ports
on Linux. On macOS use the compose service hostnames through a runner
service instead, as in `SKILL.md` §3.

## Which target a load test may hit

| Target  | Allowed                                            |
| ------- | -------------------------------------------------- |
| local   | anything; the machine is the bottleneck, not the app |
| staging | agreed windows; announce in the team channel first; shared infrastructure |
| prod    | never. `test-load-smoke` in `Makefile.tests.mk` exits 2 on `ENV=prod` before calling the loader, through the shared `REFUSE_PROD` macro. Every new `test-load-*` target starts with the same line. |

## Checklist

- [ ] Scripts read `__ENV.API_BASE_URL` through a `required()` helper; no default.
- [ ] Every `make test-load-*` target starts with `$(REFUSE_PROD)`.
- [ ] Containerised runner forwards variables with `-e NAME`, never `-e NAME=value`.
