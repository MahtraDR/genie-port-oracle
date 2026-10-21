# WP12 (G53, D4): the Miner / mm_train js_arrays.js copy (no doReplace) under Remix's Jint 4.
include _js_arrays_miner.js
var h a|b|c
js doReplace("h", "1", "z")
jscall r doReplace("h", "1", "z")
echo rep %h [%r]
js doPush("h", "d")
echo push %h
jscall r checkExists("h", "a")
echo ce [%r]
jscall r doXCompare("h", "h", "%size")
echo xc [%r]
jscall r zipArrays("h", "h")
echo zip [%r]
js doConcat("h", "e|f")
echo concat %h
