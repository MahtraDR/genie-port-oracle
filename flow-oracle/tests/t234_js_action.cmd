# WP12: js in action bodies -- $1 goes into the JavaScript text with its quotes removed.
include js_arrays.js
action js doPush("pouch","$1") when ^Your (\S+) pouch
action js setVar("cap", "$1") when ^Back (.*)$
action js buildArray("items", "$1") when ^You see (.*)\.$
put look
pause 2
echo pouch=%pouch cap=%cap items=%items
