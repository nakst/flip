[let defun [mac [name args body] 
  [list let name nil] 
  [list = name [list fun args body]]]]

[defun square [x] [* x x]]

[let inc [mac [s] [list [q =] s [list [q +] s 1]]]]

[defun to-upper [str] [capture-upper [print str]]]
[defun to-lower [str] [capture-lower [print str]]]

[defun last [x] [if [cdr x] [last [cdr x]] [car x]]]
[defun del-last [x] [if [cdr [cdr x]] [del-last [cdr x]] [setcdr x nil]]]

[defun nth [a n] [if [is n 0] [car a] [nth [cdr a] [- n 1]]]]
