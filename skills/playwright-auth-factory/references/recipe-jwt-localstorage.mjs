/**
 * Recipe: the app keeps a JWT in localStorage, not in a cookie.
 *
 * Drop this `authenticate` into scripts/auth-state.mjs. The prize is the
 * `origins` array: Playwright seeds localStorage per origin before the first
 * navigation, so the app boots already logged in.
 *
 * Find the real storage key first — read it from the running app rather than
 * guessing, because a wrong key fails silently as "logged out":
 *   await page.evaluate(() => Object.keys(localStorage))
 */
async function authenticate(config) {
  const response = await fetch(new URL("/oauth/token", config.BASE_URL), {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "password",
      client_id: config.OIDC_CLIENT_ID,
      username: config.AUTH_USERNAME,
      password: config.AUTH_PASSWORD,
      scope: "openid profile email",
    }),
    signal: AbortSignal.timeout(20_000),
  });

  if (!response.ok) {
    throw new Failure(`token request failed (${response.status}): ${(await response.text()).slice(0, 400)}`);
  }

  const token = await response.json();

  return {
    cookies: [],
    origins: [
      {
        origin: new URL(config.BASE_URL).origin,
        localStorage: [
          // Shape this exactly as the app writes it. Many SPAs store one JSON
          // blob rather than separate keys; a per-key guess will not load.
          { name: config.TOKEN_STORAGE_KEY, value: token.access_token },
          { name: `${config.TOKEN_STORAGE_KEY}.refresh`, value: token.refresh_token },
        ],
      },
    ],
  };
}

/**
 * WHEN THIS RECIPE DOES NOT APPLY. A password grant (`grant_type=password`,
 * also called ROPC) needs the realm to hold the users itself. Against a realm
 * that BROKERS to a corporate IdP there is no local user to match, and the
 * request fails no matter how correct the credentials are. Check before
 * building on it — that failure reads like a bad password and is not one.
 */
