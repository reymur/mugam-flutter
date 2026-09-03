/** @type {import('jest').Config} */
module.exports = {
  preset: "ts-jest",
  testEnvironment: "node",
  rootDir: ".",
  testMatch: ["<rootDir>/test/**/*.test.ts"],
  // ПОДНЯТО С 20 000 ДО 60 000 03.09 ВМЕСТЕ С `DEFAULT_TIMEOUT_MS` (N197).
  // Оба числа связаны и обязаны двигаться вместе: порог `waitFor` должен
  // оставаться ЗАВЕДОМО МЕНЬШЕ этого, иначе ожидание убьёт сам jest, и вместо
  // «waitFor: condition not met» в отчёте встанет безымянное «Exceeded
  // timeout», не называющее причину. Разбор — у самой константы, test/helpers.ts.
  testTimeout: 60000,
  // ПОРЯДОК НАБОРОВ ПЕРЕМЕШИВАЕТСЯ КАЖДЫЙ ПРОГОН (долг N192). Разбор, цена и
  // границы — в самом файле; повторить порядок красного прогона:
  // JEST_SHUFFLE_SEED=<зерно из вывода> npm test
  testSequencer: "<rootDir>/test-sequencer.js",
};
