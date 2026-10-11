#!/usr/bin/env bats
# Unit tests for UPGRADE_GITLAB_CONFIG_RECIPIENT parsing (#32): the recipient's form picks the tool.
# _parse_config_recipient is source-extracted, like config_discovery.bats does with scan().

setup() {
    load test_helper
    eval "$(sed -n '/^_parse_config_recipient() {/,/^}$/p' "$PROJECT_ROOT/upgrade-gitlab")"
    dir=$(mktemp -d)
}

teardown() {
    rm -rf "$dir"
}

@test "recipient: unset means no encryption" {
    _parse_config_recipient ""
    [ -z "$_recipient_tool" ]
    [ ${#_recipient_args[@]} -eq 0 ]
}

@test "recipient: an age1 string is one age recipient" {
    _parse_config_recipient age1abc
    [ "$_recipient_tool" = age ]
    [ "${_recipient_args[*]}" = "-r age1abc" ]
}

@test "recipient: a file of age recipients passes each one, comments and blank lines skipped" {
    printf '# backup keys\n  age1first  # laptop\n\nssh-ed25519 AAAAC3Nza key@host\n' > "$dir/r.txt"
    _parse_config_recipient "$dir/r.txt"
    [ "$_recipient_tool" = age ]
    [ ${#_recipient_args[@]} -eq 4 ]
    [ "${_recipient_args[1]}" = age1first ]
    [ "${_recipient_args[3]}" = "ssh-ed25519 AAAAC3Nza key@host" ]
}

@test "recipient: an armored PGP public key file uses gpg" {
    printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nmDMEZ...\n-----END PGP PUBLIC KEY BLOCK-----\n' > "$dir/k.asc"
    _parse_config_recipient "$dir/k.asc"
    [ "$_recipient_tool" = gpg ]
}

@test "recipient: anything else is an error" {
    printf 'age1ok\nnot-a-key\n' > "$dir/mixed.txt"
    run _parse_config_recipient "$dir/mixed.txt"
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be an age recipient"* ]]
    run _parse_config_recipient "$dir/missing.txt"
    [ "$status" -eq 1 ]
    run _parse_config_recipient "AGE1UPPER"
    [ "$status" -eq 1 ]
}
