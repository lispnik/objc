# objc bench

Nanoseconds per call, median of 5 rounds of 200000 after a warm-up.
Produced by `make bench`; see bench/bench.lisp for what each row does.

- **sbcl**: SBCL 2.6.8 ARM64 Darwin 25.6.0 2026-09-17 00:03 n=200000 rounds=5
- **ecl**: ECL 26.5.5 arm64 Darwin 25.6.0 2026-09-17 00:03 n=200000 rounds=5
- **lispworks**: LispWorks Personal Edition 8.1.2 arm64 Darwin 25.6.0 2026-09-16 10:26 n=200000 rounds=5

| measurement | sbcl | ecl | lispworks |
|---|---:|---:|---:|
| lisp: (length "hello world") | 5 | 13 | 5 |
| ffi: objc_msgSend -length, no bridge | 8 | 116 | 15 |
| invoke: -length (method on the receiver's class) | 116 | 462 | 120 |
| invoke: -self (inherited from NSObject) | 111 | 452 | 1,870 |
| invoke: +class on "NSString" (class receiver) | 119 | 470 | 780 |
| invoke: -objectAtIndex: (id in, id out) | 130 | 565 | 160 |
| invoke: -rangeOfString: (NSRange out) | 291 | 1,015 | 1,565 |
| invoke: -UTF8String -> Lisp string | 202 | 903 | 365 |
| invoke: -isEqualToString: (Lisp string in) | 337 | 1,685 | 580 |
| invoke: (invoke (invoke s uppercaseString) length) | 404 | 1,106 | 1,495 |
| invoke: -setPosition: float2 as double (list form) | 133 | 542 | 80 |
| invoke: -position -> double (list form) | 124 | 464 | 75 |
| invoke: -setPosition: #(1.0 2.0) (declared float2) | 177 | 779 | n/a |
| invoke: -position -> #(x y) (declared float2) | 170 | 834 | n/a |
| invoke: -setPosition: #(1.0 2.0 3.0) (declared float3) | 241 | 1,036 | n/a |
| invoke: -position -> #(x y z) (declared float3) | 179 | 761 | n/a |
| block: called back per element by NSArray | 105 | 1,380 | 50 |
| method: Lisp -twice: via invoke | 208 | 964 | 175 |
| method: Lisp -tick per element, makeObjectsPerformSelector: | 56 | 396 | 45 |
