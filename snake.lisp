[let TILE 16]
[let GRID_X 20]
[let GRID_Y 12]

[let snake nil]
[let direction nil]
[let direction-id nil]
[let apple nil]
[let game-running nil]
[let score nil]

[let tile-head-left  [q [1 1 1 3 3 3 1 1 1 2 3 4 5 4 3 3 1 3 4 6 5 5 5 5 1 3 4 4 5 5 5 5 1 3 4 4 5 5 5 5 1 3 4 6 5 5 5 5 1 2 3 4 5 4 3 3 1 1 1 3 3 3 1 1]]]
[let tile-head-right [q [1 1 3 3 3 1 1 1 3 3 4 5 4 3 2 1 5 5 5 5 6 4 3 1 5 5 5 5 4 4 3 1 5 5 5 5 4 4 3 1 5 5 5 5 6 4 3 1 3 3 4 5 4 3 2 1 1 1 3 3 3 1 1 1]]]
[let tile-head-down  [q [1 3 5 5 5 5 3 1 1 3 5 5 5 5 3 1 3 4 5 5 5 5 4 3 3 5 5 5 5 5 5 3 3 4 6 4 4 6 4 3 1 3 4 4 4 4 3 1 1 2 3 3 3 3 2 1 1 1 1 1 1 1 1 1]]]
[let tile-head-up    [q [1 1 1 1 1 1 1 1 1 2 3 3 3 3 2 1 1 3 4 4 4 4 3 1 3 4 6 4 4 6 4 3 3 5 5 5 5 5 5 3 3 4 5 5 5 5 4 3 1 3 5 5 5 5 3 1 1 3 5 5 5 5 3 1]]]
[let tile-tail-left  [q [1 1 1 1 1 1 1 1 3 3 2 1 1 2 2 1 5 5 4 3 1 1 2 1 5 5 5 5 4 3 1 1 5 5 5 5 4 3 1 1 5 5 4 3 1 1 2 1 3 3 2 1 1 2 2 1 1 1 1 1 1 1 1 1]]]
[let tile-tail-right [q [1 1 1 1 1 1 1 1 1 2 2 1 1 2 3 3 1 2 1 1 3 4 5 5 1 1 3 4 5 5 5 5 1 1 3 4 5 5 5 5 1 2 1 1 3 4 5 5 1 2 2 1 1 2 3 3 1 1 1 1 1 1 1 1]]]
[let tile-tail-down  [q [1 1 1 1 1 1 1 1 1 2 2 1 1 2 2 1 1 2 1 3 3 1 2 1 1 1 1 4 4 1 1 1 1 1 3 5 5 3 1 1 1 2 4 5 5 4 2 1 1 3 5 5 5 5 3 1 1 3 5 5 5 5 3 1]]]
[let tile-tail-up    [q [1 3 5 5 5 5 3 1 1 3 5 5 5 5 3 1 1 2 4 5 5 4 2 1 1 1 3 5 5 3 1 1 1 1 1 4 4 1 1 1 1 2 1 3 3 1 2 1 1 2 2 1 1 2 2 1 1 1 1 1 1 1 1 1]]]
[let tile-body-h     [q [1 1 1 1 1 1 1 1 3 3 3 1 1 3 3 3 5 5 4 3 3 4 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 4 3 3 4 5 5 3 3 3 1 1 3 3 3 1 1 1 1 1 1 1 1]]]
[let tile-body-v     [q [1 3 5 5 5 5 3 1 1 3 5 5 5 5 3 1 1 3 4 5 5 4 3 1 1 1 3 5 5 3 1 1 1 1 3 5 5 3 1 1 1 3 4 5 5 4 3 1 1 3 5 5 5 5 3 1 1 3 5 5 5 5 3 1]]]
[let tile-body-nw    [q [1 3 5 5 5 5 3 1 3 4 5 5 5 5 3 1 5 5 5 5 5 5 3 1 5 5 5 5 5 4 3 1 5 5 5 5 4 3 1 1 5 5 5 4 3 1 2 1 3 3 3 3 1 2 2 1 1 1 1 1 1 1 1 1]]]
[let tile-body-ne    [q [1 3 5 5 5 5 3 1 1 3 5 5 5 5 4 3 1 3 5 5 5 5 5 5 1 3 4 5 5 5 5 5 1 1 3 4 5 5 5 5 1 2 1 3 4 5 5 5 1 2 2 1 3 3 3 3 1 1 1 1 1 1 1 1]]]
[let tile-body-sw    [q [1 1 1 1 1 1 1 1 3 3 3 3 1 2 2 1 5 5 5 4 3 1 2 1 5 5 5 5 4 3 1 1 5 5 5 5 5 4 3 1 5 5 5 5 5 5 3 1 3 4 5 5 5 5 3 1 1 3 5 5 5 5 3 1]]]
[let tile-body-se    [q [1 1 1 1 1 1 1 1 1 2 2 1 3 3 3 3 1 2 1 3 4 5 5 5 1 1 3 4 5 5 5 5 1 3 4 5 5 5 5 5 1 3 5 5 5 5 5 5 1 3 5 5 5 5 4 3 1 3 5 5 5 5 3 1]]]
[let tile-background [q [1 1 1 1 1 1 1 1 1 2 2 1 1 2 2 1 1 2 1 1 1 1 2 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 2 1 1 1 1 2 1 1 2 2 1 1 2 2 1 1 1 1 1 1 1 1 1]]]
[let tile-apple      [q [1 1 1 9 1 1 1 1 1 2 2 1 9 2 2 1 1 7 7 7 9 8 8 1 7 7 9 7 7 8 8 8 7 9 9 7 7 8 8 8 7 7 7 7 7 8 8 8 1 7 7 7 7 8 8 1 1 1 7 7 8 8 1 1]]]
[let tile-digit-0    [q [2 2 7 7 7 7 2 2 2 7 7 8 8 7 7 2 2 7 7 8 2 7 7 8 2 7 7 8 7 7 7 8 2 7 7 7 2 7 7 8 2 7 7 8 2 7 7 8 2 7 7 8 2 7 7 8 2 2 7 7 7 7 8 2]]]
[let tile-digit-1    [q [2 2 2 7 7 2 2 2 2 2 7 7 7 8 2 2 2 2 7 7 7 8 2 2 2 2 2 7 7 8 2 2 2 2 2 7 7 8 2 2 2 2 2 7 7 8 2 2 2 2 2 7 7 8 2 2 2 2 2 7 7 8 2 2]]]
[let tile-digit-2    [q [2 2 7 7 7 7 2 2 2 7 7 8 8 7 7 8 2 7 7 8 2 7 7 8 2 2 8 2 2 7 7 8 2 2 7 7 7 7 8 2 2 7 7 8 8 8 2 2 2 7 7 8 2 7 7 2 2 7 7 7 7 7 7 8]]]
[let tile-digit-3    [q [2 2 7 7 7 7 2 2 2 2 2 8 8 7 7 2 2 2 2 2 2 7 7 8 2 2 2 7 7 7 7 8 2 2 2 2 8 7 7 8 2 2 2 2 2 7 7 8 2 2 2 2 2 7 7 8 2 2 7 7 7 7 8 2]]]
[let tile-digit-4    [q [2 2 7 2 2 7 7 2 2 2 7 8 2 7 7 8 2 7 7 8 2 7 7 8 2 7 7 8 2 7 7 8 2 7 7 7 7 7 7 8 2 2 8 8 8 7 7 8 2 2 2 2 2 7 7 8 2 2 2 2 2 7 7 8]]]
[let tile-digit-5    [q [2 2 7 7 7 7 7 2 2 2 7 7 8 8 8 2 2 2 7 7 2 2 2 2 2 2 7 7 7 7 2 2 2 2 2 8 8 7 7 2 2 2 2 2 2 7 7 8 2 2 2 2 2 7 7 8 2 2 7 7 7 7 8 2]]]
[let tile-digit-6    [q [2 2 7 7 7 7 2 2 2 7 7 8 8 7 7 2 2 7 7 2 2 7 7 8 2 7 7 2 2 2 8 8 2 7 7 7 7 7 7 2 2 7 7 8 8 7 7 8 2 7 7 8 2 7 7 8 2 2 7 7 7 7 8 2]]]
[let tile-digit-7    [q [2 7 7 7 7 7 7 2 2 7 7 8 8 7 7 8 2 2 8 2 2 7 7 8 2 2 2 2 2 7 7 8 2 2 2 2 2 7 7 8 2 2 2 2 7 7 8 2 2 2 2 2 7 7 8 2 2 2 2 2 7 7 8 2]]]
[let tile-digit-8    [q [2 2 7 7 7 7 2 2 2 7 7 8 8 7 7 2 2 7 7 8 2 7 7 8 2 2 7 7 7 7 8 2 2 7 7 8 8 7 7 2 2 7 7 8 2 7 7 8 2 7 7 8 2 7 7 8 2 2 7 7 7 7 8 2]]]
[let tile-digit-9    [q [2 2 7 7 7 7 2 2 2 7 7 8 8 7 7 2 2 7 7 8 2 7 7 8 2 2 7 7 7 7 7 8 2 2 2 8 8 7 7 8 2 2 2 2 2 7 7 8 2 7 7 2 2 7 7 8 2 2 7 7 7 7 8 2]]]

