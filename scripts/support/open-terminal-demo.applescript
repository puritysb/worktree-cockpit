on run argv
  set repoPath to item 1 of argv
  set sessionName to item 2 of argv
  set cmd to "cd " & quoted form of repoPath & "; printf '\\033]0;wtcp GUI demo\\007'; tmux attach -t " & quoted form of sessionName & "; exit"

  tell application "Terminal"
    activate
    do script cmd
    delay 0.8
    set bounds of front window to {80, 60, 1540, 940}
  end tell
end run
