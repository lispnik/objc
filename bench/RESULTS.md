# objc bench

Nanoseconds per call, median of 5 rounds of 200000 after a warm-up.
Produced by `make bench`; see bench/bench.lisp for what each row does.

- **sbcl**: SBCL 2.6.8 ARM64 Darwin 25.6.0 2026-09-16 10:22 n=200000 rounds=5
- **ecl**: ECL 26.5.5 arm64 Darwin 25.6.0 2026-09-16 10:28 n=200000 rounds=5
- **lispworks**: LispWorks Personal Edition 8.1.2 arm64 Darwin 25.6.0 2026-09-16 10:26 n=200000 rounds=5

| measurement | sbcl | ecl | lispworks |
|---|---:|---:|---:|
| lisp: (length "hello world") | 5 | 11 | 5 |
| ffi: objc_msgSend -length, no bridge | 8 | 120 | 15 |
| invoke: -length (method on the receiver's class) | 238 | 15,860 | 120 |
| invoke: -self (inherited from NSObject) | 1,119 | 16,507 | 1,870 |
| invoke: +class on "NSString" (class receiver) | 505 | 16,234 | 780 |
| invoke: -objectAtIndex: (id in, id out) | 249 | 15,948 | 160 |
| invoke: -rangeOfString: (NSRange out) | 769 | 18,956 | 1,565 |
| invoke: -UTF8String -> Lisp string | 311 | 19,081 | 365 |
| invoke: -isEqualToString: (Lisp string in) | 1,472 | 66,893 | 580 |
| invoke: (invoke (invoke s uppercaseString) length) | 1,018 | 32,325 | 1,495 |
| invoke: -setPosition: float2 as double (list form) | 537 | 11,145 | 80 |
| invoke: -position -> double (list form) | 441 | 10,231 | 75 |
| invoke: -setPosition: #(1.0 2.0) (declared float2) | 491 | 19,575 | n/a |
| invoke: -position -> #(x y) (declared float2) | 490 | 19,559 | n/a |
| invoke: -setPosition: #(1.0 2.0 3.0) (declared float3) | 348 | 9,048 | n/a |
| invoke: -position -> #(x y z) (declared float3) | 295 | 7,428 | n/a |
| block: called back per element by NSArray | 108 | 1,641 | 50 |
| method: Lisp -twice: via invoke | 344 | 19,902 | 175 |
| method: Lisp -tick per element, makeObjectsPerformSelector: | 60 | 464 | 45 |
