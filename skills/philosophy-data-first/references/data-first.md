# Data-First & State Transitions — contenu à insérer dans PHILOSOPHY.md

> Bloc à insérer dans `PHILOSOPHY.md` via le skill `project-philosophy`.
> Remplacer les `à choisir` par les décisions prises avec l'humain.

## Philosophies adoptées

- **Data-First & State Transitions** — la donnée pilote la fonctionnalité :
  toute feature est une transition d'état transactionnelle et vérifiable en
  base de données, jamais un simple « formulaire » ou « endpoint ».

## 1. Principes

1. **La base est la source de vérité de l'état ; le code est l'auteur des
   transitions.** Les invariants critiques sont garantis par la base
   (contraintes, clés étrangères, `CHECK`, unicité), pas seulement par le code.
   Le code calcule et transforme ; toute logique métier aboutit à une
   transition d'état explicite et vérifiable.
2. **Un use case = une transaction atomique.** Il est défini par un
   déclencheur, un état initial (préconditions) et un état final committé. Si
   les préconditions ne sont pas remplies, rien n'est écrit.
3. **Pas d'I/O externe dans une transaction.** Tout effet asynchrone ou
   externe (appel d'API, email, webhook sortant) passe par un **job mis en file
   dans la même transaction** que la donnée métier, via l'orchestrateur choisi
   (§3). Chaque job est lui-même un use case, avec son déclencheur, son état
   initial et son état final (ex. `email_status : PENDING → SENT | FAILED`).
4. **L'état final est toujours un état committé ; les sorties en sont des
   conséquences :**
   - réponse synchrone (HTTP / callback) → lue depuis l'état committé ;
   - effet externe sortant → job mis en file, puis use case du job ;
   - mutation interne seule → commit de la transaction.
5. **Les webhooks entrants sont d'abord persistés**, puis traités par un job.
6. **Les jobs sont idempotents** (livraison *au moins une fois*) ; les appels
   sortants portent une clé d'idempotence.
7. **La concurrence est explicite** : chaque transition déclare sa protection
   (`SELECT … FOR UPDATE`, colonne de version, contrainte d'unicité).
8. **Les valeurs dérivées stockées sont qualifiées** : *photo figée* (ex. prix
   au moment de la commande) ou *valeur recalculable* (projection).
9. **Les lectures ne sont pas des use cases de mutation** : ce sont des
   projections de l'état.
10. **L'accès aux données exploite le modèle physique.** L'ORM / query builder
    doit exposer le schéma réel (types, contraintes, enums, index,
    transactions) plutôt que de le masquer ; ce qu'il ne sait pas exprimer est
    écrit en SQL dans la migration, jamais abandonné.

## 2. Formats obligatoires

Toute spec de feature, issue ou prompt majeur décrit chaque use case ainsi.
Les mutations sont décrites conceptuellement (`table.champ : A → B`), pas en
SQL.

### Template de use case (transition d'état)

- **Nom :** `verbe_entite` (ex. `valider_panier`)
- **Déclencheur :** action utilisateur | cron | webhook entrant | job
- **Préconditions (état initial) :**
  - `paniers.status` = `PENDING`
  - l'utilisateur possède une relation active dans `abonnements`
- **Transitions (mutations) :**
  - `paniers.status` : `PENDING → CONFIRMED`
  - `commandes` : création d'une ligne (`panier_id`, `montant_total` = photo figée)
- **Invariants garantis après commit :** <contraintes qui doivent tenir>
- **Jobs mis en file (même transaction) :** `envoyer_confirmation` —
  payload `{ commande_id }`, clé d'idempotence `commande_id`
- **Sortie synchrone :** <réponse HTTP / callback, lue depuis l'état committé>
- **Échecs :** <précondition non remplie → erreur renvoyée, aucun changement d'état>
- **Concurrence :** <verrou / version / contrainte>
- **Exemple :**
  - *État avant (JSON ou mock BDD) :* …
  - *Action :* …
  - *État après (JSON ou mock BDD) :* …

## 3. Décisions d'implémentation

| Décision | Choix | Critère | Date |
|---|---|---|---|
| Orchestrateur de jobs | à choisir | La mise en file doit pouvoir partager la transaction métier ; sinon table outbox obligatoire | |
| ORM / query builder | à choisir | Expose le modèle physique (contraintes, enums, index, transactions typées) et produit des migrations SQL lisibles | |
