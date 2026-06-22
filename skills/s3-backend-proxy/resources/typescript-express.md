# TypeScript Express

Exemple cible: route backend `/api/assets/:tenant/*` qui mappe vers `s3://app-private-assets/tenants/{tenant}/{path}` avec AWS SDK v3. Le navigateur ne voit que l'URL applicative.

```ts
import express from "express";
import {
  GetObjectCommand,
  HeadObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";
import { Readable } from "node:stream";

const app = express();
const s3 = new S3Client({});
const BUCKET = "app-private-assets";
const PREFIX = "tenants";
const TTL_MS = 60_000;
const MAX_CACHE_BYTES = 2 * 1024 * 1024;

type CacheEntry = {
  body: Buffer;
  headers: Record<string, string>;
  expiresAt: number;
};

const cache = new Map<string, CacheEntry>();

function toS3Key(tenant: string, path: string): string {
  if (path.startsWith("/") || path.split("/").includes("..")) {
    throw Object.assign(new Error("Invalid path"), { status: 400 });
  }
  return `${PREFIX}/${tenant}/${path}`;
}

app.get("/api/assets/:tenant/*", async (req, res, next) => {
  try {
    const tenant = req.params.tenant;
    const path = req.params[0];
    const key = toS3Key(tenant, path);
    const now = Date.now();
    const hit = cache.get(key);

    if (hit && hit.expiresAt > now) {
      if (req.header("if-none-match") === hit.headers.ETag) {
        return res.status(304).set(hit.headers).end();
      }
      return res.status(200).set(hit.headers).send(hit.body);
    }

    const head = await s3.send(new HeadObjectCommand({ Bucket: BUCKET, Key: key }));
    const headers: Record<string, string> = {
      "Content-Type": head.ContentType ?? "application/octet-stream",
      ETag: head.ETag ?? "",
      "Last-Modified": head.LastModified?.toUTCString() ?? "",
      "Cache-Control": "private, max-age=60, stale-while-revalidate=300",
    };
    if (head.ContentLength !== undefined) {
      headers["Content-Length"] = String(head.ContentLength);
    }

    if (req.header("if-none-match") === headers.ETag) {
      return res.status(304).set(headers).end();
    }

    const obj = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: key }));
    const body = obj.Body as Readable;

    if ((head.ContentLength ?? 0) <= MAX_CACHE_BYTES) {
      const chunks: Buffer[] = [];
      for await (const chunk of body) chunks.push(Buffer.from(chunk));
      const buffer = Buffer.concat(chunks);
      cache.set(key, { body: buffer, headers, expiresAt: now + TTL_MS });
      return res.status(200).set(headers).send(buffer);
    }

    res.status(200).set(headers);
    body.pipe(res);
  } catch (error) {
    next(error);
  }
});
```

Points a adapter:

- Remplacer le cache `Map` par Redis, LRU partagee, CDN devant le backend, ou cache framework selon le deploiement.
- Ajouter l'autorisation avant `HeadObjectCommand`: tenant courant, droits utilisateur, statut de publication.
- Brancher le middleware d'erreur Express pour traduire `NoSuchKey` en `404`, acces refuse en `403`, et panne S3 en `502`.
- Ajouter le support `Range` si le backend sert des videos, PDF volumineux ou gros binaires.
