declare-option -docstring %{
    shell command to which the path of a copy of the current buffer will be 
    passed The output returned by this command is expected to be a stream of 
    JSON objects with the following fields: "file", "start_line", "start_col", 
    "end_line", "end_col", "kind", "msg", and optionally "fix". If present, 
    "fix" should be an array of objects which each have the fields "start", 
    "length", and "text"
} str flintcmd

declare-option -docstring %{
    color of the error marker in the gutter
} str flint_error_face red

declare-option -docstring %{
    color of the warning marker in the gutter
} str flint_warning_face yellow

declare-option -hidden line-specs flint_flags
declare-option -hidden range-specs flint_errors
declare-option -hidden str-list flint_messages
declare-option -hidden str-list flint_fixes
declare-option -hidden range-specs flint_fix
declare-option -hidden int flint_last_run_timestamp
declare-option -hidden int flint_error_count
declare-option -hidden int flint_warning_count

declare-option str flint_python3 python3

define-command flint -docstring 'Parse the current buffer with a linter' %{
    evaluate-commands %sh{
        if [ -z "${kak_opt_flintcmd}" ]; then
            printf %s\\n 'echo -markup {Error}The `flintcmd` option is not set'
            exit 1
        fi

        extension=""
        if printf %s "${kak_buffile}" | grep -qE '[^/.]\.[[:alnum:]]+$'; then
            extension=".${kak_buffile##*.}"
        fi

        dir=$(mktemp -d "${TMPDIR:-/tmp}"/kak-flint.XXXXXXXX)
        printf '%s\n' \
            "evaluate-commands -no-hooks write -sync $dir/buf${extension}"

        { # do the parsing in the background and when ready send to the session

        eval "$kak_opt_flintcmd '$dir'/buf${extension}" \
            | jq '[.,inputs] | sort_by(.start_line)' > "$dir"/stderr

        jq --raw-output \
        --arg file "$kak_buffile" --arg stamp "$kak_timestamp" \
        --arg client "$kak_client" --arg errface "$kak_opt_flint_error_face" \
        --arg warnface "$kak_opt_flint_warning_face" '
            def kakquote(s): s | "'\''\(gsub("'\''"; "'\'\''"))'\''";
            {
                "errors":
                    map(.kind | select(test("error|fatal"; "i"))) | length,
                "warnings":
                    map(.kind | select(test("error|fatal"; "i") | not))
                    | length,
                "error_lines":
                    [ .[]
                        | select(.kind | test("error|fatal"; "i"))
                        | range(.start_line; .end_line + 1) ]
                    | sort | unique,
                "warning_lines":
                    [ .[]
                        | select(.kind | test("error|fatal"; "i") | not)
                        | range(.start_line; .end_line + 1) ]
                    | sort | unique,
                "lint":
                    . | to_entries
                    | map(.value.key = .key | .value)
                    | sort_by(.key)
            } | "
                set-option \"buffer=\($file)\" flint_flags \($stamp) \(
                    .error_lines | map("\(.)|{\($errface)}█") | join(" ")
                ) \(
                    .warning_lines | map("\(.)|{\($warnface)}█") | join(" ")
                )
                set-option \"buffer=\($file)\" flint_error_count \(.errors)
                set-option \"buffer=\($file)\" flint_warning_count \(.warnings)
                set-option \"buffer=\($file)\" flint_messages \(
                    .lint | map(kakquote("\(.msg)\(
                        if .fix then
                            " [quickfix available]"
                        else
                            ""
                        end
                    )")) | join(" ")
                )
                set-option \"buffer=\($file)\" flint_fixes \(
                    .lint | map(
                        if .fix then
                            kakquote(.fix | tojson)
                        else
                            "NOFIX"
                        end
                    ) | join(" ")
                )
                set-option \"buffer=\($file)\" flint_errors \($stamp) \(
                    .lint | map(
                        "\(.start_line).\(.start_col),"
                        + "\(.end_line).\(.end_col)|"
                        + "\(.key)"
                    ) | join(" ")
                )
                set-option \"buffer=\($file)\" flint_last_run_timestamp \($stamp)
            "
        ' < "$dir"/stderr > "$dir"/flint

        (
            [ "$(stat -c%s "$dir"/flint)" -le 2 ] && printf %s "
                evaluate-commands -buffer '$kak_buffile' %{
                    set-option buffer flint_flags $kak_timestamp
                    set-option buffer flint_error_count 0 
                    set-option buffer flint_warning_count 0
                    set-option buffer flint_messages $kak_timestamp
                    set-option buffer flint_fixes
                    set-option buffer flint_errors
                }
            "
            cat "$dir"/flint
        ) | kak -p "$kak_session"

        rm -r "$dir"

        } >/dev/null 2>/dev/null </dev/null &
    }
}

