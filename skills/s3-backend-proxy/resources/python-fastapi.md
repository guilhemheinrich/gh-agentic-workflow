# Python FastAPI

Exemple cible: route backend `/api/assets/{tenant}/{path}` qui mappe vers `s3://app-private-assets/tenants/{tenant}/{path}`. Le navigateur ne recoit jamais d'URL S3.

```python
import time
from email.utils import format_datetime

import boto3
from botocore.exceptions import ClientError
from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import Response, StreamingResponse

app = FastAPI()
s3 = boto3.client("s3")
BUCKET = "app-private-assets"
PREFIX = "tenants"
MAX_CACHE_BYTES = 2 * 1024 * 1024
TTL_SECONDS = 60
cache: dict[str, dict] = {}


def s3_key(tenant: str, path: str) -> str:
    if path.startswith("/") or ".." in path.split("/"):
        raise HTTPException(status_code=400, detail="Invalid path")
    return f"{PREFIX}/{tenant}/{path}"


@app.get("/api/assets/{tenant}/{path:path}")
def get_asset(
    tenant: str,
    path: str,
    if_none_match: str | None = Header(default=None),
):
    key = s3_key(tenant, path)
    now = time.time()
    hit = cache.get(key)

    if hit and hit["expires_at"] > now:
        headers = hit["headers"]
        if if_none_match == headers.get("ETag"):
            return Response(status_code=304, headers=headers)
        return Response(content=hit["body"], headers=headers)

    try:
        head = s3.head_object(Bucket=BUCKET, Key=key)
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code")
        if code in {"404", "NoSuchKey", "NotFound"}:
            raise HTTPException(status_code=404, detail="Asset not found")
        raise

    etag = head["ETag"]
    headers = {
        "Content-Type": head.get("ContentType", "application/octet-stream"),
        "ETag": etag,
        "Last-Modified": format_datetime(head["LastModified"], usegmt=True),
        "Cache-Control": "private, max-age=60, stale-while-revalidate=300",
    }
    if head.get("ContentLength") is not None:
        headers["Content-Length"] = str(head["ContentLength"])

    if if_none_match == etag:
        return Response(status_code=304, headers=headers)

    obj = s3.get_object(Bucket=BUCKET, Key=key)
    size = head.get("ContentLength", 0)

    if size <= MAX_CACHE_BYTES:
        body = obj["Body"].read()
        cache[key] = {"body": body, "headers": headers, "expires_at": now + TTL_SECONDS}
        return Response(content=body, headers=headers)

    return StreamingResponse(obj["Body"].iter_chunks(), headers=headers)
```

Points a adapter:

- Remplacer le cache memoire par Redis ou un cache applicatif partage si plusieurs replicas servent les memes objets.
- Ajouter l'autorisation avant `head_object`: tenant courant, droits utilisateur, statut de publication.
- Ajouter le support `Range` si le backend sert des videos, PDF volumineux ou gros binaires.
- Utiliser `Cache-Control: no-store` pour les objets hautement sensibles.
