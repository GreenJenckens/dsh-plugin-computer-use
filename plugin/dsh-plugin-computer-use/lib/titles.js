// Locale-independent window title helpers.
// Windows Calculator is hosted by ApplicationFrameHost and its title is
// localized ("Калькулятор" on a Russian system), so tests must never match
// only the English word.
const CALCULATOR_TITLE = /"(?:[^"]*)(Calculator|Калькулятор)[^"]*"/i

export function isCalculatorTitle(line) {
  return typeof line === 'string' && CALCULATOR_TITLE.test(line)
}
