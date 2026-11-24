# ORM leakage patterns

"ORM leakage" = a rule about the data that exists only in application code.
The database accepts rows that violate it; every other writer (a script, a
second service, a manual fix, a future rewrite) can break it; every other
reader (BI, ETL) cannot know it.

Made-up example: the Rails model says `validates :email, uniqueness: true`.
Two requests arriving together both pass the `SELECT` check and both `INSERT`.
Without a unique index the table now holds two rows with the same email, and
the validation that "guarantees" uniqueness never fails again.

The principle being audited is stated in this repository:
`skills/sql-migration-guidelines/SKILL.md:13` ("The ORM mirrors the schema; it
must not hide integrity, ownership, timestamps or polymorphism that belongs in
SQL") and `skills/philosophy-data-first/references/data-first.md:16`
("Critical invariants are guaranteed by the database").

## Method

1. Locate the models and the migrations (ask, or look for `app/models`,
   `models.py`, `app/Models`, `*.entity.ts`, `schema.prisma`, `schema.ts`,
   `db/migrate`, `migrations/`).
2. Run the grep blocks below for the project's stack. Patterns are extended
   regular expressions; directories are the conventional ones, adapt them.
3. A grep hit is a **candidate**, not a finding. Open the file, then find the
   matching constraint in the catalog (query given per check). Present in both
   and in agreement = healthy. Present in both but different (other values,
   other delete rule) = finding. Code only = finding when other writers or
   readers rely on the rule; input hygiene (a format, a display length) is fine
   in code.
4. For each catalog finding from Step 3 of the workflow (`REL-001`, `REL-004`,
   `CON-001`, `AUD-002`, `TEN-001`...), find the code that carries the rule and
   cite `file:line`. A finding with both sides named is far more convincing:
   "`orders.status` has no CHECK (`CON-001`); the five legal values are in
   `app/models/order.rb:12`".

Report hits as counts with three examples, not as an exhaustive list.

## The checks

| Id | Rule that lives only in code | Default severity | Database counterpart to look for |
|---|---|---|---|
| ORM-001 | Polymorphic relation | high (critical with `REL-003` orphans) | Real foreign keys ([polymorphic-associations.md](polymorphic-associations.md)) |
| ORM-002 | Relation declared with the foreign key switched off | high | `pg_constraint.contype = 'f'` (`REL-004`) |
| ORM-003 | Cascade / dependent delete done by the ORM | high | `ON DELETE` rule (`REL-009`) |
| ORM-004 | Uniqueness validation | high | Unique index (`pg_index.indisunique`) |
| ORM-005 | Presence / format / range validation | medium | `NOT NULL`, `CHECK` (`CON-003`) |
| ORM-006 | Enum values listed in code | medium | `CHECK ... IN`, enum type, lookup table (`CON-001`) |
| ORM-007 | Defaults and timestamps computed by the client | medium | `DEFAULT`, trigger (`AUD-002`) |
| ORM-008 | Soft delete as a default scope | medium | Partial unique indexes (`CON-002`), views for readers |
| ORM-009 | Structured data serialised into one column | medium | Columns / child table (`TYP-003`, `TYP-004`) |
| ORM-010 | Derived or copied values maintained by callbacks | medium | Trigger, generated column, or a view (`DUP-001`) |
| ORM-011 | Single-table inheritance | low to medium | `CHECK` per subtype, or subtype tables |
| ORM-012 | Tenant filter as a default scope / middleware | high | RLS, composite keys (`TEN-001`, `TEN-002`) |
| ORM-013 | State machine in code | low to medium | Transition guard (`CON-005`) |

### ORM-001 Polymorphic relations

Patterns per stack: [polymorphic-associations.md](polymorphic-associations.md#detection-in-the-code---orm-001).

### ORM-002 Relations with the foreign key switched off

The ORM lets you navigate `order.customer` while the database holds no
constraint. Some of these are a single configuration line that disables every
foreign key of the project.

```bash
# Prisma: relationMode "prisma" emulates ALL relations in the client; no FK exists in the database
grep -nE "relationMode *= *\"prisma\"|referentialIntegrity" prisma/schema.prisma
# TypeORM
grep -rnE "createForeignKeyConstraints: *false" --include='*.ts' src
# Sequelize
grep -rnE "constraints: *false|foreignKeyConstraint: *false" --include='*.js' --include='*.ts' .
# Django
grep -rnE "db_constraint *= *False" --include='*.py' .
# Hibernate / JPA
grep -rnE "ConstraintMode\.NO_CONSTRAINT" --include='*.java' --include='*.kt' .
# Laravel: foreignId()/unsignedBigInteger() alone create a plain column; only ->constrained() or ->foreign() add the key
grep -rnE "foreignId\(|foreignUuid\(|unsignedBigInteger\('[a-z_]+_id'\)" database/migrations | grep -vE "constrained\(|->foreign\("
# Rails: t.references / add_reference without foreign_key: true; belongs_to never creates one
grep -rnE "t\.references|add_reference|t\.belongs_to" db/migrate | grep -vE "foreign_key: *(true|\{)"
# Drizzle: relations() is query-layer only; the FK comes from .references() or the table-level foreignKey({...})
grep -rnE "relations\(" --include='*.ts' src ; grep -rnE "\.references\(|foreignKey\(" --include='*.ts' src
# SQLAlchemy: relationship() joined by hand with no ForeignKey on the column
grep -rnE "primaryjoin=|foreign\(" --include='*.py' .
```

Confirm in the catalog: `REL-004` / `REL-006` list the columns; or for one table
`SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'orders'::regclass AND contype = 'f';`

For Drizzle, compare the two outputs: a table that appears in `relations(` but
has neither `.references(` on its columns nor a `foreignKey(` entry has
navigation without integrity.

### ORM-003 Cascades done by the ORM

```bash
# Rails: runs in Ruby, one DELETE per child; skipped by delete_all, by SQL, by other services
grep -rnE "dependent: *:(destroy|delete_all|nullify|restrict_with_(error|exception))" app/models
# Django: on_delete is emulated by the ORM's collector; the database key is created without ON DELETE
grep -rnE "on_delete *= *models\.(CASCADE|SET_NULL|PROTECT|SET_DEFAULT)" --include='*.py' .
# TypeORM: cascade: true / ['remove'] is ORM-side (['insert'], ['update'] do not delete); onDelete: 'CASCADE' is the database rule
grep -rnE "cascade: *(true|\[[^]]*remove)" --include='*.ts' src ; grep -rnE "onDelete: *'" --include='*.ts' src
# Hibernate / JPA
grep -rnE "CascadeType\.(ALL|REMOVE)|orphanRemoval *= *true" --include='*.java' --include='*.kt' .
# Laravel model events doing the deletes
grep -rnE "static::deleting|function deleting|->delete\(\);" app/Models app/Observers
# SQLAlchemy
grep -rnE "cascade=\"[^\"]*delete" --include='*.py' .
```

Confirm against the catalog. Three different situations, do not mix them up:

| Database side | A parent `DELETE` typed in SQL (no ORM) | Finding |
|---|---|---|
| Foreign key, `NO ACTION` / `RESTRICT` (`REL-009`) | Is **refused** while children exist (verified: "violates foreign key constraint"). No orphan | Mismatch: code promises a cascade, the database refuses. Medium |
| Foreign key, `ON DELETE CASCADE` | Deletes the children, **without** running ORM callbacks (files, counters, events) | Finding only if a callback does something the database cannot |
| No foreign key (`REL-004`) | Succeeds and leaves **orphans** | High, with `REL-005` for the count |

Do not "fix" the first row by switching to `CASCADE`: that turns a refused
delete into deleted data. Ask the owner which behaviour is the rule. With
Django, check the generated SQL (`sqlmigrate`) rather than assume.

### ORM-004 Uniqueness validated in code

```bash
grep -rnE "validates .*uniqueness|validates_uniqueness_of" app/models                # Rails
grep -rnE "unique:[a-z_]+|Rule::unique" app                                          # Laravel validation
grep -rnE "@IsUnique|isUnique|already ?(exists|taken|in use)" --include='*.ts' src   # hand-rolled check-then-insert (the error message is the tell)
grep -rnE "get_or_create|update_or_create|validate_unique|UniqueValidator" --include='*.py' .   # Django check-then-insert
```

Confirm: for each validated column, a unique index must exist.
`SELECT indexrelid::regclass, pg_get_indexdef(indexrelid) FROM pg_index WHERE indrelid = 'customers'::regclass AND indisunique;`
`get_or_create` without a unique constraint creates duplicates under concurrency.

### ORM-005 Presence, format and range validated in code

```bash
grep -rnE "validates .*(presence|numericality|length|format|inclusion)" app/models   # Rails
grep -rnE "validators *= *\[|MinValueValidator|MaxValueValidator|RegexValidator" --include='*.py' .   # Django (a field is NOT NULL unless null=True; validators run in forms only)
grep -rnE "'required|\|required|Rule::in|'min:|'max:" app/Http app/Models            # Laravel
grep -rnE "@IsNotEmpty|@IsEmail|@Min\(|@Max\(|@Length\(|z\.(string|number)\(\)\.(min|max|email)" --include='*.ts' src   # class-validator, zod
grep -rnE "@NotNull|@NotBlank|@Size\(|@Min\(|@Max\(|@Email" --include='*.java' --include='*.kt' .   # Bean Validation
```

Confirm: `CON-003` (nullable but never null) lists the columns the code keeps
filled; a required field must be `NOT NULL`; a numeric range must be a `CHECK`.
Do not ask for a `CHECK` on every format rule: reserve it for invariants other
rows or other systems rely on (positive quantity, end after start, percentage
between 0 and 100).

### ORM-006 Enums listed in code

```bash
grep -rnE "^[[:space:]]*enum[[:space:]]+:?[a-z_]+|enum\(:?[a-z_]+" app/models         # Rails, old `enum status:` and new `enum :status,` forms (integers in the column: meaning lost)
grep -rnE "choices *=|TextChoices|IntegerChoices" --include='*.py' .                   # Django (choices= adds no CHECK)
grep -rnE "text\([^)]*enum:|varchar\([^)]*enum:" --include='*.ts' src                  # Drizzle (TypeScript-only typing; pgEnum is the real one)
grep -rnE "type: *'(varchar|text)'.*enum|simple-enum" --include='*.ts' src             # TypeORM
grep -rnE "@Enumerated\(EnumType\.ORDINAL\)|@Enumerated *$" --include='*.java' --include='*.kt' .   # JPA ordinal: 0,1,2 with no legend
grep -rnE "casts.*::class|protected \\\$casts" app/Models                              # Laravel enum casts
```

Confirm: `CON-001`. Integer-coded enums are worse than text for a reader: the
column shows `2` and only the code knows it means "shipped". Recommend a
lookup table or a `COMMENT` listing the codes, plus a `CHECK`.

### ORM-007 Defaults and timestamps computed by the client

```bash
# Prisma: uuid(), cuid(), nanoid() and @updatedAt are produced by the client; now(), autoincrement(), dbgenerated() are database defaults
grep -nE "@default\((uuid|cuid|nanoid)\(|@updatedAt" prisma/schema.prisma
# Drizzle: $defaultFn / $default / $onUpdate run in the application
grep -rnE "\\\$defaultFn\(|\\\$default\(|\\\$onUpdate(Fn)?\(" --include='*.ts' src
# TypeORM
grep -rnE "@UpdateDateColumn|@BeforeInsert|@BeforeUpdate" --include='*.ts' src
# Django: default= is applied in Python (db_default is the database one); auto_now is skipped by QuerySet.update()
grep -rnE "auto_now(_add)? *= *True|default *= *" --include='models.py' -r .
# Sequelize: timestamps are ON by default and set by the client; only `timestamps: false` opts out
grep -rnE "defaultValue: *(DataTypes|Sequelize)\.(UUIDV4|NOW)" --include='*.js' --include='*.ts' . ; grep -rnE "timestamps: *false" --include='*.js' --include='*.ts' .
# Rails / Laravel: timestamps maintained by the framework
grep -rnE "t\.timestamps|\\\$table->timestamps\(\)" db/migrate database/migrations
```

Confirm: `AUD-002` (no trigger) and, for defaults,
`SELECT attname, pg_get_expr(adbin, adrelid) FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum WHERE a.attrelid = 'orders'::regclass AND a.attnum > 0;`
A column with a client-side default is `NULL` or fails for any insert not made
through the ORM.

### ORM-008 Soft delete as a default scope

```bash
grep -rnE "acts_as_paranoid|include Discard|default_scope" app/models                 # Rails
grep -rnE "use SoftDeletes|withTrashed|onlyTrashed" app                               # Laravel
grep -rnE "@DeleteDateColumn|withDeleted|softDelete\(|softRemove\(" --include='*.ts' src   # TypeORM
grep -rnE "paranoid: *true" --include='*.js' --include='*.ts' .                       # Sequelize
grep -rnE "@SQLDelete|@Where\(clause|@SoftDelete|@SQLRestriction" --include='*.java' --include='*.kt' .   # Hibernate
grep -rnE "is_deleted|deleted_at|objects *= *.*Manager\(" --include='*.py' .           # Django custom managers
```

Why it matters: the ORM silently appends `WHERE deleted_at IS NULL`; a BI
query on the table does not, and counts deleted customers. Recommend a view
per soft-deleted table (`CREATE VIEW live_customers AS SELECT ... WHERE deleted_at IS NULL`)
granted to reporting roles, plus `CON-002`'s partial unique indexes. **On a
tenant-scoped table, check `TEN-005` first:** a plain view runs with its
owner's rights, so this very view hands every tenant's live customers to the
reporting role (verified: 2 rows through the view, 1 on the table). Create it
`WITH (security_invoker = true)` (PostgreSQL 15+), or give it an owner that is
subject to the policies, then test the granted view as the reporting role. Also check
that foreign keys to a soft-deleted parent mean what the team thinks: the
child still references a "deleted" row and no `ON DELETE` ever fires.

### ORM-009 Structured data serialised into one column

```bash
grep -rnE "serialize :|store :|store_accessor" app/models                              # Rails (YAML/JSON in text)
grep -rnE "'(array|json|collection|object)'|AsCollection|AsArrayObject" app/Models     # Laravel casts
grep -rnE "simple-array|simple-json|type: *'jsonb?'" --include='*.ts' src              # TypeORM (simple-array = comma-separated text)
grep -rnE "JSONField|ArrayField|PickleType|HStoreField" --include='*.py' .             # Django / SQLAlchemy
grep -rnE " Json[ ?]| String\[\]| Int\[\]" prisma/schema.prisma                        # Prisma
grep -rnE "jsonb?\(|\.array\(\)" --include='*.ts' src                                  # Drizzle
grep -rnE "@Convert\(|AttributeConverter|@JdbcTypeCode\(SqlTypes\.JSON\)" --include='*.java' --include='*.kt' .
```

Confirm: `TYP-003` inventories the columns, `TYP-004` shows keys that are
references. Read the type or interface the code maps the JSON to: fields that
other tables or reports depend on belong in columns. Comma-separated ids in a
text column are a join table that was never created.

### ORM-010 Derived or copied values maintained by callbacks

```bash
grep -rnE "counter_cache|before_save|after_save|after_commit|before_validation" app/models   # Rails
grep -rnE "static::(saving|saved|creating|updating)|Observer" app/Models app/Observers       # Laravel
grep -rnE "@BeforeInsert|@BeforeUpdate|@AfterInsert|@AfterUpdate|EventSubscriber" --include='*.ts' src
grep -rnE "post_save|pre_save|def save\(self" --include='*.py' .                             # Django signals / save overrides
grep -rnE "hooks: *\{|addHook\(|beforeCreate|afterUpdate" --include='*.js' --include='*.ts' .   # Sequelize
grep -rnE "@PrePersist|@PreUpdate|@Formula|@EntityListeners" --include='*.java' --include='*.kt' .
```

Read each hit: a callback that copies a field from a parent, maintains a
counter, a total or a slug is denormalisation whose only sync mechanism is
that callback. `DUP-001` catches the copies that follow a naming pattern; this
grep catches the rest. Verify drift with a query, for example
`SELECT count(*) FROM orders o JOIN customers c ON c.id = o.customer_id WHERE o.customer_email IS DISTINCT FROM c.email;`
(a count, not the rows). Fix by intent: snapshot (rename, comment), generated
column, trigger, or drop the copy and join.

### ORM-011 Single-table inheritance

```bash
grep -rnE "self\.inheritance_column|^class [A-Z][A-Za-z:]+ < [A-Z]" app/models | grep -vE "< (ApplicationRecord|ActiveRecord::Base)"   # Rails subclasses of a model
grep -rnE "@TableInheritance|@ChildEntity" --include='*.ts' src
grep -rnE "@Inheritance\(strategy *= *InheritanceType\.SINGLE_TABLE|@DiscriminatorColumn|@DiscriminatorValue" --include='*.java' --include='*.kt' .
grep -rnE "polymorphic_identity|polymorphic_on" --include='*.py' .
```

Database signature: a `type` column plus many nullable columns that are filled
only for some types. The schema cannot say which columns belong to which
type. Minimum fix: `CHECK (type IN (...))` and one `CHECK` per subtype-only
column (`CHECK (type = 'Invoice' OR due_date IS NULL)`). Structural fix:
subtype tables sharing the parent key (the supertype pattern).

### ORM-012 Tenant isolation in code only

```bash
grep -rnE "default_scope.*tenant|acts_as_tenant|ActsAsTenant|Current\.tenant" app      # Rails
grep -rnE "addGlobalScope|TenantScope|BelongsToTenant" app                             # Laravel
grep -rnE "tenantId|tenant_id" --include='*.ts' src | grep -E "where|eq\(|filter" | head -n 40
grep -rnE "set_config\(|SET LOCAL|SET +app\.|current_setting\('app\." -r .               # the RLS way: read every hit
```

Setting the tenant for RLS is only safe when it is **transaction-scoped**:
`SET LOCAL app.tenant_id = ...` or `set_config('app.tenant_id', $1, true)`,
inside an explicit transaction. `SET app.tenant_id = ...` and
`set_config(..., false)` are session-scoped: behind a connection pool the
value stays on the connection, and the next request, for another tenant,
inherits it. That is a critical finding, not a good sign. Made-up example:
request A runs `set_config('app.tenant_id', '7', false)` and returns the
connection; request B, tenant 9, forgets to set it and reads tenant 7's rows.

Transaction scope stops the value leaking; it does not authenticate it. Any
session can run `SET app.tenant_id = 'B'` on itself (verified: the same role
then reads tenant B's rows). So a `current_setting(...)` policy isolates
tenants only from code that cannot issue SQL. When a caller can (a BI tool, a
reporting login, a shared SQL console), report the filter as
**application-enforced**, not as database isolation. Database-enforced
isolation needs an identity the caller cannot change: one login role per
tenant with policies on `current_user`, or a tenant set by a
`SECURITY DEFINER` function from a verified credential.

Confirm: `TEN-001`, `TEN-002`, `TEN-004`, `TEN-005`. Then list the code paths that bypass
the scope: raw SQL, background jobs, admin tools, reporting exports
(`unscoped`, `withoutGlobalScope`, `$queryRaw`, tagged `sql` templates). Each is a place where
one missing `WHERE` returns every tenant's rows. Prefer database isolation (RLS or
per-tenant schemas) over application-only filters.

### ORM-013 State machines in code

```bash
grep -rnE "aasm|state_machine|include Statesman|workflow do" app/models                # Rails
grep -rnE "xstate|createMachine|transition\(|canTransition" --include='*.ts' src
grep -rnE "django_fsm|FSMField|@transition" --include='*.py' .
grep -rnE "spatie.*ModelStates|HasStates|StateMachine" app
```

Confirm: `CON-005`. The legal transitions are a business rule worth a table in
the report: list them from the code, then say which the database would refuse
today (usually none).

## Signs that the ORM is the schema's owner

Not rules, but context that raises the severity of everything above:

```bash
# The application can alter the schema at start-up (MIG-006)
grep -rnE "synchronize: *true|(hbm2ddl\.auto|ddl-auto) *[:=] *(update|create)|sync\(\{ *(alter|force)|prisma db push" -r .
# Raw SQL is rare or absent: nobody has looked at the database directly
grep -rnE "execute\(|\\\$queryRaw|find_by_sql|DB::(select|statement)|\.raw\(|sql\`" -r . | wc -l
# Migrations contain no CHECK, no ON DELETE, no COMMENT at all
grep -rnEic "check \(|on delete|comment on" db/migrate migrations prisma/migrations drizzle 2>/dev/null | grep -v ":0" | wc -l
```

## Writing ORM findings

Name both sides and the gap, then give the SQL:

> **ORM-004 (high) Email uniqueness is enforced only by a Rails validation.**
> Code: `app/models/customer.rb:9` (`validates :email, uniqueness: true`).
> Database: `customers` has no unique index on `email` (catalog query above
> returned only the primary key). Impact: two concurrent sign-ups create
> duplicate accounts; imports and admin scripts are not checked at all.
> Fix: count the duplicate groups with the exact expression of the future index,
> without returning any address
> (`SELECT count(*) FROM (SELECT 1 FROM customers WHERE email IS NOT NULL GROUP BY lower(email) HAVING count(*) > 1) d`;
> NULLs are left out because a unique index accepts several of them),
> resolve them, then `CREATE UNIQUE INDEX CONCURRENTLY customers_email_key ON customers (lower(email));`.
> Keep the validation: it gives the user a readable error.

Before proposing the index, settle with the owner what "unique" means: case
(`lower(email)` only if `A@x.org` and `a@x.org` are the same account), tenant
scope, NULLs, and soft-deleted rows (`CON-002`). The preflight must group by
the same expression and predicate as the index, or it passes and the build fails.

(The file path in this example is made up; in a real report it must be a real
`file:line` from the audited repository.)
