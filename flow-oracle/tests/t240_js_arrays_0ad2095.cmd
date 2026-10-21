# WP12-r1 N2: js_arrays.js version 0ad2095 (DR-Genie-Scripts blob; lab-only, GPLv3) under Jint 4 -- every function once.
include _js_arrays_0ad2095.js
var a x
var b y|z
var pv $foo
var dv %a
var e
var one 1
js doPush("a", "y")
echo p1 [%a]
js doPush("a", "%b")
echo p2 [%a]
js doPush("a", "$roomid")
echo p3 [%a]
js doPush("a", "%pv")
echo p4 [%a]
js doPush("e", "q")
echo p5 [%e]
js doPush("a", "%dv")
echo p6 [%a]
js doPush("a", "%nosuch")
echo p7 [%a]
var e
js doUnshift("e", "r")
echo u1 [%e]
js doUnshift("b", "%pv")
echo u2 [%b]
js doUnshift("b", "$roomid")
echo u3 [%b]
js doUnshift("nu", "s")
echo u4 [%nu]
jscall r doPop("a")
echo o1 [%r]
jscall r doShift("a")
echo o2 [%r]
jscall r doPop()
echo o3 [%r]
js doReplace("b", "0", "%pv")
echo r1 [%b]
js doReplace("b", "%one", "w")
echo r2 [%b]
jscall r zipArrays("a", "b")
echo z1 [%r]
jscall r findIndex("a", "%pv")
echo f1 [%r]
jscall r findIndex("a")
echo f2 [%r]
jscall r checkExists("a", "$x")
echo f3 [%r]
jscall r doRemove("a", "y", 1)
echo f4 [%r] [%a]
jscall r doRemove("a")
echo f5 [%r]
jscall r doXCompare("a", "b", "$x")
echo f6 [%r]
jscall r doXCompare("a", "b")
echo f7 [%r]
jscall r doInsert("a", "x", 1)
echo f8 [%r]
js doConcat("a", "m|n")
echo c1 [%a]
js doConcat("cc", 12)
echo c2 [%cc]
js buildArray("ba", "a foo, an bar and some baz, an apple and a pie")
echo ba1 [%ba]
js buildArray("ba", "a foo and a bar")
echo ba2 [%ba]
jscall r buildArrayStr("bs", "a foo", "$x")
echo bs1 [%r] [%bs]
jscall r buildArrayStr("bs", "a foo", "%pv")
echo bs2 [%r]
jscall r buildArrayStr("bs", "a foo")
echo bs3 [%r]
js doSort("a", 0)
echo s1 [%a]
js doSort("a", 2)
echo s2 [%a]
jscall r findMax("a")
echo m1 [%r]
jscall r i
echo m2 [%r]
jscall r findMinGlobal("a")
echo m3 [%r]
jscall r i
echo m4 [%r]
jscall r findMin("a")
jscall r findMaxIndex("a")
jscall r findMinIndex("a")
jscall r findMaxGlobal("a")
jscall r j
echo m5 [%r]
echo end
