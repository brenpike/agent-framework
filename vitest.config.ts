import { defineConfig } from 'vitest/config';

// Characterization-test harness for the website (web/scripts/main.js).
// INVARIANT: include is scoped to web/tests so Vitest never discovers the repo's
// non-vitest fixture trees under plugin/ or tests/ (policy fixtures, report fixtures).
export default defineConfig({
  test: {
    environment: 'jsdom',
    include: ['web/tests/**/*.test.ts'],
    setupFiles: ['web/tests/setup/test-setup.ts'],
  },
});
