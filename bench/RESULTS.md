# objc bench

Nanoseconds per call, median of 5 rounds of 200000 after a warm-up.
Produced by `make bench`; see bench/bench.lisp for what each row does.

- **sbcl**: SBCL 2.6.8 ARM64 Darwin 25.6.0 2026-09-20 21:35 n=200000 rounds=5
- **sbcl-safepoint**: SBCL 2.6.8 (safepoint) ARM64 Darwin 25.6.0 2026-09-20 21:35 n=200000 rounds=5
- **ecl**: ECL 26.5.5 arm64 Darwin 25.6.0 2026-09-20 21:35 n=200000 rounds=5
- **lispworks**: LispWorks Personal Edition 8.1.2 arm64 Darwin 25.6.0 2026-09-16 10:26 n=200000 rounds=5

| measurement | sbcl | sbcl-safepoint | ecl | lispworks |
|---|---:|---:|---:|---:|
| lisp: (length "hello world") | 5 | 5 | 12 | 5 |
| ffi: objc_msgSend -length, no bridge | 7 | 8 | 127 | 15 |
| invoke: -length (method on the receiver's class) | 126 | 125 | 509 | 120 |
| invoke: -self (inherited from NSObject) | 128 | 125 | 478 | 1,870 |
| invoke: +class on "NSString" (class receiver) | 127 | 121 | 493 | 780 |
| invoke: -objectAtIndex: (id in, id out) | 141 | 137 | 677 | 160 |
| invoke: -rangeOfString: (NSRange out) | 290 | 308 | 1,065 | 1,565 |
| invoke: -UTF8String -> Lisp string | 218 | 238 | 997 | 365 |
| invoke: -isEqualToString: (Lisp string in) | 351 | 379 | 1,919 | 580 |
| invoke: (invoke (invoke s uppercaseString) length) | 418 | 414 | 1,120 | 1,495 |
| invoke: -setPosition: float2 as double (list form) | 130 | 132 | 554 | 80 |
| invoke: -position -> double (list form) | 129 | 130 | 485 | 75 |
| invoke: -setPosition: #(1.0 2.0) (declared float2) | 182 | 180 | 801 | n/a |
| invoke: -position -> #(x y) (declared float2) | 173 | 174 | 936 | n/a |
| invoke: -setPosition: #(1.0 2.0 3.0) (declared float3) | 241 | 242 | 1,090 | n/a |
| invoke: -position -> #(x y z) (declared float3) | 191 | 191 | 817 | n/a |
| block: called back per element by NSArray | 89 | 87 | 1,409 | 50 |
| method: Lisp -twice: via invoke | 273 | 264 | 1,042 | 175 |
| method: Lisp -tick per element, makeObjectsPerformSelector: | 110 | 102 | 443 | 45 |
| worker: a C no-op block through a queue and back (the hop) | 4,429 | 4,878 | 9,952 | n/a |
| worker: a Lisp block held here (the hop plus one Lisp entry) | 32,248 | 31,428 | 78,531 | n/a |
| worker: a Lisp block copied fresh (the same, plus copy and dispose) | 33,690 | 31,446 | 69,085 | n/a |
