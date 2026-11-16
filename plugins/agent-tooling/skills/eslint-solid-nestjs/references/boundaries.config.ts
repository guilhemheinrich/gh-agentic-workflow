/**
 * ESLint Boundaries Configuration — Clean Architecture Layer Isolation
 *
 * Defines architectural element types and the allowed import matrix
 * for a vertical-slice NestJS project.
 *
 * Layout:
 *   src/modules/<feature>/domain/        → pure business logic, models, ports
 *   src/modules/<feature>/application/   → use-cases, orchestration services
 *   src/modules/<feature>/infrastructure/ → controllers, repositories, gateways, DTOs
 *   src/shared/domain/                   → cross-cutting types (IDs, value objects)
 *   src/shared/infrastructure/           → shared clients, adapters
 *
 * Import rules (dependency direction):
 *   infrastructure → application → domain → shared/domain
 *   shared can only import shared
 *   Controllers CANNOT import other controllers
 *
 * @see https://github.com/javierbrea/eslint-plugin-boundaries
 */

// ──────────────────────────────────────────────
// Element type definitions
// ──────────────────────────────────────────────

export const boundariesSettings = {
  'boundaries/elements': [
    {
      type: 'domain',
      pattern: 'src/modules/*/domain/**',
      mode: 'file' as const,
      capture: ['module'],
    },
    {
      type: 'application',
      pattern: 'src/modules/*/application/**',
      mode: 'file' as const,
      capture: ['module'],
    },
    {
      type: 'infrastructure',
      pattern: 'src/modules/*/infrastructure/**',
      mode: 'file' as const,
      capture: ['module'],
    },
    {
      type: 'shared-domain',
      pattern: 'src/shared/domain/**',
      mode: 'file' as const,
    },
    {
      type: 'shared-infra',
      pattern: 'src/shared/infrastructure/**',
      mode: 'file' as const,
    },
    {
      type: 'controller',
      pattern: 'src/modules/*/infrastructure/http/**/*.controller.ts',
      mode: 'file' as const,
      capture: ['module'],
    },
  ],

  'boundaries/ignore': [
    '**/*.spec.ts',
    '**/*.test.ts',
    '**/*.e2e-spec.ts',
    '**/test/**',
  ],
};

// ──────────────────────────────────────────────
// Import rules matrix
// ──────────────────────────────────────────────

export const boundariesRules = {
  'boundaries/element-types': ['error', {
    default: 'disallow',
    rules: [
      // ── Domain layer ──
      // Can only import from its own domain or shared-domain.
      // This is the innermost layer — no outward dependencies.
      {
        from: ['domain'],
        allow: [
          ['domain', { module: '${from.module}' }],
          'shared-domain',
        ],
      },

      // ── Application layer ──
      // Can import domain (same module) and shared-domain.
      // Cannot reach into infrastructure.
      {
        from: ['application'],
        allow: [
          ['domain', { module: '${from.module}' }],
          ['application', { module: '${from.module}' }],
          'shared-domain',
        ],
      },

      // ── Infrastructure layer ──
      // Can import application and domain from the same module,
      // plus shared-domain and shared-infra.
      {
        from: ['infrastructure'],
        allow: [
          ['domain', { module: '${from.module}' }],
          ['application', { module: '${from.module}' }],
          ['infrastructure', { module: '${from.module}' }],
          'shared-domain',
          'shared-infra',
        ],
      },

      // ── Controllers ──
      // Same as infrastructure, but CANNOT import other controllers.
      // This prevents controller-to-controller coupling.
      {
        from: ['controller'],
        allow: [
          ['domain', { module: '${from.module}' }],
          ['application', { module: '${from.module}' }],
          'shared-domain',
          'shared-infra',
        ],
        disallow: [
          'controller',
        ],
        message: 'Controllers must not import other controllers. Use a shared service or use-case instead.',
      },

      // ── Shared domain ──
      // Can only import other shared-domain files.
      {
        from: ['shared-domain'],
        allow: ['shared-domain'],
      },

      // ── Shared infrastructure ──
      // Can import shared-domain (types) and other shared-infra.
      {
        from: ['shared-infra'],
        allow: ['shared-domain', 'shared-infra'],
      },
    ],
  }],

  // Prevent external packages from being imported where they shouldn't be.
  // This complements element-types by catching framework leaks into domain.
  'boundaries/external': ['error', {
    default: 'allow',
    rules: [
      {
        from: ['domain'],
        disallow: [
          '@nestjs/*',
          'typeorm',
          'prisma',
          '@prisma/*',
          'express',
          'fastify',
        ],
        message: 'Domain layer must be framework-agnostic. Import only pure TS/fp-ts/Effect libraries.',
      },
    ],
  }],
} as const;
