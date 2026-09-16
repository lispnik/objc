# objc bench

Nanoseconds per call, median of 5 rounds of 200000 after a warm-up.
Produced by `make bench`; see bench/bench.lisp for what each row does.

- **sbcl**: SBCL 2.6.8 ARM64 Darwin 25.6.0 2026-09-16 12:25 n=200000 rounds=5
- **ecl**: ECL 26.5.5 arm64 Darwin 25.6.0 2026-09-16 12:26 n=200000 rounds=5
- **lispworks**: LispWorks Personal Edition 8.1.2 arm64 Darwin 25.6.0 2026-09-16 10:26 n=200000 rounds=5

| measurement | sbcl | ecl | lispworks |
|---|---:|---:|---:|
| lisp: (length "hello world") | 5 | 16 | 5 |
| ffi: objc_msgSend -length, no bridge | 8 | 116 | 15 |
| invoke: -length (method on the receiver's class) | 119 | 562 | 120 |
| invoke: -self (inherited from NSObject) | 122 | 568 | 1,870 |
| invoke: +class on "NSString" (class receiver) | 124 | 628 | 780 |
| invoke: -objectAtIndex: (id in, id out) | 136 | 680 | 160 |
| invoke: -rangeOfString: (NSRange out) | 293 | 1,093 | 1,565 |
| invoke: -UTF8String -> Lisp string | 200 | 1,016 | 365 |
| invoke: -isEqualToString: (Lisp string in) | 345 | 1,989 | 580 |
| invoke: (invoke (invoke s uppercaseString) length) | 412 | 1,308 | 1,495 |
| invoke: -setPosition: float2 as double (list form) | 136 | 651 | 80 |
| invoke: -position -> double (list form) | 128 | 585 | 75 |
| invoke: -setPosition: #(1.0 2.0) (declared float2) | 182 | 900 | n/a |
| invoke: -position -> #(x y) (declared float2) | 165 | 934 | n/a |
| invoke: -setPosition: #(1.0 2.0 3.0) (declared float3) | 244 | 1,164 | n/a |
| invoke: -position -> #(x y z) (declared float3) | 184 | 830 | n/a |
| block: called back per element by NSArray | 108 | 1,430 | 50 |
| method: Lisp -twice: via invoke | 215 | 1,113 | 175 |
| method: Lisp -tick per element, makeObjectsPerformSelector: | 59 | 425 | 45 |
