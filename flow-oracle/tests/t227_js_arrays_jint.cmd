# WP12 (G53, D4): the DR-Genie-Scripts JS_Arrays/js_arrays.js copy under Remix's Jint 4.
include js_arrays.js
var a x|y
jscall r i
echo i-before [%r]
js doPush("arr", "One")
js doPush("arr", "Two")
echo push %arr
js doPush("arr", "%a")
js doPush("arr", "%nosuch")
js doPush("arr", "$roomid")
js doPush("arr", 5)
js doPush("arr", true)
js doPush("arr", 1.5e3)
echo push2 %arr
var e
js doPush("e", "w")
echo pushempty [%e]
js doPush("e2", "")
echo pushblank [%e2]
js doUnshift("u", "Three")
js doUnshift("u", "Two")
echo unshift %u
var f
js doUnshift("f", "q")
echo unshiftempty [%f]
js doConcat("arr", "p|q")
js doConcat("nov", 12)
echo concat %arr / %nov
var h a|b|c
js doReplace("h", "5", "z")
echo rep1 %h
var h a|b|c
js doReplace("h", "-1", "z")
js doReplace("h", "01", "z")
js doReplace("h", "foo", "z")
echo rep2 %h
js doReplace("h", 1, 7)
js doReplace("h", 2.0, 0.5)
echo rep3 %h
js doReplace("h", "%idx", "%a")
var idx 0
js doReplace("h", "%idx", "%a")
echo rep4 %h
js doReplace("h", "length", "2")
echo rep5 %h
js doReplace("h", "length", "4")
echo rep6 [%h]
js doReplace("h", "length", "x")
js doReplace("h", "length", "-1")
echo rep7 [%h]
js doSort("s", "1")
echo sort-string %s
var t b|a
js doSort("t", "0")
echo sort-string2 %t
js doSort("t", 0)
js doSort("t", 1)
js doSort("t", -0)
echo sort %t
jscall r i
echo i-after-sort [%r]
jscall r findIndex("t", "a")
echo fi [%r]
jscall r checkExists("t", "%a")
jscall r doInsert("t", "x", 1)
jscall r doRemove("t", "a", 1)
jscall r doXCompare("t", "t", "$roomid")
jscall r doPop("t")
jscall r doShift("t")
jscall r buildArrayStr("b", "a foo, a bar", "foo")
jscall r buildArrayStr("b", "a foo", "%a")
echo after-throws %t [%r]
jscall r findMax("t")
jscall r i
echo i-findmax [%r]
jscall r findMin("t")
jscall r findMaxIndex("t")
jscall r findMinIndex("t")
jscall r findMaxGlobal("t")
jscall r findMinGlobal("t")
jscall r i
echo i-global [%r]
jscall r j
echo j-before [%r]
jscall r zipArrays("t", "arr")
jscall r j
echo j-after [%r]
js buildArray("ba", "a foo, an bar and some baz, an apple and a pie")
echo ba %ba
js buildArray("ba2", "")
echo ba2 [%ba2]
js buildArray("ba3", 42)
echo ba3 %ba3
js doPush("arr")
js doPush("arr", null)
js doConcat("arr")
js buildArray("ba")
js buildArrayStr("ba", "x")
js buildArrayStr("ba", "x", "$y")
js findIndex("t")
js doInsert("t")
js doReplace("t", "1")
js doReplace("t")
echo unchanged %arr / %ba / %t
jscall r doPush("arr", "t")
echo res [%r] %arr
jscall r doSort("nos", 2)
echo res2 [%r] [%nos]
