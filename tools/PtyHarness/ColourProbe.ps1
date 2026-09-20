# Test fixture: draws a screen with known colours and attributes, so a test can assert that they
# survive the trip through the pseudo console and the emulator.
#
# Row 0 is plain, row 1 mixes a palette colour with 24-bit RGB and bold, row 2 uses inverse and a
# background colour. Nothing here depends on the terminal's own palette beyond entries 1 and 4.
param([int] $HoldSeconds = 60)

$escape = [char] 27
[Console]::Write("plain`r`n")
[Console]::Write("$escape[31mred$escape[0m and $escape[1;38;2;0;128;255mbold-rgb$escape[0m`r`n")
[Console]::Write("$escape[7minverse$escape[0m$escape[44m bg $escape[0m`r`n")
[Console]::Write("$escape[4munderline$escape[0m`r`n")
# A marker the test can wait for: once this is on screen, everything above it has been drawn.
[Console]::Write('READY')
Start-Sleep -Seconds $HoldSeconds
