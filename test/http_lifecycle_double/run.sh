#!/bin/sh
# Run from the repository root; never load doubles into a native-runtime VM.
set -eu
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT HUP INT TERM
for file in test/http_lifecycle_double/*.erl.stub; do
    name=${file##*/}
    cp "$file" "$out/${name%.stub}"
done
erlc -Werror +export_all -o "$out" src/hornbeam_asgi.erl
erlc -Werror -o "$out" "$out"/*.erl
erl -noshell -pa "$out" -eval \
    'case eunit:test(hornbeam_http_lifecycle_tests, [verbose]) of ok -> halt(0); _ -> halt(1) end.'