define-command -hidden flint-show %{
    update-option buffer flint_errors
    evaluate-commands %sh{
        kakquote() { sed "s/'/''/g;1s/^/'/;\$s/\$/'/" ; }

        printf 'info -anchor %d.%d ' "$kak_cursor_line" "$kak_cursor_column"

        eval "set -- $kak_opt_flint_messages"

        line="$kak_cursor_line" "$kak_opt_flint_python3" -c "

import sys
import os
import re

flint_errors = sys.argv[2:]
line = os.environ['line']

errpat = re.compile(r\"^'(\d+).\d+,(\d+).\d+\|(\d+)'$\")

for err in flint_errors:
    match = errpat.match(err)
    if match == None: continue
    start, end = match.group(1), match.group(2)
    key = match.group(3)
    if start <= line <= end:
        print(int(key) + 1)

        " $kak_opt_flint_errors | while read -r key; do
            printf '%s ' "$(eval "echo \$$key" | kakquote)"
        done

        printf '\n'
    }
}

define-command -docstring %{
    Apply a quick-fix provided by the linter
} flint-fix %{
    update-option buffer flint_errors
    evaluate-commands %sh{
        kakquote() { sed "s/'/''/g;1s/^/'/;\$s/\$/'/" ; }

        printf 'menu -auto-single '

        line="$kak_cursor_line" "$kak_opt_flint_python3" -c "

import sys
import os
import re

flint_errors = sys.argv[2:]
line = os.environ['line']

errpat = re.compile(r\"^'(\d+).\d+,(\d+).\d+\|(\d+)'$\")

for err in flint_errors:
    match = errpat.match(err)
    if match == None: continue
    start_line, end_line = match.group(1), match.group(2)
    key = match.group(3)
    if start_line <= line <= end_line:
        print(int(key) + 1)

        " $kak_opt_flint_errors | while read -r key; do
            eval "set -- $kak_opt_flint_messages"
            msg="$(eval "printf '%s\n' \"\$$key\"" | head -c-22 | kakquote)"
            eval "set -- $kak_opt_flint_fixes"
            fix="$(eval "printf '%s\n' \"\$$key\"")"

            [ "$fix" = "NOFIX" ] && continue

            stamp=$kak_opt_flint_last_run_timestamp

            printf "\\
                %s %%{ evaluate-commands -draft %%{
                    set-option buffer flint_fix $stamp
            " "$msg"

            # Note: this approach breaks if the selection generated at lint-time
            # exceeds the bounds of the buffer at fix-time.
            printf '%s\n' "$fix" | jq --raw-output '
                def kakquote(s): s | "\"\(gsub("\""; "\"\""))\"";
                def kakescape(s):
                    s | gsub("%"; "%%") | gsub("#"; "##") | gsub("\n"; "#n")
                    | gsub("\\|"; "#b");
                to_entries | .[] | .value.key = .key + 1 | .value | "
                    execute-keys gg \\
                        \(if .start == 0 then "" else "\(.start)l" end) \\
                        \(if .length >= 1 then "\(.length - 1)L" else "" end)
                    set-option -add buffer flint_fix \\
                        \(kakquote("%val{selection_desc}|\(
                            .key
                        ),\(
                            kakescape(.text)
                        )"))
                "
            '

            printf '
                    flint-apply-fix
                } } \
            '
        done

        printf '\n'
    }
}

