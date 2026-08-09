# Slip — the micro-LISP

Slip is Caravan's embedded symbolic engine: a tiny, **total** (step-capped,
always terminates), **sandboxed** (no IO, no clock, no randomness) LISP
over the JSON universe. Models use it through the `lisp` tool to do exact
arithmetic, counting, filtering, and data reshaping instead of
approximating in prose; humans poke it with `/lisp`.

```
❯ /lisp (mean (map (lambda (r) (get "t" r)) data))
```

## Why

Long agentic runs die on small arithmetic and bookkeeping mistakes.
Handing a model — 2B or 200B — an exact calculator with its full manual
in the tool description removes a whole failure class. Homoiconicity
(code = lists) plays to model strengths: programs are easy to generate,
inspect, and even transform with `read` / `show` / `eval`.

## The language on one page

```lisp
; forms
(if cond then else)  (let ((x 1) (y 2)) body)  (define name expr)
(lambda (x) body)    (do e1 e2)                (quote x)  or  'x

; math / compare        (+ - * / mod abs min max round sum mean)
(+ 1 2 3)        ; 6    (= != < > <= >= not and or)
(sum (range 1 101))     ; 5050

; lists
(list 1 2)  (len xs)  (first xs)  (last xs)  (nth 0 xs)  (rest xs)
(append a b)  (reverse xs)  (sort xs)  (range 0 10)
(map f xs)  (filter f xs)  (reduce f init xs)
(map upper (list "a" "b"))            ; builtins are first-class

; records & tables (JSON objects / arrays of objects)
(get "name" row)  (keys row)  (put "k" v row)
(select "name" "age" rows)  (where "role" "admin" rows)  (sort-by "age" rows)

; strings
(str "n=" 3)  (upper s)  (lower s)  (contains s sub)
(split "a,b" ",")  (join xs ", ")

; types & JSON
(number? x) (string? x) (list? x) (record? x) (null? x)
(parse-json "[1,2]")  (to-json x)

; code as data
(read "(+ 1 2)")   ; → the list (+ 1 2)
(show '(+ 1 2))    ; → "(+ 1 2)"
(eval '(+ 1 2))    ; → 3
```

Recursion works and is safe — the evaluator burns a step budget
(default 100 000) and returns a clean error instead of hanging:

```lisp
(define fact (lambda (n) (if (<= n 1) 1 (* n (fact (- n 1))))))
(fact 10)   ; 3628800
```

## The `lisp` tool

Input: `{"program": "...", "data": <any JSON>}` — `data` is bound to the
symbol `data` inside the program. Native data operations (`sum`, `sort`,
`where`, …) cost one step regardless of size, so million-element folds
are fine; only interpreted steps (lambda applications) burn budget.

From OCaml: `Caravan.Lisp.run ?max_steps ?data src` →
`(Value.t, string) result`.
