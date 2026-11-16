/**
 * ESLint Flat Config — TypeScript / NestJS / SOLID
 *
 * Standard config for a vertical-slice NestJS monorepo.
 * Enforces SOLID principles and Clean Architecture boundaries via static analysis.
 *
 * Layout assumed:
 *   src/modules/<feature>/{domain,application,infrastructure}/
 *   src/shared/{domain,infrastructure}/
 *
 * @see SKILL.md for full rationale and SOLID mapping.
 */

import js from '@eslint/js';
import tseslint from 'typescript-eslint';
import importPlugin from 'eslint-plugin-import-x';
import boundaries from 'eslint-plugin-boundaries';
import promise from 'eslint-plugin-promise';
import globals from 'globals';

import { boundariesSettings, boundariesRules } from './boundaries.config';

export default tseslint.config(
  // ──────────────────────────────────────────────
  // Global ignores
  // ──────────────────────────────────────────────
  {
    ignores: [
      'dist/**',
      'node_modules/**',
      'coverage/**',
      '.turbo/**',
      '.nx/**',
      '**/*.js',
      '**/*.d.ts',
    ],
  },

  // ──────────────────────────────────────────────
  // 1. Baseline: JS recommended
  // ──────────────────────────────────────────────
  js.configs.recommended,

  // ──────────────────────────────────────────────
  // 2. TypeScript: strict + type-checked + stylistic
  //    Covers: OCP (no-explicit-any), LSP (no-unsafe-*), type consistency
  // ──────────────────────────────────────────────
  ...tseslint.configs.strictTypeChecked,
  ...tseslint.configs.stylisticTypeChecked,

  // ──────────────────────────────────────────────
  // 3. Import plugin: recommended + TypeScript resolver
  //    Covers: DIP (no-cycle, ordered imports)
  // ──────────────────────────────────────────────
  importPlugin.flatConfigs.recommended,
  importPlugin.flatConfigs.typescript,

  // ──────────────────────────────────────────────
  // 4. Promise plugin
  // ──────────────────────────────────────────────
  promise.configs['flat/recommended'],

  // ──────────────────────────────────────────────
  // 5. Main configuration block
  // ──────────────────────────────────────────────
  {
    files: ['**/*.ts'],

    languageOptions: {
      globals: {
        ...globals.node,
      },
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },

    plugins: {
      boundaries,
    },

    settings: {
      ...boundariesSettings,

      'import-x/resolver': {
        typescript: {
          alwaysTryTypes: true,
        },
      },
    },

    rules: {
      // ════════════════════════════════════════════
      // SRP — Single Responsibility Principle
      // Detect symptoms: excessive size, complexity, parameter count
      // ════════════════════════════════════════════

      'complexity': ['error', { max: 15 }],

      'max-lines': ['error', {
        max: 300,
        skipBlankLines: true,
        skipComments: true,
      }],

      'max-lines-per-function': ['error', {
        max: 60,
        skipBlankLines: true,
        skipComments: true,
        IIFEs: true,
      }],

      'max-params': ['error', { max: 4 }],

      'max-depth': ['error', { max: 4 }],

      // ════════════════════════════════════════════
      // TypeScript strict overrides
      // OCP: no any → forces generic/interface thinking
      // LSP: no-unsafe-* → prevents type system bypass
      // ════════════════════════════════════════════

      '@typescript-eslint/no-explicit-any': 'error',
      '@typescript-eslint/no-unsafe-assignment': 'error',
      '@typescript-eslint/no-unsafe-call': 'error',
      '@typescript-eslint/no-unsafe-member-access': 'error',
      '@typescript-eslint/no-unsafe-return': 'error',

      '@typescript-eslint/consistent-type-imports': ['error', {
        prefer: 'type-imports',
        fixStyle: 'inline-type-imports',
      }],

      '@typescript-eslint/consistent-type-exports': ['error', {
        fixMixedExportsWithInlineTypeSpecifier: true,
      }],

      '@typescript-eslint/no-floating-promises': ['error', {
        ignoreVoid: true,
        checkThenables: true,
      }],

      '@typescript-eslint/no-misused-promises': ['error', {
        checksVoidReturn: {
          arguments: false,
        },
      }],

      '@typescript-eslint/strict-boolean-expressions': ['error', {
        allowNullableBoolean: true,
        allowNullableString: false,
        allowNullableNumber: false,
      }],

      '@typescript-eslint/prefer-readonly': 'error',

      '@typescript-eslint/explicit-function-return-type': ['error', {
        allowExpressions: true,
        allowTypedFunctionExpressions: true,
        allowHigherOrderFunctions: true,
        allowDirectConstAssertionInArrowFunctions: true,
      }],

      '@typescript-eslint/explicit-module-boundary-types': 'error',

      // Relax: NestJS uses empty constructors for DI and class-based patterns
      '@typescript-eslint/no-extraneous-class': 'off',

      // ════════════════════════════════════════════
      // DIP — Dependency Inversion Principle
      // Import ordering, cycle detection, restricted imports
      // ════════════════════════════════════════════

      'import-x/order': ['error', {
        'groups': [
          'builtin',
          'external',
          'internal',
          'parent',
          'sibling',
          'index',
          'type',
        ],
        'newlines-between': 'always',
        'alphabetize': {
          order: 'asc',
          caseInsensitive: true,
        },
      }],

      'import-x/no-cycle': ['error', {
        maxDepth: 5,
        ignoreExternal: true,
      }],

      'import-x/no-duplicates': ['error', {
        'prefer-inline': true,
      }],

      'import-x/no-unresolved': 'error',

      'import-x/no-self-import': 'error',

      'import-x/no-useless-path-segments': 'error',

      // no-restricted-imports for infra is applied per-layer via overrides (see domain override below).
      // Applying it globally would block infrastructure files from importing their own siblings.

      // ════════════════════════════════════════════
      // Boundaries — Layer isolation (see boundaries.config.ts)
      // ════════════════════════════════════════════

      ...boundariesRules,

      // ════════════════════════════════════════════
      // Promise / Async best practices
      // ════════════════════════════════════════════

      'promise/always-return': 'error',
      'promise/no-return-wrap': 'error',
      'promise/catch-or-return': ['error', {
        allowFinally: true,
      }],

      // ════════════════════════════════════════════
      // General best practices
      // ════════════════════════════════════════════

      'no-console': ['warn', {
        allow: ['warn', 'error'],
      }],

      'no-debugger': 'error',

      'prefer-const': 'error',

      'no-var': 'error',

      'eqeqeq': ['error', 'always'],

      'curly': ['error', 'all'],
    },
  },

  // ──────────────────────────────────────────────
  // 6. Overrides: Domain layer — stricter rules
  //    Pure functions only, no NestJS decorators, no side effects
  // ──────────────────────────────────────────────
  {
    files: ['**/domain/**/*.ts'],

    rules: {
      'no-restricted-imports': ['error', {
        patterns: [
          {
            group: ['**/infrastructure/**'],
            message: 'Domain must not import infrastructure.',
          },
          {
            group: ['**/application/**'],
            message: 'Domain must not import application layer.',
          },
          {
            group: ['@nestjs/*'],
            message: 'Domain must be framework-agnostic. No NestJS imports in domain.',
          },
        ],
      }],

      'max-lines-per-function': ['error', {
        max: 40,
        skipBlankLines: true,
        skipComments: true,
      }],

      'complexity': ['error', { max: 10 }],
    },
  },

  // ──────────────────────────────────────────────
  // 7. Overrides: Application layer — no infra imports
  // ──────────────────────────────────────────────
  {
    files: ['**/application/**/*.ts'],

    rules: {
      'no-restricted-imports': ['error', {
        patterns: [
          {
            group: ['**/infrastructure/**'],
            message: 'Application layer must not import infrastructure. Depend on ports/interfaces defined in domain.',
          },
        ],
      }],
    },
  },

  // ──────────────────────────────────────────────
  // 8. Overrides: Test files — relaxed constraints
  // ──────────────────────────────────────────────
  {
    files: [
      '**/*.spec.ts',
      '**/*.test.ts',
      '**/*.e2e-spec.ts',
      '**/test/**/*.ts',
    ],

    rules: {
      'max-lines-per-function': 'off',
      'max-lines': 'off',
      'max-params': 'off',
      '@typescript-eslint/no-unsafe-assignment': 'off',
      '@typescript-eslint/no-unsafe-call': 'off',
      '@typescript-eslint/no-unsafe-member-access': 'off',
      '@typescript-eslint/no-explicit-any': 'warn',
      '@typescript-eslint/no-floating-promises': 'off',
      '@typescript-eslint/strict-boolean-expressions': 'off',
      'boundaries/element-types': 'off',
    },
  },

  // ──────────────────────────────────────────────
  // 9. Overrides: Config / barrel files
  // ──────────────────────────────────────────────
  {
    files: [
      '**/index.ts',
      '**/*.module.ts',
      '**/*.config.ts',
      'eslint.config.ts',
    ],

    rules: {
      'max-lines': 'off',
      'max-lines-per-function': 'off',
    },
  },

  // ──────────────────────────────────────────────
  // 10. Overrides: DTOs and schemas (Zod) — more fields allowed
  // ──────────────────────────────────────────────
  {
    files: ['**/*.dto.ts', '**/*.schema.ts'],

    rules: {
      'max-lines': ['error', { max: 500, skipBlankLines: true, skipComments: true }],
      'max-params': 'off',
    },
  },
);