define-command -hidden flint-apply-fix %{
    echo -debug BEFORE %sh{ echo "$kak_opt_flint_fix" }
    update-option buffer flint_fix
    echo -debug AFTER %sh{ echo "$kak_opt_flint_fix" }
    evaluate-commands -draft -save-regs '1|"' %sh{
        kakquote() { sed "s/'/''/g;1s/^/'/;\$s/\$/'/" ; }
        quote() { sed "s/'/'\\\\''/g;1s/^/'/;\$s/\$/'/" ; }

        unescape() {
            eval "local str=\"\$$1\""
            eval "$1=$(printf '%s\n' "$str" | sed 's/##/#/g;s/#b/|/g;s/#n/\n/g' | quote)"
        }
        
        compile() {
            local start=$1
            local end=$2
            local fix="$3"

            printf 'select %s\n' "${start},${end}"
            printf 'set-register 1 %s\n' "$(printf %s\\n "$fix" | kakquote)"

            if [ $start = $end ]; then
                printf 'execute-keys \\"1P\n'
            else
                printf 'execute-keys \\"1P d\n'
            fi
        }


        eval "set -- $kak_opt_flint_fix"
        shift

        for step in "$@"; do
            sel="$(printf '%s\n' "$step" | cut -d '|' -f 1)"
            start="$(echo $sel | cut -d ',' -f 1)"
            end="$(echo $sel | cut -d ',' -f 2)"
            payload="$(printf '%s\n' "$step" | cut -d '|' -f 2-)"
            key="$(printf '%s\n' "$payload" | cut -d ',' -f 1)"
            fix="$(printf '%s\n' "$payload" | cut -d ',' -f 2-)"
            unescape fix
            eval "step${key}=$(compile "$start" "$end" "$fix" | quote)"
        done

        for i in $(seq $#); do
            eval 'step="$step'"$i"'"'
            printf '%s\n' "$step"
        done
    }
}

define-command -docstring %{
    Activate automatic diagnostics of the code
} flint-enable %{
    flint-disable
    add-highlighter window/flint flag-lines default flint_flags
    hook window -group flint-diagnostics NormalIdle .* %{
        flint-show
    }
    hook window -group flint-diagnostics WinSetOption flint_flags=.* %{
        info
        flint-show
    }
}

define-command -docstring %{
    Disable automatic diagnostics of the code
} flint-disable %{
    remove-highlighter window/flint
    remove-hooks window flint-diagnostics
}

define-command -docstring %{
    Jump to the next line that contains an error
} flint-next-error %{
    update-option buffer flint_errors

    evaluate-commands %sh{
        eval "set -- ${kak_opt_flint_errors}"
        shift

        for i in "$@"; do
            candidate="${i%%|*}"
            if [ "${candidate%%.*}" -gt "${kak_cursor_line}" ]; then
                range="${candidate}"
                break
            fi
        done

        range="${range-${1%%|*}}"
        if [ -n "${range}" ]; then
            printf 'select %s\n' "${range}"
        else
            printf 'echo -markup "{Error}no lint diagnostics"\n'
        fi
    }
}

define-command -docstring %{
    Jump to the previous line that contains an error
} flint-previous-error %{
    update-option buffer flint_errors

    evaluate-commands %sh{
        eval "set -- ${kak_opt_flint_errors}"
        shift

        for i in "$@"; do
            candidate="${i%%|*}"

            if [ "${candidate%%.*}" -ge "${kak_cursor_line}" ]; then
                range="${last_candidate}"
                break
            fi

            last_candidate="${candidate}"
        done

        if [ $# -ge 1 ]; then
            shift $(($# - 1))
            range="${range:-${1%%|*}}"
            printf 'select %s\n' "${range}"
        else
            printf 'echo -markup "{Error}no lint diagnostics"\n'
        fi
    }
}

