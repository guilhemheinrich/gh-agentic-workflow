# <PRODUCT> — API collections (<STAGE>)

<!--
Template for the README shipped inside an apiconv bundle handed to an API consumer.
Replace every <PLACEHOLDER>, delete the rows and sections that do not apply, then delete this comment.
Never paste a credential into this file: the identity ships in the client files, not in the README.
-->

<N> request collections to call the <PRODUCT> API on <STAGE> (`<API_BASE_URL>`), in three clients:
**Insomnia**, **Postman** and **Bruno**. Pick the one you use; the three hold the same requests.
Every credential in this archive is a **<STAGE>** credential for you only.

| Collection | What it covers |
|---|---|
| `01-<collection-slug>` | <one line> |
| `02-<collection-slug>` | <one line> |

Your identity (`<identity-key-1>`, `<identity-key-2>`) ships ready in each client.

## Insomnia — folder `insomnia/`

1. *Import* → *From File*, one file at a time (the `00-` file is your identity).
2. In each collection, pick your identity's sub-environment as the global environment (selector at the top left).

## Postman — folder `postman/`

1. *Import* every file: the `*.postman_collection.json` files and the `00-environment-*.postman_environment.json` file.
2. Select that environment (top right) before sending.

## Bruno — folder `bruno/`

1. *Open Collection* on each sub-folder.
2. Select the environment **<BRUNO_ENVIRONMENT>** of the collection (`staging` for a bundle without stages).
   It already holds your identity.

## Running the requests

Run them in their numbered order: <say which request stores the access token, if any>.
<Say which requests write real data, and how they are marked.>

## What differs between the three clients

The Postman and Bruno files are generated from the Insomnia ones by a converter. A verifier reads them back
with each client's own parser and requires the same requests, field by field (`VERIFICATION.txt`). Where a
client has no equivalent feature, the converter uses the closest exact substitute:

- **Values computed at send time** (today's date, a timestamp, a uuid): Insomnia renders them from template
  tags; in Postman and Bruno a collection-level pre-request script renders the same templates, kept verbatim
  in that script.
- **Token re-send**: <keep only when a request uses Insomnia's `when-expired` response tag> Insomnia re-sends
  the token request by itself once the token is older than <SECONDS> s; in Postman and Bruno, re-run that
  request when the token has expired.
- **Bruno has no description field on headers and form fields**: those descriptions are appended to the
  request's Docs tab, under a "field-notes" marker.
- **Script variables**: Postman scripts store values as collection variables; Bruno scripts store them in the
  selected environment.
