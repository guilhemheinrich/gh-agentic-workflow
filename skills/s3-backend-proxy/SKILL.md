---
name: s3-backend-proxy
description: Design and implement backend proxy routes for serving S3 objects without exposing S3 directly to browsers. Use when Codex needs to map application URLs to S3 keys, stream or download S3 resources through Python or TypeScript backends, proxy trusted S3 presigned URLs without redirecting the browser, preserve HTTP headers, handle conditional requests, add cache layers, avoid presigned-browser access, or document browser-backend-S3 HTTP flows.
---

# S3 Backend Proxy

Utiliser ce skill pour construire une route backend qui sert de facade HTTP devant S3. Le navigateur appelle toujours une URL applicative; le backend traduit cette URL en cle S3, recupere l'objet, puis renvoie les octets avec les bons headers.

## Principe

Preferer ce flux:

```text
Browser
  GET /api/files/invoices/2026-001.pdf
    -> Backend
       map route -> bucket/key: private-bucket/invoices/2026-001.pdf
       GET Object ou cache hit
         -> S3
       <- bytes + metadata
  <- 200 bytes + Content-Type + Cache-Control + ETag
```

Eviter ce flux quand le navigateur ne doit pas interroger S3:

```text
Browser -> Backend -> 302 Location: https://bucket.s3.../key?signature=...
Browser -> S3
```

La redirection 302 vers une URL signee reste utile pour certains cas, mais ce n'est pas un proxy backend: S3 devient visible et directement appele par le navigateur.

## URLs Presignees

Ne pas confondre ces deux usages:

- **Redirection presigned URL**: le backend renvoie une `302 Location` vers S3. Le navigateur interroge S3 directement; ce n'est pas le pattern de ce skill.
- **Proxy de presigned URL**: le backend recoit ou genere une URL signee de confiance, fait lui-meme le `GET` vers S3, puis streame la reponse au navigateur. Le navigateur ne voit toujours que l'URL applicative.

Si le backend a deja les credentials AWS et connait le bucket/key, preferer `GetObject`/`HeadObject` via SDK: c'est plus simple a controler, journaliser et cacher. Utiliser une presigned URL cote backend surtout quand elle vient d'un service de confiance qui delegue l'acces a un objet sans donner les credentials AWS au proxy.

Pour les details, lire `resources/presigned-url-proxy.md`.

## Route Equivalente S3

Definir explicitement la correspondance entre l'URL applicative et la cle S3. Ne jamais laisser le client choisir librement bucket, region ou prefixe.

```text
GET /api/assets/{tenant}/{path}
tenant = acme
path = logos/logo.png

S3:
bucket = app-private-assets
key = tenants/acme/logos/logo.png
```

Regles a appliquer:

- Normaliser le chemin et refuser `..`, chemins absolus, caracteres de controle, bucket fourni par query string.
- Construire la cle depuis des donnees serveur: tenant authentifie, prefixe allowliste, identifiant metier.
- Verifier les droits avant l'appel S3.
- Propager `Content-Type`, `Content-Length`, `ETag`, `Last-Modified`, `Cache-Control` quand ils sont pertinents.
- Supporter `Range` si les ressources sont des videos, gros PDF, images inspectables ou lecteurs media.

## Cache a Privilegier

Mettre le cache devant ou dans le backend, pas dans le navigateur vers S3.

Ordre recommande:

1. CDN ou reverse proxy devant le backend pour les objets partageables: cle de cache = URL applicative + tenant/publication + variation d'autorisation.
2. Cache backend pour metadata S3 (`ETag`, `Last-Modified`, `Content-Type`, taille), afin de repondre aux `If-None-Match` sans refaire un `GET Object`.
3. Cache backend des octets pour petits objets frequents (logos, previews, documents publics a un tenant), avec TTL court et invalidation par version.
4. Streaming direct S3 -> backend -> browser pour gros objets, avec metadata cachee mais sans garder tout le corps en memoire.

Headers conseilles cote backend:

```http
Cache-Control: private, max-age=60, stale-while-revalidate=300
ETag: "s3-etag"
Last-Modified: Wed, 27 May 2026 10:00:00 GMT
```

Utiliser `private` si la reponse depend de l'utilisateur. Utiliser `public` seulement si l'objet est identique pour tous les utilisateurs autorises par l'URL et si le CDN ne risque pas de servir une donnee d'un tenant a un autre. Preferer des URLs versionnees (`/logo.abcd1234.png` ou `?v=etag`) pour des TTL longs.

## Flux HTTP

Toujours documenter le flux en trois acteurs: navigateur, backend, S3. Garder S3 invisible pour le navigateur.

Premier chargement:

```text
Browser -> Backend
GET /api/assets/acme/logo.png
Accept: image/png

Backend -> S3
GET Object bucket=app-private-assets key=tenants/acme/logo.png

S3 -> Backend
200 OK
Content-Type: image/png
ETag: "abc"
Body: ...

Backend -> Browser
200 OK
Content-Type: image/png
Cache-Control: private, max-age=60, stale-while-revalidate=300
ETag: "abc"
Body: ...
```

Revalidation conditionnelle:

```text
Browser -> Backend
GET /api/assets/acme/logo.png
If-None-Match: "abc"

Backend
cache metadata hit: ETag "abc"

Backend -> Browser
304 Not Modified
ETag: "abc"
Cache-Control: private, max-age=60, stale-while-revalidate=300
```

Si le cache metadata est expire, le backend peut faire un `HeadObject` S3 avant de repondre 304 ou de recuperer le nouvel objet.

## Exemples par Langage

Charger seulement la ressource correspondant au langage cible:

- Python / FastAPI: lire `resources/python-fastapi.md`.
- TypeScript / Express: lire `resources/typescript-express.md`.
- Presigned URL stream proxy: lire `resources/presigned-url-proxy.md`.

Chaque ressource montre un exemple volontairement court avec cache memoire pour petits objets, streaming pour gros objets, mapping URL -> cle S3 cote serveur, propagation des headers S3, et revalidation `If-None-Match`.

## Points de Verification

- Le navigateur ne recoit jamais d'URL S3 ni de presigned URL quand le besoin est un proxy.
- Les credentials AWS restent uniquement cote backend.
- Les presigned URLs utilisees par le backend viennent uniquement d'une source de confiance; ne jamais proxyfier une URL fournie librement par le navigateur.
- Les routes backend sont stables et metier (`/api/assets/...`), pas des copies brutes de cles S3.
- Les erreurs S3 sont traduites en statuts HTTP applicatifs (`404`, `403`, `502`) sans fuite de details internes.
- Les objets sensibles utilisent `Cache-Control: private` ou `no-store` selon le risque.
- Les objets versionnes et non sensibles utilisent un cache plus agressif, idealement devant le backend.
- Les gros fichiers sont streames; les petits objets frequents peuvent etre caches en memoire, Redis ou CDN.
