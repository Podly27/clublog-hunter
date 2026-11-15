#!/bin/zsh
app="${0:A:h}/ClubLog Hunter.app"
if [[ ! -d "$app" ]]; then
    app="${0:A:h}/build/ClubLog Hunter.app"
fi
exec /usr/bin/open "$app"
