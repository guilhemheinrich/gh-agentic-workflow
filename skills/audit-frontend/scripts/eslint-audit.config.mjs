// eslint-audit.config.mjs - audit overlay for ESLint (flat config).
//
// Runs next to, not instead of, the project's own ESLint config. It enables
// only rules that reveal state-management, rendering and accessibility
// defects, with plugins pinned by scripts/lib/battery-inner.sh, so that two
// audits of two projects are comparable. No formatting or style rule.
//
// Deliberate choices:
//   - noInlineConfig: the project's `eslint-disable` comments are ignored. An
//     audit wants to see the suppressed `react-hooks/exhaustive-deps`, which is
//     where stale closures and effect loops hide.
//   - no type information: the parser runs without the TypeScript program, so
//     type-aware rules are out of reach. tsc covers types separately.
//   - rule names are filtered against what each pinned plugin really exports:
//     a rule renamed by a plugin upgrade is reported on stderr, never fatal.
//
// AUDIT_FRAMEWORKS (comma-separated: react,vue,svelte,solid,lit) selects the
// blocks. Angular is not covered here: use the project's `ng lint`.

import tseslint from 'typescript-eslint';

const frameworks = new Set((process.env.AUDIT_FRAMEWORKS || '').split(',').filter(Boolean));
const SCRIPT_FILES = ['**/*.{js,jsx,mjs,cjs,ts,tsx,mts,cts}'];

async function load(name) {
  try {
    const mod = await import(name);
    return mod.default ?? mod;
  } catch (err) {
    console.warn(`[audit-overlay] plugin ${name} failed to load: ${String(err.message).split('\n')[0]}`);
    return null;
  }
}

function pick(plugin, prefix, wanted) {
  const out = {};
  for (const [name, severity] of Object.entries(wanted)) {
    if (plugin.rules && name in plugin.rules) out[`${prefix}/${name}`] = severity;
    else console.warn(`[audit-overlay] rule ${prefix}/${name} does not exist in the pinned plugin: skipped`);
  }
  return out;
}

const config = [
  {
    ignores: [
      '**/node_modules/**', '**/dist/**', '**/build/**', '**/out/**', '**/coverage/**',
      '**/.next/**', '**/.nuxt/**', '**/.output/**', '**/.svelte-kit/**', '**/.angular/**',
      '**/storybook-static/**', '**/*.min.js', '**/*.d.ts', '**/vendor/**', '**/public/**',
    ],
  },
  {
    linterOptions: { noInlineConfig: true, reportUnusedDisableDirectives: 'off' },
  },
  {
    files: SCRIPT_FILES,
    languageOptions: {
      parser: tseslint.parser,
      parserOptions: { ecmaVersion: 'latest', sourceType: 'module', ecmaFeatures: { jsx: true } },
    },
  },
];

if (frameworks.has('react')) {
  const hooks = await load('eslint-plugin-react-hooks');
  const react = await load('eslint-plugin-react');
  const a11y = await load('eslint-plugin-jsx-a11y');
  if (hooks) {
    config.push({
      files: SCRIPT_FILES,
      plugins: { 'react-hooks': hooks },
      rules: pick(hooks, 'react-hooks', {
        'rules-of-hooks': 'error',
        'exhaustive-deps': 'warn',
        // React Compiler diagnostics shipped with the plugin (v6 and later).
        'set-state-in-effect': 'warn', // effect -> setState cascades, derived state stored in state
        'set-state-in-render': 'error', // render loops
        'static-components': 'warn', // components defined during render: state reset on every render
        purity: 'warn', // impure calls during render
        immutability: 'warn', // mutation of props, state or hook results
        refs: 'warn', // reading or writing ref.current during render
        'use-memo': 'warn',
        'preserve-manual-memoization': 'warn', // memoization whose dependencies lie
        globals: 'warn',
        'error-boundaries': 'warn',
        'incompatible-library': 'warn',
      }),
    });
  }
  if (react) {
    config.push({
      files: SCRIPT_FILES,
      plugins: { react },
      settings: { react: { version: '19.0' } },
      rules: pick(react, 'react', {
        'jsx-key': 'error',
        'no-array-index-key': 'warn', // unstable keys
        'jsx-no-constructed-context-values': 'warn', // context value identity churn
        'no-unstable-nested-components': 'warn',
        'no-object-type-as-default-prop': 'warn', // new {} / [] default on every render
        'jsx-no-leaked-render': 'warn',
        'no-direct-mutation-state': 'error',
        'no-access-state-in-setstate': 'warn',
        'no-did-update-set-state': 'warn',
        'no-danger': 'warn',
        'jsx-no-target-blank': 'warn',
      }),
    });
  }
  if (a11y) {
    const recommended = (a11y.flatConfigs && a11y.flatConfigs.recommended && a11y.flatConfigs.recommended.rules) || {};
    config.push({ files: SCRIPT_FILES, plugins: { 'jsx-a11y': a11y }, rules: recommended });
  }
}

