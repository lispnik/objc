# objc bench

Nanoseconds per call, median of 5 rounds of 200000 after a warm-up.
Produced by `make bench`; see bench/bench.lisp for what each row does.

- **sbcl**: SBCL 2.6.8 ARM64 Darwin 25.6.0 2026-09-16 11:15 n=200000 rounds=5
- **ecl**: ECL 26.5.5 arm64 Darwin 25.6.0 2026-09-16 11:16 n=200000 rounds=5
- **lispworks**: LispWorks Personal Edition 8.1.2 arm64 Darwin 25.6.0 2026-09-16 10:26 n=200000 rounds=5

| measurement | sbcl | ecl | lispworks |
|---|---:|---:|---:|
| lisp: (length "hello world") | 6 | 10 | 5 |
| ffi: objc_msgSend -length, no bridge | 8 | 127 | 15 |
| invoke: -length (method on the receiver's class) | 122 | 574 | 120 |
| invoke: -self (inherited from NSObject) | 130 | 577 | 1,870 |
| invoke: +class on "NSString" (class receiver) | 134 | 597 | 780 |
| invoke: -objectAtIndex: (id in, id out) | 136 | 680 | 160 |
| invoke: -rangeOfString: (NSRange out) | 284 | 3,535 | 1,565 |
| invoke: -UTF8String -> Lisp string | 196 | 3,643 | 365 |
| invoke: -isEqualToString: (Lisp string in) | 359 | 3,919 | 580 |
| invoke: (invoke (invoke s uppercaseString) length) | 389 | 1,350 | 1,495 |
| invoke: -setPosition: float2 as double (list form) | 141 | 654 | 80 |
| invoke: -position -> double (list form) | 139 | 605 | 75 |
| invoke: -setPosition: #(1.0 2.0) (declared float2) | 226 | 1,332 | n/a |
| invoke: -position -> #(x y) (declared float2) | 170 | 1,144 | n/a |
| invoke: -setPosition: #(1.0 2.0 3.0) (declared float3) | 251 | 7,097 | n/a |
| invoke: -position -> #(x y z) (declared float3) | 179 | 5,438 | n/a |
| block: called back per element by NSArray | 107 | 1,446 | 50 |
| method: Lisp -twice: via invoke | 214 | 1,128 | 175 |
| method: Lisp -tick per element, makeObjectsPerformSelector: | 56 | 432 | 45 |
