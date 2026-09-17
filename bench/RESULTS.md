# objc bench

Nanoseconds per call, median of 5 rounds of 200000 after a warm-up.
Produced by `make bench`; see bench/bench.lisp for what each row does.

- **sbcl**: SBCL 2.6.8 ARM64 Darwin 25.6.0 2026-09-17 14:16 n=200000 rounds=5
- **ecl**: ECL 26.5.5 arm64 Darwin 25.6.0 2026-09-17 14:17 n=200000 rounds=5
- **lispworks**: LispWorks Personal Edition 8.1.2 arm64 Darwin 25.6.0 2026-09-16 10:26 n=200000 rounds=5

| measurement | sbcl | ecl | lispworks |
|---|---:|---:|---:|
| lisp: (length "hello world") | 6 | 13 | 5 |
| ffi: objc_msgSend -length, no bridge | 8 | 124 | 15 |
| invoke: -length (method on the receiver's class) | 117 | 488 | 120 |
| invoke: -self (inherited from NSObject) | 115 | 465 | 1,870 |
| invoke: +class on "NSString" (class receiver) | 116 | 486 | 780 |
| invoke: -objectAtIndex: (id in, id out) | 131 | 579 | 160 |
| invoke: -rangeOfString: (NSRange out) | 298 | 1,050 | 1,565 |
| invoke: -UTF8String -> Lisp string | 225 | 938 | 365 |
| invoke: -isEqualToString: (Lisp string in) | 376 | 1,825 | 580 |
| invoke: (invoke (invoke s uppercaseString) length) | 391 | 1,107 | 1,495 |
| invoke: -setPosition: float2 as double (list form) | 136 | 548 | 80 |
| invoke: -position -> double (list form) | 127 | 480 | 75 |
| invoke: -setPosition: #(1.0 2.0) (declared float2) | 180 | 788 | n/a |
| invoke: -position -> #(x y) (declared float2) | 166 | 873 | n/a |
| invoke: -setPosition: #(1.0 2.0 3.0) (declared float3) | 242 | 1,078 | n/a |
| invoke: -position -> #(x y z) (declared float3) | 186 | 788 | n/a |
| block: called back per element by NSArray | 91 | 1,404 | 50 |
| method: Lisp -twice: via invoke | 249 | 1,007 | 175 |
| method: Lisp -tick per element, makeObjectsPerformSelector: | 102 | 438 | 45 |
