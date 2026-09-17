# objc bench

Nanoseconds per call, median of 5 rounds of 200000 after a warm-up.
Produced by `make bench`; see bench/bench.lisp for what each row does.

- **sbcl**: SBCL 2.6.8 ARM64 Darwin 25.6.0 2026-09-17 13:55 n=200000 rounds=5
- **ecl**: ECL 26.5.5 arm64 Darwin 25.6.0 2026-09-17 13:57 n=200000 rounds=5
- **lispworks**: LispWorks Personal Edition 8.1.2 arm64 Darwin 25.6.0 2026-09-16 10:26 n=200000 rounds=5

| measurement | sbcl | ecl | lispworks |
|---|---:|---:|---:|
| lisp: (length "hello world") | 5 | 10 | 5 |
| ffi: objc_msgSend -length, no bridge | 8 | 125 | 15 |
| invoke: -length (method on the receiver's class) | 117 | 459 | 120 |
| invoke: -self (inherited from NSObject) | 112 | 458 | 1,870 |
| invoke: +class on "NSString" (class receiver) | 114 | 488 | 780 |
| invoke: -objectAtIndex: (id in, id out) | 131 | 578 | 160 |
| invoke: -rangeOfString: (NSRange out) | 291 | 1,139 | 1,565 |
| invoke: -UTF8String -> Lisp string | 201 | 945 | 365 |
| invoke: -isEqualToString: (Lisp string in) | 333 | 1,856 | 580 |
| invoke: (invoke (invoke s uppercaseString) length) | 441 | 1,150 | 1,495 |
| invoke: -setPosition: float2 as double (list form) | 153 | 553 | 80 |
| invoke: -position -> double (list form) | 164 | 476 | 75 |
| invoke: -setPosition: #(1.0 2.0) (declared float2) | 253 | 786 | n/a |
| invoke: -position -> #(x y) (declared float2) | 188 | 825 | n/a |
| invoke: -setPosition: #(1.0 2.0 3.0) (declared float3) | 310 | 1,182 | n/a |
| invoke: -position -> #(x y z) (declared float3) | 216 | 881 | n/a |
| block: called back per element by NSArray | 112 | 1,435 | 50 |
| method: Lisp -twice: via invoke | 286 | 1,011 | 175 |
| method: Lisp -tick per element, makeObjectsPerformSelector: | 121 | 427 | 45 |
