# Presigned URL Stream Proxy

Utiliser cette ressource quand le backend doit consommer une URL S3 presignee, mais que le navigateur ne doit pas la recevoir. Le pattern correct est un reverse proxy applicatif:

```text
Browser -> Backend
GET /api/downloads/report-123

Backend
resolve report-123 -> trusted presigned S3 URL
GET https://bucket.s3.region.amazonaws.com/key?X-Amz-...

S3 -> Backend
200 bytes + headers

Backend -> Browser
200 bytes + headers applicatifs
```

Ce n'est pas un `302`, et ce n'est pas le navigateur qui fait l'appel S3. Le backend est client HTTP de S3 et streame le corps vers la reponse navigateur.

## Quand l'utiliser

Preferer `GetObject`/`HeadObject` via SDK quand le backend a deja les credentials AWS et peut construire `bucket/key`.

Utiliser une presigned URL cote backend quand:

- un service amont fiable fournit une URL signee au lieu d'exposer bucket/key ou credentials;
- l'objet vient d'un compte, access point ou flux AWS qui delegue temporairement l'acces;
- le backend doit appliquer l'auth applicative, les logs, le rate limit ou le cache sans exposer S3 au navigateur.

Eviter ce pattern pour "securiser" une URL fournie par le navigateur: une URL presignee est une capacite d'acces. La proxyfier sans validation transforme le backend en relais SSRF.

## Regles de securite

- Accepter uniquement des URLs generees par le backend ou recuperees depuis un service de confiance.
- Valider `https`, host allowliste, bucket attendu, region attendue et, si possible, prefixe d'objet attendu.
- Ne jamais logger l'URL complete: les query params `X-Amz-*` contiennent la signature.
- Ne jamais utiliser l'URL signee complete comme cle de cache. Cacher par identifiant metier, bucket/key, version, `ETag`, ou route applicative.
- Propager seulement les headers utiles (`Content-Type`, `Content-Length`, `ETag`, `Last-Modified`, `Accept-Ranges`, `Content-Range`) et reconstruire `Cache-Control` cote backend.
- Relayer `Range` si les gros fichiers doivent etre resumables ou lus par un lecteur media.
- Prevoir `502` ou regeneration de l'URL si S3 repond `403` parce que l'URL est expiree.

## Expiration

S3 verifie l'expiration au moment ou la requete HTTP signee arrive. Si le telechargement commence avant l'expiration, le flux peut continuer apres l'heure d'expiration; si la connexion tombe et que le client tente de reprendre apres expiration, la nouvelle requete echoue.

Une URL signee expire aussi lorsque les credentials qui l'ont signee expirent, sont revoques ou desactives, meme si `X-Amz-Expires` indique une duree plus longue.

## Exemple Python FastAPI avec httpx

```python
from urllib.parse import urlparse

import httpx
from fastapi import FastAPI, Header, HTTPException
from starlette.background import BackgroundTask
from fastapi.responses import StreamingResponse

app = FastAPI()
ALLOWED_S3_HOSTS = {"app-private-assets.s3.eu-west-1.amazonaws.com"}
FORWARDED_HEADERS = {
    "content-type",
    "content-length",
    "etag",
    "last-modified",
    "accept-ranges",
    "content-range",
}


def trusted_presigned_url(document_id: str) -> str:
    # Resolve from a trusted service or generate server-side. Never read this from
    # a browser-controlled query parameter.
    raise NotImplementedError


def assert_trusted_s3_url(url: str) -> None:
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.hostname not in ALLOWED_S3_HOSTS:
        raise HTTPException(status_code=502, detail="Untrusted S3 URL")


@app.get("/api/downloads/{document_id}")
async def download(document_id: str, range: str | None = Header(default=None)):
    url = trusted_presigned_url(document_id)
    assert_trusted_s3_url(url)

    client = httpx.AsyncClient(timeout=None, follow_redirects=False)
    request = client.build_request("GET", url, headers={"Range": range} if range else None)
    upstream = await client.send(request, stream=True)

    if upstream.status_code in {403, 404}:
        await upstream.aclose()
        await client.aclose()
        raise HTTPException(status_code=upstream.status_code)
    if upstream.status_code >= 400:
        await upstream.aclose()
        await client.aclose()
        raise HTTPException(status_code=502, detail="S3 upstream error")

    headers = {
        key: value
        for key, value in upstream.headers.items()
        if key.lower() in FORWARDED_HEADERS
    }
    headers["Cache-Control"] = "private, max-age=60, stale-while-revalidate=300"

    async def close_upstream() -> None:
        await upstream.aclose()
        await client.aclose()

    return StreamingResponse(
        upstream.aiter_bytes(),
        status_code=206 if upstream.status_code == 206 else 200,
        headers=headers,
        background=BackgroundTask(close_upstream),
    )
```

## Exemple TypeScript Express avec fetch

```ts
import express from "express";
import { Readable } from "node:stream";

const app = express();
const allowedS3Hosts = new Set(["app-private-assets.s3.eu-west-1.amazonaws.com"]);
const forwardedHeaders = new Set([
  "content-type",
  "content-length",
  "etag",
  "last-modified",
  "accept-ranges",
  "content-range",
]);

async function trustedPresignedUrl(documentId: string): Promise<string> {
  // Resolve from a trusted service or generate server-side. Never read this from
  // a browser-controlled query parameter.
  throw new Error("not implemented");
}

function assertTrustedS3Url(rawUrl: string): void {
  const url = new URL(rawUrl);
  if (url.protocol !== "https:" || !allowedS3Hosts.has(url.hostname)) {
    const error = new Error("Untrusted S3 URL") as Error & { status?: number };
    error.status = 502;
    throw error;
  }
}

app.get("/api/downloads/:documentId", async (req, res, next) => {
  try {
    const url = await trustedPresignedUrl(req.params.documentId);
    assertTrustedS3Url(url);

    const range = req.header("range");
    const upstream = await fetch(url, {
      headers: range ? { range } : undefined,
      redirect: "manual",
    });

    if (upstream.status === 403 || upstream.status === 404) {
      return res.sendStatus(upstream.status);
    }
    if (!upstream.ok || !upstream.body) {
      return res.sendStatus(502);
    }

    for (const [key, value] of upstream.headers.entries()) {
      if (forwardedHeaders.has(key.toLowerCase())) res.setHeader(key, value);
    }
    res.setHeader(
      "Cache-Control",
      "private, max-age=60, stale-while-revalidate=300",
    );
    res.status(upstream.status === 206 ? 206 : 200);
    Readable.fromWeb(upstream.body).pipe(res);
  } catch (error) {
    next(error);
  }
});
```

## References officielles

- Amazon S3 User Guide: `https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html`
- Boto3 S3 presigned URLs: `https://docs.aws.amazon.com/boto3/latest/guide/s3-presigned-urls.html`
- AWS Prescriptive Guidance, presigned URL overview: `https://docs.aws.amazon.com/prescriptive-guidance/latest/presigned-url-best-practices/overview.html`
- AWS Prescriptive Guidance, foundational best practices: `https://docs.aws.amazon.com/prescriptive-guidance/latest/presigned-url-best-practices/foundational-best-practices.html`
