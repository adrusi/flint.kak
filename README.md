# Flint.kak

**Flint probably has bugs**

Flint improves upon the lint.kak functionality distributed with
[Kakoune](https://kakoune.org). In particular, it adds support for applying
automatic fixes suggested by the linter. The name comes from "**f**ix **lint**".

Flint has been designed with [tslint](https://palantir.github.io/tslint/) in
mind. Its design might not be ideally suited for other linters which provide
automatic fixes. However, its interface is flexible, and a small wrapper around
other linting tools should be sufficient to make them compatible.

## Requirements

Flint expects the JSON manipulation tool [jq](https://stedolan.github.io/jq/)
to be present on your machine. It also needs Python 3.x.

## Installation

Drop fzf.kak in your autoload directory or use 
[plug.kak](https://github.com/andreyorst/plug.kak):

```kak
plug "adrusi/flint.kak"
```

## Configuration

A typical flint configuration looks like this:

```kak
hook global WinSetOption filetype=typescript %{
    set-option window flintcmd "kak-tslint"
    flint-enable
    map global user f ": flint-fix<ret>"
}
```

The only required configuration option is `flintcmd` which tells flint which 
linter to run. Linters must be wrapped to speak flint's language. This is
straightforward with jq. I have a shell script called `kak-tsflint` in my path
which looks like this:

```sh
#!/bin/sh
npx tslint --config tslint.json --format json "$@" | jq '
    map({
        "file": .name,
        "start_line": (.startPosition.line + 1),
        "end_line": (.endPosition.line + 1),
        "start_col": (.startPosition.character + 1),
        "end_col": (.endPosition.character + 1),
        "kind": .ruleSeverity,
        "msg": .failure,
        "fix": (if .fix then (.fix | map({
            "start": .innerStart,
            "length": .innerLength,
            "text": .innerText
        })) else null end)
    }) | .[]
'
```

That's all that's needed to use flint.

If your Python 3 executable is named something other than `python3`, tell flint
about that:

```kak
set-option global flint_python3 my_python
```

And if you want to customize the colors that appear in the gutter and
and statusline, you can configure `flint_error_face` and `flint_warning_face`.
