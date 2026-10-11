#!/usr/bin/env bats
# Unit tests for the gitlab.rb path scan of the configuration archive discovery (#26 D).
# scan() is source-extracted from the in-container snippet, like deprecations.bats does with
# the script's helpers. It runs under dash and mawk in the container, here under the local awk.

setup() {
    load test_helper
    eval "$(sed -n "/^_CONFIG_DISCOVER_SH=\$(cat <<'EOF'/,/^EOF\$/p" "$PROJECT_ROOT/upgrade-gitlab" \
        | sed -n '/^scan() {/,/^}$/p')"
}

@test "scan: quoted absolute paths are reported with where they were found" {
    run scan gitlab.rb <<'EOF'
nginx['ssl_certificate'] = "/srv/certs/gitlab.crt"
gitlab_rails['ldap_servers'] = { 'main' => { 'ca_file' => '/srv/ldap/ca.pem', 'host' => 'ldap' } }
EOF
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = $'ref\t/srv/certs/gitlab.crt\tgitlab.rb:1' ]
    [ "${lines[1]}" = $'ref\t/srv/ldap/ca.pem\tgitlab.rb:2' ]
}

@test "scan: from_file targets are includes, comment lines and URLs are skipped" {
    run scan gitlab.rb <<'EOF'
external_url 'https://gitlab.example.com'
# gitlab_rails['smtp_ca_file'] = '/commented/out.pem'
from_file '/etc/gitlab/extra.rb'
from_file("/srv/conf/more.rb")
EOF
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = $'include\t/etc/gitlab/extra.rb\tgitlab.rb:3' ]
    [ "${lines[1]}" = $'include\t/srv/conf/more.rb\tgitlab.rb:4' ]
}

@test "scan: paths that cannot be resolved statically are named once per line" {
    run scan gitlab.rb <<'EOF'
gitlab_rails['smtp_ca_file'] = "/srv/#{ENV['X']}/ca.pem"
gitlab_rails['y'] = File.read('/srv/secret')
from_file ENV['EXTRA_RB']
nginx['ssl_certificate'] = ENV['CERT_PATH']
gitlab_rails['ldap_servers'] = { 'main' => { 'ca_file' => ENV['LDAP_CA'] } }
EOF
    [ "${#lines[@]}" -eq 5 ]
    [ "${lines[0]}" = $'warn\tgitlab.rb:1\tgitlab_rails[\'smtp_ca_file\'] = "/srv/#{ENV[\'X\']}/ca.pem"' ]
    [[ "${lines[1]}" == $'warn\tgitlab.rb:2\t'* ]]
    [[ "${lines[2]}" == $'warn\tgitlab.rb:3\t'* ]]
    [[ "${lines[3]}" == $'warn\tgitlab.rb:4\t'* ]]
    [[ "${lines[4]}" == $'warn\tgitlab.rb:5\t'* ]]          # inside a hash too
}

@test "scan: ENV for a password, secret or token is not reported" {
    run scan gitlab.rb <<'EOF'
gitlab_rails['db_password'] = ENV['DB_PASS']
gitlab_rails['secret_key_base'] = ENV['SKB']
gitlab_rails['initial_shared_runners_registration_token'] = ENV['TOKEN']
EOF
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