if (frameworks.has('solid')) {
  const solid = await load('eslint-plugin-solid');
  if (solid) {
    config.push({
      files: ['**/*.{jsx,tsx}'],
      plugins: { solid },
      rules: pick(solid, 'solid', {
        reactivity: 'warn', // signal read outside a tracking scope: the UI never updates
        'no-destructure': 'warn', // destructured props lose reactivity
        'components-return-once': 'warn',
        'prefer-for': 'warn', // .map() re-creates every node; <For> keys by reference
        'no-react-deps': 'warn',
        'no-react-specific-props': 'warn',
        'no-innerhtml': 'warn',
        'jsx-no-duplicate-props': 'error',
      }),
    });
  }
}

if (frameworks.has('lit')) {
  const lit = await load('eslint-plugin-lit');
  if (lit) {
    config.push({
      files: SCRIPT_FILES,
      plugins: { lit },
      rules: pick(lit, 'lit', {
        'no-property-change-update': 'error', // property set in update(): a second render cycle
        'no-this-assign-in-render': 'error', // state write during render
        'no-template-arrow': 'warn', // new function identity on every render
        'no-template-bind': 'warn',
        'no-template-map': 'off',
        'no-invalid-html': 'error',
        'no-duplicate-template-bindings': 'error',
        'no-legacy-template-syntax': 'warn',
        'binding-positions': 'error',
        'attribute-value-entities': 'warn',
        'lifecycle-super': 'error',
      }),
    });
  }
}

if (frameworks.has('vue')) {
  const vue = await load('eslint-plugin-vue');
  if (vue) {
    const base = vue.configs && vue.configs['flat/base'];
    if (Array.isArray(base)) config.push(...base);
    config.push({
      files: ['**/*.vue'],
      languageOptions: { parserOptions: { parser: tseslint.parser, ecmaVersion: 'latest', sourceType: 'module' } },
      rules: pick(vue, 'vue', {
        'no-side-effects-in-computed-properties': 'error', // a computed that writes state
        'no-async-in-computed-properties': 'error',
        'return-in-computed-property': 'error',
        'no-mutating-props': 'error', // child writes parent state: two-way sync by accident
        'no-ref-as-operand': 'error',
        'no-ref-object-reactivity-loss': 'warn',
        'no-setup-props-reactivity-loss': 'warn',
        'no-watch-after-await': 'error',
        'no-use-computed-property-like-method': 'error',
        'require-v-for-key': 'error',
        'valid-v-for': 'error',
        'no-use-v-if-with-v-for': 'error',
        'no-v-html': 'warn',
        'no-template-shadow': 'warn',
        'no-unused-refs': 'warn',
      }),
    });
  }
}

if (frameworks.has('svelte')) {
  const svelte = await load('eslint-plugin-svelte');
  if (svelte) {
    const base = svelte.configs && (svelte.configs['flat/base'] || svelte.configs.base);
    if (Array.isArray(base)) config.push(...base);
    config.push({
      files: ['**/*.svelte', '**/*.svelte.ts', '**/*.svelte.js'],
      languageOptions: { parserOptions: { parser: tseslint.parser } },
      rules: pick(svelte, 'svelte', {
        'infinite-reactive-loop': 'error',
        'no-reactive-reassign': 'error',
        'no-immutable-reactive-statements': 'warn',
        'no-reactive-functions': 'warn',
        'no-reactive-literals': 'warn',
        'prefer-writable-derived': 'warn', // $state + $effect used where $derived belongs
        'require-each-key': 'warn',
        'require-store-reactive-access': 'error',
        'no-store-async': 'error',
        'no-at-html-tags': 'warn',
        'no-dom-manipulating': 'warn',
        'no-unused-svelte-ignore': 'off',
      }),
    });
  }
}

export default config;
