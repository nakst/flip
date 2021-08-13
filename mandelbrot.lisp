[set-graphics 1]

; Constants.
[let WIDTH  320]
[let HEIGHT 200]
[let MAXIT   15]
[let FIXED  500]

; Fixed-point arithmetic.
[let mf [fun [x] [* x FIXED]]]
[let *f [fun [x y] [muldiv x y FIXED]]]

; Complex numbers.
[let re [fun [z] [car z]]]
[let im [fun [z] [cdr z]]]
[let +c [fun [a b] [cons [+ [re a] [re b]] [+ [im a] [im b]]]]]
[let square-c [fun [z] [cons 
  [- [*f [re z] [re z]] [*f [im z] [im z]]] 
  [* 2 [*f [re z] [im z]]]]]]
[let length-squared [fun [z] [+ [*f [re z] [re z]] [*f [im z] [im z]]]]]

; Viewport.
[let getx [fun [x] [- [muldiv x [mf 3] WIDTH]  [mf 2]]]]
[let gety [fun [y] [- [muldiv y [mf 2] HEIGHT] [mf 1]]]]

; Image generation.
[let iterate [fun [z c] [+c c [square-c z]]]]
[let do_pixel [fun [X Y c] [let i 0] [let z c] 
  [while [and [< i MAXIT] [<= [length-squared z] [mf 4]]] 
    [do [= z [iterate z c]] [inc i]]] 
  [poke 10 [+ X [* 320 Y]] [+ 64 i]]]]
[let do_row [fun [Y y] [let col 0] [while [< col WIDTH] 
  [do [do_pixel col Y [cons [getx col] y]] [inc col]]]]]
[let image [fun [] [let row 0] [while [< row HEIGHT] 
  [do [do_row row [gety row]] [inc row]]]]]

; Show the image and wait for user input.
[image]
[wait-key]
[set-graphics nil]
