# objc bench

Nanoseconds per call, median of 5 rounds of 200000 after a warm-up.
Produced by `make bench`; see bench/bench.lisp for what each row does.

- **sbcl**: SBCL 2.6.8 ARM64 Darwin 25.6.0 2026-09-18 13:21 n=200000 rounds=5
- **sbcl-safepoint**: SBCL 2.6.8 (safepoint) ARM64 Darwin 25.6.0 2026-09-18 13:21 n=200000 rounds=5
- **ecl**: ECL 26.5.5 arm64 Darwin 25.6.0 2026-09-18 13:22 n=200000 rounds=5
- **lispworks**: LispWorks Personal Edition 8.1.2 arm64 Darwin 25.6.0 2026-09-16 10:26 n=200000 rounds=5

| measurement | sbcl | sbcl-safepoint | ecl | lispworks |
|---|---:|---:|---:|---:|
| lisp: (length "hello world") | 6 | 5 | 10 | 5 |
| ffi: objc_msgSend -length, no bridge | 8 | 8 | 124 | 15 |
| invoke: -length (method on the receiver's class) | 122 | 120 | 475 | 120 |
| invoke: -self (inherited from NSObject) | 130 | 116 | 474 | 1,870 |
| invoke: +class on "NSString" (class receiver) | 126 | 117 | 498 | 780 |
| invoke: -objectAtIndex: (id in, id out) | 146 | 134 | 585 | 160 |
| invoke: -rangeOfString: (NSRange out) | 285 | 293 | 1,048 | 1,565 |
| invoke: -UTF8String -> Lisp string | 207 | 207 | 961 | 365 |
| invoke: -isEqualToString: (Lisp string in) | 336 | 329 | 1,813 | 580 |
| invoke: (invoke (invoke s uppercaseString) length) | 391 | 390 | 1,104 | 1,495 |
| invoke: -setPosition: float2 as double (list form) | 131 | 132 | 548 | 80 |
| invoke: -position -> double (list form) | 127 | 134 | 475 | 75 |
| invoke: -setPosition: #(1.0 2.0) (declared float2) | 185 | 178 | 832 | n/a |
| invoke: -position -> #(x y) (declared float2) | 175 | 174 | 826 | n/a |
| invoke: -setPosition: #(1.0 2.0 3.0) (declared float3) | 244 | 237 | 1,086 | n/a |
| invoke: -position -> #(x y z) (declared float3) | 243 | 192 | 798 | n/a |
| block: called back per element by NSArray | 87 | 84 | 1,366 | 50 |
| method: Lisp -twice: via invoke | 268 | 253 | 1,045 | 175 |
| method: Lisp -tick per element, makeObjectsPerformSelector: | 104 | 102 | 430 | 45 |
| worker: a C no-op block through a queue and back (the hop) | 4,842 | 4,983 | 9,811 | n/a |
| worker: a Lisp block held here (one adoption, the invoke) | 26,386 | 27,390 | 60,406 | n/a |
| worker: a Lisp block copied fresh (two: invoke and dispose helper) | 49,542 | 49,434 | 111,009 | n/a |
