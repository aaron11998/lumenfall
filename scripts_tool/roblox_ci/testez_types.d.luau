-- Type definitions for TestEZ v0.4.2 globals (AGE-142 CI type-check).
-- Minimal surface: describe/it/expect used by the suite. expect(...) is
-- callable and returns an expectation with chained matchers (TestEZ style).

declare function describe(phrase: string, callback: () -> ()): ()
declare function describeFOCUS(phrase: string, callback: () -> ()): ()
declare function describeSKIP(phrase: string, callback: () -> ()): ()
declare function it(phrase: string, callback: () -> ()): ()
declare function itFOCUS(phrase: string, callback: () -> ()): ()
declare function itSKIP(phrase: string, callback: () -> ()): ()
declare function itFIXME(phrase: string, callback: () -> ()): ()
declare function FIXME(phrase: string, callback: () -> ()): ()
declare function FOCUS(phrase: string, callback: () -> ()): ()
declare function SKIP(phrase: string, callback: () -> ()): ()

declare function expect(value: any): any
