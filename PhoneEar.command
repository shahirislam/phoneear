#!/bin/zsh
cd "$(dirname "$0")"
[[ -x bin/phoneear && bin/phoneear -nt Sources/main.swift ]] || ./build.sh
exec ./bin/phoneear "$@"