[let tile-digits [list tile-digit-0 tile-digit-1 tile-digit-2 tile-digit-3 tile-digit-4 tile-digit-5 tile-digit-6 tile-digit-7 tile-digit-8 tile-digit-9]]

[defun tile-overlap [x y] [and [is [car x] [car y]] [is [cdr x] [cdr y]]]]

[defun draw-tile [x y tile] [do
  [let i 0]
  [while [< i TILE] [do
    [let p [+ [* x TILE] [* [+ i [* y TILE]] 320]]]
    [let j 0]
    [let ts tile]
    [while [< j TILE] [do
      [let col [car tile]]
      [= tile [cdr tile]]
      [poke 10 p col]
      [inc j]
      [inc p]
      [poke 10 p col]
      [inc j]
      [inc p]
    ]]
    [inc i]
    [= p [+ [* x TILE] [* [+ i [* y TILE]] 320]]]
    [= j 0]
    [= tile ts]
    [while [< j TILE] [do
      [let col [car tile]]
      [= tile [cdr tile]]
      [poke 10 p col]
      [inc j]
      [inc p]
      [poke 10 p col]
      [inc j]
      [inc p]
    ]]
    [inc i]
  ]]
]]

[defun draw-apple [] [do
  [draw-tile [car apple] [cdr apple] tile-apple]
]]

