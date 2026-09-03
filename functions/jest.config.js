/** @type {import('jest').Config} */
module.exports = {
  preset: "ts-jest",
  testEnvironment: "node",
  rootDir: ".",
  testMatch: ["<rootDir>/test/**/*.test.ts"],
  testTimeout: 20000,
  // ПОРЯДОК НАБОРОВ ПЕРЕМЕШИВАЕТСЯ КАЖДЫЙ ПРОГОН (долг N192). Разбор, цена и
  // границы — в самом файле; повторить порядок красного прогона:
  // JEST_SHUFFLE_SEED=<зерно из вывода> npm test
  testSequencer: "<rootDir>/test-sequencer.js",
};
