# objc bench

Nanoseconds per call, median of 5 rounds of 200000 after a warm-up.
Produced by `make bench`; see bench/bench.lisp for what each row does.

- **sbcl**: SBCL 2.6.8 ARM64 Darwin 25.6.0 2026-09-16 12:25 n=200000 rounds=5
- **ecl**: ECL 26.5.5 arm64 Darwin 25.6.0 2026-09-16 14:30 n=200000 rounds=5
- **lispworks**: LispWorks Personal Edition 8.1.2 arm64 Darwin 25.6.0 2026-09-16 10:26 n=200000 rounds=5

| measurement | sbcl | ecl | lispworks |
|---|---:|---:|---:|
| lisp: (length "hello world") | 5 | 10 | 5 |
| ffi: objc_msgSend -length, no bridge | 8 | 124 | 15 |
| invoke: -length (method on the receiver's class) | 119 | 461 | 120 |
| invoke: -self (inherited from NSObject) | 122 | 457 | 1,870 |
| invoke: +class on "NSString" (class receiver) | 124 | 498 | 780 |
| invoke: -objectAtIndex: (id in, id out) | 136 | 572 | 160 |
| invoke: -rangeOfString: (NSRange out) | 293 | 1,036 | 1,565 |
| invoke: -UTF8String -> Lisp string | 200 | 929 | 365 |
| invoke: -isEqualToString: (Lisp string in) | 345 | 1,854 | 580 |
| invoke: (invoke (invoke s uppercaseString) length) | 412 | 1,108 | 1,495 |
| invoke: -setPosition: float2 as double (list form) | 136 | 544 | 80 |
| invoke: -position -> double (list form) | 128 | 467 | 75 |
| invoke: -setPosition: #(1.0 2.0) (declared float2) | 182 | 779 | n/a |
| invoke: -position -> #(x y) (declared float2) | 165 | 814 | n/a |
| invoke: -setPosition: #(1.0 2.0 3.0) (declared float3) | 244 | 1,059 | n/a |
| invoke: -position -> #(x y z) (declared float3) | 184 | 782 | n/a |
| block: called back per element by NSArray | 108 | 1,424 | 50 |
| method: Lisp -twice: via invoke | 215 | 993 | 175 |
| method: Lisp -tick per element, makeObjectsPerformSelector: | 59 | 431 | 45 |
