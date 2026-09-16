# objc bench

Nanoseconds per call, median of 5 rounds of 200000 after a warm-up.
Produced by `make bench`; see bench/bench.lisp for what each row does.

- **sbcl**: SBCL 2.6.8 ARM64 Darwin 25.6.0 2026-09-16 10:39 n=200000 rounds=5
- **ecl**: ECL 26.5.5 arm64 Darwin 25.6.0 2026-09-16 10:40 n=200000 rounds=5
- **lispworks**: LispWorks Personal Edition 8.1.2 arm64 Darwin 25.6.0 2026-09-16 10:26 n=200000 rounds=5

| measurement | sbcl | ecl | lispworks |
|---|---:|---:|---:|
| lisp: (length "hello world") | 5 | 17 | 5 |
| ffi: objc_msgSend -length, no bridge | 8 | 119 | 15 |
| invoke: -length (method on the receiver's class) | 121 | 568 | 120 |
| invoke: -self (inherited from NSObject) | 116 | 570 | 1,870 |
| invoke: +class on "NSString" (class receiver) | 123 | 588 | 780 |
| invoke: -objectAtIndex: (id in, id out) | 134 | 683 | 160 |
| invoke: -rangeOfString: (NSRange out) | 286 | 3,233 | 1,565 |
| invoke: -UTF8String -> Lisp string | 197 | 3,725 | 365 |
| invoke: -isEqualToString: (Lisp string in) | 539 | 4,858 | 580 |
| invoke: (invoke (invoke s uppercaseString) length) | 394 | 1,324 | 1,495 |
| invoke: -setPosition: float2 as double (list form) | 134 | 680 | 80 |
| invoke: -position -> double (list form) | 129 | 583 | 75 |
| invoke: -setPosition: #(1.0 2.0) (declared float2) | 382 | 4,157 | n/a |
| invoke: -position -> #(x y) (declared float2) | 372 | 4,039 | n/a |
| invoke: -setPosition: #(1.0 2.0 3.0) (declared float3) | 254 | 7,247 | n/a |
| invoke: -position -> #(x y z) (declared float3) | 177 | 5,596 | n/a |
| block: called back per element by NSArray | 101 | 1,456 | 50 |
| method: Lisp -twice: via invoke | 212 | 1,342 | 175 |
| method: Lisp -tick per element, makeObjectsPerformSelector: | 56 | 463 | 45 |
