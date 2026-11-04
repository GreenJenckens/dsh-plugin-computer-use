import { test } from 'node:test'
import assert from 'node:assert/strict'
import { isCalculatorTitle } from '../lib/titles.js'

test('calculator title matcher accepts RU and EN window titles', () => {
  assert.equal(isCalculatorTitle('hwnd=1 pid=2 ApplicationFrameHost "Калькулятор" 0,0 300x500 fg'), true)
  assert.equal(isCalculatorTitle('hwnd=1 pid=2 Calculator "Calculator" 0,0 300x500'), true)
  assert.equal(isCalculatorTitle('hwnd=1 pid=2 ApplicationFrameHost "Notepad" 0,0 300x500'), false)
  assert.equal(isCalculatorTitle('hwnd=1 pid=2 ApplicationFrameHost "Диспетчер задач" 0,0 300x500'), false)
  assert.equal(isCalculatorTitle('hwnd=1 pid=2 ApplicationFrameHost "Calculadora" 0,0 300x500'), false)
})