[defun draw-snake-body [before pos after] [do
  [draw-tile [car pos] [cdr pos] [if
    [is [car before] [car after]] tile-body-v
    [is [cdr before] [cdr after]] tile-body-h
    [and [is [car before] [- [car pos] 1]] [is [cdr after] [- [cdr pos] 1]]] tile-body-nw
    [and [is [car after] [- [car pos] 1]] [is [cdr before] [- [cdr pos] 1]]] tile-body-nw
    [and [is [car before] [- [car pos] 1]] [is [cdr after] [+ [cdr pos] 1]]] tile-body-sw
    [and [is [car after] [- [car pos] 1]] [is [cdr before] [+ [cdr pos] 1]]] tile-body-sw
    [and [is [car before] [+ [car pos] 1]] [is [cdr after] [- [cdr pos] 1]]] tile-body-ne
    [and [is [car after] [+ [car pos] 1]] [is [cdr before] [- [cdr pos] 1]]] tile-body-ne
    tile-body-se
  ]]
]]

[defun draw-snake-head [p] [do
  [draw-tile [car p] [cdr p] [if 
    [is direction-id 0] tile-head-left 
    [is direction-id 1] tile-head-down 
    [is direction-id 2] tile-head-right 
                        tile-head-up]]
]]

[defun draw-snake-tail [before pos] [do
  [draw-tile [car pos] [cdr pos] [if 
    [is [car before] [- [car pos] 1]] tile-tail-left
    [is [car before] [+ [car pos] 1]] tile-tail-right
    [is [cdr before] [- [cdr pos] 1]] tile-tail-up
    tile-tail-down
  ]]
]]

