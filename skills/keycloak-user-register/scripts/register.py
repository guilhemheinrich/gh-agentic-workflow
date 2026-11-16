#!/usr/bin/env python3
"""Register a user (hashed password) through an Identity API fronting Keycloak.

Env (no defaults, nothing points at a real host):
  TOKEN_URL      OIDC token endpoint (client_credentials)
  REGISTER_URL   full URL of PATCH /v1/register
  CLIENT_ID, CLIENT_SECRET
  ACCESS_REALM, ACCESS_APP, ACCESS_ROLE   (optional, one access entry)
Usage: PASSWORD=... register.py EMAIL FIRST_NAME LAST_NAME
"""
import base64, hashlib, json, os, sys
from typing import Any
import urllib.parse, urllib.request

ITERATIONS = 27500


def env(name):
    value = os.environ.get(name)
    if not value:
        sys.exit(f"missing environment variable {name}")
    return value


def post_json(req):
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)


def main(email, first, last):
    form = urllib.parse.urlencode({"grant_type": "client_credentials",
                                   "client_id": env("CLIENT_ID"),
                                   "client_secret": env("CLIENT_SECRET")}).encode()
    token = post_json(urllib.request.Request(env("TOKEN_URL"), data=form))["access_token"]

    salt = os.urandom(16)
    digest = hashlib.pbkdf2_hmac("sha256", env("PASSWORD").encode(), salt, ITERATIONS, dklen=32)
    body: dict[str, Any] = {"user": {"email": email, "firstName": first, "lastName": last,
                     "password": {"hashType": "pbkdf2-sha256", "nbIteration": str(ITERATIONS),
                                  "salt": base64.b64encode(salt).decode(),
                                  "hash": base64.b64encode(digest).decode(),
                                  "temporary": False},
                     "emailVerified": True}}
    if os.environ.get("ACCESS_REALM"):
        body["access"] = [{"realm": env("ACCESS_REALM"), "app": env("ACCESS_APP"),
                           "role": env("ACCESS_ROLE")}]
    req = urllib.request.Request(env("REGISTER_URL"), data=json.dumps(body).encode(),
                                 method="PATCH",
                                 headers={"Authorization": f"Bearer {token}",
                                          "Content-Type": "application/json"})
    print(json.dumps(post_json(req)))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
