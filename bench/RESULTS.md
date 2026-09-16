# objc bench

Nanoseconds per call, median of 5 rounds of 200000 after a warm-up.
Produced by `make bench`; see bench/bench.lisp for what each row does.

- **sbcl**: SBCL 2.6.8 ARM64 Darwin 25.6.0 2026-09-16 11:42 n=200000 rounds=5
- **ecl**: ECL 26.5.5 arm64 Darwin 25.6.0 2026-09-16 11:43 n=200000 rounds=5
- **lispworks**: LispWorks Personal Edition 8.1.2 arm64 Darwin 25.6.0 2026-09-16 10:26 n=200000 rounds=5

| measurement | sbcl | ecl | lispworks |
|---|---:|---:|---:|
| lisp: (length "hello world") | 5 | 14 | 5 |
| ffi: objc_msgSend -length, no bridge | 8 | 121 | 15 |
| invoke: -length (method on the receiver's class) | 121 | 567 | 120 |
| invoke: -self (inherited from NSObject) | 122 | 603 | 1,870 |
| invoke: +class on "NSString" (class receiver) | 126 | 590 | 780 |
| invoke: -objectAtIndex: (id in, id out) | 138 | 679 | 160 |
| invoke: -rangeOfString: (NSRange out) | 313 | 3,236 | 1,565 |
| invoke: -UTF8String -> Lisp string | 206 | 3,707 | 365 |
| invoke: -isEqualToString: (Lisp string in) | 365 | 3,899 | 580 |
| invoke: (invoke (invoke s uppercaseString) length) | 421 | 1,339 | 1,495 |
| invoke: -setPosition: float2 as double (list form) | 145 | 653 | 80 |
| invoke: -position -> double (list form) | 145 | 577 | 75 |
| invoke: -setPosition: #(1.0 2.0) (declared float2) | 193 | 1,098 | n/a |
| invoke: -position -> #(x y) (declared float2) | 166 | 1,079 | n/a |
| invoke: -setPosition: #(1.0 2.0 3.0) (declared float3) | 245 | 6,974 | n/a |
| invoke: -position -> #(x y z) (declared float3) | 180 | 5,402 | n/a |
| block: called back per element by NSArray | 103 | 1,485 | 50 |
| method: Lisp -twice: via invoke | 220 | 1,128 | 175 |
| method: Lisp -tick per element, makeObjectsPerformSelector: | 56 | 518 | 45 |
