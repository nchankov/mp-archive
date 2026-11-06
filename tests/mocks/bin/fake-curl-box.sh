#!/usr/bin/env bash
# fake-curl-box.sh - a fake curl for the offline tests of ticket 10.
# It makes no network call. It answers the Box token endpoint and GET /users/me.
# The test sets FC_DIR. The data files in FC_DIR are:
#   codes     lines "CODE ACCESS REFRESH"               (grant_type=authorization_code)
#   refresh   lines "REFRESH_TOKEN ACCESS NEW_REFRESH"  (grant_type=refresh_token)
#   users     lines "ACCESS USER_ID LOGIN AMOUNT USED"  (GET /users/me)
# An unknown value gives HTTP 400 at the token endpoint and HTTP 401 at the API.
# Each form body is copied to $FC_DIR/forms/NNN. The argv log holds no secret.
set -u

FC_DIR="${FC_DIR:?FC_DIR must be set}"

# Print the line of a data file whose first field is <key>. Return 1 when none.
# Args: <file> <key>
lookup() {
    local file="$1" key="$2"
    [[ -n "$key" && -f "$file" ]] || return 1
    awk -v k="$key" '$1 == k { print; found = 1; exit } END { exit !found }' "$file"
}

# Print the value of one field of the form body in $form.
# Args: <field name>
form_field() {
    printf '%s\n' "$form" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1
}

out="" prev="" a="" url="" hdr="" form="" n="" line="" tok="" grant=""
code=404
body='{"type":"error","code":"not_found"}'

# Read the arguments. Keep the header and the form in memory only.
for a in "$@"; do
    if [[ "$prev" == "-o" ]]; then
        out="$a"
    fi
    if [[ "$a" == @* ]]; then
        if [[ "$prev" == "-H" ]]; then
            # The Authorization header file. Read it, never log it.
            hdr="$(cat -- "${a#@}")"
        else
            # A form body. Copy it to the sandbox folder of the test.
            form="$(cat -- "${a#@}")"
            mkdir -p -- "$FC_DIR/forms"
            n="$(ls -1 "$FC_DIR/forms" | wc -l | tr -d ' ')"
            printf '%s' "$form" >"$FC_DIR/forms/$(printf '%03d' $((n + 1)))"
        fi
    fi
    prev="$a"
    url="$a"
done

# The argv log holds the arguments only. Secrets come through files and pipes.
printf '%s\n' "$*" >>"$FC_DIR/argv.log"

case "$url" in
    */oauth2/token)
        grant="$(form_field grant_type)"
        if [[ "$grant" == "authorization_code" ]]; then
            line="$(lookup "$FC_DIR/codes" "$(form_field code)")" || line=""
        else
            line="$(lookup "$FC_DIR/refresh" "$(form_field refresh_token)")" || line=""
        fi
        if [[ -n "$line" ]]; then
            read -r _key at nrt <<<"$line"
            code=200
            body="{\"access_token\":\"${at}\",\"expires_in\":3600,\"refresh_token\":\"${nrt}\",\"token_type\":\"bearer\"}"
        else
            code=400
            body='{"type":"error","error":"invalid_grant","error_description":"Invalid grant"}'
        fi
        ;;
    *users/me*)
        tok="${hdr#Authorization: Bearer }"
        line="$(lookup "$FC_DIR/users" "$tok")" || line=""
        if [[ -n "$line" ]]; then
            read -r _key uid login amount used <<<"$line"
            code=200
            body="{\"type\":\"user\",\"id\":\"${uid}\",\"login\":\"${login}\",\"space_amount\":${amount},\"space_used\":${used}}"
        else
            code=401
            body='{"type":"error","status":401,"code":"unauthorized"}'
        fi
        ;;
esac

if [[ -n "$out" ]]; then
    printf '%s' "$body" >"$out"
fi
printf '%s' "$code"