[defun draw-background-piece [p] [do
  [draw-tile [car p] [cdr p] tile-background]
]]

[defun draw-background [] [do
  [let i 0]
  [while [< i GRID_X] [do
    [let j 0]
    [while [< j GRID_Y] [do
      [draw-background-piece [cons i j]]
      [inc j]
    ]]
    [inc i]
  ]]
]]

[defun move-apple [] [do
  [= apple [cons [mod [random] GRID_X] [mod [random] GRID_Y]]]
  [inc score]
]]

[defun wrap [x y] [if [< x 0] -1 [is x y] -1 x]]

[defun move-snake [] [do
  [let head [car snake]]
  [let moved-head [cons [wrap [+ [car head] [car direction]] GRID_X] [wrap [+ [cdr head] [cdr direction]] GRID_Y]]]
  [= snake [cons moved-head snake]]
]]

[defun process-input [] [do
  [let x [last-scancode]]
  [if [is x 72] [do [= direction [cons 0 -1]] [= direction-id 3]] 0]
  [if [is x 77] [do [= direction [cons 1  0]] [= direction-id 2]] 0]
  [if [is x 80] [do [= direction [cons 0  1]] [= direction-id 1]] 0]
  [if [is x 75] [do [= direction [cons -1 0]] [= direction-id 0]] 0]
]]

[defun game-over [] [do 
  [if game-running [= game-running nil] 0]
]]

[defun check-collision [] [do
  [let s snake]
  [let head [car s]]
  [if [or [is [car head] -1] [is [cdr head] -1]] [game-over] 0]
  [while s [do 
    [let t [cdr s]]
    [while t [do
      [if [tile-overlap [car s] [car t]]
        [game-over] 0
      ]
      [= t [cdr t]]
    ]]
    [= s [cdr s]]
  ]]
]]

[defun show-score [] [do
  [draw-tile 9  4 [nth tile-digits [mod [/ score 100] 10]]]
  [draw-tile 10 4 [nth tile-digits [mod [/ score 10 ] 10]]]
  [draw-tile 11 4 [nth tile-digits [mod [/ score 1  ] 10]]]
]]

[defun set-color [i r g b] [do
  [outb 968 i]
  [outb 969 r]
  [outb 969 g]
  [outb 969 b]
]]

[defun set-palette [] [do
  [set-color 1 24 20 20]
  [set-color 2 30 25 26]
  [set-color 3 27 44 31]
  [set-color 4 32 48 31]
  [set-color 5 36 52 31]
  [set-color 6 12  7 11]
  [set-color 7 57 36 29]
  [set-color 8 44 23 20]
  [set-color 9 56 48 43]
]]

[defun before-last [x] [if [cdr [cdr x]] [before-last [cdr x]] x]]

[defun start-game [] [do
  [set-graphics 1]
  [set-palette]
  [= game-running 1]
  [= score 0]
  [= snake [list [q [8 . 5]] [q [7 . 5]] [q [6 . 5]] [q [5. 5]]]]
  [= direction [q [1 . 0]]]
  [= direction-id 2]
  [draw-background]
  [move-apple]
  [while game-running [do
    [let tail [last snake]]
    [draw-background-piece tail]
    [move-snake]
    [let head [car snake]]
    [let body [car [cdr snake]]]
    [let body-after [car [cdr [cdr snake]]]]
    [draw-snake-body head body body-after]
    [draw-snake-head head]
    [if [tile-overlap head apple] [move-apple] [del-last snake]]
    [let tail-before [before-last snake]]
    [draw-snake-tail [car tail-before] [car [cdr tail-before]]]
    [draw-apple]
    [process-input]
    [check-collision]
    [pause]
    [pause]
  ]]
  [show-score]
  [wait-key]
  [set-graphics nil]
  [print "Type [start-game] to play again!"]
]]

[start-game]
