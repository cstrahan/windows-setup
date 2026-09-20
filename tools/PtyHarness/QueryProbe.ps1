# Test fixture: asks the terminal a question and prints the answer it gets back, so a test can
# assert that queries are answered rather than swallowed.
#
# Primary device attributes (ESC [ c) is the simplest one: a terminal replies with what it is,
# e.g. ESC [ ? 62 ; 22 c for a VT220 with ANSI colour.
param([int] $WaitMilliseconds = 500)

$escape = [char] 27
[Console]::Write("$escape[c")
Start-Sleep -Milliseconds $WaitMilliseconds

$answer = ''
while ([Console]::KeyAvailable) { $answer += [Console]::ReadKey($true).KeyChar }
# Printed with the escape spelled out, so it survives being read off a rendered screen.
[Console]::Write('ANSWER:' + ($answer -replace [regex]::Escape($escape), '<ESC>') + ':END')
Start-Sleep -Seconds 30
