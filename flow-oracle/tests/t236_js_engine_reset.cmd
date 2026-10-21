# WP12: a JavaScript block error drops the engine (m_JintEngine = null, Script.cs:1792-1795 R): the
# js_arrays functions are gone at the scripterror label; a single-line if skips a block AND the next row.
include js_arrays.js
js doPush("a", "x")
echo a=%a
if 0 then
<%
setVar("s", "1")
%>
echo after-if s=%s
if 1 then
<%
setVar("s2", "1")
%>
echo after-if2 s2=%s2
<%
nosuch()
%>
echo not
scripterror:
js doPush("a", "y")
echo a2=%a
