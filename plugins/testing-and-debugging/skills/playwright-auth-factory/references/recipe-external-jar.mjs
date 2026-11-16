/**
 * Recipe: an out-of-band tool already holds the session; convert its cookie jar.
 *
 * Use this when a shell script, a CLI, or another team's tool already walks the
 * authentication chain and caches cookies. Converting its jar keeps ONE
 * authentication mechanism in the codebase instead of two that drift apart.
 *
 * curl writes the Netscape format, tab-separated:
 *   domain  include_subdomains  path  secure  expiry  name  value
 * with two wrinkles that silently produce an unusable state file:
 *   - a `#HttpOnly_` prefix on the domain carries the httpOnly flag;
 *   - an expiry of 0 means "session cookie", which Playwright spells -1.
 *     Writing a literal 0 dates the cookie to 1970 and the browser drops it.
 */
import { readFile } from "node:fs/promises";

const COOKIE_ALLOWLIST = /^(session|csrf)/i;

export async function cookiesFromNetscapeJar(jarPath) {
  const text = await readFile(jarPath, "utf8");
  const cookies = [];

  for (const rawLine of text.split("\n")) {
    let line = rawLine;
    let httpOnly = false;

    if (line.startsWith("#HttpOnly_")) {
      httpOnly = true;
      line = line.slice("#HttpOnly_".length);
    } else if (line.startsWith("#") || line.trim() === "") {
      continue;
    }

    const fields = line.split("\t");
    if (fields.length < 7) continue;

    const [domain, , path, secure, expiry, name, value] = fields;
    if (!COOKIE_ALLOWLIST.test(name)) continue;

    cookies.push({
      name,
      value,
      domain,
      path: path || "/",
      expires: expiry === "0" ? -1 : Number(expiry),
      httpOnly,
      secure: secure === "TRUE",
      // The Netscape format carries no SameSite field. Read the real value off
      // the server's Set-Cookie once, then hardcode it here.
      sameSite: "Lax",
    });
  }

  if (!cookies.some((cookie) => cookie.name.startsWith("session"))) {
    throw new Error(`no session cookie in ${jarPath}; it may belong to another environment`);
  }
  return cookies;
}

/**
 * The jar usually holds MORE than your app's session — corporate IdP cookies
 * live there too. Export the allowlist only. Widen it just for the narrow case
 * of letting the browser replay SSO mid-run, and say so in the code.
 */
