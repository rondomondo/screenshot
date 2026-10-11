alias gmod="git status | tac | grep modified | cut -f2 -d':' | tr '\n' ' '"
alias c=clear

export LS_OPTIONS='--color=auto'
eval "$(dircolors)"
alias ls='ls $LS_OPTIONS'
alias l='ls $LS_OPTIONS -lA'
alias ll='ls $LS_OPTIONS -lrta'

alias pwcli='/app/node_modules/playwright-core/cli.js'
alias chromiumcli='/app/node_modules/playwright-chromium/cli.js'
